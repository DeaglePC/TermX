import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:xterm/xterm.dart';

import '../theme/adaptive_layout.dart';
import 'terminal_workspace.dart';

/// 界面个性化偏好与上次打开的工作区完整布局快照
class UiPreferences {
  const UiPreferences({
    this.windowOpacity = 1.0,
    this.colorPaletteName,
    this.rightPanelWidth,
    this.cursorType = TerminalCursorType.block,
    this.leftSidebarCollapsed = false,
    this.collapsedHostGroups = const [],
    this.rightPanelOpen = true,
    this.activeRightPluginId,
    this.enabledExtraPluginIds = const [],
    this.disabledPluginIds = const [],
    this.formFactorOverride = FormFactorOverride.auto,
    this.workspaceLayout,
  });

  static const double minOpacity = 0.35;
  static const double maxOpacity = 1.0;

  final double windowOpacity;
  final String? colorPaletteName;
  final double? rightPanelWidth;
  final TerminalCursorType cursorType;
  final bool leftSidebarCollapsed;
  final List<String> collapsedHostGroups;
  final bool rightPanelOpen;
  final String? activeRightPluginId;
  final List<String> enabledExtraPluginIds;
  final List<String> disabledPluginIds;
  final FormFactorOverride formFactorOverride;
  final WorkspaceLayoutSnapshot? workspaceLayout;

  UiPreferences copyWith({
    double? windowOpacity,
    String? colorPaletteName,
    double? rightPanelWidth,
    bool clearRightPanelWidth = false,
    TerminalCursorType? cursorType,
    bool? leftSidebarCollapsed,
    List<String>? collapsedHostGroups,
    bool? rightPanelOpen,
    String? activeRightPluginId,
    bool clearActiveRightPluginId = false,
    List<String>? enabledExtraPluginIds,
    List<String>? disabledPluginIds,
    FormFactorOverride? formFactorOverride,
    WorkspaceLayoutSnapshot? workspaceLayout,
    bool clearWorkspaceLayout = false,
  }) => UiPreferences(
    windowOpacity: (windowOpacity ?? this.windowOpacity).clamp(
      minOpacity,
      maxOpacity,
    ),
    colorPaletteName: colorPaletteName ?? this.colorPaletteName,
    rightPanelWidth: clearRightPanelWidth
        ? null
        : (rightPanelWidth ?? this.rightPanelWidth),
    cursorType: cursorType ?? this.cursorType,
    leftSidebarCollapsed: leftSidebarCollapsed ?? this.leftSidebarCollapsed,
    collapsedHostGroups: collapsedHostGroups ?? this.collapsedHostGroups,
    rightPanelOpen: rightPanelOpen ?? this.rightPanelOpen,
    activeRightPluginId: clearActiveRightPluginId
        ? null
        : (activeRightPluginId ?? this.activeRightPluginId),
    enabledExtraPluginIds: enabledExtraPluginIds ?? this.enabledExtraPluginIds,
    disabledPluginIds: disabledPluginIds ?? this.disabledPluginIds,
    formFactorOverride: formFactorOverride ?? this.formFactorOverride,
    workspaceLayout: clearWorkspaceLayout
        ? null
        : (workspaceLayout ?? this.workspaceLayout),
  );

  static String _encodeCursorType(TerminalCursorType type) => switch (type) {
    TerminalCursorType.block => 'block',
    TerminalCursorType.verticalBar => 'beam',
    TerminalCursorType.underline => 'underline',
  };

  static TerminalCursorType _decodeCursorType(String? raw) => switch (raw) {
    'beam' || 'verticalBar' => TerminalCursorType.verticalBar,
    'underline' => TerminalCursorType.underline,
    _ => TerminalCursorType.block,
  };

  static FormFactorOverride _decodeFormFactor(String? raw) {
    for (final item in FormFactorOverride.values) {
      if (item.name == raw) return item;
    }
    return FormFactorOverride.auto;
  }

  Map<String, dynamic> toJson() => {
    'version': 2,
    'windowOpacity': windowOpacity.clamp(minOpacity, maxOpacity),
    'cursorType': _encodeCursorType(cursorType),
    'leftSidebarCollapsed': leftSidebarCollapsed,
    if (collapsedHostGroups.isNotEmpty)
      'collapsedHostGroups': collapsedHostGroups,
    'rightPanelOpen': rightPanelOpen,
    if (activeRightPluginId != null) 'activeRightPluginId': activeRightPluginId,
    if (enabledExtraPluginIds.isNotEmpty)
      'enabledExtraPluginIds': enabledExtraPluginIds,
    if (disabledPluginIds.isNotEmpty) 'disabledPluginIds': disabledPluginIds,
    if (formFactorOverride != FormFactorOverride.auto)
      'formFactorOverride': formFactorOverride.name,
    if (colorPaletteName != null) 'colorPaletteName': colorPaletteName,
    if (rightPanelWidth != null) 'rightPanelWidth': rightPanelWidth,
    if (workspaceLayout != null) 'workspaceLayout': workspaceLayout!.toJson(),
  };

  factory UiPreferences.fromJson(Map<String, dynamic> json) {
    final rawOpacity = (json['windowOpacity'] as num?)?.toDouble() ?? 1.0;
    final rawWidth = (json['rightPanelWidth'] as num?)?.toDouble();
    final rawCollapsedGroups = json['collapsedHostGroups'];
    final rawExtraPlugins = json['enabledExtraPluginIds'];
    final rawDisabledPlugins = json['disabledPluginIds'];
    final rawWorkspace = json['workspaceLayout'];
    return UiPreferences(
      windowOpacity: rawOpacity.clamp(minOpacity, maxOpacity),
      colorPaletteName: json['colorPaletteName'] as String?,
      rightPanelWidth: rawWidth != null && rawWidth >= 300 && rawWidth <= 960
          ? rawWidth
          : null,
      cursorType: _decodeCursorType(json['cursorType'] as String?),
      leftSidebarCollapsed: json['leftSidebarCollapsed'] == true,
      collapsedHostGroups: rawCollapsedGroups is List
          ? rawCollapsedGroups.whereType<String>().toList()
          : const [],
      rightPanelOpen: json['rightPanelOpen'] != false,
      activeRightPluginId: json['activeRightPluginId'] as String?,
      enabledExtraPluginIds: rawExtraPlugins is List
          ? rawExtraPlugins.whereType<String>().toList()
          : const [],
      disabledPluginIds: rawDisabledPlugins is List
          ? rawDisabledPlugins.whereType<String>().toList()
          : const [],
      formFactorOverride: _decodeFormFactor(
        json['formFactorOverride'] as String?,
      ),
      workspaceLayout: rawWorkspace is Map
          ? WorkspaceLayoutSnapshot.fromJson(
              rawWorkspace.cast<String, dynamic>(),
            )
          : null,
    );
  }
}

/// 界面个性化偏好持久化仓库
class UiPreferencesStore {
  UiPreferencesStore({Future<Directory> Function()? directoryProvider})
    : _isInMemoryTestFallback =
          directoryProvider == null &&
          Platform.environment['FLUTTER_TEST'] == 'true',
      _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final bool _isInMemoryTestFallback;
  final Future<Directory> Function() _directoryProvider;
  Future<void> _pendingWrite = Future<void>.value();
  UiPreferences _testMemoryPrefs = const UiPreferences();

  Future<File> get _configFile async {
    final dir = await _directoryProvider();
    return File('${dir.path}${Platform.pathSeparator}ui_preferences.json');
  }

  Future<UiPreferences> load() async {
    if (_isInMemoryTestFallback) return _testMemoryPrefs;
    try {
      final file = await _configFile;
      if (!await file.exists()) return const UiPreferences();
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return UiPreferences.fromJson(data);
    } catch (_) {
      return const UiPreferences();
    }
  }

  Future<void> save(UiPreferences prefs) {
    if (_isInMemoryTestFallback) {
      _testMemoryPrefs = prefs;
      return Future<void>.value();
    }
    final encoded = const JsonEncoder.withIndent('  ').convert(prefs.toJson());
    final write = _pendingWrite.then((_) async {
      final file = await _configFile;
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(encoded, flush: true);
      try {
        await tmp.rename(file.path);
      } on FileSystemException {
        await file.writeAsString(encoded, flush: true);
        if (await tmp.exists()) {
          try {
            await tmp.delete();
          } catch (_) {}
        }
      }
    });
    _pendingWrite = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }
}
