"""tkinter 中文 UI。

只放 UI 代码,业务逻辑都在 main 里调用。所有可见字符串都从 strings.py 来。
"""
from __future__ import annotations

import ctypes
import logging
from typing import Iterable

from . import strings

log = logging.getLogger(__name__)


# ---------- MessageBoxW 常量 ----------
MB_OK = 0x00000000
MB_OKCANCEL = 0x00000001
MB_YESNO = 0x00000004
MB_ICONERROR = 0x00000010
MB_ICONQUESTION = 0x00000020
MB_ICONWARNING = 0x00000030
MB_ICONINFORMATION = 0x00000040
MB_TOPMOST = 0x00040000
MB_SETFOREGROUND = 0x00010000
MB_DEFAULT_DESKTOP_ONLY = 0x00020000
MB_SYSTEMMODAL = 0x00001000     # 系统模态,弹窗一定显示在所有窗口之上
MB_TASKMODAL = 0x00002000
MB_RIGHT = 0x00080000
MB_RTLREADING = 0x00100000

IDOK = 1
IDCANCEL = 2
IDYES = 6
IDNO = 7
IDRETRY = 4

_MBOX = ctypes.windll.user32.MessageBoxW
_MBOX.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint]
_MBOX.restype = ctypes.c_int


def _mbox(text: str, title: str, flags: int) -> int:
    """统一调用 MessageBoxW。

    不像 VBS,exe 是从右键菜单启动的子进程,弹窗默认可能被 explorer 盖后面。
    MB_TASKMODAL 让弹窗成为"顶级模态"。
    MB_SETFOREGROUND 强制抓住焦点。
    MB_TOPMOST 让它在最上层。
    MB_SYSTEMMODAL 是最强的(系统模态),适合关键确认。

    我们加 MB_SYSTEMMODAL,确保一定能弹出并抢焦点。
    """
    log.info("弹窗: title=%s flags=0x%X body_chars=%d", title, flags, len(text))
    rc = _MBOX(
        0,
        text,
        title,
        flags | MB_TOPMOST | MB_SETFOREGROUND | MB_SYSTEMMODAL,
    )
    log.info("弹窗返回 rc=%d (1=确定 2=取消 6=是 7=否)", rc)
    return rc


# ---------- 公共 API ----------
def show_info(body: str, title: str = strings.APP_TITLE_RESULT) -> None:
    """信息提示弹窗(绿色/蓝色)。"""
    _mbox(body, title, MB_OK | MB_ICONINFORMATION)


def show_error(body: str, title: str = strings.APP_TITLE_ERROR) -> None:
    """错误提示弹窗(红色 X)。"""
    _mbox(body, title, MB_OK | MB_ICONERROR)


def show_warning(body: str, title: str = strings.APP_TITLE_DETECT) -> None:
    """警告提示弹窗。"""
    _mbox(body, title, MB_OK | MB_ICONWARNING)


def ask_yes_no(title: str, body: str) -> bool:
    """是/否确认框。

    Returns:
        True = 用户点了【是】
        False = 用户点了【否】或关了弹窗
    """
    rc = _mbox(body, title, MB_YESNO | MB_ICONQUESTION)
    return rc == IDYES


def ask_ok_cancel(title: str, body: str) -> bool:
    """确定/取消确认框。

    Returns:
        True = 用户点了【确定】
        False = 用户点了【取消】或 ESC
    """
    rc = _mbox(body, title, MB_OKCANCEL | MB_ICONQUESTION)
    return rc == IDOK


class ConfirmDialog:
    """与原 tkinter 版本同名,但用 MessageBoxW 实现。

    返回 "kill" 或 "cancel",由 main.py 决定下一步。

    不再用 tkinter,因为 PyInstaller --onefile --noconsole 打包的 tkinter
    弹窗首次启动要解压 _MEI 临时目录,卡顿 1~2 秒,且观感"很老"。
    MessageBoxW 是系统原生 API,~10ms 响应。
    """

    def __init__(self, blocked_paths: list[str], occupiers: list[dict]):
        self.blocked_paths = blocked_paths
        self.occupiers = occupiers
        self.user_choice: str | None = None

    def run(self) -> str:
        n = len(self.blocked_paths)
        bodies: list[str] = [f"以下 {n} 个目标被占用:\n"]
        for p in self.blocked_paths:
            bodies.append(f"  {p}")

        crit_list = [o for o in self.occupiers if o.get("is_critical")]
        normal_list = [o for o in self.occupiers if not o.get("is_critical")]

        if normal_list:
            bodies.append("\n占用程序:")
            for o in normal_list:
                bodies.append(f"  PID {o['pid']}  {o['app_name']}")
        if crit_list:
            names = ", ".join(o["app_name"] for o in crit_list)
            bodies.append(f"\n受保护的系统进程(不会关闭): {names}")

        bodies.append("\n是否强制关闭这些程序?")
        bodies.append("(被关闭的程序中未保存数据可能丢失)")

        body = "\n".join(bodies)
        log.info(
            "ConfirmDialog: 弹窗前; title=%r; body=<<%s>>",
            strings.APP_TITLE_CONFIRM, body
        )
        rc = _mbox(body, strings.APP_TITLE_CONFIRM, MB_YESNO | MB_ICONWARNING)
        log.info("ConfirmDialog: 弹窗后 rc=%d", rc)
        if rc == IDYES:
            self.user_choice = "kill"
            return "kill"
        self.user_choice = "cancel"
        return "cancel"


class ResultDialog:
    """最简单的"完成"提示,纯 MessageBoxW。"""

    def __init__(self, title: str, body: str, is_error: bool = False):
        self.title = title
        self.body = body
        self.is_error = is_error

    def show(self) -> None:
        if self.is_error:
            show_error(self.body, self.title)
        else:
            show_info(self.body, self.title)
