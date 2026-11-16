import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../core/models/host_config.dart';
import '../core/models/host_store.dart';
import '../core/models/remote_os.dart';
import '../core/models/shortcut_settings.dart';
import '../core/models/terminal_workspace.dart';
import '../core/models/ui_preferences.dart';
import '../core/platform/desktop_native_bridge.dart';
import '../core/plugin_system/plugin_interface.dart';
import '../core/plugin_system/plugin_manager.dart';
import '../core/ssh/ssh_session_controller.dart';
import '../core/theme/adaptive_layout.dart';
import '../core/theme/ui_tokens.dart';
import '../core/vault/vault_service.dart';
import '../plugins/command_beautifier/command_beautifier_plugin.dart';
import '../plugins/command_beautifier/command_output_models.dart';
import '../plugins/docker_inspector/docker_inspector_plugin.dart';
import '../plugins/port_forward/port_forward_plugin.dart';
import '../plugins/server_monitor/server_monitor_plugin.dart';
import '../plugins/sftp_manager/sftp_manager_plugin.dart';
import '../plugins/snippets/snippets_plugin.dart';
import 'mobile/mobile_accessory_keyboard.dart';
import 'tablet/ipad_adaptive_controls.dart';
import 'widgets/dialogs_and_sheets.dart';
import 'widgets/os_logo_icon.dart';
import 'widgets/shortcut_settings_dialog.dart';
import 'widgets/terminal_pane_view.dart';
import 'widgets/terminal_tab_button.dart';

class TermXWorkbench extends StatefulWidget {
  const TermXWorkbench({
    super.key,
    this.hostStore,
    this.shortcutStore,
    this.uiPreferencesStore,
    this.autoStartLocalShell = true,
    this.restoreSavedWorkspace,
  });

  final HostStore? hostStore;
  final ShortcutStore? shortcutStore;
  final UiPreferencesStore? uiPreferencesStore;
  final bool autoStartLocalShell;

  /// 是否在启动时自动恢复上次保存的工作区标签页与分屏树；默认跟随 [autoStartLocalShell]。
  final bool? restoreSavedWorkspace;

  @override
  State<TermXWorkbench> createState() => _TermXWorkbenchState();
}

class _TermXWorkbenchState extends State<TermXWorkbench>
    implements DesktopFileDropListener {
  final VaultService _vaultService = VaultService();
  final PluginManager _pluginManager = PluginManager();
  final CommandBeautifierPlugin _beautifierPlugin = CommandBeautifierPlugin();
  late final HostStore _hostStore = widget.hostStore ?? HostStore();
  late final ShortcutStore _shortcutStore =
      widget.shortcutStore ?? ShortcutStore();
  late final UiPreferencesStore _uiPrefsStore =
      widget.uiPreferencesStore ?? UiPreferencesStore();
  ShortcutConfig _shortcutConfig = ShortcutConfig.defaults();
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
  double _windowOpacity = 1.0;
  TerminalCursorType _cursorType = TerminalCursorType.block;
  bool _leftSidebarCollapsed = false;
  bool _bootstrapCompleted = false;
  UiPreferences? _initialLoadedUiPrefs;
  final ValueNotifier<double?> _rightPanelWidthNotifier =
      ValueNotifier<double?>(null);
  final VirtualModifierController _virtualModifierController =
      VirtualModifierController();
  bool get _isSplitTerminal =>
      (_workspace.activeTab?.root.paneIds.length ?? 0) > 1;
  bool _ipadThumbPadsVisible = true;
  bool _capsLockRemappedToEsc = true;

  SshSessionController? get _activeSession => _workspace.activePane?.session;

  @override
  void initState() {
    super.initState();
    if (Platform.isAndroid || Platform.isIOS) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    DesktopNativeBridge.instance.addDropListener(this);
    _workspace.addListener(_onWorkspaceChanged);
    _pluginManager.addListener(_onPluginManagerLayoutChanged);
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

  Future<void> _loadSavedShortcuts() async {
    try {
      final loaded = await _shortcutStore.load();
      if (!mounted) return;
      setState(() => _shortcutConfig = loaded);
    } catch (_) {}
  }

  void _updateShortcutConfig(ShortcutConfig next) {
    setState(() => _shortcutConfig = next);
    unawaited(_shortcutStore.save(next).catchError((Object _) {}));
  }

  void _openShortcutSettings() {
    showShortcutSettingsDialog(
      context: context,
      initialConfig: _shortcutConfig,
      onChanged: _updateShortcutConfig,
    );
  }

  Future<UiPreferences> _loadUiPreferences() async {
    try {
      final prefs = await _uiPrefsStore.load();
      _initialLoadedUiPrefs = prefs;
      if (!mounted) return prefs;
      TermXColorPalette? matchedPalette;
      if (prefs.colorPaletteName != null) {
        for (final p in TermXColorPalette.presets) {
          if (p.id == prefs.colorPaletteName ||
              p.name == prefs.colorPaletteName) {
            matchedPalette = p;
            break;
          }
        }
      }
      _rightPanelWidthNotifier.value = prefs.rightPanelWidth;
      setState(() {
        _windowOpacity = prefs.windowOpacity;
        _cursorType = prefs.cursorType;
        _leftSidebarCollapsed = prefs.leftSidebarCollapsed;
        _collapsedGroups
          ..clear()
          ..addAll(prefs.collapsedHostGroups);
        _formFactorOverride = prefs.formFactorOverride;
        if (matchedPalette != null) {
          _colorPalette = matchedPalette;
        }
      });
      if (_windowOpacity < 0.999 &&
          DesktopNativeBridge.instance.supportsWindowOpacity) {
        unawaited(DesktopNativeBridge.instance.setWindowOpacity(_windowOpacity));
      }
      return prefs;
    } catch (_) {
      return const UiPreferences();
    }
  }

  void _onPluginManagerLayoutChanged() {
    if (!_bootstrapCompleted || !mounted) return;
    _persistUiPreferences();
  }

  void _persistUiPreferences() {
    final bool rightPanelOpen;
    final String? activeRightPluginId;
    final List<String> enabledExtraPluginIds;
    final List<String> disabledPluginIds;
    final WorkspaceLayoutSnapshot? workspaceLayout;

    if (_bootstrapCompleted) {
      rightPanelOpen = _pluginManager.activePanelPlugin != null;
      activeRightPluginId = _pluginManager.activePanelPluginId;
      enabledExtraPluginIds = [
        if (_pluginManager.allPlugins.any(
              (p) => p.manifest.id == DockerInspectorPlugin.pluginId,
            ) &&
            _pluginManager.isPluginEnabled(DockerInspectorPlugin.pluginId))
          DockerInspectorPlugin.pluginId,
      ];
      disabledPluginIds = _pluginManager.allPlugins
          .map((p) => p.manifest.id)
          .where((id) => !_pluginManager.isPluginEnabled(id))
          .toList(growable: false);
      workspaceLayout = _workspace.captureSnapshot();
    } else {
      final initial = _initialLoadedUiPrefs;
      rightPanelOpen = initial?.rightPanelOpen ?? true;
      activeRightPluginId = initial?.activeRightPluginId;
      enabledExtraPluginIds = initial?.enabledExtraPluginIds ?? const [];
      disabledPluginIds = initial?.disabledPluginIds ?? const [];
      workspaceLayout = initial?.workspaceLayout;
    }

    final prefs = UiPreferences(
      windowOpacity: _windowOpacity,
      colorPaletteName: _colorPalette.id,
      rightPanelWidth: _rightPanelWidthNotifier.value,
      cursorType: _cursorType,
      leftSidebarCollapsed: _leftSidebarCollapsed,
      collapsedHostGroups: _collapsedGroups.toList(growable: false),
      rightPanelOpen: rightPanelOpen,
      activeRightPluginId: activeRightPluginId,
      enabledExtraPluginIds: enabledExtraPluginIds,
      disabledPluginIds: disabledPluginIds,
      formFactorOverride: _formFactorOverride,
      workspaceLayout: workspaceLayout,
    );
    unawaited(_uiPrefsStore.save(prefs).catchError((Object _) {}));
  }

  void _setCursorType(TerminalCursorType next) {
    if (_cursorType == next) return;
    setState(() => _cursorType = next);
    _persistUiPreferences();
  }

  void _setWindowOpacity(double value, {bool persist = false}) {
    final clamped = value.clamp(
      UiPreferences.minOpacity,
      UiPreferences.maxOpacity,
    );
    if ((clamped - _windowOpacity).abs() > 0.0005) {
      setState(() => _windowOpacity = clamped);
    }
    unawaited(DesktopNativeBridge.instance.setWindowOpacity(clamped));
    if (persist) {
      _persistUiPreferences();
    }
  }

  void _openWindowOpacityDialog() {
    const presets = <(String label, double value)>[
      ('100% 不透明', 1.0),
      ('92% 微透', 0.92),
      ('85% 舒适', 0.85),
      ('75% 半透', 0.75),
      ('60% 强透', 0.60),
    ];

    showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.12),
      builder: (dialogCtx) => StatefulBuilder(
        builder: (dialogCtx, setDialogState) {
          final pct = (_windowOpacity * 100).round();
          return Align(
            alignment: Alignment.topRight,
            child: Padding(
              padding: const EdgeInsets.only(top: 52, right: 16),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  width: 344,
                  padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
                  decoration: BoxDecoration(
                    color: TxColors.bgSidebar,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: TxColors.borderStrong),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.42),
                        blurRadius: 24,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.opacity_rounded,
                            size: 18,
                            color: TxColors.accent,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '窗口透明度',
                              style: TextStyle(
                                fontSize: 14.5,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 9,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: TxColors.accent.withValues(alpha: 0.16),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: TxColors.accent.withValues(alpha: 0.4),
                              ),
                            ),
                            child: Text(
                              '$pct%',
                              style: const TextStyle(
                                fontFamily: TxColors.monoFamily,
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: TxColors.accent,
                              ),
                            ),
                          ),
                          if (_windowOpacity < 0.995) ...[
                            const SizedBox(width: 6),
                            TextButton(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                minimumSize: const Size(0, 28),
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                              onPressed: () {
                                _setWindowOpacity(1.0, persist: true);
                                setDialogState(() {});
                              },
                              child: const Text(
                                '恢复 100%',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: TxColors.textSecondary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '拖动滑块实时调节窗口透视度，便于对照底层网页文档或监控画面。',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: TxColors.textMuted,
                        ),
                      ),
                      const SizedBox(height: 10),
                      SliderTheme(
                        data: SliderTheme.of(dialogCtx).copyWith(
                          trackHeight: 4.5,
                          activeTrackColor: TxColors.accent,
                          inactiveTrackColor: TxColors.bgHover,
                          thumbColor: TxColors.accent,
                          overlayColor: TxColors.accent.withValues(alpha: 0.16),
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 7.5,
                          ),
                        ),
                        child: Slider(
                          value: _windowOpacity.clamp(
                            UiPreferences.minOpacity,
                            UiPreferences.maxOpacity,
                          ),
                          min: UiPreferences.minOpacity,
                          max: UiPreferences.maxOpacity,
                          divisions: 65,
                          onChanged: (v) {
                            _setWindowOpacity(v);
                            setDialogState(() {});
                          },
                          onChangeEnd: (v) {
                            _setWindowOpacity(v, persist: true);
                            setDialogState(() {});
                          },
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final (label, val) in presets)
                            _buildOpacityPresetChip(
                              label: label,
                              selected: (_windowOpacity - val).abs() < 0.015,
                              onTap: () {
                                _setWindowOpacity(val, persist: true);
                                setDialogState(() {});
                              },
                            ),
                        ],
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Divider(height: 1, color: TxColors.borderSubtle),
                      ),
                      const Text(
                        '终端光标样式',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: TxColors.textSecondary,
                        ),
                      ),
                      const SizedBox(height: 7),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final (cLabel, cType)
                              in const <(String, TerminalCursorType)>[
                                ('反色方块 █', TerminalCursorType.block),
                                ('纤细竖线 |', TerminalCursorType.verticalBar),
                                ('底部下划线 _', TerminalCursorType.underline),
                              ])
                            _buildOpacityPresetChip(
                              label: cLabel,
                              selected: _cursorType == cType,
                              onTap: () {
                                _setCursorType(cType);
                                setDialogState(() {});
                              },
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildOpacityPresetChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => Material(
    color: Colors.transparent,
    child: InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? TxColors.accent.withValues(alpha: 0.18)
              : TxColors.bgElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected
                ? TxColors.accent.withValues(alpha: 0.55)
                : TxColors.borderSubtle,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
            color: selected ? TxColors.textPrimary : TxColors.textSecondary,
          ),
        ),
      ),
    ),
  );

  Future<void> _bootstrapCoreAndPlugins() async {
    // 并行立即读取本地持久化的 SSH 服务器列表、快捷键配置、界面偏好与安全凭据策略，无需等待本机 PTY 启动
    final hostsFuture = _loadSavedHosts();
    unawaited(_loadSavedShortcuts());
    final prefsFuture = _loadUiPreferences();
    unawaited(_vaultService.loadPreferences());

    // 注册官方核心插件到微内核 PluginManager
    await _pluginManager.registerPlugin(ServerMonitorPlugin());
    await _pluginManager.registerPlugin(SftpManagerPlugin());
    await _pluginManager.registerPlugin(_beautifierPlugin);
    await _pluginManager.registerPlugin(SnippetsPlugin());
    await _pluginManager.registerPlugin(PortForwardPlugin());

    await hostsFuture;
    final prefs = await prefsFuture;
    if (!mounted) return;

    // 恢复上次已启用的社区扩展（如 Docker 容器插件）及停用状态
    if (prefs.enabledExtraPluginIds.contains(DockerInspectorPlugin.pluginId) &&
        !_pluginManager.allPlugins.any(
          (p) => p.manifest.id == DockerInspectorPlugin.pluginId,
        )) {
      await _pluginManager.registerPlugin(DockerInspectorPlugin());
      if (!mounted) return;
    }
    for (final disabledId in prefs.disabledPluginIds) {
      _pluginManager.setPluginEnabled(disabledId, false);
    }

    // 恢复右侧辅助面板开关与上次选中的插件标签页
    if (!prefs.rightPanelOpen) {
      _pluginManager.setActivePanelPlugin(null);
    } else if (prefs.activeRightPluginId != null &&
        _pluginManager.isPluginEnabled(prefs.activeRightPluginId!)) {
      _pluginManager.setActivePanelPlugin(prefs.activeRightPluginId!);
    }

    // 恢复上次打开的工作区标签页与递归分屏布局树
    final shouldRestoreWorkspace =
        widget.restoreSavedWorkspace ?? widget.autoStartLocalShell;
    var restoredAnyTab = false;
    if (shouldRestoreWorkspace &&
        prefs.workspaceLayout != null &&
        prefs.workspaceLayout!.tabs.isNotEmpty) {
      final restoredPanes = _workspace.restoreFromSnapshot(
        prefs.workspaceLayout!,
        (hostId) => _hosts.where((h) => h.id == hostId).firstOrNull,
      );
      if (restoredPanes.isNotEmpty) {
        restoredAnyTab = true;
        for (final pane in restoredPanes) {
          unawaited(_connectPane(pane));
        }
        _pluginManager.notifyActiveSessionChanged(
          _workspace.activePane?.session,
        );
      }
    }

    // 若无历史工作区快照，Windows 默认自动打开本地 PowerShell；其他平台等待用户添加主机。
    if (!restoredAnyTab &&
        mounted &&
        widget.autoStartLocalShell &&
        _hosts.isNotEmpty &&
        _hosts.first.authMethod == AuthMethod.localShell) {
      await _openNewSession(_hosts.first);
    }

    if (!mounted) return;
    _bootstrapCompleted = true;
    if (restoredAnyTab || _workspace.tabs.isNotEmpty) {
      _persistUiPreferences();
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
      vaultService: _vaultService,
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
    final previousHost = _hosts[idx];
    await _vaultService.saveCredential(updated, secret);
    if (previousHost.keychainAccountKey != updated.keychainAccountKey) {
      try {
        await _vaultService.deleteCredential(previousHost);
      } catch (_) {}
    }
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
    final hasSaved = await _vaultService.hasSavedCredential(host);
    if (!mounted) return;
    await showHostFormDialog(
      context: context,
      existingHost: host,
      vaultService: _vaultService,
      hasSavedCredential: hasSaved,
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
    _persistUiPreferences();
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
    _persistUiPreferences();
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
    session.inputModifierTransform =
        _virtualModifierController.transformTerminalOutput;

    final knownHost = _hosts.where((h) => h.id == host.id).firstOrNull;
    if (knownHost?.detectedOs != null) {
      session.applyDetectedOs(
        knownHost!.detectedOs!,
        knownHost.detectedOsPrettyName,
      );
    }
    session.addListener(() => _syncDetectedOsFromSession(session));
    _pluginManager.notifySessionAttached(session);

    final needConnectAuth =
        host.authMethod != AuthMethod.localShell &&
        host.authMethod != AuthMethod.demoSandbox &&
        (host.requireBiometricUnlock || _vaultService.biometricLockEnabled);
    if (needConnectAuth) {
      final auth = await _vaultService.authenticateUser(
        reason: '连接远程服务器 "${host.name}" (${host.username}@${host.host}) 前需验证系统身份',
      );
      if (pane.disposed) return;
      if (!auth.isAuthenticated) {
        final detail = auth.message.isEmpty ? '身份验证未通过或已取消' : auth.message;
        session.terminal.write(
          '\r\n\x1b[33m[TermX 安全中心]\x1b[0m $detail，已中止自动读取凭据连接。\r\n',
        );
        return;
      }
    }

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
    if (_bootstrapCompleted) {
      _persistUiPreferences();
    }
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
      useSafeArea: true,
      backgroundColor: TxColors.bgSidebar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.72,
        minChildSize: 0.42,
        maxChildSize: 0.94,
        builder: (ctx, scrollController) => SafeArea(
          top: false,
          child: Column(
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
                    return Material(
                      color: TxColors.bgSidebar,
                      child:
                          current.buildPanelWidget(ctx, pluginContext) ??
                          const SizedBox.shrink(),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openMobilePaletteAndCursorSheet() {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      backgroundColor: TxColors.bgSidebar,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 3.5,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: TxColors.borderStrong,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Text(
                  '终端配色主题',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: TxColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in TermXColorPalette.presets)
                      _buildOpacityPresetChip(
                        label: p.name,
                        selected: _colorPalette.id == p.id,
                        onTap: () {
                          setState(() => _colorPalette = p);
                          _persistUiPreferences();
                          setSheetState(() {});
                        },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '终端光标样式',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: TxColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final (cLabel, cType)
                        in const <(String, TerminalCursorType)>[
                          ('反色方块 █', TerminalCursorType.block),
                          ('纤细竖线 |', TerminalCursorType.verticalBar),
                          ('底部下划线 _', TerminalCursorType.underline),
                        ])
                      _buildOpacityPresetChip(
                        label: cLabel,
                        selected: _cursorType == cType,
                        onTap: () {
                          _setCursorType(cType);
                          setSheetState(() {});
                        },
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 处理 iPadOS Magic Keyboard / 桌面端全局可自定义快捷键与 CapsLock -> ESC 重映射
  KeyEventResult _handleGlobalKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // iPadOS / Vim 用户专属：CapsLock 重映射为物理 ESC
    if (_capsLockRemappedToEsc &&
        event.logicalKey == LogicalKeyboardKey.capsLock) {
      _activeSession?.sendRawInput('\x1b');
      return KeyEventResult.handled;
    }

    final kb = HardwareKeyboard.instance;
    final isCmdOrCtrl = kb.isMetaPressed || kb.isControlPressed;
    final isShift = kb.isShiftPressed;
    final isAlt = kb.isAltPressed;

    if (isAlt &&
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

    if (isCmdOrCtrl &&
        event.logicalKey == LogicalKeyboardKey.tab &&
        _workspace.tabs.isNotEmpty) {
      final current = _workspace.tabs.indexOf(_workspace.activeTab!);
      final index = (current + (isShift ? -1 : 1)) % _workspace.tabs.length;
      _workspace.activate(_workspace.tabs[index]);
      return KeyEventResult.handled;
    }

    final matched = _shortcutConfig.matchAction(
      event,
      isCmdOrCtrlPressed: isCmdOrCtrl,
      isShiftPressed: isShift,
      isAltPressed: isAlt,
    );
    switch (matched) {
      case ShortcutAction.openShortcuts:
        _openShortcutSettings();
        return KeyEventResult.handled;
      case ShortcutAction.splitRight:
        _splitPane(Axis.horizontal);
        return KeyEventResult.handled;
      case ShortcutAction.splitDown:
        _splitPane(Axis.vertical);
        return KeyEventResult.handled;
      case ShortcutAction.newTab:
        _newLocalTab();
        return KeyEventResult.handled;
      case ShortcutAction.closePane:
        final tab = _workspace.activeTab;
        if (tab != null) _workspace.closePane(tab, tab.focusedPaneId);
        return KeyEventResult.handled;
      case ShortcutAction.maximizePane:
        final tab = _workspace.activeTab;
        if (tab != null) _workspace.toggleMaximize(tab, tab.focusedPaneId);
        return KeyEventResult.handled;
      case ShortcutAction.toggleBeauty:
        if (_pluginManager.isPluginEnabled(CommandBeautifierPlugin.pluginId)) {
          final session = _activeSession;
          if (session == null ||
              !_beautifierPlugin.toggleSessionDisplayMode(session.sessionId)) {
            _pluginManager.togglePanelPlugin(CommandBeautifierPlugin.pluginId);
          }
          return KeyEventResult.handled;
        }
      case ShortcutAction.toggleMonitor:
        _pluginManager.togglePanelPlugin(ServerMonitorPlugin.pluginId);
        return KeyEventResult.handled;
      case ShortcutAction.toggleSftp:
        _pluginManager.togglePanelPlugin(SftpManagerPlugin.pluginId);
        return KeyEventResult.handled;
      default:
        break;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    DesktopNativeBridge.instance.removeDropListener(this);
    _virtualModifierController.dispose();
    _rightPanelWidthNotifier.dispose();
    _hostSearchCtrl.dispose();
    _workspace.removeListener(_onWorkspaceChanged);
    _pluginManager.removeListener(_onPluginManagerLayoutChanged);
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
        final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
        final showBottomStatusBar =
            !(layoutMode == AdaptiveLayoutMode.compact && keyboardOpen);

        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: const SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness: Brightness.light,
            statusBarBrightness: Brightness.dark,
            systemNavigationBarColor: TxColors.bgChrome,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarIconBrightness: Brightness.light,
            systemStatusBarContrastEnforced: false,
            systemNavigationBarContrastEnforced: false,
          ),
          child: Focus(
            onKeyEvent: _handleGlobalKeyEvent,
            child: Scaffold(
              backgroundColor: _colorPalette.surfaceColor,
              drawer: layoutMode == AdaptiveLayoutMode.compact
                  ? Drawer(
                      width: (constraints.maxWidth * 0.84).clamp(260.0, 324.0),
                      backgroundColor: TxColors.bgSidebar,
                      child: SafeArea(child: _buildHostSidebar(layoutMode)),
                    )
                  : null,
              body: Column(
                children: [
                  // 顶部工作台标题与会话标签栏（自适应刘海 / 挖孔与状态栏高度）
                  _buildTopHeaderBar(layoutMode, pluginContext),

                  // 主工作区（横屏时避开左右异形屏安全区）
                  Expanded(
                    child: SafeArea(
                      top: false,
                      bottom: false,
                      child: Row(
                        children: [
                          // 1. 左侧服务器会话树
                          if (layoutMode == AdaptiveLayoutMode.expanded &&
                              !_leftSidebarCollapsed)
                            SizedBox(
                              width: 248,
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
                                  final defaultPanelWidth =
                                      layoutMode == AdaptiveLayoutMode.expanded
                                      ? (constraints.maxWidth >= 1320
                                            ? 430.0
                                            : 398.0)
                                      : 346.0;
                                  final leftOccupied =
                                      layoutMode == AdaptiveLayoutMode.expanded
                                      ? (_leftSidebarCollapsed ? 0.0 : 248.0)
                                      : 58.0;
                                  const minPanelWidth = 330.0;
                                  final maxPanelWidth =
                                      (constraints.maxWidth -
                                              leftOccupied -
                                              260.0)
                                          .clamp(350.0, 920.0);
                                  final panelContent = Column(
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
                                  );
                                  return ValueListenableBuilder<double?>(
                                    valueListenable: _rightPanelWidthNotifier,
                                    child: panelContent,
                                    builder: (context, customWidth, panelChild) {
                                      final panelWidth =
                                          (customWidth ?? defaultPanelWidth)
                                              .clamp(
                                                minPanelWidth,
                                                maxPanelWidth,
                                              );
                                      return Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          _RightPanelResizeHandle(
                                            key: const ValueKey(
                                              'right_panel_resize_handle',
                                            ),
                                            currentWidth: panelWidth,
                                            minWidth: minPanelWidth,
                                            maxWidth: maxPanelWidth,
                                            onWidthChanged: (next) {
                                              _rightPanelWidthNotifier.value =
                                                  next;
                                            },
                                            onDragEnd: _persistUiPreferences,
                                            onResetDefault: () {
                                              _rightPanelWidthNotifier.value =
                                                  null;
                                              _persistUiPreferences();
                                            },
                                          ),
                                          SizedBox(
                                            key: _rightPanelBoundsKey,
                                            width: panelWidth - 7,
                                            child: Material(
                                              color: TxColors.bgSidebar,
                                              child: panelChild,
                                            ),
                                          ),
                                        ],
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                        ],
                      ),
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
                      onShowShortcutCheatSheet: _openShortcutSettings,
                      onSplitTerminal: () => _splitPane(Axis.horizontal),
                      isSplitTerminal: _isSplitTerminal,
                    ),

                  // 手机端专属：双层可滑动虚拟扩展键盘栏 + 本地防抖草稿箱
                  if (layoutMode == AdaptiveLayoutMode.compact)
                    ListenableBuilder(
                      listenable: Listenable.merge([
                        _beautifierPlugin,
                        if (_activeSession != null) _activeSession!,
                      ]),
                      builder: (context, _) {
                        final session = _activeSession;
                        final sessionId = session?.sessionId;
                        final cardCount = sessionId != null
                            ? _beautifierPlugin.cardsForSession(sessionId).length
                            : 0;
                        final showingCard = sessionId != null &&
                            _beautifierPlugin.hasOverlayForSession(sessionId) &&
                            _beautifierPlugin.displayModeForSession(sessionId) ==
                                CardDisplayMode.beautified;
                        final isDisconnected =
                            session != null &&
                            (session.state ==
                                    SessionConnectionState.disconnected ||
                                session.state == SessionConnectionState.error);
                        final activeTab = _workspace.activeTab;
                        return MobileAccessoryKeyboardBar(
                          includeBottomSafeArea: !showBottomStatusBar,
                          modifierController: _virtualModifierController,
                          onRequestTerminalFocus: () =>
                              _workspace.activePane?.focus.requestFocus(),
                          onReconnect: activeTab == null
                              ? null
                              : () => _restartPane(
                                  activeTab,
                                  activeTab.focusedPaneId,
                                ),
                          isDisconnected: isDisconnected,
                          onSendRaw: (seq) => _activeSession?.sendRawInput(seq),
                          onOpenSftp: () => _openMobilePluginBottomSheet(
                            SftpManagerPlugin.pluginId,
                          ),
                          onOpenMonitor: () => _openMobilePluginBottomSheet(
                            ServerMonitorPlugin.pluginId,
                          ),
                          onOpenBeautifier: () => _openMobilePluginBottomSheet(
                            CommandBeautifierPlugin.pluginId,
                          ),
                          beautifierCardCount: cardCount,
                          beautifierShowingCard: showingCard,
                          onToggleBeautifierMode: sessionId == null
                              ? null
                              : () => _beautifierPlugin.toggleSessionDisplayMode(
                                  sessionId,
                                ),
                          onOpenSnippets: () => _openMobilePluginBottomSheet(
                            SnippetsPlugin.pluginId,
                          ),
                          onOpenPortForward: () => _openMobilePluginBottomSheet(
                            PortForwardPlugin.pluginId,
                          ),
                        );
                      },
                    ),

                  // 底部状态栏（手机端弹出软键盘时自动收起，日常完整避让手势小白条）
                  if (showBottomStatusBar)
                    RepaintBoundary(
                      child: _buildBottomPluginStatusBar(
                        pluginContext,
                        layoutMode,
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _topToolbarAction({
    required String tooltip,
    required IconData icon,
    required VoidCallback onPressed,
    String? label,
    bool highlighted = false,
  }) {
    final fg = highlighted ? TxColors.accent : TxColors.iconDefault;
    if (label != null && label.isNotEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onPressed,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 9),
              decoration: BoxDecoration(
                color: highlighted
                    ? TxColors.accent.withValues(alpha: 0.14)
                    : TxColors.bgElevated.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: highlighted
                      ? TxColors.accent.withValues(alpha: 0.45)
                      : TxColors.borderSubtle,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 17.5, color: fg),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: highlighted
                          ? FontWeight.w600
                          : FontWeight.w500,
                      color: highlighted
                          ? TxColors.textPrimary
                          : TxColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.5),
      child: SizedBox(
        width: 34,
        height: 32,
        child: IconButton(
          padding: EdgeInsets.zero,
          tooltip: tooltip,
          style: IconButton.styleFrom(
            backgroundColor: highlighted
                ? TxColors.accent.withValues(alpha: 0.14)
                : Colors.transparent,
            hoverColor: TxColors.bgHover,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          icon: Icon(icon, size: 18.5, color: fg),
          onPressed: onPressed,
        ),
      ),
    );
  }

  void _openPluginManagerSheetOrDialog(PluginContext pluginContext) {
    showPluginManagerDialog(
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
        _pluginManager.setActivePanelPlugin(DockerInspectorPlugin.pluginId);
        pluginContext.showToast('已启用扩展：Docker 容器');
      },
    );
  }

  Widget _buildTopHeaderBar(
    AdaptiveLayoutMode layoutMode,
    PluginContext pluginContext,
  ) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final mediaPadding = MediaQuery.paddingOf(context);
    final isCompact = layoutMode == AdaptiveLayoutMode.compact;
    final showDesktopLabels =
        layoutMode == AdaptiveLayoutMode.expanded && screenWidth >= 1220;
    final barHeight = isCompact ? 48.0 : 46.0;
    final hPad = isCompact ? 8.0 : 10.0;

    return Container(
      key: _topBarBoundsKey,
      height: barHeight + mediaPadding.top,
      padding: EdgeInsets.fromLTRB(
        hPad + mediaPadding.left,
        mediaPadding.top,
        hPad + mediaPadding.right,
        0,
      ),
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
          if (isCompact)
            Builder(
              builder: (ctx) => SizedBox(
                width: 38,
                height: 38,
                child: IconButton(
                  tooltip: '服务器列表',
                  padding: EdgeInsets.zero,
                  icon: const Icon(
                    Icons.menu_rounded,
                    size: 22,
                    color: TxColors.iconDefault,
                  ),
                  onPressed: () => Scaffold.of(ctx).openDrawer(),
                ),
              ),
            )
          else if (layoutMode == AdaptiveLayoutMode.expanded)
            _topToolbarAction(
              tooltip: '显示/隐藏服务器栏',
              icon: _leftSidebarCollapsed
                  ? Icons.menu_open_rounded
                  : Icons.view_sidebar_outlined,
              highlighted: !_leftSidebarCollapsed,
              onPressed: () {
                setState(
                  () => _leftSidebarCollapsed = !_leftSidebarCollapsed,
                );
                _persistUiPreferences();
              },
            ),

          const SizedBox(width: 4),

          // 手机端在已有会话标签时自动隐藏品牌文字以腾出标签宽度；无标签或平板/PC 常驻显示
          if (!isCompact || _workspace.tabs.isEmpty) ...[
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: TxColors.bgElevated,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TxColors.borderDefault),
                  ),
                  alignment: Alignment.center,
                  child: const Icon(
                    Icons.terminal_rounded,
                    size: 15,
                    color: TxColors.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'TermX',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: TxColors.textPrimary,
                  ),
                ),
              ],
            ),
            Container(
              width: 1,
              height: 18,
              margin: EdgeInsets.symmetric(horizontal: isCompact ? 8 : 10),
              color: TxColors.borderSubtle,
            ),
          ],

          Expanded(child: _buildSessionTabs()),

          const SizedBox(width: 4),
          if (isCompact) ...[
            SizedBox(
              width: 38,
              height: 38,
              child: IconButton(
                tooltip: '新建连接',
                padding: EdgeInsets.zero,
                icon: const Icon(
                  Icons.add_rounded,
                  size: 22,
                  color: TxColors.iconDefault,
                ),
                onPressed: _newLocalTab,
              ),
            ),
            SizedBox(
              width: 38,
              height: 38,
              child: PopupMenuButton<String>(
                tooltip: '更多设置',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 188),
                icon: const Icon(
                  Icons.more_vert_rounded,
                  size: 21,
                  color: TxColors.iconDefault,
                ),
                onSelected: (action) {
                  switch (action) {
                    case 'new_ssh':
                      if (_hostsLoaded) _addHost();
                    case 'palette_cursor':
                      _openMobilePaletteAndCursorSheet();
                    case 'vault':
                      showKeychainVaultDialog(
                        context: context,
                        vaultService: _vaultService,
                        hosts: _hosts,
                      );
                    case 'plugins':
                      _openPluginManagerSheetOrDialog(pluginContext);
                    case 'shortcuts':
                      _openShortcutSettings();
                  }
                },
                itemBuilder: (ctx) => const [
                  PopupMenuItem(
                    value: 'new_ssh',
                    child: Row(
                      children: [
                        Icon(Icons.dns_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('新建 SSH 主机'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'palette_cursor',
                    child: Row(
                      children: [
                        Icon(Icons.contrast_rounded, size: 18),
                        SizedBox(width: 10),
                        Text('终端配色与光标'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'vault',
                    child: Row(
                      children: [
                        Icon(Icons.key_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('安全凭据管理'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'plugins',
                    child: Row(
                      children: [
                        Icon(Icons.widgets_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('扩展管理'),
                      ],
                    ),
                  ),
                  PopupMenuItem(
                    value: 'shortcuts',
                    child: Row(
                      children: [
                        Icon(Icons.keyboard_alt_outlined, size: 18),
                        SizedBox(width: 10),
                        Text('外接键盘快捷键'),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            _topToolbarAction(
              tooltip:
                  '新建本地终端    ${_shortcutConfig.chordFor(ShortcutAction.newTab).displayLabel}',
              icon: Icons.add_rounded,
              label: showDesktopLabels ? '新建' : null,
              onPressed: _newLocalTab,
            ),

            Container(
              width: 1,
              height: 18,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: TxColors.borderSubtle,
            ),

            // 布局视图切换
            SizedBox(
              width: 34,
              height: 32,
              child: PopupMenuButton<FormFactorOverride>(
                tooltip: '布局视图 (${_formFactorOverride.label})',
                initialValue: _formFactorOverride,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 160),
                style: IconButton.styleFrom(
                  hoverColor: TxColors.bgHover,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                icon: Icon(
                  Icons.devices_outlined,
                  size: 18.5,
                  color: _formFactorOverride == FormFactorOverride.auto
                      ? TxColors.iconDefault
                      : TxColors.accent,
                ),
                onSelected: (val) {
                  setState(() => _formFactorOverride = val);
                  _persistUiPreferences();
                },
                itemBuilder: (context) => FormFactorOverride.values
                    .map(
                      (f) => PopupMenuItem(
                        value: f,
                        height: 36,
                        child: Row(
                          children: [
                            Icon(
                              _formFactorOverride == f
                                  ? Icons.check_rounded
                                  : null,
                              size: 15,
                              color: TxColors.accent,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              f.label,
                              style: const TextStyle(fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),

            // 终端配色切换
            SizedBox(
              width: 34,
              height: 32,
              child: PopupMenuButton<TermXColorPalette>(
                tooltip: '终端配色',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 190),
                style: IconButton.styleFrom(
                  hoverColor: TxColors.bgHover,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
                icon: const Icon(
                  Icons.contrast_rounded,
                  size: 18.5,
                  color: TxColors.iconDefault,
                ),
                onSelected: (p) {
                  setState(() => _colorPalette = p);
                  _persistUiPreferences();
                },
                itemBuilder: (context) => TermXColorPalette.presets
                    .map(
                      (p) => PopupMenuItem(
                        value: p,
                        height: 36,
                        child: Row(
                          children: [
                            Container(
                              width: 13,
                              height: 13,
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
                            Text(p.name, style: const TextStyle(fontSize: 13)),
                          ],
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),

            // 窗口透明度调节（PC 桌面端）
            if (DesktopNativeBridge.instance.supportsWindowOpacity)
              _topToolbarAction(
                tooltip: '窗口透明度 (${(_windowOpacity * 100).round()}%)',
                icon: Icons.opacity_rounded,
                label: showDesktopLabels
                    ? (_windowOpacity < 0.995
                          ? '${(_windowOpacity * 100).round()}%'
                          : '透明度')
                    : null,
                highlighted: _windowOpacity < 0.995,
                onPressed: _openWindowOpacityDialog,
              ),

            // 快捷键设置
            _topToolbarAction(
              tooltip:
                  '快捷键设置    ${_shortcutConfig.chordFor(ShortcutAction.openShortcuts).displayLabel}',
              icon: Icons.keyboard_alt_outlined,
              label: showDesktopLabels ? '快捷键' : null,
              onPressed: _openShortcutSettings,
            ),

            // 凭据管理
            _topToolbarAction(
              tooltip: '安全凭据管理',
              icon: Icons.key_outlined,
              label: showDesktopLabels ? '凭据' : null,
              onPressed: () => showKeychainVaultDialog(
                context: context,
                vaultService: _vaultService,
                hosts: _hosts,
              ),
            ),

            // 扩展管理
            _topToolbarAction(
              tooltip: '扩展管理',
              icon: Icons.widgets_outlined,
              label: showDesktopLabels ? '扩展' : null,
              onPressed: () => _openPluginManagerSheetOrDialog(pluginContext),
            ),

            // 右侧辅助面板开关
            ListenableBuilder(
              listenable: _pluginManager,
              builder: (context, _) {
                final open = _pluginManager.activePanelPlugin != null;
                return _topToolbarAction(
                  tooltip: open ? '隐藏右侧面板' : '展开右侧面板',
                  icon: Icons.space_dashboard_outlined,
                  label: showDesktopLabels ? '面板' : null,
                  highlighted: open,
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
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '服务器',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: TxColors.textSecondary,
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 30,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: '新建 SSH 主机',
                    style: IconButton.styleFrom(
                      hoverColor: TxColors.bgHover,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    icon: const Icon(
                      Icons.add_rounded,
                      size: 18.5,
                      color: TxColors.iconDefault,
                    ),
                    onPressed: _hostsLoaded ? () => _addHost() : null,
                  ),
                ),
              ],
            ),
          ),
          if (_hosts.length > 1 || query.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: SizedBox(
                height: 32,
                child: TextField(
                  controller: _hostSearchCtrl,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: TxColors.textPrimary,
                  ),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: '搜索主机、分组或 IP…',
                    hintStyle: const TextStyle(
                      fontSize: 12,
                      color: TxColors.textMuted,
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 15,
                      color: TxColors.textMuted,
                    ),
                    prefixIconConstraints: const BoxConstraints(minWidth: 30),
                    suffixIcon: query.isNotEmpty
                        ? InkWell(
                            onTap: () => setState(() => _hostSearchCtrl.clear()),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 15,
                              color: TxColors.textSecondary,
                            ),
                          )
                        : null,
                    suffixIconConstraints: const BoxConstraints(minWidth: 26),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    filled: true,
                    fillColor: TxColors.bgChrome,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
                      borderSide: const BorderSide(color: TxColors.borderSubtle),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(6),
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
                                _persistUiPreferences();
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5,
                                  vertical: 6,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      isCollapsed
                                          ? Icons.chevron_right_rounded
                                          : Icons.expand_more_rounded,
                                      size: 16,
                                      color: TxColors.textSecondary,
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: Text(
                                        groupName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                          color: TxColors.textSecondary,
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
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: TxColors.borderSubtle)),
            ),
            child: Row(
              children: [
                InkWell(
                  borderRadius: BorderRadius.circular(6),
                  onTap: _hostsLoaded ? () => _addHost() : null,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6, vertical: 5),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_rounded,
                          size: 16,
                          color: TxColors.textSecondary,
                        ),
                        SizedBox(width: 5),
                        Text(
                          '新建连接',
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
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
                    fontSize: 11.5,
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
            onPressed: () {
              setState(() => _formFactorOverride = FormFactorOverride.auto);
              _persistUiPreferences();
            },
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
                child: _buildTabTerminalArea(item, layoutMode, pluginContext),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildTabTerminalArea(
    TerminalTab tab,
    AdaptiveLayoutMode layoutMode,
    PluginContext pluginContext,
  ) {
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
                pluginContext,
              ),
            ),
          ],
        ),
        if ((layoutMode == AdaptiveLayoutMode.medium ||
                _formFactorOverride == FormFactorOverride.ipad) &&
            _ipadThumbPadsVisible)
          Positioned.fill(
            child: IpadFloatingThumbPads(
              modifierController: _virtualModifierController,
              onRequestTerminalFocus: () =>
                  _workspace.activePane?.focus.requestFocus(),
              onSendRaw: (seq) => _activeSession?.sendRawInput(seq),
            ),
          ),
      ],
    );
  }

  void _togglePaneBeautyCard(
    SshSessionController session,
    PluginContext pluginContext,
  ) {
    if (!_pluginManager.isPluginEnabled(CommandBeautifierPlugin.pluginId)) {
      pluginContext.showToast('命令输出美化插件当前已停用，可在右上角「扩展管理」中启用');
      return;
    }
    if (!_beautifierPlugin.toggleSessionDisplayMode(session.sessionId)) {
      pluginContext.requestOpenPanel(CommandBeautifierPlugin.pluginId);
      pluginContext.showToast('当前窗格暂无已捕获的命令输出，可在右侧命令清单中一键预览');
    }
  }

  Widget _buildPaneLayout(
    TerminalTab tab,
    PaneLayout layout,
    PluginContext pluginContext,
  ) {
    if (layout is PaneSplit) {
      return ResizablePaneSplit(
        key: ObjectKey(layout),
        split: layout,
        first: _buildPaneLayout(tab, layout.first, pluginContext),
        second: _buildPaneLayout(tab, layout.second, pluginContext),
        onRatioChanged: _persistUiPreferences,
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
      terminalOverlay: ListenableBuilder(
        listenable: _pluginManager,
        builder: (context, _) =>
            _pluginManager.buildTerminalOverlay(
              context,
              pluginContext,
              pane.session,
            ) ??
            const IgnorePointer(child: SizedBox.expand()),
      ),
      onToggleBeautyCard: () =>
          _togglePaneBeautyCard(pane.session, pluginContext),
      shortcutConfig: _shortcutConfig,
      onOpenShortcutSettings: _openShortcutSettings,
      cursorType: _cursorType,
      onCursorTypeChanged: _setCursorType,
      onFontSizeChanged: _persistUiPreferences,
      virtualModifierController: _virtualModifierController,
    );
  }

  static String _shortPluginTitle(PluginManifest m) {
    switch (m.id) {
      case ServerMonitorPlugin.pluginId:
        return '监控';
      case SftpManagerPlugin.pluginId:
        return '文件';
      case CommandBeautifierPlugin.pluginId:
        return '美化';
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
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 8),
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
                        horizontal: 2.5,
                        vertical: 5,
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(6),
                        hoverColor: TxColors.bgHover,
                        onTap: () => _pluginManager.setActivePanelPlugin(m.id),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 11),
                          decoration: BoxDecoration(
                            color: selected
                                ? TxColors.bgElevated
                                : Colors.transparent,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: selected
                                  ? TxColors.accent.withValues(alpha: 0.5)
                                  : Colors.transparent,
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                m.icon,
                                size: 16,
                                color: selected
                                    ? TxColors.accent
                                    : TxColors.textMuted,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _shortPluginTitle(m),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: selected
                                      ? FontWeight.w600
                                      : FontWeight.w500,
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
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    tooltip: '收起右侧面板',
                    style: IconButton.styleFrom(
                      hoverColor: TxColors.bgHover,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    icon: const Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: TxColors.textSecondary,
                    ),
                    onPressed: () => _pluginManager.setActivePanelPlugin(null),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBottomPluginStatusBar(
    PluginContext pluginContext,
    AdaptiveLayoutMode layoutMode,
  ) {
    final mediaPadding = MediaQuery.paddingOf(context);
    final isCompact = layoutMode == AdaptiveLayoutMode.compact;
    final hPad = isCompact ? 14.0 : 12.0;
    final fullVaultLabel = _vaultService.platformVaultBackendName;
    final vaultLabel = isCompact
        ? fullVaultLabel.split(' (').first
        : fullVaultLabel;

    return ListenableBuilder(
      listenable: _pluginManager,
      builder: (context, _) {
        final statusWidgets = <Widget>[];
        for (final plugin in _pluginManager.enabledPlugins) {
          final w = plugin.buildStatusBarWidget(context, pluginContext);
          if (w != null) {
            statusWidgets.add(
              Padding(padding: const EdgeInsets.only(right: 12), child: w),
            );
          }
        }

        return Container(
          key: const ValueKey('termx_bottom_status_bar'),
          height: 30 + mediaPadding.bottom,
          padding: EdgeInsets.fromLTRB(
            hPad + mediaPadding.left,
            0,
            hPad + mediaPadding.right,
            mediaPadding.bottom,
          ),
          decoration: const BoxDecoration(
            color: TxColors.bgChrome,
            border: Border(top: BorderSide(color: TxColors.borderSubtle)),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.lock_outline_rounded,
                size: 13,
                color: TxColors.textMuted,
              ),
              const SizedBox(width: 6),
              Flexible(
                fit: FlexFit.loose,
                child: Text(
                  vaultLabel,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: TxColors.textMuted,
                  ),
                ),
              ),
              if (statusWidgets.isNotEmpty)
                Container(
                  width: 1,
                  height: 13,
                  margin: EdgeInsets.symmetric(horizontal: isCompact ? 10 : 12),
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
              7,
              widget.isEditable ? 4 : 8,
              7,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 20,
                  decoration: BoxDecoration(
                    color: widget.isCurrent
                        ? indicatorColor
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                OsLogoIcon(
                  os: widget.osType,
                  size: 19,
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
                              width: 6.5,
                              height: 6.5,
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
                                fontSize: 13,
                                fontWeight: widget.isCurrent
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        h.authMethod == AuthMethod.localShell
                            ? '${h.username} · 本机终端'
                            : '${h.username}@${h.host}:${h.port}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textMuted,
                        ),
                      ),
                      if (showTags) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 4,
                          runSpacing: 3,
                          children: [
                            for (final t in h.tags)
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 5.5,
                                  vertical: 1.5,
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
                                    fontSize: 10.5,
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
                  SizedBox(
                    width: 30,
                    height: 30,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      tooltip: '编辑会话配置',
                      style: IconButton.styleFrom(
                        hoverColor: TxColors.bgHover,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                            icon: Icon(
                        Icons.edit_outlined,
                        size: 15.5,
                        color: (_hovered || widget.isCurrent)
                            ? TxColors.iconDefault
                            : TxColors.textMuted.withValues(alpha: 0.45),
                      ),
                      onPressed: widget.onEdit,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 右侧检查器面板 1:1 全局坐标跟随分隔手柄
///
/// 采用底层 [Listener] 捕获屏幕全局坐标 (`event.position.dx`) 与按下时的基准宽度做纯增量计算，
/// 彻底避免 [GestureDetector.onHorizontalDragUpdate] 因自身 [RenderBox] 同步位移引发的局部坐标
/// 反向抵消（“不跟手/橡皮筋滞后”）与 18px 拖拽死区问题。
class _RightPanelResizeHandle extends StatefulWidget {
  const _RightPanelResizeHandle({
    super.key,
    required this.currentWidth,
    required this.minWidth,
    required this.maxWidth,
    required this.onWidthChanged,
    required this.onDragEnd,
    required this.onResetDefault,
  });

  final double currentWidth;
  final double minWidth;
  final double maxWidth;
  final ValueChanged<double> onWidthChanged;
  final VoidCallback onDragEnd;
  final VoidCallback onResetDefault;

  @override
  State<_RightPanelResizeHandle> createState() =>
      _RightPanelResizeHandleState();
}

class _RightPanelResizeHandleState extends State<_RightPanelResizeHandle> {
  bool _hovered = false;
  int? _activePointer;
  double _dragStartGlobalX = 0.0;
  double _dragStartWidth = 0.0;

  bool get _dragging => _activePointer != null;

  @override
  Widget build(BuildContext context) {
    final highlight = _hovered || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onDoubleTap: () {
          setState(() => _activePointer = null);
          widget.onResetDefault();
        },
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (event.kind == PointerDeviceKind.mouse && event.buttons != 1) {
              return;
            }
            setState(() {
              _activePointer = event.pointer;
              _dragStartGlobalX = event.position.dx;
              _dragStartWidth = widget.currentWidth;
            });
          },
          onPointerMove: (event) {
            if (event.pointer != _activePointer) return;
            final deltaX = event.position.dx - _dragStartGlobalX;
            final nextWidth = (_dragStartWidth - deltaX).clamp(
              widget.minWidth,
              widget.maxWidth,
            );
            if ((nextWidth - widget.currentWidth).abs() > 0.05) {
              widget.onWidthChanged(nextWidth);
            }
          },
          onPointerUp: (event) {
            if (event.pointer == _activePointer) {
              setState(() => _activePointer = null);
              widget.onDragEnd();
            }
          },
          onPointerCancel: (event) {
            if (event.pointer == _activePointer) {
              setState(() => _activePointer = null);
              widget.onDragEnd();
            }
          },
          child: Container(
            width: 7,
            color: TxColors.bgSidebar,
            alignment: Alignment.centerLeft,
            child: Container(
              width: highlight ? 2 : 1,
              color: highlight ? TxColors.accent : TxColors.borderSubtle,
            ),
          ),
        ),
      ),
    );
  }
}
