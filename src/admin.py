"""权限/管理员辅助模块的轻量入口。

具体的提权策略、SYSTEM 兜底逻辑在 process_mgr.py。
本模块只暴露 is_admin 和 elevate_and_reopen_self 给 UI 使用。
"""
from __future__ import annotations

from .process_mgr import is_admin, elevate_and_reopen_self

__all__ = ["is_admin", "elevate_and_reopen_self"]
