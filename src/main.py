"""主入口:解析命令行 → 单实例合并 → RM 查询 → UI → 三层强杀。
"""
from __future__ import annotations

import argparse
import logging
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from . import strings
from .critical import is_critical
from .rm_api import find_occupiers, shutdown_occupiers, Occupier
from .process_mgr import kill_with_fallback, taskkill, is_admin
from .single_inst import SingleInstance
from .ui import ConfirmDialog, ResultDialog, ask_yes_no, show_info, show_error


# ---------- 日志 ----------
def _setup_logging() -> logging.Logger:
    log_path = Path(tempfile.gettempdir()) / strings.DEBUG_LOG_NAME
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=[
            logging.FileHandler(log_path, encoding="utf-8"),
        ],
        force=True,
    )
    return logging.getLogger("FileUnlocker")


logger = _setup_logging()


# ---------- 主流程 ----------
def run_unlock(targets: list[str]) -> int:
    """完整解锁流程。

    Args:
        targets: 已合并去重的目标路径列表
    Returns:
        退出码
    """
    if not targets:
        logger.info("未收到任何目标")
        return 0

    logger.info("处理目标数=%d: %s", len(targets), targets)

    # 用 Restart Manager 查询
    occupiers: list[Occupier] = []
    try:
        occupiers = find_occupiers(targets)
    except Exception as e:
        logger.exception("Restart Manager 查询失败")
        show_error(f"查询占用失败:{e}")
        return 2

    # 排除自己 + 系统关键
    my_pid = os.getpid()
    proc_list: list[dict] = []
    critical_pids: list[int] = []
    for o in occupiers:
        if o.pid == my_pid:
            continue
        critical = o.is_critical_process or is_critical(o.app_name)
        entry = {
            "pid": o.pid,
            "app_name": o.app_name,
            "type_name": o.app_type_name,
            "is_critical": critical,
            "is_restartable": o.is_restartable,
        }
        proc_list.append(entry)
        if critical:
            critical_pids.append(o.pid)

    if not proc_list:
        show_info(strings.MSG_NOT_OCCUPIED.format(n=len(targets)))
        return 0

    # 把系统关键进程的提示插到最前
    has_critical = any(p["is_critical"] for p in proc_list)
    if has_critical:
        crit_names = ", ".join(p["app_name"] for p in proc_list if p["is_critical"])
        show_info(strings.MSG_CRITICAL_PROTECTED.format(procs=crit_names))

    # 用户确认
    confirm = ConfirmDialog(blocked_paths=targets, occupiers=proc_list).run()
    if confirm != "kill":
        logger.info("用户取消")
        return 0

    # 先尝试 Restart Manager 的"温柔关闭"
    try:
        if shutdown_occupiers(targets):
            logger.info("RmShutdown 至少关闭了一部分进程")
            # 给进程 1 秒反应时间,然后再扫一次
            import time
            time.sleep(1.0)
            occupiers2 = find_occupiers(targets)
            still_alive_pids = {o.pid for o in occupiers2 if o.pid != my_pid}
            proc_list = [p for p in proc_list if p["pid"] in still_alive_pids]
    except Exception as e:
        logger.warning("RmShutdown 异常: %s", e)

    if not proc_list:
        show_info(strings.MSG_KILL_OK.format(n=len(occupiers)))
        return 0

    # 三层兜底强杀
    ok_count = 0
    fail_detail: list[str] = []
    success_levels: dict[str, int] = {"normal": 0, "admin": 0, "system": 0}
    for p in proc_list:
        if p["is_critical"]:
            fail_detail.append(f"{p['app_name']}(PID {p['pid']}):系统关键进程,跳过")
            continue
        ok, level, msg = kill_with_fallback(p["pid"], tree=True)
        if ok:
            ok_count += 1
            success_levels[level] += 1
            logger.info("PID %d 已用 %s 方式关闭", p["pid"], level)
        else:
            fail_detail.append(f"{p['app_name']}(PID {p['pid']}):{msg}")
            logger.warning("PID %d 关闭失败: %s", p["pid"], msg)

    if not fail_detail:
        summary = strings.MSG_KILL_OK.format(n=ok_count)
        if sum(success_levels.values()):
            by = ", ".join(f"{k}={v}" for k, v in success_levels.items() if v)
            summary += f"\n(层级统计: {by})"
        show_info(summary)
        return 0

    show_info(strings.MSG_PARTIAL_OK.format(
        ok_count=ok_count,
        fail_count=len(fail_detail),
        fail_detail="\n".join(fail_detail),
    ))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="解除文件占用")
    parser.add_argument(
        "targets", nargs="*", help="要解锁的文件或文件夹路径(可多个)"
    )
    parser.add_argument("--install", action="store_true", help="安装到 LOCALAPPDATA 并注册右键菜单")
    parser.add_argument("--uninstall", action="store_true", help="从系统卸载并清理")
    parser.add_argument("--quiet", action="store_true", help="配合 --uninstall,不弹确认")
    parser.add_argument("--kill-pid", type=int, help="(内部)直接强杀指定 PID,不提权不走 UI")
    parser.add_argument("--kill-tree", action="store_true", help="(内部)强杀整棵进程树")

    args = parser.parse_args()

    # ------- 特殊模式 -------
    if args.install:
        from .installer import main_install
        return main_install(quiet=args.quiet)
    if args.uninstall:
        from .installer import main_uninstall
        return main_uninstall(quiet=args.quiet)
    if args.kill_pid is not None:
        ok, msg = taskkill(args.kill_pid, tree=args.kill_tree)
        if not ok:
            print(msg, file=sys.stderr)
            return 1
        return 0

    # ------- 常规模式: 解锁 -------
    if not args.targets:
        show_error("没有传入目标路径。\n通常通过右键菜单调用。")
        return 1

    # 多选合并(单实例)
    root_dir = Path(sys.argv[0]).resolve().parent
    try:
        si = SingleInstance(root_dir)
        si.append_target(args.targets[0])
        if not si.try_become_coordinator():
            # 让别人处理
            return 0
        targets = si.read_targets()
    except Exception as e:
        logger.warning("单实例合并失败,改用直接目标: %s", e)
        targets = args.targets

    try:
        return run_unlock(targets)
    finally:
        try:
            si.cleanup()
        except Exception:
            pass


if __name__ == "__main__":
    sys.exit(main())
