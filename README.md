# TermX — 跨平台插件化 SSH 终端与服务器运维套件

[![Build & Release All Platforms](https://github.com/DeaglePC/TermX/actions/workflows/build-and-release.yml/badge.svg)](https://github.com/DeaglePC/TermX/actions/workflows/build-and-release.yml)

支持 **Windows / macOS / Linux / Android / iOS / iPadOS** 的现代化插件化 SSH 终端，基于 **Flutter 3.x + `xterm.dart` + `dartssh2`** 构建。

## 核心特性

1. **三态自适应 UI 引擎 (Phone / iPadOS / Desktop)**
   - **桌面端 (macOS / Windows)**：可折叠主机侧栏、多标签、左右/上下嵌套分屏，以及右侧停靠式插件工作台。每个窗格运行独立会话。
   - **iPadOS 平板专属体验**：
     - 完美适配 **Stage Manager（台前调度）** 与 **Split View（1/2、1/3 分屏）** 及 **Slide Over（侧拉浮窗）**，窗口缩放带 80ms 防抖自动发送 `SIGWINCH`。
     - **双手拇指悬浮分体键盘球 (`IpadFloatingThumbPads`)**：可自由拖拽吸附在屏幕左右边缘，解决大屏 iPad 手持时拇指够不到中间快捷键的痛点。
     - **妙控键盘 (Magic Keyboard) 深度适配**：内置 **`CapsLock 映射为 ESC` (Vim 模式)** 与快捷键速查面板（`⌘+Shift+D` 向右分屏、`⌘+Shift+E` 向下分屏、`⌘+Shift+M` 监控、`⌘+Alt+F` SFTP）。
   - **手机端 (iOS / Android)**：双层可滑动虚拟控制键盘栏（支持 `CTRL`/`ALT` 单击组合与双击锁定 + 触觉反馈）+ 弱网防抖 **本地命令草稿箱 (Command Composer)** + 底部上滑插件抽屉。

2. **Apple 钥匙串 (Keychain) 与安全凭据中心**
   - 在 macOS / iOS / iPadOS 上通过原生 `Security.framework` (`SecItemAdd` / `SecItemCopyMatching`) 将密码与私钥存入系统钥匙串。
   - 支持开启 **`kSecAttrSynchronizable` (iCloud Keychain 跨设备同步)** 与 **Touch ID / Face ID 生物识别保护**。

3. **微内核插件架构 (`TermXPlugin`)**
   - **`ServerMonitorPlugin` (`plugin.server_monitor`)**：复用 SSH 独立 Exec 通道实时监控服务器 CPU（含多核负载与历史波形）、内存/Swap、网卡实时吞吐、磁盘分区告警与 Top 进程一键 `SIGTERM`。
   - **`SftpManagerPlugin` (`plugin.sftp_manager`)**：基于 SFTP 协议的可视化文件管理器，支持上传下载进度队列、iPadOS 分屏拖拽投递、`chmod` 权限修改及内置远程配置文件编辑器。
   - **`SnippetsPlugin` (`plugin.snippets`)**：移动端与平板端一键下发常用运维脚本片段。
   - **`PortForwardPlugin` (`plugin.port_forward`)**：可视化管理 SSH 本地 (`-L`) 与远程 (`-R`) 端口转发隧道。
   - **`DockerInspectorPlugin` (`plugin.docker_ui`)**：可在应用内“插件中心”一键动态热加载的社区扩展插件示例。

## 快速运行与测试

### 标签与分屏

- 右键标签：向右/向下分屏、复制为新会话、重命名、重新连接/重启、关闭当前/其他/右侧标签。
- 拖动标签左侧手柄调整顺序；双击标签重命名；中键关闭标签。最后一个标签也可以关闭，再通过「＋」新建。
- 拖动分隔线调整窗格大小，双击分隔线恢复等分。点击窗格切换焦点，插件与快捷命令跟随当前焦点。
- 双击窗格标题或按 `Alt+Enter` 最大化/还原窗格；`Alt+方向键` 依次切换窗格。
- 右键终端：复制、粘贴、全选、查找、清屏、分屏、重连与关闭。查找区分大小写，支持上/下一个匹配和中文/emoji。
- SSH 连接失败会显示真实错误；通过右键菜单重连，不会切入模拟终端。

按 `F1` 查看快捷键。Windows 常用快捷键：

| 操作 | 快捷键 |
| --- | --- |
| 新建本地终端 | Ctrl+Shift+T |
| 向右 / 向下分屏 | Ctrl+Shift+D / Ctrl+Shift+E |
| 关闭当前窗格 | Ctrl+Shift+W |
| 上一个 / 下一个标签 | Ctrl+Shift+Tab / Ctrl+Tab |
| 复制 / 粘贴 / 全选 | Ctrl+Shift+C / V / A |
| 查找 / 上下一个匹配 | Ctrl+Shift+F / Shift+F3 / F3 |
| 清屏 | Ctrl+Shift+K |
| 调整字号 / 重置 | Ctrl+加号 / 减号 / 0 |

`Ctrl+C`、`Ctrl+D` 等 Shell 控制键保留给终端进程。重新连接、重启或关闭会结束对应会话中的进程；复制标签和分屏会建立新会话，不复制进程状态。

### 启动与配置

Windows 启动时默认打开本机真实 Windows PowerShell 会话，工作目录为应用启动目录。
终端通过 ConPTY 连接本机进程，支持交互输入、窗口缩放和 Ctrl+C；退出应用或关闭标签会清理进程。
本地会话不提供 SSH/SFTP 远程插件通道。侧栏不预置模拟服务器，真实 SSH 主机由用户通过添加入口配置。
手动添加的主机元数据保存在应用支持目录的 `hosts.json`，启动时自动恢复，默认仍打开本地 PowerShell。
密码、私钥和私钥口令独立写入系统安全存储；Windows 使用当前用户的 DPAPI 加密，保存在同目录的 `flutter_secure_storage.dat`，不会明文写入主机配置文件。
Windows 默认目录为 `%APPDATA%\com.termx.ssh\termx`。复制到其他电脑或 Windows 用户时，通常需要重新输入凭据。
开发环境需要 Dart 3.10 / Flutter 3.38 或更高版本，以及 Visual Studio C++ 桌面开发工具。

```powershell
# 运行静态代码分析
flutter analyze

# 运行单元测试与组件测试
flutter test

# 在当前桌面端或连接的移动设备/模拟器上启动
flutter run
```
