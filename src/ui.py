"""tkinter 中文 UI。

只放 UI 代码,业务逻辑都在 main 里调用。所有可见字符串都从 strings.py 来。
"""
from __future__ import annotations

import logging
import tkinter as tk
from tkinter import messagebox
from typing import Callable, Iterable

from . import strings

log = logging.getLogger(__name__)


def _center(win: tk.Toplevel | tk.Tk, w: int = 480, h: int = 320) -> None:
    win.update_idletasks()
    sw = win.winfo_screenwidth()
    sh = win.winfo_screenheight()
    x = (sw - w) // 2
    y = (sh - h) // 2
    win.geometry(f"{w}x{h}+{x}+{y}")


class ConfirmDialog:
    """检测结果 + 用户确认是否强制关闭占用程序的主对话框。"""

    def __init__(self, blocked_paths: list[str], occupiers: list[dict]):
        """
        Args:
            blocked_paths: 被占用的文件路径列表
            occupiers: [{pid, app_name, type_name, is_critical, ...}, ...]
        """
        self.user_choice: str | None = None  # "kill" / "cancel"
        self.blocked_paths = blocked_paths
        self.occupiers = occupiers
        self.root = tk.Tk()
        self.root.title(strings.APP_TITLE_CONFIRM)
        self.root.configure(padx=14, pady=14)
        self.root.attributes("-topmost", True)
        self.root.resizable(True, True)
        _center(self.root, 560, 380)

        self._build()

    def _build(self) -> None:
        f = tk.Frame(self.root)
        f.pack(fill="both", expand=True)

        # 标题
        title = tk.Label(
            f,
            text=f"以下 {len(self.blocked_paths)} 个项目被占用:",
            anchor="w",
            font=("Microsoft YaHei UI", 10, "bold"),
        )
        title.pack(fill="x", pady=(0, 6))

        # 文件列表
        files_frame = tk.LabelFrame(f, text="被占用的目标", padx=8, pady=6)
        files_frame.pack(fill="x", pady=4)
        txt_files = tk.Text(files_frame, height=4, wrap="none", bd=0)
        txt_files.pack(fill="x")
        txt_files.insert("1.0", "\n".join(self.blocked_paths))
        txt_files.configure(state="disabled")

        # 进程列表
        proc_frame = tk.LabelFrame(f, text="占用程序", padx=8, pady=6)
        proc_frame.pack(fill="both", expand=True, pady=4)
        txt_procs = tk.Text(proc_frame, height=6, wrap="none", bd=0)
        txt_procs.pack(fill="both", expand=True)
        for o in self.occupiers:
            tag = " [系统关键,不会杀]" if o.get("is_critical") else ""
            line = f"PID {o['pid']:>6}  {o['app_name']}  ({o.get('type_name','')}){tag}"
            txt_procs.insert("end", line + "\n")
        txt_procs.configure(state="disabled")

        # 警告
        warn = tk.Label(
            f,
            text="强制关闭程序可能导致未保存的数据丢失,请谨慎操作。",
            anchor="w",
            fg="#a00",
        )
        warn.pack(fill="x", pady=(6, 4))

        # 按钮
        btn_row = tk.Frame(f)
        btn_row.pack(fill="x", pady=(6, 0))

        def on_kill():
            self.user_choice = "kill"
            self.root.destroy()

        def on_cancel():
            self.user_choice = "cancel"
            self.root.destroy()

        kill_btn = tk.Button(
            btn_row, text=strings.BTN_KILL, width=14,
            bg="#d9534f", fg="white", activebackground="#c9302c",
            command=on_kill,
        )
        kill_btn.pack(side="left")
        cancel_btn = tk.Button(
            btn_row, text=strings.BTN_CANCEL, width=14, command=on_cancel,
        )
        cancel_btn.pack(side="right")

        self.root.protocol("WM_DELETE_WINDOW", on_cancel)
        self.root.bind("<Escape>", lambda e: on_cancel())
        self.root.bind("<Return>", lambda e: on_kill())
        kill_btn.focus_set()

    def run(self) -> str:
        self.root.mainloop()
        return self.user_choice or "cancel"


class ResultDialog:
    """处理完成后的总结弹窗。"""

    def __init__(self, title: str, body: str, is_error: bool = False):
        self.title = title
        self.body = body
        self.is_error = is_error

    def show(self) -> None:
        icon = "error" if self.is_error else "info"
        messagebox.showinfo(self.title, self.body, icon=icon)


def show_error(body: str) -> None:
    messagebox.showerror(strings.APP_TITLE_ERROR, body)


def show_info(body: str) -> None:
    messagebox.showinfo(strings.APP_TITLE_RESULT, body)


def ask_yes_no(title: str, body: str) -> bool:
    return messagebox.askyesno(title, body, icon="warning", default="no")
