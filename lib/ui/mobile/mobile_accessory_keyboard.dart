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

/// 手机端 (iOS / Android) 专属虚拟扩展键盘栏 + CTRL/ALT 组合键快捷排 + 弱网本地草稿箱
class MobileAccessoryKeyboardBar extends StatefulWidget {
  final void Function(String rawSequence) onSendRaw;
  final VoidCallback onOpenSnippets;
  final VoidCallback onOpenSftp;
  final VoidCallback onOpenMonitor;
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
    required this.onOpenSnippets,
    required this.onOpenSftp,
    required this.onOpenMonitor,
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
      widget.modifierController ?? (_internalModCtrl ??= VirtualModifierController());

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
        color: const Color(0xFF13141C),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
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
                color: const Color(0xFF1F2335),
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
                          hintText: '在本地编辑完整命令后一键下发 (防弱网抖动)...',
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

            // 当 CTRL 激活时，自动展开高频 CTRL+字母 组合键栏（也可直接在系统软键盘输入字母触发）
            if (ctrlActive)
              Container(
                height: 38,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1D2B),
                  border: Border(
                    bottom: BorderSide(
                      color: const Color(0xFFBB9AF7).withValues(alpha: 0.25),
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

            // 第一层：核心控制键与方向键
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                children: [
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
                  _buildKeyButton('↑', '\x1b[A', isArrow: true),
                  _buildKeyButton('↓', '\x1b[B', isArrow: true),
                  _buildKeyButton('←', '\x1b[D', isArrow: true),
                  _buildKeyButton('→', '\x1b[C', isArrow: true),
                  _buildKeyButton('^C', '\x03', isDanger: true),
                  _buildKeyButton('^L', '\x0c'),
                  _buildKeyButton('ENTER', '\r', isAccent: true),
                ],
              ),
            ),

            // 第二层：高频管道符号 + 移动端一键插件抽屉入口
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                children: [
                  if (widget.onReconnect != null && widget.isDisconnected)
                    _buildActionChip(
                      icon: Icons.refresh_rounded,
                      label: '重新连接',
                      active: true,
                      onTap: widget.onReconnect!,
                    ),
                  _buildActionChip(
                    icon: Icons.edit_road_rounded,
                    label: _composerVisible ? '收起草稿' : '命令草稿箱',
                    active: _composerVisible,
                    onTap: () =>
                        setState(() => _composerVisible = !_composerVisible),
                  ),
                  if (widget.onOpenBeautifier != null)
                    _buildActionChip(
                      icon: Icons.auto_awesome_outlined,
                      label: widget.beautifierCardCount > 0
                          ? '输出美化 (${widget.beautifierCardCount})'
                          : '输出美化',
                      active: widget.beautifierShowingCard,
                      onTap: widget.onOpenBeautifier!,
                    ),
                  if (widget.beautifierCardCount > 0 &&
                      widget.onToggleBeautifierMode != null)
                    _buildActionChip(
                      icon: widget.beautifierShowingCard
                          ? Icons.terminal_rounded
                          : Icons.visibility_outlined,
                      label: widget.beautifierShowingCard ? '切原文' : '显卡片',
                      active: widget.beautifierShowingCard,
                      onTap: widget.onToggleBeautifierMode!,
                    ),
                  _buildActionChip(
                    icon: Icons.folder_open_rounded,
                    label: 'SFTP互传',
                    onTap: widget.onOpenSftp,
                  ),
                  _buildActionChip(
                    icon: Icons.monitor_heart_outlined,
                    label: '负载监控',
                    onTap: widget.onOpenMonitor,
                  ),
                  _buildActionChip(
                    icon: Icons.bolt_rounded,
                    label: '快捷片段',
                    onTap: widget.onOpenSnippets,
                  ),
                  if (widget.onOpenPortForward != null)
                    _buildActionChip(
                      icon: Icons.alt_route_rounded,
                      label: '端口隧道',
                      onTap: widget.onOpenPortForward!,
                    ),
                  if (widget.onReconnect != null && !widget.isDisconnected)
                    _buildActionChip(
                      icon: Icons.refresh_rounded,
                      label: '重连',
                      onTap: widget.onReconnect!,
                    ),
                  _buildKeyButton('|', '|'),
                  _buildKeyButton('/', '/'),
                  _buildKeyButton('-', '-'),
                  _buildKeyButton('~', '~'),
                  _buildKeyButton(':', ':'),
                  _buildKeyButton('"', '"'),
                  _buildKeyButton('HOME', '\x1b[H'),
                  _buildKeyButton('END', '\x1b[F'),
                ],
              ),
            ),
          ],
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
                ? const Color(0xFF282D46)
                : const Color(0xFF1F2335);

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
            constraints: const BoxConstraints(minWidth: 38),
            padding: const EdgeInsets.symmetric(horizontal: 9),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
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
        color: active ? const Color(0xFFBB9AF7) : const Color(0xFF1F2335),
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          key: key,
          canRequestFocus: false,
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          onLongPress: onLongPress,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44),
            padding: const EdgeInsets.symmetric(horizontal: 9),
            alignment: Alignment.center,
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
