# 解除文件占用 (FileUnlocker)

> 一键强制解锁被占用的文件/文件夹 — 右键菜单集成,毫秒级检测。

纯 Python + Windows 官方 Restart Manager API + PEB cwd 检测。
响应速度从 v1.0 的 5~15 秒降到**毫秒级**。

![License](https://img.shields.io/badge/license-MIT-blue)
![Python](https://img.shields.io/badge/python-3.10+-blue)
![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)
![Version](https://img.shields.io/badge/version-2.1.0-green)

---

## 用法

### 一键远程安装(推荐)

打开 PowerShell 粘贴一行:

```powershell
iex (irm https://gh-proxy.com/https://raw.githubusercontent.com/yangshu114514/FileUnlocker/main/remote-install.ps1)
```

如果你的网络直连 raw 快,可以去掉镜像前缀:

```powershell
iex (irm https://raw.githubusercontent.com/yangshu114514/FileUnlocker/main/remote-install.ps1)
```

脚本会自动:
1. 探测可用镜像(gh-proxy.com / ghproxy.net / ghfast.top / 源站)
2. 下载最新 exe 到 `%LOCALAPPDATA%\FileUnlocker\`
3. 注册右键菜单 + 控制面板"已安装应用"入口
4. 清理 v1.0 老版残留(如有,需管理员)

### 本地源码安装(开发者)

```powershell
# 1. 拉代码
git clone https://github.com/yangshu114514/FileUnlocker.git
cd FileUnlocker

# 2. 打包(会生成文件解锁器.exe 自动复制到当前目录)
.\构建.ps1

# 3. 一键安装
.\安装.ps1

# 4. 使用 — 右键任何被占用的文件/文件夹,选择【解除文件占用】
```

### 卸载

- **首选**: 设置 → 应用 → 已安装的应用 → 搜 "FileUnlocker" → 卸载
- **本地**: 双击 `卸载.ps1` 或运行exe加 `--uninstall` 参数

---

## 核心特性

| 特性 | 说明 |
|------|------|
| **极速检测** | Restart Manager API(rstrtmgr.dll),毫秒级返回结构化进程列表 |
| **cwd 占用检测** | 进程把目录当工作目录(cwd)持有时,RM 查不到——用 PEB.CurrentDirectory 读进程内存兜底枚举 (~40ms), 找出"python main.py 位于项目目录"之类的场景 |
| **三层兜底** | taskkill → UAC 提权 → SCHTASKS+SYSTEM,自动选择合适层级 |
| **多选合并** | 同时右键多个文件自动合并为一次操作,单实例锁 + 队列 |
| **文件夹支持** | 自动递归枚举文件夹内所有文件,**不限数量**——分批查询合并,嵌套多深、文件多少都能全部查出,不截断不漏报 |
| **进程保护** | 内置系统关键进程黑名单(`system`/`svchost`/`explorer`/`dwm` 等),绝不误杀 |
| **自身保护** | exe 通过 PID + exe 路径双重排除,不会把自己列为可杀目标 |
| **实时验证** | 强杀前再次检查,避免误杀已被释放的目标 |
| **无黑框闪烁** | 所有 subprocess 调用加 CREATE_NO_WINDOW,调用 taskkill/schtasks 不会弹出黑色 cmd 窗口 |
| **日志自动滚动** | 超过 512KB 自动截断,只留最近一半 |
| **干净卸载** | 注册表 + 文件 + 控制面板入口三点全清 |
| **旧版兼容** | 安装时自动清理 v1.0 在 HKLM 里的旧右键菜单 |

## 三层检测架构(v2.1)

```
目标路径
  ↓
[第一层] Restart Manager (毫秒级)
  ↓ 适用: 被打开的文件句柄占用(文件/文件夹均可)
  ↓ 查到 → 直接列进程
未查到且目标是文件夹 → 进第二层
  ↓
[第二层] MoveFile 试探(微秒级)
  ↓ 若改名成功 → 目录未被持 cwd,安全返回"未占用"
  ↓ 若失败 → 目录被持 cwd,进第三层
  ↓
[第三层] PEB cwd 枚举(~40ms)
  ↓ 枚举全部进程,读 PEB.CurrentDirectory
  ↓ 匹配目标路径父子关系 → 命中 → 列进程
```

| 场景 | 检测耗时 |
|------|------|
| 文件被打开(Word/Excel) | ~0.01s (RM) |
| 文件夹未被占用 | ~0.03s (RM + 试探失败) |
| 文件夹被持 cwd | ~0.04s (RM → 试探失败 → cwd 枚举命中) |

## 两层架构差别

### v1.0 (VBS + PS1 + handle.exe, 已废弃)

- 用 Sysinternals handle.exe 全系统扫描 → 慢(2~10s)
- 需要释放 EULA 接受 → 首次右键弹版权页
- VBS 中文编码 GBK,常出乱码
- 两套脚本(VBS 接收右键 + PS1 干活),整体 500+ 行
- 安装必须管理员(HKLM 注册 + Program Files)

### v2.1 (当前,纯 Python)

- Restart Manager API 直查(文件占用) + PEB cwd 枚举(目录占用),毫秒级
- 单一 exe 干所有事(UI/检测/强杀/安装/卸载)
- 全 UTF-8 + BOM 写法,中文不炸
- 安装路径在 `%LOCALAPPDATA%` + `HKCU`,**不需要管理员**
- 完整测试 + 端到端验证通过
- 所有 subprocess 加 `CREATE_NO_WINDOW` 不弹黑色窗口

> v1.0 完整源码已存档到 [release v1.0-legacy](https://github.com/yangshu114514/FileUnlocker/releases/tag/v1.0-legacy) 供历史参考。

---

## 工作原理

```
右键点击 → 文件夹展开成文件列表,分批注册 Restart Manager
              ↓
       列出占用进程(跨批合并去重,过滤关键)
              ↓
       MessageBoxW 中文弹窗(YES/NO)
              ↓
         强杀(分三层)
     1. taskkill /F        (普通权限)
     2. taskkill + UAC ↑   (管理员)
     3. SCHTASKS + SYSTEM    (最高级)
              ↓
         解锁完成弹窗
```

| 方案 | 旧版 (handle.exe) | 新版 (RM + PEB cwd) |
|------|---|---|
| 启动开销 | 1~2.5s 两次 | 0.1s 一次 |
| 占用检测 | 全系统扫描 2~10s | 毫秒级 |
| EULA 弹窗 | 首次必弹 | 无 |
| 总响应 | 5~15s | **<1s**(不含 UI) |

---

## 项目结构

```
FileUnlocker/
├─ run.py                  # PyInstaller 打包入口
├─ src/
│  ├─ __init__.py
│  ├─ main.py              # 主流程: 命令行 → 单实例合并 → 解锁
│  ├─ installer.py         # 安装/卸载(注册表项 + 控制面板入口)
│  ├─ rm_api.py            # Restart Manager 封装: 文件夹展开 + 分批查询合并
│  ├─ cwd_enum.py          # PEB cwd 枚举: 检测进程把目录当 cwd 持有的场景
│  ├─ process_mgr.py       # 三层强杀(taskkill / UAC / SYSTEM)+ 无黑框 subprocess
│  ├─ admin.py             # 提权辅助
│  ├─ single_inst.py       # 单实例锁,多选合并
│  ├─ critical.py          # 系统关键进程黑名单
│  ├─ ui.py                # MessageBoxW 中文 UI(全代码 < 200 行)
│  ├─ strings.py           # 集中所有中文文案
│  └─ __main__.py          # 支持 python -m src
│
├─ 构建.ps1 / .cmd         # PyInstaller 打包
├─ 安装.ps1 / .cmd         # 一键安装(双击 .cmd 最方便)
├─ 卸载.ps1 / .cmd         # 一键卸载
├─ remote-install.ps1      # 远程一键安装(iex(i
│
├─ .editorconfig           # 强制 UTF-8 with BOM
├─ .gitignore              # 排除 dist/build/__pycache__ 等
├─ .gitattributes          # CRLF/Binary 处理
└─ LICENSE                  # MIT 协议
```

---

## 开发者指南

### 调试模式(不打包,直接跑)

```powershell
cd D:\文档\FileUnlocker

python run.py --help
python run.py "D:\path\to\locked\file.txt"      # 解锁单文件
python run.py --install --quiet                 # 静默安装
python run.py --uninstall --quiet               # 静默卸载
python run.py --kill-pid 1234                   # 强杀某 PID
python run.py --kill-pid 1234 --kill-tree       # 强杀整个进程树
```

### 重打包 exe

```powershell
.\构建.ps1
# 自动生成 文件解锁器.exe,复制一份到当前目录
```

### 修改中文文案

所有可见UI文字都在 `src/strings.py`,改一个文件即可。

### 添加新的关键进程

修改 `src/critical.py` 的 `CRITICAL_PROCESS_NAMES` 集合。

### 新增右键菜单位置

修改 `src/installer.py` 的 `REG_LOCATIONS`,目前选项在:

- `Software\Classes\*\shell` — 文件右键
- `Software\Classes\Directory\shell` — 文件夹右键  
- `Software\Classes\Directory\Background\shell` — 文件夹空白右键(需要加)

---

## 编码约定(重要)

本项目所有 `.py` 与 `.ps1` 文件**必须使用 UTF-8 with BOM** 保存。

why:
- PowerShell 5.1/7 用 BOM 来判断脚本编码,无 BOM 时按 ANSI(GBK 解释),中文大乱码;
- Python 源码默认按 UTF-8 读,带 BOM 兼容性更好;
- 仓库根的 `.editorconfig` 已强制 `charset = utf-8-bom`,VS Code 装 EditorConfig 插件即可保存时自动加 BOM。

如果你用记事本/其他编辑器手改文件:
1. 打开文件 → 文件 → 另存为 → 选 "UTF-8 with BOM"
2. 保存后跑 `python run.py --help` 验证 OK

---

## License

MIT - 详见 [LICENSE](LICENSE) 文件

Copyright (c) 2026 yangshu114514

v1.0 → v2.1 完整重写,仅继承"解除文件占用"这一核心理念;旧版见 [release v1.0-legacy](https://github.com/yangshu114514/FileUnlocker/releases/tag/v1.0-legacy)
