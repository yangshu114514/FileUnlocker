"""Windows 系统关键进程黑名单。

这些进程的 PID 即使占用了文件,也绝不强杀——
杀掉它们会导致系统崩溃/蓝屏/桌面崩坏。
所有名字一律小写,匹配前调用 .lower()。
"""

CRITICAL_PROCESS_NAMES: frozenset[str] = frozenset(
    {
        # 内核态/系统启动
        "system",
        "registry",
        "smss.exe",
        "csrss.exe",
        "wininit.exe",
        "winlogon.exe",
        "services.exe",
        "lsass.exe",
        "lsaiso.exe",
        "svchost.exe",
        "fontdrvhost.exe",
        "dwm.exe",
        "sihost.exe",
        "taskhostw.exe",
        "runtimebroker.exe",
        "ctfmon.exe",
        "chttime.exe",
        "searchhost.exe",
        "startmenuexperiencehost.exe",
        "shellexperiencehost.exe",
        "textinputhost.exe",
        "securityhealthservice.exe",
        "securityhealthsystray.exe",
        # 资源管理器
        "explorer.exe",
    }
)


def is_critical(process_name: str) -> bool:
    """判断给定进程名是否为系统关键进程(大小写不敏感)。

    Args:
        process_name: 进程名,如 "explorer.exe"、"System"、"chrome.exe"。

    Returns:
        True 表示关键进程,**绝不可**强杀;False 可以正常处理。
    """
    if not process_name:
        return False
    return process_name.lower() in CRITICAL_PROCESS_NAMES
