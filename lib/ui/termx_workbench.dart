import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models/host_config.dart';
import '../core/models/host_store.dart';
import '../core/models/remote_os.dart';
import '../core/models/terminal_workspace.dart';
import '../core/platform/desktop_native_bridge.dart';
import '../core/plugin_system/plugin_interface.dart';
import '../core/plugin_system/plugin_manager.dart';
import '../core/ssh/ssh_session_controller.dart';
import '../core/theme/adaptive_layout.dart';
import '../core/theme/ui_tokens.dart';
import '../core/vault/vault_service.dart';
import '../plugins/docker_inspector/docker_inspector_plugin.dart';
import '../plugins/port_forward/port_forward_plugin.dart';
import '../plugins/server_monitor/server_monitor_plugin.dart';
import '../plugins/sftp_manager/sftp_manager_plugin.dart';
import '../plugins/snippets/snippets_plugin.dart';
import 'mobile/mobile_accessory_keyboard.dart';
import 'tablet/ipad_adaptive_controls.dart';
import 'widgets/dialogs_and_sheets.dart';
import 'widgets/os_logo_icon.dart';
import 'widgets/terminal_pane_view.dart';
import 'widgets/terminal_tab_button.dart';

class TermXWorkbench extends StatefulWidget {
  const TermXWorkbench({
    super.key,
    this.hostStore,
    this.autoStartLocalShell = true,
  });

  final HostStore? hostStore;
  final bool autoStartLocalShell;

  @override
  State<TermXWorkbench> createState() => _TermXWorkbenchState();
}

class _TermXWorkbenchState extends State<TermXWorkbench>
    implements DesktopFileDropListener {
  final VaultService _vaultService = VaultService();
  final PluginManager _pluginManager = PluginManager();
  late final HostStore _hostStore = widget.hostStore ?? HostStore();
  final GlobalKey _rightPanelBoundsKey = GlobalKey();
  bool _hostsLoaded = false;

  final List<HostConfig> _hosts = [
    if (Platform.isWindows)
      HostConfig(
        id: 'local_powershell',
        name: '本地 PowerShell',
        group: '本机',
        host: 'localhost',
        username: Platform.environment['USERNAME'] ?? 'local',
        authMethod: AuthMethod.localShell,
        tags: const ['Windows', 'PowerShell'],
        syncToICloudKeychain: false,
      )
    else if ((Platform.isMacOS || Platform.isLinux) &&
        Platform.environment['FLUTTER_TEST'] != 'true')
      HostConfig(
        id: 'local_shell',
        name: Platform.isMacOS ? '本地 Zsh' : '本地 Bash',
        group: '本机',
        host: 'localhost',
        username: Platform.environment['USER'] ?? 'local',
        authMethod: AuthMethod.localShell,
        tags: Platform.isMacOS
            ? const ['macOS', 'zsh']
            : const ['Linux', 'bash'],
        syncToICloudKeychain: false,
      ),
  ];

  final TerminalWorkspace _workspace = TerminalWorkspace();
  final Set<String> _collapsedGroups = {};
  final TextEditingController _hostSearchCtrl = TextEditingController();
  final GlobalKey _topBarBoundsKey = GlobalKey();
  String? _lastFocusedPane;
  // Coalesce plugin refreshes until the selected terminal has painted.
  bool _workspaceUpdateScheduled = false;

  // 顶部标签 / 窗格拖拽分屏与重排状态
  TerminalTab? _pointerDownTab;
  TerminalTab? _tabActiveBeforePointerDown;
  Offset? _tabPointerDownPos;
  Offset? _tabPointerLatestPos;
  Offset? _dragTrackPos;
  TerminalTab? _draggingTab;
  TerminalTab? _autoPreviewTargetTab;
  String? _tabReorderHoverId;
  AxisDirection? _tabReorderHoverEdge;
  bool _topBarDetachHover = false;

  // 界面状态与自适应参数
  FormFactorOverride _formFactorOverride = FormFactorOverride.auto;
  TermXColorPalette _colorPalette = TermXColorPalette.presets.first;
  bool _leftSidebarCollapsed = false;
  bool get _isSplitTerminal =>
      (_workspace.activeTab?.root.paneIds.length ?? 0) > 1;
  bool _ipadThumbPadsVisible = true;
  bool _capsLockRemappedToEsc = true;

  SshSessionController? get _activeSession => _workspace.activePane?.session;

  @override
  void initState() {
    super.initState();
    DesktopNativeBridge.instance.addDropListener(this);
    _workspace.addListener(_onWorkspaceChanged);
    _bootstrapCoreAndPlugins();
  }

  void _maybeAutoOpenSftpOnDrag(Offset globalPosition) {
    final session = _activeSession;
    if (session == null || session.isLocalSession) return;
    if (session.state != SessionConnectionState.connected &&
        !session.isDemoMode) {
      return;
    }
    if (_pluginManager.activePanelPluginId == SftpManagerPlugin.pluginId) {
      return;
    }
    final ctx = _rightPanelBoundsKey.currentContext;
    final box = ctx?.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      final local = box.globalToLocal(globalPosition);
      if (box.paintBounds.contains(local)) {
        _pluginManager.setActivePanelPlugin(SftpManagerPlugin.pluginId);
      }
    }
  }

  @override
  void onNativeDragEntered(Offset globalPosition) {
    _maybeAutoOpenSftpOnDrag(globalPosition);
  }

  @override
  void onNativeDragUpdated(Offset globalPosition) {
    _maybeAutoOpenSftpOnDrag(globalPosition);
  }

  @override
  void onNativeDragExited() {}

  @override
  void onNativeFilesDropped(Offset globalPosition, List<String> paths) {}

  Future<void> _loadSavedHosts() async {
    try {
      final savedHosts = await _hostStore.load();
      if (!mounted) return;
      setState(() {
        _hosts.addAll(savedHosts);
        _hostsLoaded = true;
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('读取本地主机配置失败。原文件已保留，暂时无法添加主机。')),
      );
    }
  }

  Future<void> _bootstrapCoreAndPlugins() async {
    // 并行立即读取本地持久化的 SSH 服务器列表（含已记忆的系统类型与 Logo），无需等待本机 PTY 启动
    unawaited(_loadSavedHosts());

    // 注册四大官方核心插件到微内核 PluginManager
    await _pluginManager.registerPlugin(ServerMonitorPlugin());
    await _pluginManager.registerPlugin(SftpManagerPlugin());
    await _pluginManager.registerPlugin(SnippetsPlugin());
    await _pluginManager.registerPlugin(PortForwardPlugin());

    // Windows 自动打开本地 PowerShell；其他平台等待用户添加主机。
    if (mounted &&
        widget.autoStartLocalShell &&
        _hosts.isNotEmpty &&
        _hosts.first.authMethod == AuthMethod.localShell) {
      await _openNewSession(_hosts.first);
    }
  }

  Future<void> _saveHost(HostConfig host, HostSecretCredential secret) async {
    if (!_hostsLoaded) throw StateError('本地主机配置尚未成功读取，请稍后重试');
    await _vaultService.saveCredential(host, secret);
    final updatedHosts = [..._hosts, host];
    try {
      await _hostStore.save(updatedHosts);
    } catch (_) {
      await _vaultService.deleteCredential(host);
      rethrow;
    }
    if (!mounted) return;
    setState(() => _hosts.add(host));
  }

  static String _normalizedGroupName(HostConfig h) {
    if (h.authMethod == AuthMethod.localShell) return '本机';
    final g = h.group.trim();
    return g.isEmpty ? '默认分组' : g;
  }

  List<String> get _existingSshGroups {
    final seen = <String>{};
    for (final h in _hosts) {
      if (h.authMethod == AuthMethod.localShell) continue;
      seen.add(_normalizedGroupName(h));
    }
    return seen.toList();
  }

  Future<void> _addHost([String? initialGroup]) async {
    final host = await showAddHostDialog(
      context: context,
      onSave: _saveHost,
      initialGroup: initialGroup,
      existingGroups: _existingSshGroups,
    );
    if (mounted && host != null) await _openNewSession(host);
  }

  Future<void> _updateHost(
    HostConfig updated,
    HostSecretCredential secret,
  ) async {
    if (!_hostsLoaded) throw StateError('本地主机配置尚未成功读取，请稍后重试');
    final idx = _hosts.indexWhere((h) => h.id == updated.id);
    if (idx < 0) return;
    await _vaultService.saveCredential(updated, secret);
    final updatedHosts = List<HostConfig>.of(_hosts);
    updatedHosts[idx] = updated;
    await _hostStore.save(updatedHosts);
    if (!mounted) return;
    setState(() {
      _hosts[idx] = updated;
      for (final pane in _workspace.panes.values) {
        if (!pane.disposed && pane.session.host.id == updated.id) {
          pane.session.updateHostMetadata(updated);
        }
      }
    });
  }

  Future<void> _deleteHost(HostConfig target) async {
    if (!_hostsLoaded || target.authMethod == AuthMethod.localShell) return;
    final updatedHosts = _hosts.where((h) => h.id != target.id).toList();
    await _hostStore.save(updatedHosts);
    try {
      await _vaultService.deleteCredential(target);
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _hosts.removeWhere((h) => h.id == target.id);
    });
  }

  Future<void> _editHost(HostConfig host) async {
    if (!_hostsLoaded || host.authMethod == AuthMethod.localShell) return;
    HostSecretCredential? existingCred;
    try {
      existingCred = await _vaultService.readCredential(host);
    } catch (_) {}
    if (!mounted) return;
    await showHostFormDialog(
      context: context,
      existingHost: host,
      initialCredential: existingCred,
      onSave: _updateHost,
      onDelete: _deleteHost,
      existingGroups: _existingSshGroups,
    );
  }

  Future<void> _moveHostToGroup(HostConfig host) async {
    if (!_hostsLoaded || host.authMethod == AuthMethod.localShell) return;
    final ctrl = TextEditingController(text: _normalizedGroupName(host));
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(
            '移动 "${host.name}" 到分组',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: ctrl,
                  autofocus: true,
                  onChanged: (_) => setDialogState(() {}),
                  decoration: const InputDecoration(
                    labelText: '目标分组名称（可直接输入新分组）',
                    isDense: true,
                  ),
                  onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final g in <String>{
                      ..._existingSshGroups,
                      '默认分组',
                      '家庭 NAS',
                      '生产环境',
                    })
                      ActionChip(
                        visualDensity: VisualDensity.compact,
                        label: Text(g, style: const TextStyle(fontSize: 11.5)),
                        onPressed: () => Navigator.of(ctx).pop(g),
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    ctrl.dispose();
    if (!mounted || chosen == null) return;
    final nextGroup = chosen.isEmpty ? '默认分组' : chosen;
    final idx = _hosts.indexWhere((h) => h.id == host.id);
    if (idx < 0) return;
    final updated = _hosts[idx].copyWith(group: nextGroup);
    final updatedHosts = List<HostConfig>.of(_hosts)..[idx] = updated;
    await _hostStore.save(updatedHosts);
    if (!mounted) return;
    setState(() {
      _hosts[idx] = updated;
      _collapsedGroups.remove(nextGroup);
    });
  }

  Future<void> _renameHostGroup(String oldGroup) async {
    if (!_hostsLoaded || oldGroup == '本机') return;
    final ctrl = TextEditingController(text: oldGroup);
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '重命名分组',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '新分组名称',
            isDense: true,
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    ctrl.dispose();
    if (!mounted || chosen == null || chosen.isEmpty || chosen == oldGroup) {
      return;
    }
    final updatedHosts = _hosts
        .map(
          (h) => h.authMethod != AuthMethod.localShell &&
                  _normalizedGroupName(h) == oldGroup
              ? h.copyWith(group: chosen)
              : h,
        )
        .toList();
    await _hostStore.save(updatedHosts);
    if (!mounted) return;
    setState(() {
      for (var i = 0; i < _hosts.length; i++) {
        _hosts[i] = updatedHosts[i];
      }
      if (_collapsedGroups.remove(oldGroup)) {
        _collapsedGroups.add(chosen);
      }
    });
  }

  Future<void> _showGroupContextMenu(String groupName, Offset globalPos) async {
    if (groupName == '本机') return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(globalPos);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        point.dx,
        point.dy,
        overlay.size.width - point.dx,
        overlay.size.height - point.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'add',
          child: Text('在 "$groupName" 中新增主机…'),
        ),
        const PopupMenuItem(value: 'rename', child: Text('重命名此分组…')),
      ],
    );
    if (!mounted) return;
    if (action == 'add') {
      await _addHost(groupName);
    } else if (action == 'rename') {
      await _renameHostGroup(groupName);
    }
  }

  Future<void> _showHostContextMenu(HostConfig host, Offset globalPos) async {
    if (host.authMethod == AuthMethod.localShell) return;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(globalPos);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        point.dx,
        point.dy,
        overlay.size.width - point.dx,
        overlay.size.height - point.dy,
      ),
      items: const [
        PopupMenuItem(value: 'connect', child: Text('新建终端连接')),
        PopupMenuItem(value: 'edit', child: Text('编辑会话配置…')),
        PopupMenuItem(value: 'moveGroup', child: Text('移动到分组…')),
        PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: Text('删除主机', style: TextStyle(color: TxColors.danger)),
        ),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'connect':
        await _openNewSession(host);
      case 'edit':
        await _editHost(host);
      case 'moveGroup':
        await _moveHostToGroup(host);
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text(
              '删除已保存会话',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
            content: Text(
              '确定要删除 "${host.name}" (${host.username}@${host.host}:${host.port}) 及其登录凭据吗？',
              style: const TextStyle(fontSize: 13),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: TxColors.danger,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('确认删除'),
              ),
            ],
          ),
        );
        if (confirmed == true && mounted) {
          await _deleteHost(host);
        }
    }
  }

  Future<void> _openNewSession(HostConfig host) async {
    if (!mounted) return;
    await _connectPane(_workspace.open(host));
  }

  Future<void> _connectPane(TerminalPane pane) async {
    final session = pane.session;
    final host = session.host;

    final knownHost = _hosts.where((h) => h.id == host.id).firstOrNull;
    if (knownHost?.detectedOs != null) {
      session.applyDetectedOs(
        knownHost!.detectedOs!,
        knownHost.detectedOsPrettyName,
      );
    }
    session.addListener(() => _syncDetectedOsFromSession(session));

    HostSecretCredential? credential;
    try {
      credential = host.authMethod == AuthMethod.localShell
          ? null
          : await _vaultService.readCredential(host);
    } catch (_) {
      if (pane.disposed) return;
      session.terminal.write('\r\n无法读取系统安全存储中的登录凭据，请检查当前用户权限。\r\n');
      return;
    }
    if (pane.disposed) return;
    await session.connect(credential);
    if (!mounted || pane.disposed || _workspace.activePane != pane) return;
    _pluginManager.notifyActiveSessionChanged(pane.session);
  }

  void _syncDetectedOsFromSession(SshSessionController session) {
    if (!mounted || session.isDisposed) return;
    final os = session.detectedOs;
    if (os == RemoteOsType.unknown) return;
    final pretty = session.detectedOsPrettyName;

    for (final other in _workspace.panes.values) {
      if (!other.disposed && other.session.host.id == session.host.id) {
        other.session.applyDetectedOs(os, pretty);
      }
    }

    final idx = _hosts.indexWhere((h) => h.id == session.host.id);
    if (idx < 0) return;
    final current = _hosts[idx];
    if (current.detectedOs == os && current.detectedOsPrettyName == pretty) {
      return;
    }
    setState(() {
      _hosts[idx] = current.copyWith(
        detectedOs: os,
        detectedOsPrettyName: pretty,
      );
    });
    if (_hostsLoaded && current.authMethod != AuthMethod.localShell) {
      unawaited(_hostStore.save(_hosts).catchError((Object _) {}));
    }
  }

  RemoteOsType _hostOsType(HostConfig h) {
    if (h.authMethod == AuthMethod.localShell) {
      if (Platform.isMacOS) return RemoteOsType.macos;
      if (Platform.isLinux) return RemoteOsType.linux;
      return RemoteOsType.windows;
    }
    if (h.authMethod == AuthMethod.demoSandbox) return RemoteOsType.ubuntu;
    return h.detectedOs ?? RemoteOsType.unknown;
  }

  String? _hostOsLabel(HostConfig h) {
    final os = _hostOsType(h);
    if (os == RemoteOsType.unknown) return null;
    return h.detectedOsPrettyName ?? os.displayName;
  }

  void _onWorkspaceChanged() {
    if (!mounted) return;
    setState(() {});
    final paneId = _workspace.activePane?.id;
    if (paneId == _lastFocusedPane) return;
    _lastFocusedPane = paneId;
    if (_workspaceUpdateScheduled) return;
    _workspaceUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _workspaceUpdateScheduled = false;
      if (!mounted) return;
      final pane = _workspace.activePane;
      if (pane != null && !pane.disposed) pane.focus.requestFocus();
      // Show the selected terminal before starting plugin I/O. Rapid switches
      // within a frame refresh only the final selected session.
      _pluginManager.notifyActiveSessionChanged(pane?.session);
    });
  }

  void _splitPane(Axis axis, {TerminalTab? tab, String? paneId}) {
    final target = tab ?? _workspace.activeTab;
    if (target == null) return;
    _connectPane(
      _workspace.split(target, paneId ?? target.focusedPaneId, axis),
    );
  }

  void _restartPane(TerminalTab tab, String paneId) {
    _connectPane(_workspace.restart(tab, paneId));
  }

  Future<void> _renameTab(TerminalTab tab) async {
    final controller = TextEditingController(text: _workspace.title(tab));
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名标签'),
        content: TextField(
          controller: controller,
          autofocus: true,
          onSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    // Let the dialog finish its closing animation before disposing the field.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    controller.dispose();
    if (mounted && title != null && _workspace.tabs.contains(tab)) {
      _workspace.rename(tab, title);
    }
  }

  void _applyTabColor(TerminalTab tab, Color? color) {
    _workspace.setTabColor(tab, color);
    final pane = _workspace.panes[tab.focusedPaneId];
    if (pane == null || pane.disposed) return;
    final host = pane.session.host;
    if (host.authMethod == AuthMethod.localShell) return;
    final idx = _hosts.indexWhere((h) => h.id == host.id);
    if (idx < 0) return;
    final updated = color == null
        ? _hosts[idx].copyWith(clearTabColor: true)
        : _hosts[idx].copyWith(tabColorValue: color.toARGB32());
    setState(() {
      _hosts[idx] = updated;
      pane.session.updateHostMetadata(updated);
    });
    if (_hostsLoaded) {
      unawaited(_hostStore.save(_hosts).catchError((Object _) {}));
    }
  }

  Future<void> _showTabMenu(TerminalTab tab, Offset position) async {
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
    final currentColorVal = tab.customColor?.toARGB32();
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        point.dx,
        point.dy,
        overlay.size.width - point.dx,
        overlay.size.height - point.dy,
      ),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          height: 44,
          child: Builder(
            builder: (menuCtx) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '标签颜色',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                const SizedBox(height: 5),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    Tooltip(
                      message: '默认无色',
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: () => Navigator.of(menuCtx).pop('color:clear'),
                        child: Container(
                          width: 19,
                          height: 19,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white10,
                            border: Border.all(
                              color: currentColorVal == null
                                  ? Colors.white
                                  : Colors.white24,
                              width: currentColorVal == null ? 1.8 : 1.0,
                            ),
                          ),
                          child: const Icon(
                            Icons.format_color_reset_outlined,
                            size: 11,
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    ),
                    for (final preset in TabColorPreset.presets)
                      Tooltip(
                        message: preset.name,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => Navigator.of(
                            menuCtx,
                          ).pop('color:${preset.color.toARGB32()}'),
                          child: Container(
                            width: 19,
                            height: 19,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: preset.color,
                              border: Border.all(
                                color: currentColorVal == preset.color.toARGB32()
                                    ? Colors.white
                                    : Colors.black26,
                                width: currentColorVal == preset.color.toARGB32()
                                    ? 2.0
                                    : 1.0,
                              ),
                            ),
                            child: currentColorVal == preset.color.toARGB32()
                                ? const Icon(
                                    Icons.check,
                                    size: 11,
                                    color: Colors.black87,
                                  )
                                : null,
                          ),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'right', child: Text('向右分屏    Ctrl+Shift+D')),
        const PopupMenuItem(value: 'down', child: Text('向下分屏    Ctrl+Shift+E')),
        const PopupMenuItem(value: 'duplicate', child: Text('复制标签（新建独立会话）')),
        const PopupMenuItem(value: 'rename', child: Text('重命名标签')),
        const PopupMenuItem(value: 'restart', child: Text('重新连接 / 重启终端')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'close', child: Text('关闭标签')),
        const PopupMenuItem(value: 'others', child: Text('关闭其他标签')),
        const PopupMenuItem(value: 'rightTabs', child: Text('关闭右侧标签')),
      ],
    );
    if (!mounted || !_workspace.tabs.contains(tab) || action == null) return;
    if (action == 'color:clear') {
      _applyTabColor(tab, null);
      return;
    }
    if (action.startsWith('color:')) {
      final argb = int.tryParse(action.substring(6));
      if (argb != null) {
        _applyTabColor(tab, Color(argb));
      }
      return;
    }
    switch (action) {
      case 'right':
        _splitPane(Axis.horizontal, tab: tab);
      case 'down':
        _splitPane(Axis.vertical, tab: tab);
      case 'duplicate':
        _openNewSession(_workspace.panes[tab.focusedPaneId]!.session.host);
      case 'rename':
        await _renameTab(tab);
      case 'restart':
        _restartPane(tab, tab.focusedPaneId);
      case 'close':
        _workspace.closeTab(tab);
      case 'others':
        _workspace.closeOthers(tab);
      case 'rightTabs':
        _workspace.closeOthers(tab, onlyRight: true);
    }
  }

  void _newLocalTab() {
    final host = _hosts
        .where((h) => h.authMethod == AuthMethod.localShell)
        .firstOrNull;
    if (host != null) {
      _openNewSession(host);
    } else if (_activeSession != null) {
      _openNewSession(_activeSession!.host);
    } else if (_hostsLoaded) {
      _addHost();
    }
  }

  PluginContext _buildPluginContext(AdaptiveLayoutMode layoutMode) {
    return PluginContext(
      activeSession: _activeSession,
      showToast: (msg) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg, style: const TextStyle(fontSize: 12.5)),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 2),
          ),
        );
      },
      requestOpenPanel: (pluginId) {
        _pluginManager.setActivePanelPlugin(pluginId);
        if (layoutMode == AdaptiveLayoutMode.compact) {
          _openMobilePluginBottomSheet(pluginId);
        }
      },
    );
  }

  void _openMobilePluginBottomSheet(String pluginId) {
    _pluginManager.setActivePanelPlugin(pluginId);
    final plugin = _pluginManager.activePanelPlugin;
    if (plugin == null) return;
    final pluginContext = _buildPluginContext(AdaptiveLayoutMode.compact);

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: TxColors.bgSidebar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.68,
        minChildSize: 0.4,
        maxChildSize: 0.92,
        builder: (ctx, scrollController) => Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 36,
              height: 3.5,
              decoration: BoxDecoration(
                color: TxColors.borderStrong,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            _buildPluginSelectorHeader(pluginContext, isCompactSheet: true),
            Expanded(
              child: ListenableBuilder(
                listenable: _pluginManager,
                builder: (ctx, _) {
                  final current = _pluginManager.activePanelPlugin;
                  if (current == null) {
                    return const Center(child: Text('未选择插件'));
                  }
                  return current.buildPanelWidget(ctx, pluginContext) ??
                      const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 处理 iPadOS Magic Keyboard / 桌面端全局快捷键与 CapsLock -> ESC 重映射
  KeyEventResult _handleGlobalKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // iPadOS / Vim 用户专属：CapsLock 重映射为物理 ESC
    if (_capsLockRemappedToEsc &&
        event.logicalKey == LogicalKeyboardKey.capsLock) {
      _activeSession?.sendRawInput('\x1b');
      return KeyEventResult.handled;
    }

    final isCmdOrCtrl =
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;

    if (event.logicalKey == LogicalKeyboardKey.f1) {
      showIpadShortcutCheatSheet(context);
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isAltPressed &&
        [
          LogicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowRight,
          LogicalKeyboardKey.arrowUp,
          LogicalKeyboardKey.arrowDown,
        ].contains(event.logicalKey)) {
      final tab = _workspace.activeTab;
      if (tab != null) {
        final ids = tab.root.paneIds;
        final previous =
            event.logicalKey == LogicalKeyboardKey.arrowLeft ||
            event.logicalKey == LogicalKeyboardKey.arrowUp;
        final id =
            ids[(ids.indexOf(tab.focusedPaneId) + (previous ? -1 : 1)) %
                ids.length];
        if (tab.maximizedPaneId != null) tab.maximizedPaneId = id;
        _workspace.activate(tab, id);
      }
      return KeyEventResult.handled;
    }

    if (isCmdOrCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyD) {
      _splitPane(Axis.horizontal);
      return KeyEventResult.handled;
    }
    if (isCmdOrCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyE) {
      _splitPane(Axis.vertical);
      return KeyEventResult.handled;
    }
    if (isCmdOrCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyT) {
      _newLocalTab();
      return KeyEventResult.handled;
    }
    if (isCmdOrCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyW) {
      final tab = _workspace.activeTab;
      if (tab != null) _workspace.closePane(tab, tab.focusedPaneId);
      return KeyEventResult.handled;
    }
    if (isCmdOrCtrl &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        _workspace.tabs.isNotEmpty) {
      final current = _workspace.tabs.indexOf(_workspace.activeTab!);
      final index = (current + (isShift ? -1 : 1)) % _workspace.tabs.length;
      _workspace.activate(_workspace.tabs[index]);
      return KeyEventResult.handled;
    }
    if (HardwareKeyboard.instance.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.enter) {
      final tab = _workspace.activeTab;
      if (tab != null) _workspace.toggleMaximize(tab, tab.focusedPaneId);
      return KeyEventResult.handled;
    }
    if (isCmdOrCtrl && isShift && event.logicalKey == LogicalKeyboardKey.keyM) {
      _pluginManager.togglePanelPlugin(ServerMonitorPlugin.pluginId);
      return KeyEventResult.handled;
    }
    if (isCmdOrCtrl &&
        HardwareKeyboard.instance.isAltPressed &&
        event.logicalKey == LogicalKeyboardKey.keyF) {
      _pluginManager.togglePanelPlugin(SftpManagerPlugin.pluginId);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    DesktopNativeBridge.instance.removeDropListener(this);
    _hostSearchCtrl.dispose();
    _workspace.removeListener(_onWorkspaceChanged);
    _workspace.dispose();
    _pluginManager.dispose();
    _vaultService.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final layoutMode = AdaptiveBreakpoints.resolve(
          constraints.maxWidth,
          _formFactorOverride,
        );
        final pluginContext = _buildPluginContext(layoutMode);

        return Focus(
          onKeyEvent: _handleGlobalKeyEvent,
          child: Scaffold(
            backgroundColor: _colorPalette.surfaceColor,
            drawer: layoutMode == AdaptiveLayoutMode.compact
                ? Drawer(
                    backgroundColor: TxColors.bgSidebar,
                    child: _buildHostSidebar(layoutMode),
                  )
                : null,
            body: Column(
              children: [
                // 顶部工作台标题与会话标签栏
                _buildTopHeaderBar(layoutMode, pluginContext),

                // 主工作区
                Expanded(
                  child: Row(
                    children: [
                      // 1. 左侧服务器会话树
                      if (layoutMode == AdaptiveLayoutMode.expanded &&
                          !_leftSidebarCollapsed)
                        SizedBox(
                          width: 236,
                          child: _buildHostSidebar(layoutMode),
                        )
                      else if (layoutMode == AdaptiveLayoutMode.medium)
                        _buildTabletNavigationRail(),

                      // 2. 中间核心终端区
                      Expanded(
                        child: _buildCenterTerminalArea(
                          layoutMode,
                          pluginContext,
                        ),
                      ),

                      // 3. 右侧辅助检查器面板
                      if (layoutMode != AdaptiveLayoutMode.compact)
                        RepaintBoundary(
                          child: ListenableBuilder(
                            listenable: _pluginManager,
                            builder: (context, _) {
                              final activePlugin =
                                  _pluginManager.activePanelPlugin;
                              if (activePlugin == null) {
                                return const SizedBox.shrink();
                              }
                              final panelWidth =
                                  layoutMode == AdaptiveLayoutMode.expanded
                                  ? 356.0
                                  : 316.0;
                              return Container(
                                key: _rightPanelBoundsKey,
                                width: panelWidth,
                                decoration: const BoxDecoration(
                                  color: TxColors.bgSidebar,
                                  border: Border(
                                    left: BorderSide(
                                      color: TxColors.borderSubtle,
                                    ),
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    _buildPluginSelectorHeader(pluginContext),
                                    Expanded(
                                      child:
                                          activePlugin.buildPanelWidget(
                                            context,
                                            pluginContext,
                                          ) ??
                                          const SizedBox.shrink(),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ),

                // iPadOS 专属：妙控键盘 (Magic Keyboard) 胶囊条與 Stage Manager 控制栏
                if (layoutMode == AdaptiveLayoutMode.medium ||
                    _formFactorOverride == FormFactorOverride.ipad)
                  IpadMagicKeyboardCapsuleBar(
                    floatingThumbPadsVisible: _ipadThumbPadsVisible,
                    onToggleThumbPads: (v) =>
                        setState(() => _ipadThumbPadsVisible = v),
                    capsLockRemappedToEsc: _capsLockRemappedToEsc,
                    onToggleCapsLockRemap: (v) =>
                        setState(() => _capsLockRemappedToEsc = v),
                    onShowShortcutCheatSheet: () =>
                        showIpadShortcutCheatSheet(context),
                    onSplitTerminal: () => _splitPane(Axis.horizontal),
                    isSplitTerminal: _isSplitTerminal,
                  ),

                // 手机端专属：双层可滑动虚拟扩展键盘栏 + 本地防抖草稿箱
                if (layoutMode == AdaptiveLayoutMode.compact)
                  MobileAccessoryKeyboardBar(
                    onSendRaw: (seq) => _activeSession?.sendRawInput(seq),
                    onOpenSftp: () => _openMobilePluginBottomSheet(
                      SftpManagerPlugin.pluginId,
                    ),
                    onOpenMonitor: () => _openMobilePluginBottomSheet(
                      ServerMonitorPlugin.pluginId,
                    ),
                    onOpenSnippets: () =>
                        _openMobilePluginBottomSheet(SnippetsPlugin.pluginId),
                  ),

                // 底部状态栏
                RepaintBoundary(
                  child: _buildBottomPluginStatusBar(pluginContext),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTopHeaderBar(
    AdaptiveLayoutMode layoutMode,
    PluginContext pluginContext,
  ) {
    return Container(
      key: _topBarBoundsKey,
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: TxColors.bgChrome,
        border: Border(
          bottom: BorderSide(
            color: _topBarDetachHover
                ? TxColors.accent.withValues(alpha: 0.75)
                : TxColors.borderSubtle,
          ),
        ),
      ),
      child: Row(
        children: [
          if (layoutMode == AdaptiveLayoutMode.compact)
            Builder(
              builder: (ctx) => IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(
                  Icons.menu_rounded,
                  size: 18,
                  color: TxColors.iconDefault,
                ),
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            )
          else if (layoutMode == AdaptiveLayoutMode.expanded)
            IconButton(
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              padding: EdgeInsets.zero,
              tooltip: '显示/隐藏服务器栏',
              icon: Icon(
                _leftSidebarCollapsed
                    ? Icons.menu_open_rounded
                    : Icons.view_sidebar_outlined,
                size: 16.5,
                color: _leftSidebarCollapsed
                    ? TxColors.iconDefault
                    : TxColors.textSecondary,
              ),
              onPressed: () => setState(
                () => _leftSidebarCollapsed = !_leftSidebarCollapsed,
              ),
            ),

          const SizedBox(width: 4),

          // 克制的原生桌面端品牌标识（去除蓝紫荧光渐变）
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 21,
                height: 21,
                decoration: BoxDecoration(
                  color: TxColors.bgElevated,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: TxColors.borderDefault),
                ),
                alignment: Alignment.center,
                child: const Icon(
                  Icons.terminal_rounded,
                  size: 13,
                  color: TxColors.textPrimary,
                ),
              ),
              const SizedBox(width: 7),
              const Text(
                'TermX',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                  color: TxColors.textPrimary,
                ),
              ),
            ],
          ),
          Container(
            width: 1,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 10),
            color: TxColors.borderSubtle,
          ),

          Expanded(child: _buildSessionTabs()),

          const SizedBox(width: 4),
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            tooltip: '新建本地终端    Ctrl+Shift+T',
            icon: const Icon(
              Icons.add_rounded,
              size: 17,
              color: TxColors.iconDefault,
            ),
            onPressed: _newLocalTab,
          ),

          Container(
            width: 1,
            height: 14,
            margin: const EdgeInsets.symmetric(horizontal: 6),
            color: TxColors.borderSubtle,
          ),

          // 布局视图切换（单色克制图标）
          if (layoutMode != AdaptiveLayoutMode.compact)
            PopupMenuButton<FormFactorOverride>(
              tooltip: '布局视图 (${_formFactorOverride.label})',
              initialValue: _formFactorOverride,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 150),
              icon: Icon(
                Icons.devices_outlined,
                size: 16,
                color: _formFactorOverride == FormFactorOverride.auto
                    ? TxColors.iconDefault
                    : TxColors.accent,
              ),
              onSelected: (val) => setState(() => _formFactorOverride = val),
              itemBuilder: (context) => FormFactorOverride.values
                  .map(
                    (f) => PopupMenuItem(
                      value: f,
                      height: 34,
                      child: Row(
                        children: [
                          Icon(
                            _formFactorOverride == f
                                ? Icons.check_rounded
                                : null,
                            size: 14,
                            color: TxColors.accent,
                          ),
                          const SizedBox(width: 8),
                          Text(f.label, style: const TextStyle(fontSize: 12.5)),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),

          // 终端配色切换
          PopupMenuButton<TermXColorPalette>(
            tooltip: '终端配色',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 180),
            icon: const Icon(
              Icons.contrast_rounded,
              size: 16,
              color: TxColors.iconDefault,
            ),
            onSelected: (p) => setState(() => _colorPalette = p),
            itemBuilder: (context) => TermXColorPalette.presets
                .map(
                  (p) => PopupMenuItem(
                    value: p,
                    height: 34,
                    child: Row(
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: p.surfaceColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: _colorPalette.id == p.id
                                  ? TxColors.accent
                                  : TxColors.borderStrong,
                              width: _colorPalette.id == p.id ? 1.8 : 1.0,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(p.name, style: const TextStyle(fontSize: 12.5)),
                      ],
                    ),
                  ),
                )
                .toList(),
          ),

          // 凭据管理
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
            padding: EdgeInsets.zero,
            tooltip: '安全凭据管理',
            icon: const Icon(
              Icons.key_outlined,
              size: 16.5,
              color: TxColors.iconDefault,
            ),
            onPressed: () => showKeychainVaultDialog(
              context: context,
              vaultService: _vaultService,
              hosts: _hosts,
            ),
          ),

          // 扩展管理
          IconButton(
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
            padding: EdgeInsets.zero,
            tooltip: '扩展管理',
            icon: const Icon(
              Icons.widgets_outlined,
              size: 16,
              color: TxColors.iconDefault,
            ),
            onPressed: () => showPluginManagerDialog(
              context: context,
              pluginManager: _pluginManager,
              onInstallSampleCommunityPlugin: () async {
                if (_pluginManager.allPlugins.any(
                  (p) => p.manifest.id == DockerInspectorPlugin.pluginId,
                )) {
                  pluginContext.showToast('Docker 容器扩展已处于启用状态');
                  return;
                }
                await _pluginManager.registerPlugin(DockerInspectorPlugin());
                _pluginManager.setActivePanelPlugin(
                  DockerInspectorPlugin.pluginId,
                );
                pluginContext.showToast('已启用扩展：Docker 容器');
              },
            ),
          ),

          // 右侧辅助面板开关
          if (layoutMode != AdaptiveLayoutMode.compact)
            ListenableBuilder(
              listenable: _pluginManager,
              builder: (context, _) {
                final open = _pluginManager.activePanelPlugin != null;
                return IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 28),
                  padding: EdgeInsets.zero,
                  tooltip: open ? '隐藏右侧面板' : '展开右侧面板',
                  icon: Icon(
                    Icons.space_dashboard_outlined,
                    size: 16,
                    color: open ? TxColors.textPrimary : TxColors.iconDefault,
                  ),
                  onPressed: () {
                    if (open) {
                      _pluginManager.setActivePanelPlugin(null);
                    } else {
                      final first = _pluginManager.enabledPlugins.firstOrNull;
                      if (first != null) {
                        _pluginManager.setActivePanelPlugin(first.manifest.id);
                      }
                    }
                  },
                );
              },
            ),
        ],
      ),
    );
  }

  Widget _buildHostSidebar(AdaptiveLayoutMode layoutMode) {
    final query = _hostSearchCtrl.text.trim().toLowerCase();
    final grouped = <String, List<HostConfig>>{};
    for (final h in _hosts) {
      final gName = _normalizedGroupName(h);
      if (query.isNotEmpty) {
        final matched =
            h.name.toLowerCase().contains(query) ||
            h.host.toLowerCase().contains(query) ||
            h.username.toLowerCase().contains(query) ||
            gName.toLowerCase().contains(query) ||
            h.tags.any((t) => t.toLowerCase().contains(query));
        if (!matched) continue;
      }
      grouped.putIfAbsent(gName, () => []).add(h);
    }
    final groupEntries = grouped.entries.toList();
    final sshCount = _hosts
        .where((h) => h.authMethod != AuthMethod.localShell)
        .length;

    return Container(
      decoration: const BoxDecoration(
        color: TxColors.bgSidebar,
        border: Border(right: BorderSide(color: TxColors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '服务器',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: TxColors.textSecondary,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  padding: EdgeInsets.zero,
                  tooltip: '新建 SSH 主机',
                  icon: const Icon(
                    Icons.add_rounded,
                    size: 16.5,
                    color: TxColors.iconDefault,
                  ),
                  onPressed: _hostsLoaded ? () => _addHost() : null,
                ),
              ],
            ),
          ),
          if (_hosts.length > 1 || query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
              child: SizedBox(
                height: 27,
                child: TextField(
                  controller: _hostSearchCtrl,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: TxColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索主机、分组或 IP…',
                    hintStyle: const TextStyle(
                      fontSize: 11,
                      color: TxColors.textMuted,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 13.5,
                      color: TxColors.textMuted,
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 26),
                    suffixIcon: query.isNotEmpty
                        ? InkWell(
                            onTap: () => setState(() => _hostSearchCtrl.clear()),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 13,
                              color: TxColors.textSecondary,
                            ),
                          )
                        : null,
                    suffixIconConstraints: const BoxConstraints(minWidth: 22),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    filled: true,
                    fillColor: TxColors.bgChrome,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(5),
                      borderSide: const BorderSide(color: TxColors.borderSubtle),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(5),
                      borderSide: const BorderSide(color: TxColors.borderSubtle),
                    ),
                  ),
                ),
              ),
            ),
          Expanded(
            child: groupEntries.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16),
                      child: Text(
                        '无匹配的服务器会话',
                        style: TextStyle(fontSize: 11.5, color: TxColors.textMuted),
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    itemCount: groupEntries.length,
                    itemBuilder: (context, gIdx) {
                      final entry = groupEntries[gIdx];
                      final groupName = entry.key;
                      final members = entry.value;
                      final isCollapsed =
                          query.isEmpty && _collapsedGroups.contains(groupName);
                      final isSshGroup = groupName != '本机';

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          GestureDetector(
                            onSecondaryTapUp: isSshGroup
                                ? (d) => _showGroupContextMenu(
                                    groupName,
                                    d.globalPosition,
                                  )
                                : null,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(5),
                              onTap: () {
                                setState(() {
                                  if (_collapsedGroups.contains(groupName)) {
                                    _collapsedGroups.remove(groupName);
                                  } else {
                                    _collapsedGroups.add(groupName);
                                  }
                                });
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isCollapsed
                                          ? Icons.chevron_right_rounded
                                          : Icons.expand_more_rounded,
                                      size: 14,
                                      color: TxColors.textMuted,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        groupName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: TxColors.textMuted,
                                        ),
                                      ),
                                    ),
                                    Text(
                                      '${members.length}',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        color: TxColors.textMuted,
                                      ),
                                    ),
                                    if (isSshGroup && _hostsLoaded) ...[
                                      const SizedBox(width: 4),
                                      Tooltip(
                                        message: '在 "$groupName" 分组新增主机',
                                        child: InkWell(
                                          borderRadius: BorderRadius.circular(4),
                                          onTap: () => _addHost(groupName),
                                          child: const Padding(
                                            padding: EdgeInsets.all(2),
                                            child: Icon(
                                              Icons.add_rounded,
                                              size: 13.5,
                                              color: TxColors.textMuted,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ),
                          ),
                          if (!isCollapsed)
                            for (final h in members)
                              _buildHostCard(h, layoutMode),
                          const SizedBox(height: 6),
                        ],
                      );
                    },
                  ),
          ),

          // 底部简洁状态与快速添加栏
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: TxColors.borderSubtle)),
            ),
            child: Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: _hostsLoaded ? () => _addHost() : null,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_rounded,
                          size: 14,
                          color: TxColors.textSecondary,
                        ),
                        SizedBox(width: 4),
                        Text(
                          '新建连接',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: TxColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  '$sshCount 台远程主机',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: TxColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHostCard(HostConfig h, AdaptiveLayoutMode layoutMode) {
    final isCurrent = _activeSession?.host.id == h.id;
    final isEditable = h.authMethod != AuthMethod.localShell;
    final hostColor = h.tabColorValue != null ? Color(h.tabColorValue!) : null;
    final item = HostSidebarItem(
      host: h,
      osType: _hostOsType(h),
      osLabel: _hostOsLabel(h),
      isCurrent: isCurrent,
      isEditable: isEditable,
      hostColor: hostColor,
      onTap: () {
        _openNewSession(h);
        if (layoutMode == AdaptiveLayoutMode.compact) {
          Navigator.of(context).maybePop();
        }
      },
      onEdit: _hostsLoaded && isEditable ? () => _editHost(h) : null,
      onSecondaryTap: isEditable
          ? (pos) => _showHostContextMenu(h, pos)
          : null,
    );
    if (layoutMode == AdaptiveLayoutMode.compact) return item;
    return Draggable<PaneDockPayload>(
      data: HostDockPayload(h),
      dragAnchorStrategy: pointerDragAnchorStrategy,
      feedback: FractionalTranslation(
        translation: const Offset(-0.5, -0.5),
        child: _buildFloatingDragChip(
          leading: OsLogoIcon(os: _hostOsType(h), size: 14),
          title: h.name,
          accentColor: hostColor,
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.45, child: item),
      child: item,
    );
  }

  Widget _buildTabletNavigationRail() {
    return Container(
      width: 52,
      decoration: const BoxDecoration(
        color: TxColors.bgSidebar,
        border: Border(right: BorderSide(color: TxColors.borderSubtle)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 6),
          IconButton(
            tooltip: '新建 SSH 连接',
            icon: const Icon(
              Icons.add_rounded,
              size: 19,
              color: TxColors.iconDefault,
            ),
            onPressed: _hostsLoaded ? _addHost : null,
          ),
          const Divider(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: _hosts.length,
              itemBuilder: (context, idx) {
                final h = _hosts[idx];
                final osLabel = _hostOsLabel(h);
                final isEditable = h.authMethod != AuthMethod.localShell;
                return GestureDetector(
                  onSecondaryTapUp: isEditable
                      ? (details) =>
                            _showHostContextMenu(h, details.globalPosition)
                      : null,
                  onLongPress: isEditable ? () => _editHost(h) : null,
                  child: IconButton(
                    tooltip: osLabel != null
                        ? '${h.name} · $osLabel (${h.host})'
                        : '${h.name} (${h.host})',
                    icon: OsLogoIcon(
                      os: _hostOsType(h),
                      size: 19,
                    ),
                    onPressed: () => _openNewSession(h),
                  ),
                );
              },
            ),
          ),
          IconButton(
            tooltip: '恢复自动布局',
            icon: const Icon(
              Icons.fullscreen_rounded,
              size: 18,
              color: TxColors.iconDefault,
            ),
            onPressed: () =>
                setState(() => _formFactorOverride = FormFactorOverride.auto),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildFloatingDragChip({
    required Widget leading,
    required String title,
    Color? accentColor,
  }) {
    final border = accentColor != null
        ? accentColor.withValues(alpha: 0.75)
        : TxColors.accent.withValues(alpha: 0.75);
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: TxColors.bgElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 12,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            leading,
            const SizedBox(width: 7),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 180),
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TxColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  TerminalTab? _fallbackUnderlyingTab(TerminalTab draggedTab) {
    if (_workspace.tabs.length <= 1) return null;
    final prev = _tabActiveBeforePointerDown;
    if (prev != null && prev != draggedTab && _workspace.tabs.contains(prev)) {
      return prev;
    }
    final idx = _workspace.tabs.indexOf(draggedTab);
    if (idx > 0) return _workspace.tabs[idx - 1];
    return _workspace.tabs.where((t) => t != draggedTab).firstOrNull;
  }

  void _onTabPointerActivate(TerminalTab tab) {
    _pointerDownTab = tab;
    _tabActiveBeforePointerDown = _workspace.activeTab;
    _workspace.activate(tab);
  }

  void _onTabDragStarted(TerminalTab tab) {
    _draggingTab = tab;
    _autoPreviewTargetTab = null;
    _dragTrackPos = _tabPointerDownPos;
    if (_pointerDownTab == tab &&
        _tabActiveBeforePointerDown != null &&
        _tabActiveBeforePointerDown != tab &&
        _workspace.tabs.contains(_tabActiveBeforePointerDown)) {
      _autoPreviewTargetTab = _tabActiveBeforePointerDown;
      _workspace.activate(_tabActiveBeforePointerDown!);
      return;
    }
    // 如果拖拽的是当前已激活标签且初始手势向下，立即露出底层标签以便分屏预览
    if (_workspace.tabs.length > 1 &&
        _workspace.activeTab == tab &&
        _tabPointerDownPos != null &&
        _tabPointerLatestPos != null) {
      final delta = _tabPointerLatestPos! - _tabPointerDownPos!;
      if (delta.dy > delta.dx.abs()) {
        final fallback = _fallbackUnderlyingTab(tab);
        if (fallback != null) {
          _autoPreviewTargetTab = fallback;
          _workspace.activate(fallback);
        }
      }
    }
  }

  void _onTabDragUpdate(TerminalTab tab, DragUpdateDetails details) {
    if (_draggingTab != tab || _workspace.tabs.length <= 1) return;
    _dragTrackPos = (_dragTrackPos ?? details.globalPosition) + details.delta;
    final currentPos = _dragTrackPos!;
    final barBox = _topBarBoundsKey.currentContext?.findRenderObject();
    final double barBottom = (barBox is RenderBox && barBox.hasSize)
        ? barBox.localToGlobal(Offset(0, barBox.size.height)).dy
        : 44.0;
    final isBelowHeader = currentPos.dy > barBottom + 6;
    if (isBelowHeader && _workspace.activeTab == tab) {
      final fallback = _fallbackUnderlyingTab(tab);
      if (fallback != null) {
        _autoPreviewTargetTab = fallback;
        _workspace.activate(fallback);
      }
    } else if (!isBelowHeader &&
        _autoPreviewTargetTab != null &&
        _tabActiveBeforePointerDown == tab &&
        _workspace.tabs.contains(tab)) {
      _autoPreviewTargetTab = null;
      _workspace.activate(tab);
    }
  }

  void _onTabDragEnd(TerminalTab tab, DraggableDetails details) {
    final shouldRestoreActive =
        !details.wasAccepted &&
        _tabActiveBeforePointerDown == tab &&
        _workspace.tabs.contains(tab);
    _draggingTab = null;
    _autoPreviewTargetTab = null;
    _pointerDownTab = null;
    _tabActiveBeforePointerDown = null;
    _dragTrackPos = null;
    if (_tabReorderHoverId != null ||
        _tabReorderHoverEdge != null ||
        _topBarDetachHover) {
      setState(() {
        _tabReorderHoverId = null;
        _tabReorderHoverEdge = null;
        _topBarDetachHover = false;
      });
    }
    if (shouldRestoreActive) {
      _workspace.activate(tab);
    }
  }

  String _dockPayloadLabel(PaneDockPayload payload) => switch (payload) {
    TabDockPayload(tab: final t) =>
      _workspace.tabs.contains(t) ? _workspace.title(t) : '',
    PaneItemDockPayload(paneId: final id) =>
      _workspace.panes[id]?.session.host.name ?? '',
    HostDockPayload(host: final h) => h.name,
  };

  bool _canPaneAcceptDrop(
    TerminalTab targetTab,
    TerminalPane targetPane,
    PaneDockPayload payload,
  ) => switch (payload) {
    TabDockPayload(tab: final srcTab) =>
      srcTab != targetTab ||
          _workspace.tabs.length > 1 ||
          (_workspace.tabs.length == 1 && targetTab.root.paneIds.length == 1),
    PaneItemDockPayload(tab: final srcTab, paneId: final srcPaneId) =>
      !(srcTab == targetTab && srcPaneId == targetPane.id),
    HostDockPayload() => true,
  };

  void _handlePaneAcceptDrop(
    TerminalTab targetTab,
    TerminalPane targetPane,
    PaneDockPayload payload,
    SplitDockPosition position,
  ) {
    switch (payload) {
      case TabDockPayload(tab: final srcTab):
        if (srcTab != targetTab) {
          _workspace.dockTabIntoPane(
            sourceTab: srcTab,
            targetTab: targetTab,
            targetPaneId: targetPane.id,
            position: position,
          );
        } else if (_workspace.tabs.length > 1) {
          final fallback = _fallbackUnderlyingTab(srcTab);
          if (fallback != null) {
            _workspace.dockTabIntoPane(
              sourceTab: srcTab,
              targetTab: fallback,
              targetPaneId: fallback.focusedPaneId,
              position: position,
            );
          }
        } else if (_workspace.tabs.length == 1) {
          _connectPane(_workspace.splitAt(targetTab, targetPane.id, position));
        }
      case PaneItemDockPayload(tab: final srcTab, paneId: final srcPaneId):
        _workspace.movePaneToSplit(
          sourceTab: srcTab,
          sourcePaneId: srcPaneId,
          targetTab: targetTab,
          targetPaneId: targetPane.id,
          position: position,
        );
      case HostDockPayload(host: final host):
        _connectPane(
          _workspace.splitAt(targetTab, targetPane.id, position, host: host),
        );
    }
  }

  Widget _buildSessionTabs() => DragTarget<PaneDockPayload>(
    onWillAcceptWithDetails: (details) => switch (details.data) {
      TabDockPayload(tab: final src) =>
        _workspace.tabs.isNotEmpty && _workspace.tabs.last != src,
      PaneItemDockPayload(tab: final srcTab) => srcTab.root.paneIds.length > 1,
      HostDockPayload() => true,
    },
    onMove: (_) {
      if (!_topBarDetachHover) setState(() => _topBarDetachHover = true);
    },
    onLeave: (_) {
      if (_topBarDetachHover) setState(() => _topBarDetachHover = false);
    },
    onAcceptWithDetails: (details) {
      if (_topBarDetachHover) setState(() => _topBarDetachHover = false);
      switch (details.data) {
        case TabDockPayload(tab: final src):
          final oldIdx = _workspace.tabs.indexOf(src);
          if (oldIdx >= 0 && oldIdx < _workspace.tabs.length - 1) {
            _workspace.reorder(oldIdx, _workspace.tabs.length);
          }
        case PaneItemDockPayload(tab: final srcTab, paneId: final pid):
          _workspace.detachPaneToNewTab(srcTab, pid);
        case HostDockPayload(host: final h):
          _openNewSession(h);
      }
    },
    builder: (context, _, _) => ReorderableListView.builder(
      scrollDirection: Axis.horizontal,
      buildDefaultDragHandles: false,
      onReorder: _workspace.reorder,
      itemCount: _workspace.tabs.length,
      itemBuilder: (context, index) {
        final tab = _workspace.tabs[index];
        final pane = _workspace.panes[tab.focusedPaneId]!;
        final tabTitle = _workspace.title(tab);
        final tabButton = TerminalTabButton(
          active: tab == _workspace.activeTab,
          accent: _colorPalette.accentColor,
          customColor: tab.customColor,
          title: tabTitle,
          paneCount: tab.root.paneIds.length,
          insertionEdge: _tabReorderHoverId == tab.id
              ? _tabReorderHoverEdge
              : null,
          onActivate: () => _onTabPointerActivate(tab),
          onClose: () => _workspace.closeTab(tab),
          onRename: () => _renameTab(tab),
          onMenu: (position) => _showTabMenu(tab, position),
          dragHandle: const MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Padding(
              padding: EdgeInsets.only(right: 3),
              child: Icon(
                Icons.drag_indicator,
                size: 11,
                color: TxColors.textMuted,
              ),
            ),
          ),
          status: SessionOsStatusBadge(session: pane.session, size: 14),
        );

        return Padding(
          key: ValueKey(tab.id),
          padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
          child: Builder(
            builder: (slotContext) => DragTarget<PaneDockPayload>(
              onWillAcceptWithDetails: (details) => switch (details.data) {
                TabDockPayload(tab: final src) => src != tab,
                PaneItemDockPayload(tab: final srcTab) =>
                  srcTab.root.paneIds.length > 1,
                HostDockPayload() => true,
              },
              onMove: (details) {
                final box = slotContext.findRenderObject();
                var edge = AxisDirection.right;
                if (box is RenderBox && box.hasSize) {
                  final local = box.globalToLocal(details.offset);
                  edge = local.dx < box.size.width * 0.5
                      ? AxisDirection.left
                      : AxisDirection.right;
                }
                if (_tabReorderHoverId != tab.id ||
                    _tabReorderHoverEdge != edge) {
                  setState(() {
                    _tabReorderHoverId = tab.id;
                    _tabReorderHoverEdge = edge;
                  });
                }
              },
              onLeave: (_) {
                if (_tabReorderHoverId == tab.id) {
                  setState(() {
                    _tabReorderHoverId = null;
                    _tabReorderHoverEdge = null;
                  });
                }
              },
              onAcceptWithDetails: (details) {
                final box = slotContext.findRenderObject();
                var edge = AxisDirection.right;
                if (box is RenderBox && box.hasSize) {
                  final local = box.globalToLocal(details.offset);
                  edge = local.dx < box.size.width * 0.5
                      ? AxisDirection.left
                      : AxisDirection.right;
                }
                setState(() {
                  _tabReorderHoverId = null;
                  _tabReorderHoverEdge = null;
                });
                final currentIdx = _workspace.tabs.indexOf(tab);
                final insertIdx =
                    currentIdx + (edge == AxisDirection.right ? 1 : 0);
                switch (details.data) {
                  case TabDockPayload(tab: final src):
                    final oldIdx = _workspace.tabs.indexOf(src);
                    if (oldIdx >= 0 &&
                        currentIdx >= 0 &&
                        insertIdx != oldIdx &&
                        insertIdx != oldIdx + 1) {
                      _workspace.reorder(oldIdx, insertIdx);
                    }
                  case PaneItemDockPayload(tab: final srcTab, paneId: final pid):
                    _workspace.detachPaneToNewTab(
                      srcTab,
                      pid,
                      insertIndex: insertIdx,
                    );
                  case HostDockPayload(host: final h):
                    _openNewSession(h);
                }
              },
              builder: (context, _, _) => Draggable<PaneDockPayload>(
                data: TabDockPayload(tab),
                dragAnchorStrategy: pointerDragAnchorStrategy,
                onDragStarted: () => _onTabDragStarted(tab),
                onDragUpdate: (d) => _onTabDragUpdate(tab, d),
                onDragEnd: (d) => _onTabDragEnd(tab, d),
                feedback: FractionalTranslation(
                  translation: const Offset(-0.5, -0.5),
                  child: _buildFloatingDragChip(
                    leading: SessionOsStatusBadge(
                      session: pane.session,
                      size: 14,
                    ),
                    title: tabTitle,
                    accentColor: tab.customColor,
                  ),
                ),
                childWhenDragging: Opacity(opacity: 0.38, child: tabButton),
                child: Listener(
                  onPointerDown: (e) {
                    _tabPointerDownPos = e.position;
                    _tabPointerLatestPos = e.position;
                  },
                  onPointerMove: (e) => _tabPointerLatestPos = e.position,
                  child: tabButton,
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _buildCenterTerminalArea(
    AdaptiveLayoutMode layoutMode,
    PluginContext pluginContext,
  ) {
    final tab = _workspace.activeTab;
    if (tab == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.terminal_rounded,
              size: 34,
              color: TxColors.textMuted,
            ),
            const SizedBox(height: 10),
            const Text(
              '没有打开的终端会话',
              style: TextStyle(fontSize: 13, color: TxColors.textSecondary),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _newLocalTab,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: Text(Platform.isWindows ? '新建本地 PowerShell' : '新建连接'),
            ),
          ],
        ),
      );
    }
    return IndexedStack(
      index: _workspace.tabs.indexOf(tab),
      sizing: StackFit.expand,
      children: [
        for (final item in _workspace.tabs)
          TickerMode(
            key: ValueKey(item.id),
            enabled: item == tab,
            child: ExcludeFocus(
              excluding: item != tab,
              child: RepaintBoundary(
                child: _buildTabTerminalArea(item, layoutMode),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTabTerminalArea(TerminalTab tab, AdaptiveLayoutMode layoutMode) {
    final maximized = tab.maximizedPaneId;
    final compact = layoutMode == AdaptiveLayoutMode.compact;
    return Stack(
      children: [
        Column(
          children: [
            if (compact && tab.root.paneIds.length > 1)
              SizedBox(
                height: 30,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    const Text(
                      '窗格：',
                      style: TextStyle(fontSize: 11, color: TxColors.textMuted),
                    ),
                    for (var i = 0; i < tab.root.paneIds.length; i++)
                      TextButton(
                        onPressed: () =>
                            _workspace.activate(tab, tab.root.paneIds[i]),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(
                            color: tab.root.paneIds[i] == tab.focusedPaneId
                                ? _colorPalette.accentColor
                                : TxColors.textMuted,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: _buildPaneLayout(
                tab,
                maximized != null
                    ? PaneLeaf(maximized)
                    : compact
                    ? PaneLeaf(tab.focusedPaneId)
                    : tab.root,
              ),
            ),
          ],
        ),
        if ((layoutMode == AdaptiveLayoutMode.medium ||
                _formFactorOverride == FormFactorOverride.ipad) &&
            _ipadThumbPadsVisible)
          Positioned.fill(
            child: IpadFloatingThumbPads(
              onSendRaw: (seq) => _activeSession?.sendRawInput(seq),
            ),
          ),
      ],
    );
  }

  Widget _buildPaneLayout(TerminalTab tab, PaneLayout layout) {
    if (layout is PaneSplit) {
      return ResizablePaneSplit(
        key: ObjectKey(layout),
        split: layout,
        first: _buildPaneLayout(tab, layout.first),
        second: _buildPaneLayout(tab, layout.second),
      );
    }
    final pane = _workspace.panes[(layout as PaneLeaf).id]!;
    final isMultiPane = tab.root.paneIds.length > 1;
    return TerminalPaneView(
      key: GlobalObjectKey(pane),
      pane: pane,
      title: pane.session.isLocalSession
          ? '本地 PowerShell'
          : '${pane.session.host.username}@${pane.session.host.host}:${pane.session.host.port}',
      theme: _colorPalette.terminalTheme,
      accent: _colorPalette.accentColor,
      active: _workspace.activeTab == tab && tab.focusedPaneId == pane.id,
      maximized: tab.maximizedPaneId == pane.id,
      onActivate: () {
        if (_workspace.activeTab != tab || tab.focusedPaneId != pane.id) {
          _workspace.activate(tab, pane.id);
        }
      },
      onSplit: (axis) => _splitPane(axis, tab: tab, paneId: pane.id),
      onClose: () => _workspace.closePane(tab, pane.id),
      onRestart: () => _restartPane(tab, pane.id),
      onMaximize: () => _workspace.toggleMaximize(tab, pane.id),
      onWorkspaceKey: (event) => _handleGlobalKeyEvent(pane.focus, event),
      canAcceptDrop: (payload) => _canPaneAcceptDrop(tab, pane, payload),
      onAcceptDrop: (payload, pos) =>
          _handlePaneAcceptDrop(tab, pane, payload, pos),
      payloadLabelBuilder: _dockPayloadLabel,
      headerDragPayload: isMultiPane
          ? PaneItemDockPayload(tab, pane.id)
          : null,
      headerDragTitle: pane.session.host.name,
    );
  }

  static String _shortPluginTitle(PluginManifest m) {
    switch (m.id) {
      case ServerMonitorPlugin.pluginId:
        return '监控';
      case SftpManagerPlugin.pluginId:
        return '文件';
      case SnippetsPlugin.pluginId:
        return '片段';
      case PortForwardPlugin.pluginId:
        return '隧道';
      case DockerInspectorPlugin.pluginId:
        return '容器';
      default:
        return m.name.split(' ').first;
    }
  }

  Widget _buildPluginSelectorHeader(
    PluginContext pluginContext, {
    bool isCompactSheet = false,
  }) {
    return ListenableBuilder(
      listenable: _pluginManager,
      builder: (context, _) {
        final plugins = _pluginManager.enabledPlugins;
        final activeId = _pluginManager.activePanelPluginId;
        return Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: const BoxDecoration(
            color: TxColors.bgChrome,
            border: Border(bottom: BorderSide(color: TxColors.borderSubtle)),
          ),
          child: Row(
            children: [
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: plugins.length,
                  itemBuilder: (context, idx) {
                    final p = plugins[idx];
                    final m = p.manifest;
                    final selected = m.id == activeId;
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 2,
                        vertical: 5,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(5),
                        onTap: () => _pluginManager.setActivePanelPlugin(m.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 9),
                          decoration: BoxDecoration(
                            color: selected
                                ? TxColors.bgElevated
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(5),
                            border: Border.all(
                              color: selected
                                  ? TxColors.borderDefault
                                  : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                m.icon,
                                size: 13.5,
                                color: selected
                                    ? TxColors.textPrimary
                                    : TxColors.textMuted,
                              ),
                              const SizedBox(width: 5),
                              Text(
                                _shortPluginTitle(m),
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: selected
                                      ? TxColors.textPrimary
                                      : TxColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (!isCompactSheet)
                IconButton(
                  visualDensity: VisualDensity.compact,
                  constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                  padding: EdgeInsets.zero,
                  tooltip: '收起右侧面板',
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 15,
                    color: TxColors.textMuted,
                  ),
                  onPressed: () => _pluginManager.setActivePanelPlugin(null),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomPluginStatusBar(PluginContext pluginContext) {
    return ListenableBuilder(
      listenable: _pluginManager,
      builder: (context, _) {
        final statusWidgets = <Widget>[];
        for (final plugin in _pluginManager.enabledPlugins) {
          final w = plugin.buildStatusBarWidget(context, pluginContext);
          if (w != null) {
            statusWidgets.add(
              Padding(padding: const EdgeInsets.only(right: 10), child: w),
            );
          }
        }

        return Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: const BoxDecoration(
            color: TxColors.bgChrome,
            border: Border(top: BorderSide(color: TxColors.borderSubtle)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.lock_outline_rounded,
                size: 11.5,
                color: TxColors.textMuted,
              ),
              const SizedBox(width: 5),
              Text(
                _vaultService.platformVaultBackendName,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: TxColors.textMuted,
                ),
              ),
              if (statusWidgets.isNotEmpty)
                Container(
                  width: 1,
                  height: 11,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  color: TxColors.borderSubtle,
                )
              else
                const SizedBox(width: 10),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: statusWidgets),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class HostSidebarItem extends StatefulWidget {
  const HostSidebarItem({
    super.key,
    required this.host,
    required this.osType,
    required this.osLabel,
    required this.isCurrent,
    required this.isEditable,
    required this.hostColor,
    required this.onTap,
    this.onEdit,
    this.onSecondaryTap,
  });

  final HostConfig host;
  final RemoteOsType osType;
  final String? osLabel;
  final bool isCurrent;
  final bool isEditable;
  final Color? hostColor;
  final VoidCallback onTap;
  final VoidCallback? onEdit;
  final ValueChanged<Offset>? onSecondaryTap;

  @override
  State<HostSidebarItem> createState() => _HostSidebarItemState();
}

class _HostSidebarItemState extends State<HostSidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.host;
    final bg = widget.isCurrent
        ? TxColors.bgSelected
        : _hovered
        ? TxColors.bgHover
        : Colors.transparent;
    final indicatorColor = widget.hostColor ?? TxColors.accent;
    final showTags =
        widget.isEditable && h.tags.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          onSecondaryTapUp: widget.onSecondaryTap != null
              ? (d) => widget.onSecondaryTap!(d.globalPosition)
              : null,
          child: Container(
            padding: EdgeInsets.fromLTRB(
              8,
              6,
              widget.isEditable ? 2 : 8,
              6,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Container(
                  width: 2.5,
                  height: 18,
                  decoration: BoxDecoration(
                    color: widget.isCurrent
                        ? indicatorColor
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 7),
                OsLogoIcon(
                  os: widget.osType,
                  size: 17,
                  tooltip: widget.osLabel,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          if (widget.hostColor != null) ...[
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: widget.hostColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 5),
                          ],
                          Expanded(
                            child: Text(
                              h.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: widget.isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 1.5),
                      Text(
                        h.authMethod == AuthMethod.localShell
                            ? '${h.username} · 本机终端'
                            : '${h.username}@${h.host}:${h.port}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textMuted,
                        ),
                      ),
                      if (showTags) ...[
                        const SizedBox(height: 3.5),
                        Wrap(
                          spacing: 4,
                          runSpacing: 3,
                          children: [
                            for (final t in h.tags)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: TxColors.bgElevated,
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(
                                    color: TxColors.borderSubtle,
                                  ),
                                ),
                                child: Text(
                                  t,
                                  style: const TextStyle(
                                    fontSize: 9.5,
                                    color: TxColors.textSecondary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.isEditable)
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 26,
                      minHeight: 26,
                    ),
                    padding: EdgeInsets.zero,
                    tooltip: '编辑会话配置',
                    icon: Icon(
                      Icons.edit_outlined,
                      size: 13.5,
                      color: (_hovered || widget.isCurrent)
                          ? TxColors.iconDefault
                          : TxColors.textMuted.withValues(alpha: 0.35),
                    ),
                    onPressed: widget.onEdit,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
