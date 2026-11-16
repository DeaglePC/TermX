import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// 按下 `Ctrl+A` 时的终端行为策略
enum CtrlABehavior {
  moveToLineStart(
    id: 'line_start',
    title: '光标定位到开头（推荐 · Shell 行首习惯）',
    subtitle:
        'SSH / Linux / macOS 发送标准 ^A (0x01) 移至行首；本机 PowerShell 主界面自动映射为 Home 移至行首（tmux/vim 备用屏仍透传 ^A）。',
  ),
  passthroughCtrlA(
    id: 'passthrough',
    title: '始终原样发送 Ctrl+A (^A / 0x01)',
    subtitle: '不做平台转换，直接把 0x01 发给底层进程（适合已在 PowerShell 配置 Emacs 模式或重度 tmux 用户）。',
  ),
  selectAllText(
    id: 'select_all',
    title: '全选当前终端文字',
    subtitle: '将 Ctrl+A 作为全选缓冲区文本快捷键（默认我们已将全选移至 Ctrl+Shift+A）。',
  );

  final String id;
  final String title;
  final String subtitle;

  const CtrlABehavior({
    required this.id,
    required this.title,
    required this.subtitle,
  });

  static CtrlABehavior fromId(String? id) => CtrlABehavior.values.firstWhere(
    (e) => e.id == id,
    orElse: () => CtrlABehavior.moveToLineStart,
  );
}

/// 可自定义的终端与工作台动作枚举
enum ShortcutAction {
  copy('copy', '复制选中内容', '终端编辑'),
  paste('paste', '粘贴剪贴板文本', '终端编辑'),
  selectAll('select_all', '全选终端屏幕文字', '终端编辑'),
  find('find', '查找终端输出', '终端编辑'),
  clear('clear', '清空当前屏幕', '终端编辑'),
  newTab('new_tab', '新建本地终端标签', '标签与分屏'),
  closePane('close_pane', '关闭当前窗格', '标签与分屏'),
  splitRight('split_right', '向右分屏', '标签与分屏'),
  splitDown('split_down', '向下分屏', '标签与分屏'),
  maximizePane('maximize_pane', '最大化 / 还原当前窗格', '标签与分屏'),
  toggleBeauty('toggle_beauty', '切换命令美化卡片 / 终端原文', '插件与工作台'),
  toggleMonitor('toggle_monitor', '打开 / 收起服务器监控面板', '插件与工作台'),
  toggleSftp('toggle_sftp', '打开 / 收起 SFTP 文件面板', '插件与工作台'),
  openShortcuts('open_shortcuts', '打开快捷键设置面板', '插件与工作台');

  final String id;
  final String label;
  final String category;

  const ShortcutAction(this.id, this.label, this.category);
}

/// 单个键盘组合键定义
class KeyChord {
  final int keyId;
  final bool ctrl;
  final bool shift;
  final bool alt;

  const KeyChord({
    required this.keyId,
    this.ctrl = false,
    this.shift = false,
    this.alt = false,
  });

  factory KeyChord.fromLogical(
    LogicalKeyboardKey key, {
    bool ctrl = false,
    bool shift = false,
    bool alt = false,
  }) => KeyChord(
    keyId: _normalizeLogicalKey(key).keyId,
    ctrl: ctrl,
    shift: shift,
    alt: alt,
  );

  LogicalKeyboardKey get logicalKey =>
      LogicalKeyboardKey.findKeyByKeyId(keyId) ?? LogicalKeyboardKey(keyId);

  bool matches(
    KeyEvent event, {
    required bool isCmdOrCtrlPressed,
    required bool isShiftPressed,
    required bool isAltPressed,
  }) {
    final normalized = _normalizeLogicalKey(event.logicalKey);
    return normalized.keyId == keyId &&
        isCmdOrCtrlPressed == ctrl &&
        isShiftPressed == shift &&
        isAltPressed == alt;
  }

  String get displayLabel {
    final parts = <String>[];
    final isMac = Platform.isMacOS;
    if (ctrl) parts.add(isMac ? '⌘' : 'Ctrl');
    if (alt) parts.add(isMac ? '⌥' : 'Alt');
    if (shift) parts.add(isMac ? '⇧' : 'Shift');
    parts.add(_keyName(logicalKey));
    return parts.join('+');
  }

  Map<String, dynamic> toJson() => {
    'keyId': keyId,
    'ctrl': ctrl,
    'shift': shift,
    'alt': alt,
  };

  factory KeyChord.fromJson(Map<String, dynamic> json) => KeyChord(
    keyId: json['keyId'] as int,
    ctrl: json['ctrl'] as bool? ?? false,
    shift: json['shift'] as bool? ?? false,
    alt: json['alt'] as bool? ?? false,
  );

  @override
  bool operator ==(Object other) =>
      other is KeyChord &&
      other.keyId == keyId &&
      other.ctrl == ctrl &&
      other.shift == shift &&
      other.alt == alt;

  @override
  int get hashCode => Object.hash(keyId, ctrl, shift, alt);

  static bool isModifierOnly(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.control ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.shift ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.alt ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight ||
        key == LogicalKeyboardKey.meta;
  }

  static LogicalKeyboardKey _normalizeLogicalKey(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length == 1) {
      final upper = label.toUpperCase().codeUnitAt(0);
      if (upper >= 65 && upper <= 90) {
        return LogicalKeyboardKey(0x00000061 + (upper - 65));
      }
      if (upper >= 48 && upper <= 57) {
        return LogicalKeyboardKey(0x00000030 + (upper - 48));
      }
    }
    if (key == LogicalKeyboardKey.numpadEnter) return LogicalKeyboardKey.enter;
    return key;
  }

  static String _keyName(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.enter) return 'Enter';
    if (key == LogicalKeyboardKey.escape) return 'Esc';
    if (key == LogicalKeyboardKey.tab) return 'Tab';
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.backspace) return 'Backspace';
    if (key == LogicalKeyboardKey.delete) return 'Delete';
    if (key == LogicalKeyboardKey.home) return 'Home';
    if (key == LogicalKeyboardKey.end) return 'End';
    if (key == LogicalKeyboardKey.pageUp) return 'PageUp';
    if (key == LogicalKeyboardKey.pageDown) return 'PageDown';
    if (key == LogicalKeyboardKey.arrowUp) return '↑';
    if (key == LogicalKeyboardKey.arrowDown) return '↓';
    if (key == LogicalKeyboardKey.arrowLeft) return '←';
    if (key == LogicalKeyboardKey.arrowRight) return '→';
    if (key == LogicalKeyboardKey.comma) return ',';
    if (key == LogicalKeyboardKey.period) return '.';
    if (key == LogicalKeyboardKey.slash) return '/';
    if (key == LogicalKeyboardKey.minus) return '-';
    if (key == LogicalKeyboardKey.equal) return '=';
    if (key == LogicalKeyboardKey.f1) return 'F1';
    if (key == LogicalKeyboardKey.f2) return 'F2';
    if (key == LogicalKeyboardKey.f3) return 'F3';
    if (key == LogicalKeyboardKey.f4) return 'F4';
    if (key == LogicalKeyboardKey.f5) return 'F5';
    if (key == LogicalKeyboardKey.f6) return 'F6';
    if (key == LogicalKeyboardKey.f7) return 'F7';
    if (key == LogicalKeyboardKey.f8) return 'F8';
    if (key == LogicalKeyboardKey.f9) return 'F9';
    if (key == LogicalKeyboardKey.f10) return 'F10';
    if (key == LogicalKeyboardKey.f11) return 'F11';
    if (key == LogicalKeyboardKey.f12) return 'F12';
    final lbl = key.keyLabel.trim();
    if (lbl.isNotEmpty) return lbl.toUpperCase();
    return key.debugName ?? 'Key';
  }
}

/// 全局快捷键与终端按键习惯配置
class ShortcutConfig {
  final CtrlABehavior ctrlABehavior;
  final bool powershellCtrlELineEnd;
  final bool smartCtrlCCopy;
  final bool ctrlVPaste;
  final Map<ShortcutAction, KeyChord> bindings;

  const ShortcutConfig({
    this.ctrlABehavior = CtrlABehavior.moveToLineStart,
    this.powershellCtrlELineEnd = true,
    this.smartCtrlCCopy = true,
    this.ctrlVPaste = true,
    required this.bindings,
  });

  static Map<ShortcutAction, KeyChord> defaultBindings() => {
    ShortcutAction.copy: KeyChord.fromLogical(
      LogicalKeyboardKey.keyC,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.paste: KeyChord.fromLogical(
      LogicalKeyboardKey.keyV,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.selectAll: KeyChord.fromLogical(
      LogicalKeyboardKey.keyA,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.find: KeyChord.fromLogical(
      LogicalKeyboardKey.keyF,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.clear: KeyChord.fromLogical(
      LogicalKeyboardKey.keyK,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.newTab: KeyChord.fromLogical(
      LogicalKeyboardKey.keyT,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.closePane: KeyChord.fromLogical(
      LogicalKeyboardKey.keyW,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.splitRight: KeyChord.fromLogical(
      LogicalKeyboardKey.keyD,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.splitDown: KeyChord.fromLogical(
      LogicalKeyboardKey.keyE,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.maximizePane: KeyChord.fromLogical(
      LogicalKeyboardKey.enter,
      alt: true,
    ),
    ShortcutAction.toggleBeauty: KeyChord.fromLogical(
      LogicalKeyboardKey.keyB,
      alt: true,
    ),
    ShortcutAction.toggleMonitor: KeyChord.fromLogical(
      LogicalKeyboardKey.keyM,
      ctrl: true,
      shift: true,
    ),
    ShortcutAction.toggleSftp: KeyChord.fromLogical(
      LogicalKeyboardKey.keyF,
      ctrl: true,
      alt: true,
    ),
    ShortcutAction.openShortcuts: KeyChord.fromLogical(LogicalKeyboardKey.f1),
  };

  factory ShortcutConfig.defaults() =>
      ShortcutConfig(bindings: defaultBindings());

  KeyChord chordFor(ShortcutAction action) =>
      bindings[action] ?? defaultBindings()[action]!;

  ShortcutAction? matchAction(
    KeyEvent event, {
    required bool isCmdOrCtrlPressed,
    required bool isShiftPressed,
    required bool isAltPressed,
  }) {
    for (final entry in bindings.entries) {
      if (entry.value.matches(
        event,
        isCmdOrCtrlPressed: isCmdOrCtrlPressed,
        isShiftPressed: isShiftPressed,
        isAltPressed: isAltPressed,
      )) {
        return entry.key;
      }
    }
    return null;
  }

  ShortcutConfig copyWith({
    CtrlABehavior? ctrlABehavior,
    bool? powershellCtrlELineEnd,
    bool? smartCtrlCCopy,
    bool? ctrlVPaste,
    Map<ShortcutAction, KeyChord>? bindings,
  }) => ShortcutConfig(
    ctrlABehavior: ctrlABehavior ?? this.ctrlABehavior,
    powershellCtrlELineEnd:
        powershellCtrlELineEnd ?? this.powershellCtrlELineEnd,
    smartCtrlCCopy: smartCtrlCCopy ?? this.smartCtrlCCopy,
    ctrlVPaste: ctrlVPaste ?? this.ctrlVPaste,
    bindings: bindings ?? Map<ShortcutAction, KeyChord>.of(this.bindings),
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'ctrlABehavior': ctrlABehavior.id,
    'powershellCtrlELineEnd': powershellCtrlELineEnd,
    'smartCtrlCCopy': smartCtrlCCopy,
    'ctrlVPaste': ctrlVPaste,
    'bindings': {
      for (final e in bindings.entries) e.key.id: e.value.toJson(),
    },
  };

  factory ShortcutConfig.fromJson(Map<String, dynamic> json) {
    final merged = defaultBindings();
    final rawBindings = json['bindings'];
    if (rawBindings is Map<String, dynamic>) {
      for (final action in ShortcutAction.values) {
        final rawChord = rawBindings[action.id];
        if (rawChord is Map<String, dynamic>) {
          try {
            merged[action] = KeyChord.fromJson(rawChord);
          } catch (_) {}
        }
      }
    }
    return ShortcutConfig(
      ctrlABehavior: CtrlABehavior.fromId(json['ctrlABehavior'] as String?),
      powershellCtrlELineEnd: json['powershellCtrlELineEnd'] as bool? ?? true,
      smartCtrlCCopy: json['smartCtrlCCopy'] as bool? ?? true,
      ctrlVPaste: json['ctrlVPaste'] as bool? ?? true,
      bindings: merged,
    );
  }
}

/// 快捷键配置持久化仓库
class ShortcutStore {
  ShortcutStore({Future<Directory> Function()? directoryProvider})
    : _isInMemoryTestFallback =
          directoryProvider == null &&
          Platform.environment['FLUTTER_TEST'] == 'true',
      _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final bool _isInMemoryTestFallback;
  final Future<Directory> Function() _directoryProvider;
  Future<void> _pendingWrite = Future<void>.value();
  ShortcutConfig _testMemoryConfig = ShortcutConfig.defaults();

  Future<File> get _configFile async {
    final dir = await _directoryProvider();
    return File('${dir.path}${Platform.pathSeparator}shortcuts.json');
  }

  Future<ShortcutConfig> load() async {
    if (_isInMemoryTestFallback) return _testMemoryConfig;
    try {
      final file = await _configFile;
      if (!await file.exists()) return ShortcutConfig.defaults();
      final data =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return ShortcutConfig.fromJson(data);
    } catch (_) {
      return ShortcutConfig.defaults();
    }
  }

  Future<void> save(ShortcutConfig config) {
    if (_isInMemoryTestFallback) {
      _testMemoryConfig = config;
      return Future<void>.value();
    }
    final encoded = const JsonEncoder.withIndent('  ').convert(config.toJson());
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
