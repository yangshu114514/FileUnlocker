"""通过读取进程 PEB.CurrentDirectory 检测目录被哪个进程持作 cwd.

适用场景:
  Restart Manager 检测不到"目录被持作 cwd"类型的占用(如
  `cd D:\项目A && python main.py` —— python 持有 D:\项目A 的目录句柄,
  但 RM 只查被打开的文件, 查不到)

原理:
  每个进程的 PEB (Process Environment Block) 里存着 CurrentDirectoryPath,
  是 UNICODE_STRING 结构包含当前工作目录路径。
  我们枚举全部进程, 读取其 PEB.CurrentDirectory, 看是否匹配目标目录。
  枚举 ~200 个进程 vs 句柄 ~95000 条, 性能天差地别 (~100ms vs ~10s).

内存读取步骤 (Win10/11 x64):
  1. NtQueryInformationProcess 取 PEB 地址
  2. ReadProcessMemory(PEB + 0x20) 读 ProcessParameters 指针
  3. ReadProcessMemory(ProcessParameters + 0x38) 读 CurrentDirectory.DosPath (UNICODE_STRING 16B)
  4. ReadProcessMemory(unicode_str.Buffer) 读字符串

覆盖范围:
  - 命中: 目标目录 == 进程 cwd, 或 目标是 cwd 的子目录(共享父路径)
  - 漏检: 进程持有目录句柄但不是 cwd(罕见, 如 watcher 监听目录)
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import logging
import os
from typing import NamedTuple

log = logging.getLogger(__name__)

# ---------- Win32 常量 ----------
PROCESS_QUERY_INFORMATION = 0x0400
PROCESS_VM_READ = 0x0010
PROCESS_ALL_ACCESS = 0x1F0FFF
PROCESS_QUERY_LIMITED_INFORMATION = 0x1000

# PEB 结构偏移 (x64)
PEB_PROCESSPARAMETERS_OFFSET = 0x20
RTL_USER_PROCESS_PARAMETERS_CWD_OFFSET = 0x38

_kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
_ntdll = ctypes.WinDLL("ntdll")
_psapi = ctypes.WinDLL("psapi", use_last_error=True)


class _PROCESS_BASIC_INFORMATION(ctypes.Structure):
    _fields_ = [
        ("Reserved1", ctypes.c_void_p),
        ("PebBaseAddress", ctypes.c_void_p),
        ("Reserved2", ctypes.c_void_p * 2),
        ("UniqueProcessId", ctypes.c_void_p),
        ("Reserved3", ctypes.c_void_p),
    ]


def _setup_api():
    _ntdll.NtQueryInformationProcess.restype = ctypes.c_long
    _ntdll.NtQueryInformationProcess.argtypes = [
        ctypes.c_void_p,
        wt.INT,
        ctypes.c_void_p,
        wt.ULONG,
        ctypes.POINTER(wt.ULONG),
    ]

    _kernel32.OpenProcess.restype = ctypes.c_void_p
    _kernel32.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    _kernel32.ReadProcessMemory.restype = wt.BOOL
    _kernel32.ReadProcessMemory.argtypes = [
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_void_p,
        ctypes.c_size_t,
        ctypes.POINTER(ctypes.c_size_t),
    ]
    _kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    _kernel32.QueryFullProcessImageNameW.restype = wt.BOOL
    _kernel32.QueryFullProcessImageNameW.argtypes = [
        ctypes.c_void_p,
        wt.DWORD,
        wt.LPWSTR,
        ctypes.POINTER(wt.DWORD),
    ]


_setup_api()


def _enum_all_pids() -> list[int]:
    """用 psapi.EnumProcesses 枚举全部进程 PID. 返回 PID 列表."""
    max_count = 4096
    arr = (wt.DWORD * max_count)()
    needed = wt.DWORD(0)
    # psapi.EnumProcesses(pProcessIds, cb, pBytesReturned)
    _psapi.EnumProcesses.argtypes = [
        ctypes.POINTER(wt.DWORD),
        wt.DWORD,
        ctypes.POINTER(wt.DWORD),
    ]
    _psapi.EnumProcesses.restype = wt.BOOL
    if not _psapi.EnumProcesses(arr, ctypes.sizeof(arr), ctypes.byref(needed)):
        log.warning("EnumProcesses 失败")
        return []
    count = needed.value // 4  # 每个 DWORD 4 字节
    return [arr[i] for i in range(count)]


def _read_mem(hproc, addr: int, size: int) -> bytes | None:
    """带错误处理的 ReadProcessMemory. 失败返回 None."""
    buf = ctypes.create_string_buffer(size)
    n = ctypes.c_size_t(0)
    ok = _kernel32.ReadProcessMemory(
        hproc, ctypes.c_void_p(addr), buf, size, ctypes.byref(n)
    )
    if not ok or n.value == 0:
        return None
    return bytes(buf.raw[: n.value])


def _get_peb_address(hproc) -> int | None:
    """NtQueryInformationProcess 取 PEB 基址. 失败返回 None."""
    pbi = _PROCESS_BASIC_INFORMATION()
    retlen = wt.ULONG(0)
    r = _ntdll.NtQueryInformationProcess(
        hproc, 0, ctypes.byref(pbi), ctypes.sizeof(pbi), ctypes.byref(retlen)
    )
    if r != 0:
        return None
    return int(pbi.PebBaseAddress or 0)


def _get_process_cwd(hproc) -> str | None:
    """读进程 PEB.CurrentDirectory. 失败返回 None.

    返回路径不带尾反斜杠(标准化为 N:\\XXX\\YYY).
    """
    peb = _get_peb_address(hproc)
    if not peb:
        return None

    # PEB.ProcessParameters 指针
    raw = _read_mem(hproc, peb + PEB_PROCESSPARAMETERS_OFFSET, 8)
    if not raw:
        return None
    proc_params = int.from_bytes(raw, "little")
    if not proc_params:
        return None

    # RTL_USER_PROCESS_PARAMETERS.CurrentDirectory.DosPath (UNICODE_STRING)
    # UNICODE_STRING = { USHORT Length; USHORT MaxLen; [4 bytes padding]; PWSTR Buffer }
    raw = _read_mem(hproc, proc_params + RTL_USER_PROCESS_PARAMETERS_CWD_OFFSET, 16)
    if not raw:
        return None
    length_bytes = int.from_bytes(raw[0:2], "little")
    buf_ptr = int.from_bytes(raw[8:16], "little")
    if not length_bytes or not buf_ptr:
        return None
    if length_bytes > 4096:  # 防御
        return None

    raw = _read_mem(hproc, buf_ptr, length_bytes)
    if not raw:
        return None
    try:
        return raw.decode("utf-16-le", errors="replace").rstrip("\x00\\")
    except UnicodeDecodeError:
        return None


def _get_exe_path(hproc) -> str:
    """从 OpenProcess 句柄取完整 exe 路径. 失败返回空串."""
    buf = ctypes.create_unicode_buffer(1024)
    size = wt.DWORD(1024)
    ok = _kernel32.QueryFullProcessImageNameW(hproc, 0, buf, ctypes.byref(size))
    if not ok:
        return ""
    return buf.value


def _normalize(path: str) -> str:
    """路径小写化并去掉尾反斜杠."""
    return path.lower().rstrip("\\")


# ---------- 公开 ----------
class CwdHolder(NamedTuple):
    """持有指定目录(作为 cwd 或父目录)的进程."""

    pid: int
    cwd: str       # 进程的 CurrentDirectoryPath
    exe_path: str  # 进程可执行文件完整路径


def find_cwd_holders(targets: list[str]) -> list[CwdHolder]:
    """查找把目标目录(或其父目录)持作 cwd 的进程.

    Args:
        targets: 绝对路径列表(文件或文件夹).
                对文件夹: 若 cwd == 该文件夹(或其子目录是该文件夹的父) → 命中
                对文件: 若 cwd == 该文件所在目录或其父目录 → 命中

    Returns:
        进程列表(PID 去重). 未启用取 cwd 权限的进程被跳过(不报错).
    """
    if not targets:
        return []

    # 规范化目标到字符串集合. 对文件 → 取父目录; 对目录 → 原路径
    norm_parents: set[str] = set()
    for p in targets:
        norm_p = os.path.normpath(p)
        if os.path.isdir(norm_p):
            norm_parents.add(_normalize(norm_p))
        else:
            # 文件: 取其目录
            norm_parents.add(_normalize(os.path.dirname(norm_p)))

    if not norm_parents:
        return []

    results: list[CwdHolder] = []
    seen_pids: set[int] = set()
    pids = _enum_all_pids()
    log.info("枚举进程数: %d", len(pids))

    for pid in pids:
        if pid == 0 or pid == 4:  # System Idle / System
            continue
        if pid in seen_pids:
            continue
        # 打开进程(请求读内存 + 查询信息)
        hproc = _kernel32.OpenProcess(
            PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, False, pid
        )
        if not hproc:
            # 权限不够(开启 SeDebugPrivilege 前可能 +保护进程) 失败,但仍尝试低权限
            # 无 VM_READ 时试 PROCESS_ALL_ACCESS(若有 SeDebugPrivilege 则成功)
            hproc = _kernel32.OpenProcess(PROCESS_ALL_ACCESS, False, pid)
        if not hproc:
            continue
        try:
            cwd = _get_process_cwd(hproc)
            if not cwd:
                continue
            norm_cwd = _normalize(cwd)
            # 命中条件: 进程的 cwd 是目标的祖先, 或目标 == cwd, 或目标是 cwd 的儿子
            # (即 cwd 与 目标 存在包含关系 — 该进程"在目标内"或"父于目标")
            for tgt in norm_parents:
                if (
                    norm_cwd == tgt
                    or tgt.startswith(norm_cwd + "\\")
                    or norm_cwd.startswith(tgt + "\\")
                ):
                    if pid not in seen_pids:
                        seen_pids.add(pid)
                        exe_path = _get_exe_path(hproc)
                        results.append(CwdHolder(pid=pid, cwd=cwd, exe_path=exe_path))
                        log.info("cwd 命中: pid=%d exe=%s cwd=%s", pid, exe_path, cwd)
                    break
        finally:
            _kernel32.CloseHandle(hproc)

    log.info("cwd 扫描完成: 进程=%d, 命中=%d", len(pids), len(results))
    return results