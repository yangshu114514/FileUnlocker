"""跨进程句柄枚举(兜底检测目录级占用).

背景:
  Restart Manager 只能检测被进程**打开的文件**句柄,
  无法检测被进程**持作 cwd 的目录**句柄(如 python 以项目目录为工作目录运行)。

  典型场景: 在 cmd 里 `cd D:\\文档\\程序源码\\空战雄鹰 && python main.py`,
  RM 对项目目录下所有文件做查询都会返回空,但目录自身却被 python 锁住(不能改名/删除)。

方案:
  NtQuerySystemInformation(SystemHandleInformation) 枚举全部系统句柄,
  通过 ObjectTypeIndex 过滤只留 File 类型(含目录句柄),
  对每个句柄在**工作线程(带超时)**里 DuplicateHandle + GetFinalPathNameByHandleW 取真实路径,
  与目标目录/文件做前缀匹配,得到"持有者"列表。

性能参考(实测 Windows 11, ~95k 句柄):
  - 总耗时约 3-5 秒
  - 句柄中绝大多数超时(命名管道等)被跳过,不影响正确性
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import logging
import os
import queue
import tempfile
import threading
from typing import NamedTuple

log = logging.getLogger(__name__)

# ---------- Win32 常量 ----------
SystemHandleInformation = 16
STATUS_INFO_LENGTH_MISMATCH = 0xC0000004
PROCESS_ALL_ACCESS = 0x1F0FFF
DUPLICATE_SAME_ACCESS = 0x00000002
VOLUME_NAME_DOS = 0x0

_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_ntdll = ctypes.WinDLL("ntdll")
_advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)


class _LUID(ctypes.Structure):
    _fields_ = [("LowPart", wt.DWORD), ("HighPart", ctypes.c_long)]


class _LUID_AND_ATTRIBUTES(ctypes.Structure):
    _fields_ = [("Luid", _LUID), ("Attributes", wt.DWORD)]


class _TOKEN_PRIVILEGES(ctypes.Structure):
    _fields_ = [("PrivilegeCount", wt.DWORD), ("Privileges", _LUID_AND_ATTRIBUTES * 1)]


class _SHTEI64(ctypes.Structure):
    """SYSTEM_HANDLE_TABLE_ENTRY_INFO (x64)."""
    _fields_ = [
        ("UniqueProcessId", wt.ULONG),
        ("ObjectTypeIndex", wt.BYTE),
        ("HandleAttributes", wt.BYTE),
        ("HandleValue", wt.USHORT),
        ("Object", ctypes.c_void_p),
        ("AccessMask", wt.ULONG),
    ]


def _setup_api():
    _ntdll.NtQuerySystemInformation.restype = ctypes.c_long
    _ntdll.NtQuerySystemInformation.argtypes = [
        wt.INT, ctypes.c_void_p, wt.ULONG, ctypes.POINTER(wt.ULONG),
    ]

    _advapi32.OpenProcessToken.restype = wt.BOOL
    _advapi32.OpenProcessToken.argtypes = [
        ctypes.c_void_p, wt.DWORD, ctypes.POINTER(ctypes.c_void_p),
    ]
    _advapi32.LookupPrivilegeValueW.restype = wt.BOOL
    _advapi32.LookupPrivilegeValueW.argtypes = [
        wt.LPCWSTR, wt.LPCWSTR, ctypes.POINTER(_LUID),
    ]
    _advapi32.AdjustTokenPrivileges.restype = wt.BOOL
    _advapi32.AdjustTokenPrivileges.argtypes = [
        ctypes.c_void_p, wt.BOOL, ctypes.POINTER(_TOKEN_PRIVILEGES),
        wt.DWORD, ctypes.c_void_p, ctypes.c_void_p,
    ]

    _kernel32.OpenProcess.restype = ctypes.c_void_p
    _kernel32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    _kernel32.QueryFullProcessImageNameW.restype = wt.BOOL
    _kernel32.QueryFullProcessImageNameW.argtypes = [
        ctypes.c_void_p, wt.DWORD, wt.LPWSTR, ctypes.POINTER(wt.DWORD),
    ]
    _kernel32.DuplicateHandle.restype = wt.BOOL
    _kernel32.DuplicateHandle.argtypes = [
        ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_void_p), wt.DWORD, wt.BOOL, wt.DWORD,
    ]
    _kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    _kernel32.GetCurrentProcess.restype = ctypes.c_void_p
    _kernel32.GetFinalPathNameByHandleW.restype = wt.DWORD
    _kernel32.GetFinalPathNameByHandleW.argtypes = [
        ctypes.c_void_p, wt.LPWSTR, wt.DWORD, wt.DWORD,
    ]
    _kernel32.MoveFileW.restype = wt.BOOL
    _kernel32.MoveFileW.argtypes = [wt.LPCWSTR, wt.LPCWSTR]


_setup_api()


# ---------- 权限提升 ----------
def _enable_debug_privilege() -> bool:
    """启用 SeDebugPrivilege. 权限不足时跨进程 DuplicateHandle 会拒绝(err=5)."""
    tok = ctypes.c_void_p()
    if not _advapi32.OpenProcessToken(
        _kernel32.GetCurrentProcess(), 0x20 | 0x08, ctypes.byref(tok)
    ):
        return False
    luid = _LUID()
    _advapi32.LookupPrivilegeValueW(None, "SeDebugPrivilege", ctypes.byref(luid))
    tp = _TOKEN_PRIVILEGES()
    tp.PrivilegeCount = 1
    tp.Privileges[0].Luid = luid
    tp.Privileges[0].Attributes = 2
    ok = _advapi32.AdjustTokenPrivileges(tok, False, ctypes.byref(tp), 0, None, None)
    _kernel32.CloseHandle(tok)
    return bool(ok)


# ---------- 句柄表枚举 ----------
def _enum_handles():
    """返回 (count, entries, keepalive_buf) 或 (0, None, None) 失败."""
    buf_size = 8 * 1024 * 1024
    while True:
        buf = ctypes.create_string_buffer(buf_size)
        retlen = wt.ULONG(0)
        ret = _ntdll.NtQuerySystemInformation(
            SystemHandleInformation, buf, buf_size, ctypes.byref(retlen)
        )
        if ret == STATUS_INFO_LENGTH_MISMATCH:
            buf_size = max(buf_size * 2, retlen.value + 4096)
            continue
        if ret != 0:
            log.warning("NtQuerySystemInformation 失败 NTSTATUS=0x%08X", ret & 0xFFFFFFFF)
            return 0, None, None
        break
    count = ctypes.cast(buf, ctypes.POINTER(ctypes.c_ulong)).contents.value
    entries = ctypes.cast(ctypes.byref(buf, 8), ctypes.POINTER(_SHTEI64))
    return count, entries, buf


def _get_file_type_index() -> int | None:
    """探测当前系统 File 类型的 ObjectTypeIndex.

    原理: 打开一个已知文件, 在自己进程的句柄条目里反查类型 index.
    (Windows 不公开类型 index 常量, 需运行时探测.)
    """
    mypid = os.getpid()
    tmp = os.path.join(tempfile.gettempdir(), "fu_probe.tmp")
    try:
        with open(tmp, "w") as f:
            f.write("x")
        hf = _kernel32.CreateFileW(tmp, 0x80000000, 7, None, 3, 0x80, None)
        if not hf or hf == ctypes.c_void_p(-1).value:
            return None
        count, entries, _b = _enum_handles()
        if not entries:
            _kernel32.CloseHandle(hf)
            return None
        hf_int = int(hf)
        idx = None
        for i in range(count):
            e = entries[i]
            if e.UniqueProcessId == mypid and e.HandleValue == hf_int:
                idx = e.ObjectTypeIndex
                break
        _kernel32.CloseHandle(hf)
        return idx
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


# ---------- 带超时的调用 ----------
def _call_with_timeout(fn, timeout_s=0.5):
    """在工作线程执行 fn 带超时. 超时返回 None(线程泄漏但主线程不卡死)."""
    q = queue.Queue(maxsize=1)

    def run():
        try:
            q.put_nowait(fn())
        except Exception:
            try:
                q.put_nowait(None)
            except Exception:
                pass

    t = threading.Thread(target=run, daemon=True)
    t.start()
    try:
        return q.get(timeout=timeout_s)
    except queue.Empty:
        return None


# ---------- 公开 ----------
class DirHolder(NamedTuple):
    """持有指定目录/文件句柄的进程描述."""
    pid: int
    path: str        # 规范化后的路径(含 \\?\D:\ 前缀)
    exe_path: str    # 进程可执行文件完整路径


def _get_exe_path(hproc) -> str:
    """从 OpenProcess 句柄取完整 exe 路径. 失败返回空串."""
    buf = ctypes.create_unicode_buffer(1024)
    size = wt.DWORD(1024)
    ok = _kernel32.QueryFullProcessImageNameW(hproc, 0, buf, ctypes.byref(size))
    if not ok:
        return ""
    return buf.value


def _handle_path(dup_handle) -> str | None:
    """从 duplicated handle 取真实路径. 非文件系统对象返回 None."""
    buf = ctypes.create_unicode_buffer(4096)
    r = _kernel32.GetFinalPathNameByHandleW(
        dup_handle, buf, 4096, VOLUME_NAME_DOS,
    )
    if r == 0 or r >= 4096:
        return None
    return buf.value


def _is_locked(target: str) -> bool:
    """用 MoveFileW 试验性改名检测文件/文件夹是否被锁.

    MoveFileW 是原子操作: 要么完全成功要么完全不动.
    若成功(说明没锁)则立即改回来. 失败说明被占用.
    微秒级返回, 比全量句柄枚举快得多.
    """
    tmp = target + f".__fu_lock_test_{os.getpid()}__"
    ok = _kernel32.MoveFileW(target, tmp)
    if ok:
        _kernel32.MoveFileW(tmp, target)  # 立即恢复
        return False
    return True


def find_holders(paths: list[str]) -> list[DirHolder]:
    """查找持有指定文件/文件夹(含其子路径)句柄的进程.

    用于 RM 查询为空时的兜底, 找出把目录当 cwd 持有的进程.

    Args:
        paths: 绝对路径列表(文件或文件夹).

    Returns:
        命中列表, 每项含 pid 和实际句柄指向的路径.
        可能因为权限/类型/超时漏检, 但不会误报(只报真实匹配).
    """
    if not paths:
        return []

    # 快速预检: 目标根本未被锁 → 直接跳过乐观扫描(大部分情况)
    # 这避免了 ~5 秒的句柄枚举耗时
    unlocked = [p for p in paths if not _is_locked(p)]
    if len(unlocked) == len(paths):
        return []

    # 规范化所有目标路径为 \\?\D:\foo 形式(小写)
    norm_targets = []
    for p in paths:
        norm_p = os.path.normpath(p)
        drive, rest = os.path.splitdrive(norm_p)
        if not drive:
            continue
        full = ("\\\\?\\" + drive.upper() + rest).lower().rstrip("\\")
        norm_targets.append(full)
    if not norm_targets:
        return []

    if not _enable_debug_privilege():
        log.warning("无法启用 SeDebugPrivilege, 句柄枚举可能失败")

    fidx = _get_file_type_index()
    if fidx is None:
        log.warning("无法探测 File 类型 index, 放弃句柄枚举")
        return []

    count, entries, _buf = _enum_handles()
    if not entries:
        return []
    log.info("句柄总数: %d (File 类型 index=%d)", count, fidx)

    results: list[DirHolder] = []
    seen_pids: set[int] = set()
    proc_cache: dict[int, ctypes.c_void_p | bool] = {}
    timed_out = 0
    scanned = 0

    for i in range(count):
        e = entries[i]
        if e.ObjectTypeIndex != fidx:
            continue
        pid = e.UniqueProcessId
        if pid == 0 or pid == 4:
            continue
        if pid in seen_pids:
            continue
        hproc = proc_cache.get(pid)
        if hproc is None:
            hproc = _kernel32.OpenProcess(PROCESS_ALL_ACCESS, False, pid)
            proc_cache[pid] = hproc if hproc else False
        if not hproc:
            continue

        dup = ctypes.c_void_p()

        def _dup():
            return _kernel32.DuplicateHandle(
                hproc, ctypes.c_void_p(e.HandleValue),
                _kernel32.GetCurrentProcess(), ctypes.byref(dup),
                0, False, DUPLICATE_SAME_ACCESS,
            )

        ok = _call_with_timeout(_dup, 0.5)
        if not ok:
            if ok is None:
                timed_out += 1
            continue

        def _getpath():
            return _handle_path(dup)

        fpath = _call_with_timeout(_getpath, 0.5)
        if fpath is None:
            timed_out += 1
        _kernel32.CloseHandle(dup)
        scanned += 1

        if not fpath:
            continue
        n = fpath.lower().rstrip("\\")
        for tgt in norm_targets:
            if n == tgt or n.startswith(tgt + "\\"):
                if pid not in seen_pids:
                    seen_pids.add(pid)
                    exe_path = _get_exe_path(hproc)
                    results.append(DirHolder(pid=pid, path=fpath, exe_path=exe_path))
                    log.info("句柄命中: pid=%d exe=%s path=%s", pid, exe_path, fpath)
                break

    for hproc in proc_cache.values():
        if hproc:
            _kernel32.CloseHandle(hproc)
    log.info("句柄扫描完成: 扫描=%d, 超时跳过=%d, 命中=%d", scanned, timed_out, len(results))
    return results