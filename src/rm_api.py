"""Windows Restart Manager(rstrtmgr.dll)的 ctypes 封装。

这是官方提供的查询"谁在占用某个文件"的 API,毫秒级返回结构化结果,
免去了 handle.exe 全系统扫描的几秒开销。
"""
from __future__ import annotations

import ctypes
import ctypes.wintypes as wt
import logging
import os
from typing import NamedTuple

log = logging.getLogger(__name__)

# ---------- Win32 常量 ----------
CCH_RM_MAX_APP_NAME = 255
CCH_RM_MAX_SVC_NAME = 63
RM_MAX_TS = 16

# RM_APP_TYPE 枚举
RmUnknownApp = 0
RmMainWindow = 1
RmOtherWindow = 2
RmService = 3
RmExplorer = 4
RmConsole = 5
RmCritical = 1000

ERROR_SUCCESS = 0
ERROR_MORE_DATA = 234


# ---------- 结构体 ----------
class FILETIME(ctypes.Structure):
    _fields_ = [("dwLowDateTime", wt.DWORD), ("dwHighDateTime", wt.DWORD)]


class RM_UNIQUE_PROCESS(ctypes.Structure):
    _fields_ = [("dwProcessId", wt.DWORD), ("ProcessStartTime", FILETIME)]


class RM_PROCESS_INFO(ctypes.Structure):
    _fields_ = [
        ("Process", RM_UNIQUE_PROCESS),
        ("strAppName", wt.WCHAR * (CCH_RM_MAX_APP_NAME + 1)),
        ("strServiceShortName", wt.WCHAR * (CCH_RM_MAX_SVC_NAME + 1)),
        ("ApplicationType", wt.DWORD),
        ("AppStatus", wt.ULONG),
        ("TSSessionId", wt.ULONG),
        ("bRestartable", wt.BOOL),
    ]


# ---------- 函数指针 ----------
_rm = ctypes.windll.rstrtmgr

_rm.RmStartSession.argtypes = [
    ctypes.POINTER(wt.DWORD),
    wt.DWORD,
    wt.LPCWSTR,
]
_rm.RmStartSession.restype = wt.DWORD

_rm.RmRegisterResources.argtypes = [
    wt.DWORD,
    wt.UINT,
    ctypes.POINTER(wt.LPCWSTR),
    wt.UINT,
    ctypes.c_void_p,
    wt.UINT,
    ctypes.c_void_p,
]
_rm.RmRegisterResources.restype = wt.DWORD

_rm.RmGetList.argtypes = [
    wt.DWORD,
    ctypes.POINTER(wt.UINT),
    ctypes.POINTER(wt.UINT),
    ctypes.POINTER(RM_PROCESS_INFO),
    ctypes.POINTER(wt.ULONG),
]
_rm.RmGetList.restype = wt.DWORD

_rm.RmEndSession.argtypes = [wt.DWORD]
_rm.RmEndSession.restype = wt.DWORD


# ---------- 公开 API ----------
class Occupier(NamedTuple):
    """一个占用进程的描述。"""

    pid: int
    app_name: str
    service_short_name: str
    app_type: int            # Rm* 常量
    app_type_name: str       # 已翻译的中文类型描述
    is_critical_process: bool  # 系统关键进程(不可杀)
    is_restartable: bool


def _expand_folder(paths: list[str]) -> list[str]:
    """把文件夹展开成具体文件列表(因为 Restart Manager 不支持文件夹路径)。

    策略:
      - 如果 path 是文件,直接加入
      - 如果 path 是文件夹,递归找所有文件(最多 1000 个,防爆炸)
      - 如果路径不存在,跳过
    """
    expanded: list[str] = []
    for p in paths:
        if not os.path.exists(p):
            continue
        if os.path.isfile(p):
            expanded.append(p)
            continue
        if os.path.isdir(p):
            # 文件夹: 递归枚举(限制 1000 个,防止超大文件夹卡死)
            count = 0
            for root, dirs, files in os.walk(p):
                for name in files:
                    expanded.append(os.path.join(root, name))
                    count += 1
                    if count >= 1000:
                        log.warning(f"文件夹 {p} 文件太多,已截断到 1000 个")
                        break
                if count >= 1000:
                    break
    return expanded


def find_occupiers(paths: list[str]) -> list[Occupier]:
    """查询占用指定文件/文件夹的进程列表。

    注意: Restart Manager 不支持文件夹路径,所以文件夹会被展开成文件列表。

    Args:
        paths: 文件或文件夹的绝对路径列表。

    Returns:
        占用进程列表(可能为空)。出错时返回空列表并写日志。
    """
    if not paths:
        return []

    # 展开文件夹为文件列表
    expanded = _expand_folder(paths)
    if not expanded:
        return []

    session_handle = wt.DWORD(0)
    session_key = ctypes.create_unicode_buffer(64)

    rc = _rm.RmStartSession(ctypes.byref(session_handle), 0, session_key)
    if rc != ERROR_SUCCESS:
        log.error("RmStartSession 失败, rc=%s", rc)
        return []

    try:
        # 注册被查询的资源(1 个字符串数组)
        # 避免空数组 Bug: len(expanded) 为 0 时直接返回
        if len(expanded) == 0:
            return []
        arr = (wt.LPCWSTR * len(expanded))(*expanded)
        rc = _rm.RmRegisterResources(
            session_handle, len(expanded), arr,
            0, None,  # 没有进程资源
            0, None,  # 没有服务资源
        )
        if rc != ERROR_SUCCESS:
            log.error("RmRegisterResources 失败, rc=%s", rc)
            return []

        # 先打探数量
        needed_num = wt.UINT(0)
        array_num = wt.UINT(0)
        reboot_reason = wt.ULONG(0)
        rc = _rm.RmGetList(
            session_handle,
            ctypes.byref(needed_num),
            ctypes.byref(array_num),
            None,
            ctypes.byref(reboot_reason),
        )
        if rc not in (ERROR_SUCCESS, ERROR_MORE_DATA):
            log.error("RmGetList (探测阶段) 失败, rc=%s", rc)
            return []

        n = needed_num.value
        if n == 0:
            return []

        buffer = (RM_PROCESS_INFO * n)()
        array_num = wt.UINT(n)
        rc = _rm.RmGetList(
            session_handle,
            ctypes.byref(needed_num),
            ctypes.byref(array_num),
            buffer,
            ctypes.byref(reboot_reason),
        )
        if rc != ERROR_SUCCESS:
            log.error("RmGetList (取数阶段) 失败, rc=%s", rc)
            return []

        type_map = {
            RmUnknownApp: "未知程序",
            RmMainWindow: "桌面程序",
            RmOtherWindow: "桌面程序",
            RmService: "系统服务",
            RmExplorer: "资源管理器",
            RmConsole: "控制台",
            RmCritical: "系统关键",
        }

        occupiers: list[Occupier] = []
        seen_pids: set[int] = set()
        for i in range(array_num.value):
            info = buffer[i]
            pid = info.Process.dwProcessId
            if pid in seen_pids:
                continue
            seen_pids.add(pid)
            app_type = info.ApplicationType
            occupiers.append(
                Occupier(
                    pid=pid,
                    app_name=info.strAppName or f"PID {pid}",
                    service_short_name=info.strServiceShortName or "",
                    app_type=app_type,
                    app_type_name=type_map.get(app_type, "其他"),
                    is_critical_process=(app_type == RmCritical),
                    is_restartable=bool(info.bRestartable),
                )
            )
        return occupiers
    finally:
        _rm.RmEndSession(session_handle)


def shutdown_occupiers(paths: list[str]) -> bool:
    """尝试"温柔关闭"占用进程(RmShutdown → RmRestart 不调用)。

    受系统策略限制,可能仍返回 False。
    我们只用它做 best-effort,失败后让 process_mgr 走 taskkill。

    Returns:
        True: 至少一个进程响应了温柔关闭
        False: 无人响应或 API 报错
    """
    # RmShutdown 需要 RmStartSession 但之前必须先 RmRegisterResources
    session_handle = wt.DWORD(0)
    session_key = ctypes.create_unicode_buffer(64)
    rc = _rm.RmStartSession(ctypes.byref(session_handle), 0, session_key)
    if rc != ERROR_SUCCESS:
        return False

    try:
        arr = (wt.LPCWSTR * len(paths))(*paths)
        rc = _rm.RmRegisterResources(session_handle, len(paths), arr, 0, None, 0, None)
        if rc != ERROR_SUCCESS:
            return False

        # RmShutdown: 0 = RmForceShutdown
        _rm.RmShutdown.argtypes = [wt.DWORD, wt.ULONG, ctypes.c_void_p]
        _rm.RmShutdown.restype = wt.DWORD
        rc = _rm.RmShutdown(session_handle, 0, None)
        return rc == ERROR_SUCCESS
    except Exception as e:
        log.warning("RmShutdown 异常: %s", e)
        return False
    finally:
        _rm.RmEndSession(session_handle)
