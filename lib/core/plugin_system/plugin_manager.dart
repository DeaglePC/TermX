import 'package:flutter/material.dart';
import '../ssh/ssh_session_controller.dart';
import 'plugin_interface.dart';

/// 微内核插件注册与生命周期管理器
class PluginManager extends ChangeNotifier {
  final Map<String, TermXPlugin> _plugins = {};
  final Set<String> _enabledPluginIds = {};
  String? _activePanelPluginId;

  List<TermXPlugin> get allPlugins => _plugins.values.toList(growable: false);

  List<TermXPlugin> get enabledPlugins => _plugins.values
      .where((p) => _enabledPluginIds.contains(p.manifest.id))
      .toList(growable: false);

  String? get activePanelPluginId => _activePanelPluginId;

  TermXPlugin? get activePanelPlugin {
    if (_activePanelPluginId == null) return null;
    if (!_enabledPluginIds.contains(_activePanelPluginId)) return null;
    return _plugins[_activePanelPluginId];
  }

  /// 注册插件并默认启用
  Future<void> registerPlugin(TermXPlugin plugin, {bool enabled = true}) async {
    final id = plugin.manifest.id;
    _plugins[id] = plugin;
    if (enabled) {
      _enabledPluginIds.add(id);
    }
    await plugin.onInit();
    _activePanelPluginId ??= id;
    notifyListeners();
  }

  bool isPluginEnabled(String pluginId) => _enabledPluginIds.contains(pluginId);

  /// 动态启用或禁用插件（即时热插拔，无需重启终端）
  void setPluginEnabled(String pluginId, bool enabled) {
    final plugin = _plugins[pluginId];
    if (plugin == null) return;
    if (enabled) {
      _enabledPluginIds.add(pluginId);
      _activePanelPluginId ??= pluginId;
    } else {
      _enabledPluginIds.remove(pluginId);
      if (_activePanelPluginId == pluginId) {
        final remaining = enabledPlugins;
        _activePanelPluginId =
            remaining.isNotEmpty ? remaining.first.manifest.id : null;
      }
    }
    notifyListeners();
  }

  void setActivePanelPlugin(String? pluginId) {
    if (_activePanelPluginId == pluginId) return;
    _activePanelPluginId = pluginId;
    notifyListeners();
  }

  void togglePanelPlugin(String pluginId) {
    if (_activePanelPluginId == pluginId) {
      _activePanelPluginId = null;
    } else {
      _activePanelPluginId = pluginId;
    }
    notifyListeners();
  }

  /// 通知所有已注册插件有新会话挂载
  void notifySessionAttached(SshSessionController session) {
    for (final plugin in _plugins.values) {
      plugin.onSessionAttached(session);
    }
  }

  /// 广播当前活跃 SSH 会话变更给所有已启用插件
  void notifyActiveSessionChanged(SshSessionController? session) {
    for (final plugin in enabledPlugins) {
      plugin.onActiveSessionChanged(session);
    }
  }

  /// 构建指定终端窗格上由已启用插件提供的画布贴片浮层
  Widget? buildTerminalOverlay(
    BuildContext context,
    PluginContext pluginContext,
    SshSessionController session,
  ) {
    final overlays = <Widget>[];
    for (final plugin in enabledPlugins) {
      final w = plugin.buildTerminalOverlayWidget(
        context,
        pluginContext,
        session,
      );
      if (w != null) {
        overlays.add(w);
      }
    }
    if (overlays.isEmpty) return null;
    if (overlays.length == 1) return overlays.first;
    return Stack(fit: StackFit.expand, children: overlays);
  }

  @override
  void dispose() {
    for (final plugin in _plugins.values) {
      plugin.onUnload();
      plugin.dispose();
    }
    super.dispose();
  }
}
