"""右键菜单的安装/卸载。注册/反注册:

  - HKEY_CLASSES_ROOT\\*\\shell\\解除文件占用              (文件右键)
  - HKEY_CLASSES_ROOT\\Directory\\shell\\解除文件占用      (文件夹右键)
  - HKEY_CLASSES_ROOT\\Directory\\Background\\shell\\解除文件占用
                                                       (文件夹空白处右键,可选)

并写入 uninstaller 注册表【卸载入口】,让用户在"设置→应用→已安装应用"
里能直接看到本程序并卸载。
"""
from __future__ import annotations

import logging
import os
import shutil
import subprocess
import sys
import tempfile
import uuid
import winreg
from pathlib import Path
from typing import Iterable

from . import strings

log = logging.getLogger(__name__)


# ---------- 常量 ----------
INSTALL_DIR = Path(os.environ["LOCALAPPDATA"]) / "FileUnlocker"
APP_EXE_NAME = "文件解锁器.exe"
CONTEXT_MENU_NAME = "解除文件占用"
APP_DISPLAY_NAME = "FileUnlocker (解除文件占用)"
APP_PUBLISHER = "yangshu114514"
APP_VERSION = "2.0.0"
APP_UNINSTALL_KEY = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\FileUnlocker"

# 需要写入注册表的位置
REG_LOCATIONS = [
    r"Software\Classes\*\shell",           # 文件右键
    r"Software\Classes\Directory\shell",   # 文件夹右键
    # 文件夹空白处右键: 默认不开,如果你需要我可以再加
]

# v1.0 旧版(VBS+PS1+handle.exe)写到 HKLM 里的残留,新版安装时主动清掉
# 注意: 删 HKLM 需要管理员权限。若无权限,写日志但不让安装失败。
LEGACY_HKLM_KEYS = [
    r"SOFTWARE\Classes\*\shell\FileUnlocker",
    r"SOFTWARE\Classes\Directory\shell\FileUnlocker",
    r"SOFTWARE\Classes\Directory\Background\shell\FileUnlocker",
    r"SOFTWARE\Classes\Drive\shell\FileUnlocker",
]
LEGACY_INSTALL_DIRS = [
    r"C:\Program Files\FileUnlocker",
    r"C:\Program Files (x86)\FileUnlocker",
]


# ---------- 工具 ----------
def _reg_write(hive, subkey: str, name: str, value, value_type=winreg.REG_SZ) -> None:
    key = winreg.CreateKeyEx(hive, subkey)
    winreg.SetValueEx(key, name, 0, value_type, value)
    winreg.CloseKey(key)


def _reg_delete_tree(hive, subkey: str) -> bool:
    """递归删除注册表键,失败返回 False。使用 HKCU 无需管理员。"""
    try:
        winreg.DeleteKeyEx(hive, subkey)
        return True
    except FileNotFoundError:
        return True
    except OSError:
        # 还有子键 → 递归
        try:
            with winreg.OpenKey(hive, subkey, 0, winreg.KEY_ALL_ACCESS) as k:
                sub_names = []
                i = 0
                while True:
                    try:
                        sub_names.append(winreg.EnumKey(k, i))
                        i += 1
                    except OSError:
                        break
            for name in sub_names:
                if not _reg_delete_tree(hive, subkey + "\\" + name):
                    return False
            winreg.DeleteKeyEx(hive, subkey)
            return True
        except OSError as e:
            log.warning("删注册表失败 %s: %s", subkey, e)
            return False


# ---------- 安装 ----------
def _remove_legacy() -> list[str]:
    """清理 v1.0 旧版的 HKLM 注册表残留和 Program Files 目录。

    HKLM 操作需要管理员权限,无权限时静默忽略(记录日志)。
    返回: 实际清理动作的描述列表(用于日志/提示)。
    """
    actions: list[str] = []
    for key in LEGACY_HKLM_KEYS:
        try:
            if _reg_delete_tree(winreg.HKEY_LOCAL_MACHINE, key):
                actions.append(f"删 HKLM\\{key}")
        except PermissionError:
            log.info(f"无权限删除 HKLM\\{key}(需要管理员),跳过")
        except OSError as e:
            log.warning(f"删 HKLM\\{key} 异常: {e}")

    for d in LEGACY_INSTALL_DIRS:
        if os.path.isdir(d):
            try:
                shutil.rmtree(d, ignore_errors=True)
                if not os.path.isdir(d):
                    actions.append(f"删旧目录 {d}")
                else:
                    log.info(f"rmtree 部分失败: {d} 仍有内容,可能权限不足")
            except Exception as e:
                log.warning(f"删除旧目录 {d} 异常: {e}")
    return actions


def install() -> None:
    """执行安装:
        1. 把当前打包的 exe 复制到 INSTALL_DIR
        2. 在 HKCU 注册右键菜单
        3. 注册【设置→应用】的卸载入口
    """
    INSTALL_DIR.mkdir(parents=True, exist_ok=True)
    dst_exe = INSTALL_DIR / APP_EXE_NAME

    current_exe = Path(sys.argv[0]).resolve()
    if current_exe.is_file() and current_exe.suffix.lower() == ".exe":
        # 如果当前运行的 exe 就是目标(已经在 INSTALL_DIR),没必要复制,
        # 复制还会报 WinError 32(文件被本进程独占)。
        if current_exe != dst_exe:
            log.info("复制 %s -> %s", current_exe, dst_exe)
            shutil.copy2(current_exe, dst_exe)
        else:
            log.info("exe 已在目标位置,跳过复制")
    else:
        log.info("当前运行不是 exe(%s),请先 PyInstaller 打包再安装", current_exe)
        raise RuntimeError("程序不是 exe,请先运行 PyInstaller 再执行安装")

    # 右键菜单
    # Icon: 沿用 v1.0 的 shell32.dll,131 (红叉图标),既清晰又不需要额外 ico 文件
    #   这个图标的意思是"删除/禁止",比 exe 默认的古老 PyInstaller icon 友好得多
    #   若以后想换成自己的 icon,把 shell32.dll,131 换成 dll/exe/ico 的绝对路径即可。
    icon_value = "shell32.dll,131"
    cmd = f'"{dst_exe}" "%1"'
    for parent in REG_LOCATIONS:
        menu_key = parent + "\\" + CONTEXT_MENU_NAME
        _reg_write(winreg.HKEY_CURRENT_USER, menu_key, "", CONTEXT_MENU_NAME)
        _reg_write(winreg.HKEY_CURRENT_USER, menu_key, "Icon", icon_value)
        _reg_write(winreg.HKEY_CURRENT_USER, menu_key + "\\command", "", cmd)

    # 卸载入口(控制面板/设置→应用) — Icon 也用相同的 shell32.dll,131,
    # 不再用 exe 自带的 PyInstaller 丑陋图标
    _reg_write(winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY, "DisplayName", APP_DISPLAY_NAME)
    _reg_write(winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY, "DisplayVersion", APP_VERSION)
    _reg_write(winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY, "Publisher", APP_PUBLISHER)
    _reg_write(winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY, "InstallLocation", str(INSTALL_DIR))
    _reg_write(winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY, "DisplayIcon", "shell32.dll,131")
    _reg_write(winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY, "UninstallString", f'"{dst_exe}" --uninstall')
    _reg_write(winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY, "QuietUninstallString", f'"{dst_exe}" --uninstall --quiet')
    _reg_write(
        winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY,
        "NoModify", 1, winreg.REG_DWORD,
    )
    _reg_write(
        winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY,
        "NoRepair", 1, winreg.REG_DWORD,
    )

    # 通知资源管理器刷新图标(可选)
    try:
        subprocess.run(
            ["ie4uinit.exe", "-show"],
            capture_output=True, timeout=5,
        )
    except Exception:
        pass

    # 尝试清理 v1.0 旧版残留(HKLM + Program Files)。失败不让安装失败。
    try:
        legacy_actions = _remove_legacy()
        if legacy_actions:
            log.info(f"已清理 v1.0 旧版残留: {legacy_actions}")
    except Exception as e:
        log.warning(f"清理 v1.0 旧版残留失败(不影响新版安装): {e}")


# ---------- 卸载 ----------
def uninstall() -> None:
    """执行卸载:
        1. 删除右键菜单
        2. 删除【设置→应用】的入口
        3. 删除 INSTALL_DIR (exe 自己不能删自己,用延迟大法)
    """
    # 删右键菜单
    for parent in REG_LOCATIONS:
        _reg_delete_tree(winreg.HKEY_CURRENT_USER, parent + "\\" + CONTEXT_MENU_NAME)

    # 删卸载入口
    _reg_delete_tree(winreg.HKEY_CURRENT_USER, APP_UNINSTALL_KEY)

    # 删安装目录(包括 exe)。因为本进程是 exe 自己,必须先退出才能删。
    # 思路:
    #  1. 把清理脚本写到 TEMP,内容是 [Sleep 3s → rd INSTALL_DIR → rd 自身]
    #  2. 通过 SCHTASKS 一次性任务执行(在 SYSTEM 之外, 仅当前用户)
    #  3. 由于 SCHTASKS 对中国文路径的引号很敏感,改用 cmd /c "script.bat" 的批次脚本

    cleanup_bat = Path(tempfile.gettempdir()) / f"fu_cleanup_{uuid.uuid4().hex[:8]}.bat"
    # 用 GBK 写,这样 cmd 直接 echo / rd 都能正确处理
    cleanup_bat_content = f"""@echo off
cd /d "%TEMP%"
timeout /t 3 /nobreak >nul
powershell -NoProfile -NonInteractive -Command "Remove-Item -LiteralPath '{INSTALL_DIR}' -Recurse -Force -ErrorAction SilentlyContinue"
schtasks /Delete /TN "%~1" /F >nul 2>&1
del /f /q "%~f0" >nul 2>&1
"""
    cleanup_bat.write_bytes(cleanup_bat_content.encode("gbk", errors="replace").replace(b"\n", b"\r\n"))

    task_name = f"FileUnlocker_Cleanup_{uuid.uuid4().hex[:8]}"
    # 中文 Windows schtasks /SD 必须用 yyyy/mm/dd 格式
    create = subprocess.run(
        [
            "schtasks", "/Create", "/F",
            "/TN", task_name,
            "/SC", "ONCE", "/ST", "00:00", "/SD", "2099/12/31",
            "/TR", f'cmd /c "{cleanup_bat}" {task_name}',
        ],
        capture_output=True, timeout=15,
        encoding="mbcs", errors="replace",
    )
    if create.returncode == 0:
        subprocess.run(
            ["schtasks", "/Run", "/TN", task_name],
            capture_output=True, timeout=15,
        )
    else:
        # --- fallback: 直接 Popen ---
        log.warning("schtasks 失败, 退回 Popen 模式")
        ps_cmd = (
            f"Start-Sleep -Seconds 3; "
            f"Remove-Item -LiteralPath '{INSTALL_DIR}' -Recurse -Force -ErrorAction SilentlyContinue"
        )
        subprocess.Popen(
            [
                "powershell.exe", "-NoProfile", "-NonInteractive",
                "-WindowStyle", "Hidden", "-Command", ps_cmd
            ],
            creationflags=(
                subprocess.CREATE_NO_WINDOW
                | subprocess.DETACHED_PROCESS
                | subprocess.CREATE_NEW_PROCESS_GROUP
            ),
            close_fds=True,
            cwd=os.environ.get("TEMP", "C:\\Windows\\Temp"),
        )


# ---------- 命令行入口 ----------
def main_install(quiet: bool = False) -> int:
    try:
        install()
        log.info("安装完成")
        if not quiet:
            from .ui import show_info
            show_info(strings.INSTALL_DONE)
        return 0
    except Exception as e:
        log.exception("安装失败")
        if not quiet:
            from .ui import show_error
            show_error(f"{strings.INSTALL_FAIL}\n\n错误详情:{e}")
        return 1


def main_uninstall(quiet: bool = False) -> int:
    if not quiet:
        from .ui import ask_yes_no
        if not ask_yes_no(strings.APP_TITLE_RESULT, strings.UNINSTALL_CONFIRM):
            return 0
    try:
        uninstall()
        if not quiet:
            from .ui import show_info
            show_info(strings.UNINSTALL_DONE)
        log.info("卸载完成")
        return 0
    except Exception as e:
        log.exception("卸载失败")
        if not quiet:
            from .ui import show_error
            show_error(f"{strings.UNINSTALL_FAIL}\n\n错误详情:{e}")
        return 1
