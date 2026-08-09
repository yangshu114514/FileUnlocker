"""进程强杀三层兜底:

  1. taskkill /F /PID           (普通权限, 同会话)
  2. ShellExecuteEx "runas"     (UAC 提权后再 taskkill)
  3. SCHTASKS 计划任务 SYSTEM    (SYSTEM 完整性级别,最终手段)

每层失败才往下一层走;每层的结果都以 (成功?, 描述) 二元组返回。
"""
from __future__ import annotations

import ctypes
import logging
import os
import subprocess
import tempfile
import time
import uuid
from pathlib import Path
from typing import Tuple

log = logging.getLogger(__name__)


# ---------- 第一级: 普通 taskkill ----------
def taskkill(pid: int, tree: bool = False) -> Tuple[bool, str]:
    """用 taskkill 强制结束进程。

    Args:
        pid: 进程 ID
        tree: True 时同时杀掉子进程(/T)

    Returns:
        (是否成功, 描述文本)
    """
    args = ["taskkill", "/F", "/PID", str(pid)]
    if tree:
        args.append("/T")
    # taskkill 输出是 GBK(936) 编码,必须用 mbcs 解码,否则中文转 \ufffd
    for attempt in ("mbcs", "utf-8", "latin-1"):
        try:
            r = subprocess.run(
                args,
                capture_output=True, text=True,
                timeout=10, encoding=attempt, errors="replace",
            )
            break
        except Exception:
            continue
    try:
        if r.returncode == 0:
            return True, (r.stdout or "taskkill 成功").strip()
        return False, (r.stderr or r.stdout or f"退出码 {r.returncode}").strip()
    except UnboundLocalError:
        return False, "taskkill 调用失败"


# ---------- 第二级: 提权/UAC ----------
def is_admin() -> bool:
    """当前进程是否已经有管理员权限。"""
    try:
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception as e:
        log.debug("IsUserAnAdmin 异常: %s", e)
        return False


def elevate_and_reopen_self(extra_args: list[str] | None = None) -> Tuple[bool, str]:
    """通过 ShellExecuteEx "runas" 提权重启自身。

    Args:
        extra_args: 追加的命令行参数

    Returns:
        (是否成功拉起提权进程, 描述文本)
    """
    if is_admin():
        return True, "已是管理员"

    exe = os.sys.executable
    args_str = " ".join(f'"{a}"' for a in (extra_args or []))

    SEE_MASK_NOCLOSEPROCESS = 0x00000040
    SW_HIDE = 0

    class SHELLEXECUTEINFOW(ctypes.Structure):
        _fields_ = [
            ("cbSize", ctypes.wintypes.DWORD),
            ("fMask", ctypes.wintypes.ULONG),
            ("hwnd", ctypes.wintypes.HWND),
            ("lpVerb", ctypes.wintypes.LPCWSTR),
            ("lpFile", ctypes.wintypes.LPCWSTR),
            ("lpParameters", ctypes.wintypes.LPCWSTR),
            ("lpDirectory", ctypes.wintypes.LPCWSTR),
            ("nShow", ctypes.c_int),
            ("hInstApp", ctypes.wintypes.HINSTANCE),
            ("lpIDList", ctypes.c_void_p),
            ("lpClass", ctypes.wintypes.LPCWSTR),
            ("hkeyClass", ctypes.wintypes.HKEY),
            ("dwHotKey", ctypes.wintypes.DWORD),
            ("hMonitor_or_hIcon", ctypes.wintypes.HANDLE),
            ("hProcess", ctypes.wintypes.HANDLE),
        ]

    sei = SHELLEXECUTEINFOW()
    sei.cbSize = ctypes.sizeof(SHELLEXECUTEINFOW)
    sei.fMask = SEE_MASK_NOCLOSEPROCESS
    sei.hwnd = None
    sei.lpVerb = "runas"
    sei.lpFile = exe
    sei.lpParameters = args_str
    sei.lpDirectory = os.path.dirname(exe)
    sei.nShow = SW_HIDE

    ok = ctypes.windll.shell32.ShellExecuteExW(ctypes.byref(sei))
    if not ok:
        err = ctypes.get_last_error()
        if err == 1223:  # ERROR_CANCELLED,用户点了【否】
            return False, "用户拒绝 UAC 提权"
        return False, f"ShellExecuteExW 失败,错误码 {err}"

    ctypes.windll.kernel32.WaitForSingleObject(sei.hProcess, 30_000)  # 最多等30秒
    ctypes.windll.kernel32.CloseHandle(sei.hProcess)
    return True, "提权进程已执行"


# ---------- 第三级: SYSTEM(计划任务) ----------
def system_kill(pid: int, tree: bool = False) -> Tuple[bool, str]:
    """用 SCHTASKS 在 SYSTEM 完整性级别 taskkill。

    Args:
        pid: 进程 ID
        tree: 是否杀整棵进程树

    Returns:
        (是否成功, 描述文本)
    """
    task_name = f"FileUnlocker_SYS_{uuid.uuid4().hex[:8]}"
    kill_args = f"/F /PID {pid}" + (" /T" if tree else "")
    create_cmd = [
        "schtasks", "/Create",
        "/TN", task_name,
        "/SC", "ONCE",
        "/ST", "00:00",
        "/RU", "SYSTEM",
        "/RL", "HIGHEST",
        "/F",
        "/TR", f"taskkill {kill_args}",
    ]
    try:
        r1 = subprocess.run(
            create_cmd, capture_output=True, text=True,
            timeout=15, encoding="utf-8", errors="replace",
        )
        if r1.returncode != 0:
            return False, f"创建 SYSTEM 计划任务失败: {r1.stderr.strip()}"

        run_cmd = ["schtasks", "/Run", "/TN", task_name]
        r2 = subprocess.run(
            run_cmd, capture_output=True, text=True,
            timeout=15, encoding="utf-8", errors="replace",
        )
        # 等待真正执行完(异步)
        time.sleep(1.0)

        # 验证进程是否消失
        check = subprocess.run(
            ["tasklist", "/FI", f"PID eq {pid}"],
            capture_output=True, text=True, timeout=10,
            encoding="utf-8", errors="replace",
        )
        still_alive = str(pid) in check.stdout and "No tasks" not in check.stdout
        if still_alive:
            return False, "SYSTEM 计划任务执行后进程仍存在"

        return True, "SYSTEM taskkill 完成"
    except subprocess.TimeoutExpired:
        return False, "SYSTEM 计划任务操作超时"
    except Exception as e:
        return False, f"SYSTEM 计划任务异常: {e}"
    finally:
        try:
            subprocess.run(
                ["schtasks", "/Delete", "/TN", task_name, "/F"],
                capture_output=True, timeout=10,
                encoding="utf-8", errors="replace",
            )
        except Exception:
            pass


# ---------- 调度器: 一层层试 ----------
def kill_with_fallback(pid: int, tree: bool = False) -> Tuple[bool, str, str]:
    """三层兜底强杀。

    Returns:
        (是否成功, 所用层级, 描述文本)
    """
    log.info("开始强杀 PID=%d tree=%s", pid, tree)

    ok, msg = taskkill(pid, tree=tree)
    if ok:
        return True, "normal", msg
    log.info("普通 taskkill 失败: %s,尝试提权", msg)

    if is_admin():
        # 已是管理员,跳过 UAC,直接进 SYSTEM
        log.info("已是管理员,直接尝试 SYSTEM")
    else:
        ok, msg2 = elevate_and_reopen_self(
            ["--kill-pid", str(pid)] + (["--kill-tree"] if tree else [])
        )
        if ok:
            # 提权进程已退出,检查是否真的成功
            time.sleep(0.5)
            check = subprocess.run(
                ["tasklist", "/FI", f"PID eq {pid}"],
                capture_output=True, text=True, timeout=10,
                encoding="utf-8", errors="replace",
            )
            if str(pid) not in check.stdout or "No tasks" in check.stdout:
                return True, "admin", "管理员 taskkill 完成"
            log.info("提权 taskkill 后进程仍在,继续进入 SYSTEM")
        else:
            log.info("提权失败: %s", msg2)

    ok, msg = system_kill(pid, tree=tree)
    if ok:
        return True, "system", msg
    return False, "failed", f"三层兜底均失败: {msg}"
