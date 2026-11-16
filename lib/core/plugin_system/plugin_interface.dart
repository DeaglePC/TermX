import 'package:flutter/material.dart';
import '../ssh/ssh_session_controller.dart';

/// 插件权限声明枚举
enum PluginPermission {
  sshExec('ssh:exec (后台命令执行通道)'),
  sshSftp('ssh:sftp (SFTP 文件读写通道)'),
  terminalIo('terminal:io (终端输入输出注入)'),
  uiTerminalOverlay('ui:overlay (终端画布卡片贴片挂载)'),
  uiStatusBar('ui:statusbar (状态栏胶囊挂载)'),
  uiPanel('ui:panel (侧栏/底部抽屉挂载)'),
  localStorage('storage:local (独立沙盒配置存储)');

  final String description;
  const PluginPermission(this.description);
}

/// 插件标准元数据清单 (Manifest)
class PluginManifest {
  final String id;
  final String name;
  final String version;
  final String author;
  final String description;
  final IconData icon;
  final Color accentColor;
  final List<PluginPermission> permissions;
  final bool isCorePlugin;

  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    required this.author,
    required this.description,
    required this.icon,
    required this.accentColor,
    required this.permissions,
    this.isCorePlugin = false,
  });
}

/// 宿主向插件暴露的受控上下文能力 (Host API Context)
class PluginContext {
  final SshSessionController? activeSession;
  final void Function(String message) showToast;
  final void Function(String pluginId) requestOpenPanel;

  const PluginContext({
    required this.activeSession,
    required this.showToast,
    required this.requestOpenPanel,
  });

  /// 向当前活跃终端直接注入命令
  void writeToTerminal(String command, {bool appendNewline = true}) {
    final session = activeSession;
    if (session == null) return;
    session.sendRawInput(appendNewline ? '$command\r' : command);
  }

  /// 在独立 SSH Exec 通道执行无感命令并获取结果
  Future<String> execBackground(String command) async {
    final session = activeSession;
    if (session == null) return '';
    return session.execBackgroundCommand(command);
  }
}

/// TermX 微内核插件标准基类
/// 任何新功能只需继承 `TermXPlugin` 并向 `PluginManager` 注册即可自动挂载到桌面端、iPadOS 与手机端各插槽。
abstract class TermXPlugin extends ChangeNotifier {
  PluginManifest get manifest;

  Widget localSessionNotice() => const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text(
            '当前为本地 PowerShell 会话。\n此插件需要连接 SSH 服务器后使用。',
            textAlign: TextAlign.center,
          ),
        ),
      );

  /// 插件初始化钩子
  Future<void> onInit() async {}

  /// 当新终端会话创建或重连时触发（可用于挂载终端流式监听）
  void onSessionAttached(SshSessionController session) {}

  /// 当活跃 SSH 会话切换或建立连接时触发
  void onActiveSessionChanged(SshSessionController? session) {}

  /// 插件卸载清理钩子
  void onUnload() {}

  /// [插槽 1] 状态栏实时微件 (如 CPU/RAM 胶囊、传输进度提示)
  Widget? buildStatusBarWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) =>
      null;

  /// [插槽 2] 侧边栏面板 (Desktop/iPad 横屏) 或 底部抽屉面板 (Phone/iPad 分屏窄窗)
  Widget? buildPanelWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) =>
      null;

  /// [插槽 3] 终端窗格画布浮层微件 (如常见命令输出美化卡片、原文/卡片切换贴片)
  Widget? buildTerminalOverlayWidget(
    BuildContext context,
    PluginContext pluginContext,
    SshSessionController session,
  ) =>
      null;
}
