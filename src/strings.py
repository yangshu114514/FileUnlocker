"""所有面向用户的中文字符串集中在此。

修改文案只需要改这一个文件,不用翻业务代码。
所有字符串都是普通 Python str(UTF-8 源码),tkinter 直接显示。
"""

APP_NAME = "解除文件占用"
APP_TITLE_DETECT = f"{APP_NAME} - 检测结果"
APP_TITLE_CONFIRM = f"{APP_NAME} - 确认关闭程序"
APP_TITLE_RESULT = f"{APP_NAME} - 完成"
APP_TITLE_ERROR = f"{APP_NAME} - 错误"

# 提示信息
MSG_IN_USE_TITLE = f"{APP_NAME} - 文件被占用"
MSG_IN_USE_BODY = (
    "以下 {n} 个文件/文件夹被占用:\n\n"
    "{paths}\n\n"
    "占用它们的程序:\n{procs}\n\n"
    "是否强制关闭这些程序?\n"
    "(被关闭程序未保存的数据可能丢失)"
)
MSG_NOT_OCCUPIED = "所选 {n} 个目标均未被占用。\n可以直接删除/移动/重命名。"
MSG_CRITICAL_PROTECTED = (
    "占用程序中包含 Windows 系统关键进程\n"
    "    {procs}\n\n"
    "为保系统稳定,已自动跳过这些程序,不会尝试关闭。\n"
    "如需解锁请手动操作或重启资源管理器。"
)
MSG_KILL_ASK = (
    "即将以 {mode} 方式关闭 {n} 个程序:\n\n{procs}\n\n"
    "确认继续?"
)
MSG_KILL_OK = "成功关闭 {n} 个程序。"
MSG_KILL_FAIL = "关闭失败:{err}"
MSG_PARTIAL_OK = (
    "部分关闭成功。\n"
    "成功:{ok_count} 个\n"
    "失败:{fail_count} 个\n\n"
    "失败原因:\n{fail_detail}"
)
MSG_ELEVATE_HINT = (
    "将请求管理员权限以关闭以下程序:\n\n{procs}\n\n"
    "请在弹出的 UAC 提示中点【是】。"
)
MSG_ELEVATE_CANCEL = "已取消提权,部分占用无法解除。"
MSG_NOTHING_TO_DO = "没有可执行的操作。"

# 按钮文本
BTN_KILL = "强制关闭"
BTN_CANCEL = "取消"
BTN_OK = "确定"

# 占用模式描述
MODE_NORMAL = "常规关闭"
MODE_ADMIN = "管理员关闭"
MODE_SYSTEM = "SYSTEM 强制关闭"

# 卸载
UNINSTALL_CONFIRM = "确定要卸载【解除文件占用】吗?\n\n将删除:\n- 右键菜单项\n- %LOCALAPPDATA%\\FileUnlocker 目录\n- 控制面板中的卸载入口"
UNINSTALL_DONE = "卸载完成。祝使用愉快!"
UNINSTALL_FAIL = "卸载失败,请查看 %TEMP%\\FileUnlocker_uninstall.log"

# 安装
INSTALL_DONE = (
    "安装成功!\n\n现在可以:\n"
    "1. 右键任意文件/文件夹\n"
    "2. 选择【解除文件占用】\n"
    "3. 一键强制解锁\n\n"
    "程序位置:%LOCALAPPDATA%\\FileUnlocker"
)
INSTALL_FAIL = "安装失败,请查看 %TEMP%\\FileUnlocker_install.log"

# 调试日志路径
DEBUG_LOG_NAME = "FileUnlocker_debug.log"
UNINSTALL_LOG_NAME = "FileUnlocker_uninstall.log"
INSTALL_LOG_NAME = "FileUnlocker_install.log"
