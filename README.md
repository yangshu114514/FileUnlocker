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

以**管理员**身份运行：

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File install.ps1
```

脚本会：
1. 自提权为管理员
2. 复制 `src\` 到 `C:\Program Files\FileUnlocker\`
3. 自动下载 `handle.exe` 到安装目录
4. 注册文件与文件夹右键菜单（修复文件夹右键缺 `wscript.exe` 前缀的历史 bug）

## 卸载

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

## 目录结构

```
FileUnlocker/
├── install.ps1                 # 安装（部署 + 下载 handle + 注册菜单）
├── uninstall.ps1               # 卸载
├── src/
│   ├── FileUnlocker.ps1        # 主脚本：检测 + GUI + 派发 SYSTEM
│   ├── unlock_system_runner.ps1# SYSTEM 执行器：收 PID 强杀
│   └── FileUnlocker_Run.vbs    # 提权壳（VBS runas）
├── README.md
├── LICENSE
└── .gitignore
```

## 要求

- Windows 10/11
- **PowerShell 7**（`pwsh.exe`）。未安装时安装脚本会提示，国内用户可用：
  ```powershell
  # 方式一：winget（需已装 App Installer）
  winget install Microsoft.PowerShell
  # 方式二：清华镜像站下载离线包
  # 访问 https://mirrors.tuna.tsinghua.edu.cn/GitHub-release/PowerShell/PowerShell/
  # 下载 PowerShell-7.x.x-win-x64.msi 双击安装
  ```
- 管理员权限（终止进程需要）

## 国内用户注意事项

- **handle.exe 下载**：安装脚本默认从 Sysinternals 官方源下载，国内可能缓慢或失败。脚本已内置镜像回退（ghproxy），若仍失败，可手动下载 `Handle.zip` 解压出 `handle.exe` 放到安装目录 `C:\Program Files\FileUnlocker\` 后重跑安装。
  - 手动下载镜像：`https://mirror.ghproxy.com/https://download.sysinternals.com/files/Handle.zip`
- **PowerShell 7 安装源**：见上方「要求」章节的清华镜像。
- 若 `git clone` 慢，可配置代理或使用 `https://mirror.ghproxy.com/https://github.com/ksyangshu/FileUnlocker` 中转。

## 卸载

```powershell
pwsh -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

卸载会删除三处注册表项、注销 SYSTEM 计划任务、删除安装目录，并**重启资源管理器**使右键菜单立即失效（无需手动重启）。
