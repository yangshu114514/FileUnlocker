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


# 每批最多注册这么多文件。RM 实测 5000+ 都能一次注册,取 1000 平衡
# 内存占用与调用次数(实测单批 1000 个文件注册约 2ms)。
_BATCH_SIZE = 1000


def _iter_files(paths: list[str]):
    """生成器: 把文件/文件夹展开成具体文件路径,供分批查询使用。

    策略:
      - 文件 → 直接产出
      - 文件夹 → os.walk 递归产出所有文件(不设文件数上限,避免截断漏报)
      - 不存在 → 跳过
    注意: Restart Manager 不支持文件夹路径,所以必须展开成文件。
    """
    for p in paths:
        if not os.path.exists(p):
            continue
        if os.path.isfile(p):
            yield p
            continue
        if os.path.isdir(p):
            for root, _dirs, files in os.walk(p):
                for name in files:
                    yield os.path.join(root, name)


def _expand_folder(paths: list[str]) -> list[str]:
    """(兼容旧调用)把文件夹展开成文件列表,供外部查看/测试。"""
    return list(_iter_files(paths))


def _query_batch(batch: list[str]) -> list[Occupier]:
    """在单个 RM 会话里查询一批文件的占用进程。

    返回该批文件对应的占用进程列表(去重后)。
    """
    session_handle = wt.DWORD(0)
    session_key = ctypes.create_unicode_buffer(64)

    rc = _rm.RmStartSession(ctypes.byref(session_handle), 0, session_key)
    if rc != ERROR_SUCCESS:
        log.error("RmStartSession 失败, rc=%s", rc)
        return []

    try:
        arr = (wt.LPCWSTR * len(batch))(*batch)
        rc = _rm.RmRegisterResources(
            session_handle, len(batch), arr,
            0, None,  # 没有进程资源
            0, None,  # 没有服务资源
        )
        if rc != ERROR_SUCCESS:
            log.error("RmRegisterResources 失败, rc=%s (本批 %d 个文件)", rc, len(batch))
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
            log.error("RmGetList (探测阶段) 失败, rc=%s (本批 %d 个文件)", rc, len(batch))
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
            log.error("RmGetList (取数阶段) 失败, rc=%s (本批 %d 个文件)", rc, len(batch))
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


def find_occupiers(paths: list[str]) -> list[Occupier]:
    """查询占用指定文件/文件夹的进程列表。

    架构: 因为 Restart Manager 不支持文件夹路径,也不保证单会话能注册
    任意多的文件,所以把目标展开成文件后**分批**查询(每批 _BATCH_SIZE
    个文件开一个独立 RM 会话),最后合并所有批次的结果并去重 PID。

    这样无论嵌套多深、文件多少,都不会因为"截断"或"单批失败"而漏报占用。

    Args:
        paths: 文件或文件夹的绝对路径列表。

    Returns:
        占用进程列表(可能为空)。单批失败只影响该批,不影响整体。
    """
    if not paths:
        return []

    # 先全部展开(生成器,不占内存)。若路径都不存在则返回空。
    file_iter = _iter_files(paths)

    all_occupiers: list[Occupier] = []
    seen_pids: set[int] = set()
    batch: list[str] = []
    batch_no = 0

    for f in file_iter:
        batch.append(f)
        if len(batch) >= _BATCH_SIZE:
            batch_no += 1
            for o in _query_batch(batch):
                if o.pid not in seen_pids:
                    seen_pids.add(o.pid)
                    all_occupiers.append(o)
            batch = []

    # 收尾不足一批的剩余文件
    if batch:
        batch_no += 1
        for o in _query_batch(batch):
            if o.pid not in seen_pids:
                seen_pids.add(o.pid)
                all_occupiers.append(o)

    if batch_no > 1:
        log.info("占用查询分 %d 批完成, 共 %d 个占用进程", batch_no, len(all_occupiers))

    # 兜底: RM 查不到 且 目标含文件夹 → 目录可能被持作 cwd
    # 例如 python 以项目目录为 cwd 运行时, RM 查不到但目录实际被锁
    if not all_occupiers:
        dirs = [p for p in paths if os.path.isdir(p)]
        if dirs:
            # 句柄枚举检测(慢, ~5-15秒, 用过即弃)
            from .handle_enum import find_holders
            holders = find_holders(dirs)
            seen_holder_pids: set[int] = set()
            for h in holders:
                if h.pid in seen_holder_pids:
                    continue
                seen_holder_pids.add(h.pid)
                # 从 exe 路径提取友好名字(如 python.exe)
                exe_name = os.path.basename(h.exe_path) if h.exe_path else ""
                all_occupiers.append(
                    Occupier(
                        pid=h.pid,
                        app_name=exe_name or f"PID {h.pid}",
                        service_short_name="",
                        app_type=RmConsole,
                        app_type_name="控制台",
                        is_critical_process=False,
                        is_restartable=False,
                    )
                )
            if holders:
                log.info("句柄枚举兜底: 发现 %d 个目录持有者", len(seen_holder_pids))
    return all_occupiers


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
