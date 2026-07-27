# FileUnlocker — 右键解除文件/文件夹占用

一个 Windows 右键菜单工具：右键文件或文件夹 →「解除文件占用」→ 精确找出持有该路径句柄的进程并以 SYSTEM 权限强制终止。

## 特性

- **精确检测**：基于 Sysinternals `handle.exe` 枚举真实文件句柄，不靠命令行字符串猜测（旧方案漏报/误杀的根源）。
- **SYSTEM 提权**：终止动作通过 `NT AUTHORITY\SYSTEM` 计划任务执行，可杀掉普通管理员杀不动的顽固进程。
- **安全护栏**：自动排除自身进程树与关键系统进程（svchost / lsass / winlogon 等），终止前弹确认框。
- **文件与文件夹通用**：目录模式递归检测内部所有文件的持有者。
- **自动安装 handle**：`install.ps1` 自动从 Sysinternals 官网下载 `handle.exe`，无需手动准备。

## 原理

调用链：

```
右键菜单 → wscript.exe FileUnlocker_Run.vbs "%1"
         → VBS 以 runas 提权管理员 → pwsh FileUnlocker.ps1
         → handle.exe 枚举持有者 → 弹确认框
         → 注册 SYSTEM 计划任务执行 unlock_system_runner.ps1 强杀
         → 读回结果弹窗
```

GUI（确认框/结果框）运行在用户态管理员会话（可见），SYSTEM 仅在后台杀进程并写结果文件（规避 Session 0 隔离）。

## 安装

直接**右键 `install.bat` → 以管理员身份运行**（无需 PowerShell 7 即可启动安装器，脚本会自动检测并引导安装依赖）：

脚本会：
1. 自提权为管理员
2. 检测 PowerShell 7，缺失则弹窗询问是否下载安装
3. 复制 `src\` 到 `C:\Program Files\FileUnlocker\`
4. 自动下载 `handle.exe`（多镜像回退）到安装目录
5. 注册文件与文件夹右键菜单
6. 弹窗显示免责声明

## 卸载

右键 `uninstall.bat` → 以管理员身份运行。会删除三处注册表项、注销 SYSTEM 计划任务、删除安装目录，并**重启资源管理器**使右键菜单立即失效。

## 目录结构

```
FileUnlocker/
├── install.bat                # 安装（BAT，全系统兼容，检查并引导依赖）
├── uninstall.bat              # 卸载（BAT）
├── src/
│   ├── FileUnlocker.ps1        # 主脚本：检测 + GUI + 派发 SYSTEM
│   ├── unlock_system_runner.ps1# SYSTEM 执行器：收 PID 强杀
│   └── FileUnlocker_Run.vbs    # 提权壳（VBS runas）+ 多选协调器
├── README.md
├── LICENSE
└── .gitignore
```

> 注：`install.ps1` / `uninstall.ps1` 为旧版 PowerShell 安装器，已弃用，请使用 `.bat` 版本。

## 要求

- Windows 10/11
- **PowerShell 7**（`pwsh.exe`）：本工具的必需依赖。未安装时安装脚本会自动检测并询问是否下载安装，国内用户可用：
  ```powershell
  # 方式一：winget（需已装 App Installer）
  winget install Microsoft.PowerShell
  # 方式二：GitHub 官方（国内慢可用下方镜像中转）
  # https://github.com/PowerShell/PowerShell/releases
  # 方式三：ghproxy 镜像中转下载 MSI（可能因网络环境不可达，失败请用方式一/二）
  # https://mirror.ghproxy.com/https://github.com/PowerShell/PowerShell/releases/download/v7.5.0/PowerShell-7.5.0-win-x64.msi
  ```
- 管理员权限（终止进程需要）

## 国内用户注意事项

- **handle.exe 下载**：安装脚本默认从 Sysinternals 官方源下载，失败回退 ghproxy 镜像。若均不可达（ghproxy 可能因网络环境无法解析），可手动下载 `Handle.zip` 解压出 `handle.exe` 放到安装目录 `C:\Program Files\FileUnlocker\` 后重跑安装。
  - 手动下载：`https://download.sysinternals.com/files/Handle.zip` 或 `https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip`
- **PowerShell 7 安装源**：见上方「要求」章节的 ghproxy 镜像中转。若 ghproxy 不可达，用 `winget install Microsoft.PowerShell` 或 GitHub 官方 Release 手动下载 MSI。
- 若 `git clone` 慢，可配置代理或使用 `https://mirror.ghproxy.com/https://github.com/ksyangshu/FileUnlocker` 中转。

## 卸载

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

卸载会删除三处注册表项、注销 SYSTEM 计划任务、删除安装目录，并**重启资源管理器**使右键菜单立即失效（无需手动重启）。
