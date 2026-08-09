# 解除文件占用 (FileUnlocker)

> 一键强制解锁被占用的文件/文件夹。

纯 Python 实现 + Windows 官方 Restart Manager API + 三层兜底强杀。
不再依赖 `handle.exe`,响应速度从 5~15 秒降到 **毫秒级**。

![License](https://img.shields.io/badge/license-MIT-blue)
![Python](https://img.shields.io/badge/python-3.10+-blue)
![Platform](https://img.shields.io/badge/platform-Windows-lightgrey)

---

## 用法

1. **构建**:双击 `构建.ps1`(会自动调 PyInstaller 生成 `文件解锁器.exe`,并复制到本目录)。
2. **安装**:双击 `安装.ps1`(自动复制到 `%LOCALAPPDATA%\FileUnlocker\` + 注册右键菜单 + 注册系统卸载入口)。
3. **使用**:右键任意被占用的文件/文件夹 → **解除文件占用** → 点【强制关闭】。
4. **卸载**:双击 `卸载.ps1`,或在【设置 → 应用 → 已安装的应用】里搜"FileUnlocker"卸载。

---

## 工作原理

```
右键点击 - Detect 阶段
   |
   v
Restart Manager API       <- 官方 API,毫秒级,精准返回占用进程
   |
   v
列出占用进程,排除系统关键进程
   |
   v
用户点击【强制关闭】
   |
   v
[三层兜底强杀]
  1. taskkill /F              (普通权限)
  2. taskkill /F + UAC 提权 (管理员)
  3. SCHTASKS 计划任务 SYSTEM  (最终方案)
   |
   v
解锁完成,文件可删除/移动/重命名
```

### 为什么这么快?

| 方案 | 旧版(handle.exe) | 新版(Restart Manager) |
|------|---|---|
| 启动开销 | 1~2.5s 两次 | 0.1s 一次 |
| 占用检测 | 全系统扫描 2~10s | 毫秒级 |
| EULA 弹窗 | 首次必弹 | 无 |
| 总响应 | 5~15s | **<1s**(不含 UI) |

### 为什么不需要 handle.exe?

Windows Vista 起自带 `rstrtmgr.dll` (Restart Manager),官方为"哪些程序在锁定这个文件"提供了**专门的 API**。它直接返回结构化的进程信息,不需要解析子进程的 stdout,不会受 `handle.exe` 子字符串误报影响。

### 三层兜底怎么选?

| 层 | 适用场景 | 限制 |
|---|---|---|
| 1. taskkill | 同会话、同用户的普通进程 | 不能杀 SYSTEM 进程 |
| 2. taskkill + runas | 其他用户的进程、普通服务 | 需要 UAC 点"是" |
| 3. SCHTASKS SYSTEM | 系统服务、驱动级占用 | 极少用到,稳但稍慢 |

### 安全保护

- **关键进程黑名单**: `System`, `svchost`, `csrss`, `lsass`, `explorer`, `dwm` 等系统核心进程**永不**强杀。
- **自身保护**: 程序不会把自己列为可杀目标。
- **多选合并**: 同时右键多个文件时,自动合并为一次操作,不会启动多个实例。

---

## 项目结构

```
FileUnlocker/
├─ run.py                  # PyInstaller 打包入口
├─ src/
│  ├─ __init__.py
│  ├─ main.py              # 主流程: 参数解析 → 单实例 → 解锁
│  ├─ installer.py         # 安装/卸载(注册表写入)
│  ├─ rm_api.py            # Restart Manager API 封装
│  ├─ process_mgr.py       # 三层强杀调度
│  ├─ admin.py             # 提权辅助(给 process_mgr 用)
│  ├─ single_inst.py       # 多选合并(单实例锁 + 队列)
│  ├─ critical.py          # 系统关键进程黑名单
│  ├─ ui.py                # tkinter 中文界面
│  ├─ strings.py           # 所有中文文案集中在此
│  └─ __main__.py          # 支持 python -m src
├─ 构建.ps1                # PyInstaller 打包脚本
├─ 安装.ps1                # 一键安装(双击运行)
├─ 卸载.ps1                # 一键卸载(双击运行)
├─ .editorconfig           # 强制 UTF-8 with BOM
├─ .gitignore
└─ .gitattributes
```

---

## 开发者指南

### 调试模式(不打包,直接跑)

```powershell
# 在仓库根目录
python run.py --help
python run.py "D:\path\to\locked\file.txt"
python run.py --install --quiet        # 不弹 UI 安装(测试用)
python run.py --uninstall --quiet      # 不弹 UI 卸载(测试用)
python run.py --kill-pid 1234          # 直接强杀某 PID(内部用)
```

### 重新构建 exe

```powershell
.\构建.ps1
# 完成后 dist\文件解锁器.exe 被生成,自动复制到本目录
```

### 修改中文文案

所有可见文案都在 `src/strings.py`,改一个文件即可。

### 添加新的关键进程

修改 `src/critical.py` 的 `CRITICAL_PROCESS_NAMES` 集合。

---

## 编码约定(重要)

本项目所有 `.py` 与 `.ps1` 文件**必须使用 UTF-8 with BOM** 保存。
因为:
- PowerShell 5.1/7 用 BOM 来判断脚本编码,无 BOM 时系统按 GBK 解释,中文会乱码;
- Python 源码默认按 UTF-8 读,有 BOM 兼容性更好;
- 仓库根的 `.editorconfig` 已强制 `charset = utf-8-bom`,VS Code 装 EditorConfig 插件即可在保存时自动加 BOM。

如果你用记事本/其他编辑器手改文件:
1. 打开文件 → 文件 → 另存为;
2. 编码选择 **UTF-8 带 BOM**;
3. 保存后 `python run.py --help` 立即验证。

---

## License

MIT
