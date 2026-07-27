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
- PowerShell 7（`pwsh.exe` 在 `C:\Program Files\PowerShell\7\`）
- 管理员权限（终止进程需要）
