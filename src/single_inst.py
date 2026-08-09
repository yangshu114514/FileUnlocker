"""多选右键菜单时的参数合并/单实例锁。

Windows 右键菜单多选文件时,系统会为**每个**文件启动一次本程序。
如果每个实例都独立检查占用,会重复扫描、变慢。

策略:
  1. 用 lockfile 互斥,第一个进程作为协调者。
  2. 协调者疯狂读 queue 文件;后续每一个实例只是把自己的目标路径**追加**
     到 queue 文件,然后即刻退出。
  3. 协调者用"心跳 + 稳定窗口"的方式知道"没人再写了",再统一处理。

这套逻辑保留了你原 VBS 版本的行为,但更可靠:
  - 用 UTF-8 写入(避免 ANSI 编码问题)
  - 协调者生病(崩溃)时,后续等待 30 秒后自动销毁旧锁并重做
"""
from __future__ import annotations

import logging
import os
import time
from pathlib import Path
from typing import Iterable

log = logging.getLogger(__name__)


class SingleInstance:
    """多选右键菜单的单实例锁 + 参数收集器。

    用法:
        si = SingleInstance(root_dir)
        si.append_target(path)
        if si.try_become_coordinator():
            ...
            si.cleanup()
    """

    LOCK_FILE = "fu_lock"
    QUEUE_FILE = "fu_queue.txt"

    STABLE_WINDOW_SEC = 0.6     # 连续 600ms 没新增视为写完
    STALE_LOCK_SEC = 30         # 30 秒锁还没释放视为遗留
    WAIT_COORDINATOR_SEC = 5    # 等待自己变成协调者
    POLL_INTERVAL_SEC = 0.15

    def __init__(self, root_dir: Path):
        self.root = root_dir
        self.lock_path = root_dir / self.LOCK_FILE
        self.queue_path = root_dir / self.QUEUE_FILE
        self._is_coordinator = False
        self._lock_fd: int | None = None

    # ---------- 写入路径 ----------
    def append_target(self, path: str) -> None:
        """将一个目标路径写入队列。"""
        try:
            with open(self.queue_path, "a", encoding="utf-8", newline="\n") as f:
                f.write(path + "\n")
        except Exception as e:
            log.warning("写入队列失败 %s: %s", self.queue_path, e)

    # ---------- 抢占协调者 ----------
    def try_become_coordinator(self) -> bool:
        """尝试成为协调者。

        成功: 创建锁文件 + 等待队尾稳定,然后 True 返回。
        失败: 已经有别人在做协调者,False 返回(应该立刻退出)。
        """
        # 清掉旧锁
        try:
            if self.lock_path.exists():
                mtime = self.lock_path.stat().st_mtime
                if time.time() - mtime > self.STALE_LOCK_SEC:
                    self.lock_path.unlink(missing_ok=True)
                    self.queue_path.unlink(missing_ok=True)
        except Exception as e:
            log.debug("清理旧锁时异常: %s", e)

        acquired = False
        deadline = time.time() + self.WAIT_COORDINATOR_SEC
        while time.time() < deadline:
            try:
                # os.O_EXCL 保证原子:抢到的人才创建文件
                self._lock_fd = os.open(
                    str(self.lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY
                )
                os.write(self._lock_fd, b"coordinator\n")
                acquired = True
                break
            except FileExistsError:
                time.sleep(self.POLL_INTERVAL_SEC)
            except OSError as e:
                log.debug("os.open 锁文件失败: %s", e)
                time.sleep(self.POLL_INTERVAL_SEC)

        if not acquired:
            return False

        self._is_coordinator = True

        # 等待队列稳定(没人追加了)
        last_count = -1
        last_change_time = time.time()
        while True:
            cur_count = self._count_lines(self.queue_path)
            if cur_count != last_count:
                last_count = cur_count
                last_change_time = time.time()
            elif time.time() - last_change_time >= self.STABLE_WINDOW_SEC:
                break
            time.sleep(self.POLL_INTERVAL_SEC)

        return True

    # ---------- 读取与清理 ----------
    def read_targets(self) -> list[str]:
        """协调者读出所有去重后的目标路径。"""
        if not self.queue_path.exists():
            return []
        try:
            with open(self.queue_path, encoding="utf-8", errors="replace") as f:
                raw = [ln.strip() for ln in f if ln.strip()]
        except Exception as e:
            log.warning("读取队列失败: %s", e)
            return []
        # 去重 + 保序
        seen: set[str] = set()
        out: list[str] = []
        for p in raw:
            key = p.lower()
            if key not in seen:
                seen.add(key)
                out.append(p)
        return out

    def cleanup(self) -> None:
        """协调者完成工作后清理锁和队列。"""
        if self._lock_fd is not None:
            try:
                os.close(self._lock_fd)
            except Exception:
                pass
            self._lock_fd = None
        try:
            self.queue_path.unlink(missing_ok=True)
            self.lock_path.unlink(missing_ok=True)
        except Exception as e:
            log.debug("cleanup 异常: %s", e)
        self._is_coordinator = False

    @property
    def is_coordinator(self) -> bool:
        return self._is_coordinator

    @staticmethod
    def _count_lines(p: Path) -> int:
        if not p.exists():
            return 0
        try:
            with open(p, encoding="utf-8", errors="replace") as f:
                return sum(1 for ln in f if ln.strip())
        except Exception:
            return 0


def collect_targets(initial: Iterable[str], root_dir: Path) -> list[str]:
    """便捷入口:把整个合并流程跑完,返回去重后的目标列表。

    Args:
        initial: 程序启动时从 sys.argv 拿到的目标列表(可能就是 1 个)。
        root_dir: 用来放锁/队列文件的目录(通常是程序目录)。

    Returns:
        - 协调者: 合并后的所有目标
        - 非协调者: 空 list(应该立刻退出)
    """
    si = SingleInstance(root_dir)
    targets = [str(t) for t in initial]
    if not targets:
        return []

    si.append_target(targets[0])
    if si.try_become_coordinator():
        return si.read_targets()
    return []
