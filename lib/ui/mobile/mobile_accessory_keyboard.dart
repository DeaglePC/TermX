import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 跨组件共享的虚拟修饰键控制器（支持底部 CTRL / ALT 组合键同时作用于：
/// 1. 底部扩展键盘栏自身按键与展开的 A-Z 组合键排；
/// 2. 手机系统软键盘 (IME) 输入；
/// 3. 外接物理键盘按键）
class VirtualModifierController extends ChangeNotifier {
  bool _ctrlArmed = false;
  bool _ctrlLocked = false;
  bool _altArmed = false;
  bool _altLocked = false;
  DateTime? _lastCtrlTapAt;
  DateTime? _lastAltTapAt;

  bool get ctrlArmed => _ctrlArmed;
  bool get ctrlLocked => _ctrlLocked;
  bool get isCtrlActive => _ctrlArmed || _ctrlLocked;

  bool get altArmed => _altArmed;
  bool get altLocked => _altLocked;
  bool get isAltActive => _altArmed || _altLocked;

  bool get hasActiveModifier => isCtrlActive || isAltActive;

  /// 单击立即激活 CTRL（0ms 延迟，不注册 DoubleTapGestureRecognizer 阻塞手势竞技场）；
  /// 350ms 内再次点击自动升级为锁定状态 `CTRL🔒`，再次点击解除。
  void tapCtrl({DateTime? now}) {
    final current = now ?? DateTime.now();
    if (_ctrlLocked) {
      _ctrlLocked = false;
      _ctrlArmed = false;
      _lastCtrlTapAt = null;
    } else if (_ctrlArmed) {
      if (_lastCtrlTapAt != null &&
          current.difference(_lastCtrlTapAt!) <=
              const Duration(milliseconds: 350)) {
        _ctrlLocked = true;
        _ctrlArmed = true;
      } else {
        _ctrlArmed = false;
      }
      _lastCtrlTapAt = null;
    } else {
      _ctrlArmed = true;
      _lastCtrlTapAt = current;
    }
    notifyListeners();
  }

  void toggleCtrlLock() {
    _ctrlLocked = !_ctrlLocked;
    _ctrlArmed = _ctrlLocked;
    _lastCtrlTapAt = null;
    notifyListeners();
  }

  void tapAlt({DateTime? now}) {
    final current = now ?? DateTime.now();
    if (_altLocked) {
      _altLocked = false;
      _altArmed = false;
      _lastAltTapAt = null;
    } else if (_altArmed) {
      if (_lastAltTapAt != null &&
          current.difference(_lastAltTapAt!) <=
              const Duration(milliseconds: 350)) {
        _altLocked = true;
        _altArmed = true;
      } else {
        _altArmed = false;
      }
      _lastAltTapAt = null;
    } else {
      _altArmed = true;
      _lastAltTapAt = current;
    }
    notifyListeners();
  }

  void toggleAltLock() {
    _altLocked = !_altLocked;
    _altArmed = _altLocked;
    _lastAltTapAt = null;
    notifyListeners();
  }

  void clearAll() {
    if (!_ctrlArmed && !_ctrlLocked && !_altArmed && !_altLocked) return;
    _ctrlArmed = false;
    _ctrlLocked = false;
    _altArmed = false;
    _altLocked = false;
    _lastCtrlTapAt = null;
    _lastAltTapAt = null;
    notifyListeners();
  }

  /// 将单次触发的修饰键复位（锁定态保持不变）
  void consumeOneShot() {
    var changed = false;
    if (_ctrlArmed && !_ctrlLocked) {
      _ctrlArmed = false;
      _lastCtrlTapAt = null;
      changed = true;
    }
    if (_altArmed && !_altLocked) {
      _altArmed = false;
      _lastAltTapAt = null;
      changed = true;
    }
    if (changed) notifyListeners();
  }

  String? _lastHardwareConsumedRaw;
  DateTime? _lastHardwareConsumedAt;

  /// 记录已由外接物理键盘 KeyDownEvent 拦截并消耗虚拟修饰键的原始字符，避免桌面端 IME 紧接着重发同一字符
  void recordHardwareKeyHandled(String rawChar) {
    _lastHardwareConsumedRaw = rawChar;
    _lastHardwareConsumedAt = DateTime.now();
  }

  /// 供 `SshSessionController.inputModifierTransform` 使用：拦截软键盘或终端输入并套用当前 CTRL / ALT
  String transformTerminalOutput(String rawSequence) {
    if (_lastHardwareConsumedRaw != null &&
        _lastHardwareConsumedAt != null &&
        rawSequence.toLowerCase() == _lastHardwareConsumedRaw!.toLowerCase() &&
        DateTime.now().difference(_lastHardwareConsumedAt!) <=
            const Duration(milliseconds: 60)) {
      _lastHardwareConsumedRaw = null;
      _lastHardwareConsumedAt = null;
      return '';
    }
    return applyAndConsume(rawSequence);
  }

  /// 将输入序列按当前激活的 CTRL / ALT 状态转换为终端控制序列，并自动消耗单次修饰态
  String applyAndConsume(String rawSequence) {
    final ctrl = isCtrlActive;
    final alt = isAltActive;
    if (!ctrl && !alt) return rawSequence;
    final transformed = transformSequence(
      rawSequence,
      ctrl: ctrl,
      alt: alt,
    );
    consumeOneShot();
    return transformed;
  }

  /// 纯函数：将按键或转义序列转换为带 CTRL / ALT 修饰的终端字节序列
  static String transformSequence(
    String sequence, {
    required bool ctrl,
    required bool alt,
  }) {
    if (sequence.isEmpty) return sequence;
    var result = sequence;

    if (ctrl) {
      result = _applyCtrlToSequence(result);
    }

    if (alt) {
      if (result.startsWith('\x1b[') && result.length == 3) {
        // 方向键 / Home / End 叠加 Alt (modifier 3) 或 Ctrl+Alt (modifier 7)
        final finalChar = result[2];
        final mod = ctrl ? 7 : 3;
        result = '\x1b[1;$mod$finalChar';
      } else if (!result.startsWith('\x1b')) {
        result = '\x1b$result';
      }
    }

    return result;
  }

  static String _applyCtrlToSequence(String sequence) {
    // 1. 标准 CSI 方向键与 Home/End -> xterm Ctrl 修饰序列 (\x1b[1;5X)
    switch (sequence) {
      case '\x1b[A':
        return '\x1b[1;5A';
      case '\x1b[B':
        return '\x1b[1;5B';
      case '\x1b[C':
        return '\x1b[1;5C';
      case '\x1b[D':
        return '\x1b[1;5D';
      case '\x1b[H':
        return '\x1b[1;5H';
      case '\x1b[F':
        return '\x1b[1;5F';
    }

    // 2. 单字符（含软键盘多字符逐一转换）
    if (sequence.length == 1) {
      return _charToCtrlCode(sequence);
    }

    // 若不是以 ESC 开头的控制序列（例如软键盘一次性提交了普通文本），对首字符或逐字符转换
    if (!sequence.startsWith('\x1b')) {
      final buf = StringBuffer();
      for (var i = 0; i < sequence.length; i++) {
        buf.write(_charToCtrlCode(sequence[i]));
      }
      return buf.toString();
    }

    return sequence;
  }

  static String _charToCtrlCode(String ch) {
    final upper = ch.toUpperCase().codeUnitAt(0);
    // A-Z (65..90) 及 @ [ \ ] ^ _ (64..95) -> 0x00..0x1F
    if (upper >= 64 && upper <= 95) {
      return String.fromCharCode(upper - 64);
    }
    switch (ch) {
      case ' ':
      case '2':
      case '`':
        return '\x00'; // Ctrl+Space / Ctrl+2 -> NUL
      case '3':
        return '\x1b'; // Ctrl+3 -> ESC
      case '4':
      case '|':
        return '\x1c'; // Ctrl+\ / Ctrl+| -> FS (SIGQUIT)
      case '5':
        return '\x1d'; // Ctrl+] -> GS
      case '6':
      case '~':
        return '\x1e'; // Ctrl+^ / Ctrl+~ -> RS
      case '7':
      case '/':
      case '-':
        return '\x1f'; // Ctrl+/ / Ctrl+- / Ctrl+_ -> US (Undo)
      case '8':
      case '?':
        return '\x7f'; // Ctrl+? / Ctrl+8 -> DEL
      default:
        return ch;
    }
  }
}

/// 手机端 (iOS / Android) Termius 极简风格单行虚拟扩展键盘栏 + CTRL 展开组合键 + 本地草稿箱
class MobileAccessoryKeyboardBar extends StatefulWidget {
  final void Function(String rawSequence) onSendRaw;
  final VoidCallback? onOpenSnippets;
  final VoidCallback? onOpenSftp;
  final VoidCallback? onOpenMonitor;
  final VoidCallback? onOpenBeautifier;
  final VoidCallback? onToggleBeautifierMode;
  final int beautifierCardCount;
  final bool beautifierShowingCard;
  final VoidCallback? onOpenPortForward;
  final VoidCallback? onReconnect;
  final bool isDisconnected;
  final bool includeBottomSafeArea;
  final VirtualModifierController? modifierController;
  final VoidCallback? onRequestTerminalFocus;

  const MobileAccessoryKeyboardBar({
    super.key,
    required this.onSendRaw,
    this.onOpenSnippets,
    this.onOpenSftp,
    this.onOpenMonitor,
    this.onOpenBeautifier,
    this.onToggleBeautifierMode,
    this.beautifierCardCount = 0,
    this.beautifierShowingCard = false,
    this.onOpenPortForward,
    this.onReconnect,
    this.isDisconnected = false,
    this.includeBottomSafeArea = true,
    this.modifierController,
    this.onRequestTerminalFocus,
  });

  @override
  State<MobileAccessoryKeyboardBar> createState() =>
      _MobileAccessoryKeyboardBarState();
}

class _MobileAccessoryKeyboardBarState
    extends State<MobileAccessoryKeyboardBar> {
  VirtualModifierController? _internalModCtrl;
  bool _composerVisible = false;
  final TextEditingController _composerCtrl = TextEditingController();

  static const List<(String key, String hint)> _ctrlQuickCombos = [
    ('C', '中断'),
    ('D', '退出'),
    ('Z', '挂起'),
    ('A', '行首'),
    ('E', '行尾'),
    ('U', '清行'),
    ('K', '删尾'),
    ('W', '删词'),
    ('R', '搜索'),
    ('L', '清屏'),
    ('X', '退出Nano'),
    ('O', '保存'),
    ('B', '前翻'),
    ('F', '后翻'),
    ('G', '取消'),
    ('N', '下行'),
    ('P', '上行'),
    ('H', '退格'),
    ('T', '交换'),
    ('Y', '粘贴'),
    ('V', '逐字'),
    ('Q', '恢复'),
    ('S', '暂停'),
    ('\\', '退出信号'),
    (']', 'Telnet'),
    ('_', '撤销'),
  ];

  VirtualModifierController get _mod =>
      widget.modifierController ??
      (_internalModCtrl ??= VirtualModifierController());

  @override
  void initState() {
    super.initState();
    _mod.addListener(_onModifierChanged);
  }

  @override
  void didUpdateWidget(covariant MobileAccessoryKeyboardBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.modifierController != widget.modifierController) {
      (oldWidget.modifierController ?? _internalModCtrl)
          ?.removeListener(_onModifierChanged);
      _mod.addListener(_onModifierChanged);
    }
  }

  @override
  void dispose() {
    _mod.removeListener(_onModifierChanged);
    _internalModCtrl?.dispose();
    _composerCtrl.dispose();
    super.dispose();
  }

  void _onModifierChanged() {
    if (mounted) setState(() {});
  }

  void _triggerKey(String label, String sequence) {
    HapticFeedback.lightImpact();
    final out = _mod.applyAndConsume(sequence);
    widget.onSendRaw(out);
    widget.onRequestTerminalFocus?.call();
  }

  void _triggerCtrlCombo(String keyChar) {
    HapticFeedback.lightImpact();
    final seq = VirtualModifierController.transformSequence(
      keyChar,
      ctrl: true,
      alt: _mod.isAltActive,
    );
    _mod.consumeOneShot();
    widget.onSendRaw(seq);
    widget.onRequestTerminalFocus?.call();
  }

  @override
  Widget build(BuildContext context) {
    final ctrlActive = _mod.isCtrlActive;
    final ctrlLocked = _mod.ctrlLocked;
    final altActive = _mod.isAltActive;
    final altLocked = _mod.altLocked;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF11131A).withValues(alpha: 0.94),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: SafeArea(
        top: false,
        bottom: widget.includeBottomSafeArea,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 可选展开：弱网防抖本地命令草稿箱 (Command Composer)
            if (_composerVisible)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                color: const Color(0xFF1A1D29),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _composerCtrl,
                        autofocus: true,
                        style: const TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 13,
                        ),
                        decoration: const InputDecoration(
                          hintText: '在本地编辑完整命令后一键下发...',
                          isDense: true,
                          border: InputBorder.none,
                        ),
                        onSubmitted: (val) {
                          if (val.trim().isNotEmpty) {
                            widget.onSendRaw('$val\r');
                            _composerCtrl.clear();
                          }
                        },
                      ),
                    ),
                    FilledButton.icon(
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                      ),
                      onPressed: () {
                        final text = _composerCtrl.text.trim();
                        if (text.isNotEmpty) {
                          widget.onSendRaw('$text\r');
                          _composerCtrl.clear();
                        }
                      },
                      icon: const Icon(Icons.send_rounded, size: 14),
                      label: const Text('发送', style: TextStyle(fontSize: 11)),
                    ),
                  ],
                ),
              ),

            // 当 CTRL 激活时，自动展开高频 CTRL+字母 组合键栏
            if (ctrlActive)
              Container(
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF171A26),
                  border: Border(
                    bottom: BorderSide(
                      color: const Color(0xFFBB9AF7).withValues(alpha: 0.22),
                    ),
                  ),
                ),
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  children: [
                    Container(
                      margin: const EdgeInsets.only(right: 6),
                      padding: const EdgeInsets.symmetric(horizontal: 7),
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: const Color(0xFFBB9AF7).withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        ctrlLocked ? 'CTRL🔒 已锁定' : 'CTRL 组合键',
                        style: const TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFBB9AF7),
                        ),
                      ),
                    ),
                    for (final (k, hint) in _ctrlQuickCombos)
                      _buildCtrlComboButton(k, hint),
                  ],
                ),
              ),

            // Termius 极简风格：仅保留单行核心终端按键栏（各类功能面板交由底部 iOS 液态玻璃菜单切换）
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 4,
                ),
                children: [
                  if (widget.onReconnect != null && widget.isDisconnected)
                    _buildActionChip(
                      icon: Icons.refresh_rounded,
                      label: '重新连接',
                      active: true,
                      onTap: widget.onReconnect!,
                    ),
                  _buildKeyButton('ESC', '\x1b', isAccent: true),
                  _buildKeyButton('TAB', '\t'),
                  _buildModifierButton(
                    key: const ValueKey('mobile_key_ctrl'),
                    label: ctrlLocked ? 'CTRL🔒' : 'CTRL',
                    active: ctrlActive,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _mod.tapCtrl();
                      widget.onRequestTerminalFocus?.call();
                    },
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      _mod.toggleCtrlLock();
                      widget.onRequestTerminalFocus?.call();
                    },
                  ),
                  _buildModifierButton(
                    key: const ValueKey('mobile_key_alt'),
                    label: altLocked ? 'ALT🔒' : 'ALT',
                    active: altActive,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _mod.tapAlt();
                      widget.onRequestTerminalFocus?.call();
                    },
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      _mod.toggleAltLock();
                      widget.onRequestTerminalFocus?.call();
                    },
                  ),
                  _buildKeyButton('←', '\x1b[D', isArrow: true),
                  _buildKeyButton('↓', '\x1b[B', isArrow: true),
                  _buildKeyButton('↑', '\x1b[A', isArrow: true),
                  _buildKeyButton('→', '\x1b[C', isArrow: true),
                  _buildKeyButton('-', '-'),
                  _buildKeyButton('/', '/'),
                  _buildKeyButton('|', '|'),
                  _buildKeyButton('~', '~'),
                  _buildKeyButton('^C', '\x03', isDanger: true),
                  _buildKeyButton('ENTER', '\r', isAccent: true),
                  if (widget.beautifierCardCount > 0 &&
                      widget.onToggleBeautifierMode != null)
                    _buildActionChip(
                      icon: widget.beautifierShowingCard
                          ? Icons.terminal_rounded
                          : Icons.auto_awesome_outlined,
                      label: widget.beautifierShowingCard ? '原文' : '卡片',
                      active: widget.beautifierShowingCard,
                      onTap: widget.onToggleBeautifierMode!,
                    ),
                  _buildIconKeyButton(
                    tooltip: _composerVisible ? '收起草稿箱' : '命令草稿箱',
                    icon: Icons.edit_note_rounded,
                    active: _composerVisible,
                    onTap: () =>
                        setState(() => _composerVisible = !_composerVisible),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIconKeyButton({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: active
              ? const Color(0xFF7AA2F7).withValues(alpha: 0.24)
              : const Color(0xFF1D2030),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
            child: Container(
              width: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: active
                      ? const Color(0xFF7AA2F7).withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: Icon(
                icon,
                size: 15,
                color: active ? const Color(0xFF7DCFFF) : Colors.white70,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCtrlComboButton(String keyChar, String hint) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Material(
        color: const Color(0xFF282D46),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: ValueKey('mobile_ctrl_combo_$keyChar'),
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(6),
          onTap: () => _triggerCtrlCombo(keyChar),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: const Color(0xFFBB9AF7).withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '^$keyChar',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Consolas',
                    color: Color(0xFFBB9AF7),
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  hint,
                  style: const TextStyle(
                    fontSize: 10,
                    color: Color(0xFFC0CAF5),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildKeyButton(
    String label,
    String sequence, {
    bool isAccent = false,
    bool isDanger = false,
    bool isArrow = false,
  }) {
    final bgColor = isDanger
        ? const Color(0xFFF7768E).withValues(alpha: 0.18)
        : isAccent
            ? const Color(0xFF7AA2F7).withValues(alpha: 0.22)
            : isArrow
                ? const Color(0xFF25293E)
                : const Color(0xFF1D2030);

    final textColor = isDanger
        ? const Color(0xFFF7768E)
        : isAccent
            ? const Color(0xFF7DCFFF)
            : Colors.white;

    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(6),
          onTap: () => _triggerKey(label, sequence),
          child: Container(
            constraints: const BoxConstraints(minWidth: 36),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                fontFamily: 'Consolas',
                color: textColor,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildModifierButton({
    Key? key,
    required String label,
    required bool active,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: Material(
        color: active ? const Color(0xFFBB9AF7) : const Color(0xFF1D2030),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: key,
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            constraints: const BoxConstraints(minWidth: 42),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: active
                    ? Colors.transparent
                    : Colors.white.withValues(alpha: 0.07),
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                color: active ? const Color(0xFF15161E) : Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildActionChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: InkWell(
        canRequestFocus: false,
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: active
                ? const Color(0xFF7AA2F7).withValues(alpha: 0.28)
                : const Color(0xFF24283B),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: const Color(0xFF7AA2F7).withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 13, color: const Color(0xFF7DCFFF)),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFC0CAF5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 手机模式底部 iOS 液态玻璃导航分区
enum MobileNavSection {
  terminal('终端', Icons.terminal_rounded),
  hosts('主机', Icons.dns_rounded),
  sftp('SFTP', Icons.folder_rounded),
  monitor('监控', Icons.monitor_heart_rounded),
  tools('工具', Icons.grid_view_rounded);

  final String label;
  final IconData icon;
  const MobileNavSection(this.label, this.icon);
}

/// iOS 原生液态玻璃 (Liquid Glass) 底部悬浮胶囊菜单栏
/// 采用实时高斯背景模糊 (BackdropFilter) + 顶部高光折射边缘 + 悬浮水滴透镜高亮胶囊，
/// 模仿 Termius + iOS 液态玻璃质感切换各个核心功能区。
class MobileLiquidGlassBottomBar extends StatelessWidget {
  final MobileNavSection currentSection;
  final ValueChanged<MobileNavSection> onSelectSection;
  final VoidCallback? onOpenVerticalTabs;
  final int openTabCount;
  final Color accentColor;

  const MobileLiquidGlassBottomBar({
    super.key,
    required this.currentSection,
    required this.onSelectSection,
    this.onOpenVerticalTabs,
    this.openTabCount = 0,
    this.accentColor = const Color(0xFF7AA2F7),
  });

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Container(
      key: const ValueKey('mobile_liquid_glass_bottom_bar'),
      color: Colors.transparent,
      padding: EdgeInsets.fromLTRB(
        14,
        6,
        14,
        bottomInset > 0 ? bottomInset + 4 : 10,
      ),
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.48),
              blurRadius: 26,
              spreadRadius: -2,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: accentColor.withValues(alpha: 0.08),
              blurRadius: 18,
              spreadRadius: 0,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: CustomPaint(
              foregroundPainter: _LiquidGlassRimPainter(
                accentColor: accentColor,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withValues(alpha: 0.14),
                      const Color(0xFF1A1E2B).withValues(alpha: 0.76),
                      const Color(0xFF10131C).withValues(alpha: 0.84),
                    ],
                    stops: const [0.0, 0.35, 1.0],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 5,
                  ),
                  child: Row(
                    children: [
                      for (final section in MobileNavSection.values)
                        Expanded(
                          child: _buildGlassTabItem(section),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGlassTabItem(MobileNavSection section) {
    final selected = currentSection == section;
    final isTerminal = section == MobileNavSection.terminal;

    return GestureDetector(
      key: ValueKey('liquid_nav_${section.name}'),
      behavior: HitTestBehavior.opaque,
      onTap: () {
        HapticFeedback.selectionClick();
        if (isTerminal && selected && onOpenVerticalTabs != null) {
          onOpenVerticalTabs!();
        } else {
          onSelectSection(section);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: selected
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.24),
                    accentColor.withValues(alpha: 0.22),
                    Colors.white.withValues(alpha: 0.08),
                  ],
                )
              : null,
          border: selected
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.32),
                  width: 0.9,
                )
              : null,
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.22),
                    blurRadius: 12,
                    spreadRadius: -2,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  section.icon,
                  size: 19,
                  color: selected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.62),
                ),
                if (isTerminal && openTabCount > 0)
                  Positioned(
                    right: -9,
                    top: -4,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 4.5,
                        vertical: 0.5,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? accentColor
                            : const Color(0xFF2B3147),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.28),
                          width: 0.7,
                        ),
                      ),
                      child: Text(
                        '$openTabCount',
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w700,
                          color: selected
                              ? const Color(0xFF0E1017)
                              : Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              section.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: 0.1,
                color: selected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.64),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 绘制 iOS 原生液态玻璃胶囊边缘的顶部高光折射环 (Specular Rim Highlight)
class _LiquidGlassRimPainter extends CustomPainter {
  final Color accentColor;

  const _LiquidGlassRimPainter({required this.accentColor});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(0.5),
      const Radius.circular(999),
    );
    final rimPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: 0.42),
          Colors.white.withValues(alpha: 0.14),
          accentColor.withValues(alpha: 0.22),
          Colors.white.withValues(alpha: 0.24),
        ],
        stops: const [0.0, 0.35, 0.7, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, rimPaint);
  }

  @override
  bool shouldRepaint(covariant _LiquidGlassRimPainter oldDelegate) =>
      oldDelegate.accentColor != accentColor;
}

/// 手机端垂直标签页条目视图模型
class MobileVerticalTabEntry {
  final String id;
  final String title;
  final String subtitle;
  final Widget statusBadge;
  final bool active;
  final bool isDisconnected;
  final int paneCount;
  final Color? customColor;
  final VoidCallback onSelect;
  final VoidCallback onReconnect;
  final VoidCallback onRename;
  final VoidCallback onClose;

  const MobileVerticalTabEntry({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.statusBadge,
    required this.active,
    required this.isDisconnected,
    this.paneCount = 1,
    this.customColor,
    required this.onSelect,
    required this.onReconnect,
    required this.onRename,
    required this.onClose,
  });
}

/// 手机端专属：垂直标签页抽屉/面板 (Vertical Tabs Sheet)
/// 解决手机窄屏下水平标签栏拥挤难按的痛点，以全宽垂直卡片列表清晰呈现所有打开的终端会话。
class MobileVerticalTabsSheet extends StatelessWidget {
  final List<MobileVerticalTabEntry> entries;
  final VoidCallback onNewSession;
  final VoidCallback onBrowseHosts;
  final void Function(int oldIndex, int newIndex)? onReorder;
  final Color accentColor;

  const MobileVerticalTabsSheet({
    super.key,
    required this.entries,
    required this.onNewSession,
    required this.onBrowseHosts,
    this.onReorder,
    this.accentColor = const Color(0xFF7AA2F7),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('mobile_vertical_tabs_sheet'),
      decoration: BoxDecoration(
        color: const Color(0xFF131620),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 38,
              height: 4,
              margin: const EdgeInsets.only(top: 10, bottom: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.24),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 12, 10),
              child: Row(
                children: [
                  Icon(Icons.layers_rounded, size: 18, color: accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '垂直会话标签 (${entries.length})',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: onBrowseHosts,
                    icon: const Icon(Icons.dns_outlined, size: 15),
                    label: const Text('主机列表', style: TextStyle(fontSize: 12)),
                  ),
                  const SizedBox(width: 4),
                  FilledButton.icon(
                    key: const ValueKey('vertical_tabs_new_btn'),
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: onNewSession,
                    icon: const Icon(Icons.add_rounded, size: 15),
                    label: const Text('新建', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0x1FFFFFFF)),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 36,
                  horizontal: 24,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.terminal_rounded,
                      size: 32,
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      '暂无活动终端会话',
                      style: TextStyle(fontSize: 13, color: Colors.white70),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: ReorderableListView.builder(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
                  itemCount: entries.length,
                  onReorder: onReorder ?? (_, _) {},
                  itemBuilder: (context, index) {
                    final item = entries[index];
                    final indicatorColor = item.customColor ?? accentColor;
                    return Padding(
                      key: ValueKey('vertical_tab_${item.id}'),
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Material(
                        color: item.active
                            ? indicatorColor.withValues(alpha: 0.16)
                            : const Color(0xFF1B1F2E),
                        borderRadius: BorderRadius.circular(12),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: item.onSelect,
                          child: Container(
                            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: item.active
                                    ? indicatorColor.withValues(alpha: 0.65)
                                    : Colors.white.withValues(alpha: 0.08),
                                width: item.active ? 1.3 : 1.0,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 4,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: item.active
                                        ? indicatorColor
                                        : Colors.white.withValues(alpha: 0.14),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                item.statusBadge,
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              item.title,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 13.5,
                                                fontWeight: item.active
                                                    ? FontWeight.w700
                                                    : FontWeight.w500,
                                                color: Colors.white,
                                              ),
                                            ),
                                          ),
                                          if (item.paneCount > 1)
                                            Container(
                                              margin: const EdgeInsets.only(
                                                left: 6,
                                              ),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 5,
                                                    vertical: 1,
                                                  ),
                                              decoration: BoxDecoration(
                                                color: Colors.white.withValues(
                                                  alpha: 0.1,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: Text(
                                                '${item.paneCount}分屏',
                                                style: const TextStyle(
                                                  fontSize: 10,
                                                  color: Colors.white70,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        item.subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontFamily: 'Consolas',
                                          color: item.isDisconnected
                                              ? const Color(0xFFF7768E)
                                              : Colors.white54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  tooltip: '重新连接',
                                  visualDensity: VisualDensity.compact,
                                  icon: Icon(
                                    Icons.refresh_rounded,
                                    size: 18,
                                    color: item.isDisconnected
                                        ? accentColor
                                        : Colors.white60,
                                  ),
                                  onPressed: item.onReconnect,
                                ),
                                IconButton(
                                  tooltip: '重命名标签',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 17,
                                    color: Colors.white60,
                                  ),
                                  onPressed: item.onRename,
                                ),
                                IconButton(
                                  tooltip: '关闭此会话',
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: Color(0xFFF7768E),
                                  ),
                                  onPressed: item.onClose,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }
}
