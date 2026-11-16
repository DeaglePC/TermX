import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/ui_tokens.dart';
import '../mobile/mobile_accessory_keyboard.dart';

/// iPadOS 专属：双手握持分体式拇指悬浮快捷键面板 (Floating Ergonomic Thumb Pads)
/// 解决 iPad 大屏宽度下双手握持时拇指无法触及屏幕中央按键的痛点，支持自由拖拽位置。
class IpadFloatingThumbPads extends StatefulWidget {
  final void Function(String rawSequence) onSendRaw;
  final VirtualModifierController? modifierController;
  final VoidCallback? onRequestTerminalFocus;

  const IpadFloatingThumbPads({
    super.key,
    required this.onSendRaw,
    this.modifierController,
    this.onRequestTerminalFocus,
  });

  @override
  State<IpadFloatingThumbPads> createState() => _IpadFloatingThumbPadsState();
}

class _IpadFloatingThumbPadsState extends State<IpadFloatingThumbPads> {
  Offset _leftOffset = const Offset(16, 180);
  Offset _rightOffset = const Offset(16, 180);
  VirtualModifierController? _internalModCtrl;

  static const List<String> _ipadCtrlQuickKeys = [
    'C',
    'D',
    'Z',
    'A',
    'E',
    'U',
    'K',
    'W',
    'R',
    'L',
    'X',
    'O',
  ];

  VirtualModifierController get _mod =>
      widget.modifierController ?? (_internalModCtrl ??= VirtualModifierController());

  @override
  void initState() {
    super.initState();
    _mod.addListener(_onModifierChanged);
  }

  @override
  void didUpdateWidget(covariant IpadFloatingThumbPads oldWidget) {
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
    super.dispose();
  }

  void _onModifierChanged() {
    if (mounted) setState(() {});
  }

  void _send(String seq) {
    HapticFeedback.lightImpact();
    final out = _mod.applyAndConsume(seq);
    widget.onSendRaw(out);
    widget.onRequestTerminalFocus?.call();
  }

  void _sendCtrlCombo(String keyChar) {
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

    return Stack(
      children: [
        // 左手拇指扇区：ESC / TAB / CTRL / ^C / 管道符 + CTRL 展开组合键
        Positioned(
          left: _leftOffset.dx,
          bottom: _leftOffset.dy,
          child: GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _leftOffset = Offset(
                  (_leftOffset.dx + details.delta.dx).clamp(8.0, 260.0),
                  (_leftOffset.dy - details.delta.dy).clamp(24.0, 420.0),
                );
              });
            },
            child: _buildPadContainer(
              title: '左手拇指区 (可拖拽)',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      _padBtn('ESC', () => _send('\x1b'), accent: true),
                      _padBtn('TAB', () => _send('\t')),
                      _padBtn(
                        ctrlLocked ? 'CTRL🔒' : 'CTRL',
                        () {
                          _mod.tapCtrl();
                          widget.onRequestTerminalFocus?.call();
                        },
                        active: ctrlActive,
                      ),
                      _padBtn('^C', () => _send('\x03'), danger: true),
                      _padBtn('|', () => _send('|')),
                      _padBtn('/', () => _send('/')),
                    ],
                  ),
                  if (ctrlActive) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final k in _ipadCtrlQuickKeys)
                          _padBtn(
                            '^$k',
                            () => _sendCtrlCombo(k),
                            accent: true,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),

        // 右手拇指扇区：五向方向键十字盘 + ENTER
        Positioned(
          right: _rightOffset.dx,
          bottom: _rightOffset.dy,
          child: GestureDetector(
            onPanUpdate: (details) {
              setState(() {
                _rightOffset = Offset(
                  (_rightOffset.dx - details.delta.dx).clamp(8.0, 260.0),
                  (_rightOffset.dy - details.delta.dy).clamp(24.0, 420.0),
                );
              });
            },
            child: _buildPadContainer(
              title: '右手方向区 (可拖拽)',
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _padBtn('~', () => _send('~')),
                      const SizedBox(width: 6),
                      _padBtn('↑', () => _send('\x1b[A'), accent: true),
                      const SizedBox(width: 6),
                      _padBtn('-', () => _send('-')),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _padBtn('←', () => _send('\x1b[D'), accent: true),
                      const SizedBox(width: 6),
                      _padBtn('↓', () => _send('\x1b[B'), accent: true),
                      const SizedBox(width: 6),
                      _padBtn('→', () => _send('\x1b[C'), accent: true),
                    ],
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 132,
                    child: _padBtn('ENTER ⏎', () => _send('\r'), accent: true),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPadContainer({required String title, required Widget child}) {
    return Container(
      width: 152,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF16161E).withValues(alpha: 0.88),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFF7AA2F7).withValues(alpha: 0.35),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.drag_handle_rounded,
                size: 12,
                color: Colors.white54,
              ),
              const SizedBox(width: 4),
              Text(
                title,
                style: const TextStyle(fontSize: 9.5, color: Colors.white54),
              ),
            ],
          ),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }

  Widget _padBtn(
    String label,
    VoidCallback onTap, {
    bool accent = false,
    bool active = false,
    bool danger = false,
  }) {
    final bg = active
        ? const Color(0xFFBB9AF7)
        : danger
        ? const Color(0xFFF7768E).withValues(alpha: 0.2)
        : accent
        ? const Color(0xFF7AA2F7).withValues(alpha: 0.22)
        : const Color(0xFF24283B);

    final fg = active
        ? const Color(0xFF15161E)
        : danger
        ? const Color(0xFFF7768E)
        : Colors.white;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minWidth: 40, minHeight: 34),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.bold,
                fontFamily: 'Consolas',
                color: fg,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// iPadOS 妙控键盘 (Magic Keyboard) 专属底部胶囊工具栏
class IpadMagicKeyboardCapsuleBar extends StatelessWidget {
  final bool floatingThumbPadsVisible;
  final ValueChanged<bool> onToggleThumbPads;
  final bool capsLockRemappedToEsc;
  final ValueChanged<bool> onToggleCapsLockRemap;
  final VoidCallback onShowShortcutCheatSheet;
  final VoidCallback onSplitTerminal;
  final bool isSplitTerminal;

  const IpadMagicKeyboardCapsuleBar({
    super.key,
    required this.floatingThumbPadsVisible,
    required this.onToggleThumbPads,
    required this.capsLockRemappedToEsc,
    required this.onToggleCapsLockRemap,
    required this.onShowShortcutCheatSheet,
    required this.onSplitTerminal,
    required this.isSplitTerminal,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF16161E),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF7AA2F7).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.tablet_mac_rounded,
                    size: 13,
                    color: Color(0xFF7DCFFF),
                  ),
                  SizedBox(width: 5),
                  Text(
                    'iPadOS Stage Manager / Split View 已适配',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF7DCFFF),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            FilterChip(
              visualDensity: VisualDensity.compact,
              selected: floatingThumbPadsVisible,
              onSelected: onToggleThumbPads,
              avatar: const Icon(Icons.touch_app_outlined, size: 14),
              label: const Text('双手拇指悬浮键盘球', style: TextStyle(fontSize: 11)),
            ),
            const SizedBox(width: 8),
            FilterChip(
              visualDensity: VisualDensity.compact,
              selected: capsLockRemappedToEsc,
              onSelected: onToggleCapsLockRemap,
              avatar: const Icon(Icons.keyboard_command_key_rounded, size: 14),
              label: const Text(
                'CapsLock 映射为 ESC (Vim模式)',
                style: TextStyle(fontSize: 11),
              ),
            ),
            const SizedBox(width: 8),
            FilterChip(
              visualDensity: VisualDensity.compact,
              selected: isSplitTerminal,
              onSelected: (_) => onSplitTerminal(),
              avatar: const Icon(Icons.vertical_split_rounded, size: 14),
              label: const Text('向右分屏 (⌘+⇧+D)', style: TextStyle(fontSize: 11)),
            ),
            const SizedBox(width: 12),
            TextButton.icon(
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              onPressed: onShowShortcutCheatSheet,
              icon: const Icon(Icons.keyboard_alt_outlined, size: 15),
              label: const Text(
                '妙控键盘 ⌘ 快捷键表',
                style: TextStyle(fontSize: 11.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 呼出 iPadOS 原生风格长按 Command ⌘ 键快捷键速查浮层
void showIpadShortcutCheatSheet(BuildContext context) {
  final shortcuts = [
    ('Ctrl/⌘ + ⇧ + T', '新建本地终端标签'),
    ('Ctrl/⌘ + ⇧ + W', '关闭当前窗格'),
    ('Ctrl/⌘ + ⇧ + D', '向右分屏（独立会话）'),
    ('Ctrl/⌘ + ⇧ + E', '向下分屏（独立会话）'),
    ('Ctrl/⌘ + Tab / ⇧ + Tab', '切换标签'),
    ('Ctrl/⌘ + ⇧ + C / V', '复制 / 粘贴'),
    ('Ctrl/⌘ + ⇧ + A', '全选终端输出'),
    ('Ctrl/⌘ + ⇧ + F', '查找终端输出'),
    ('Ctrl/⌘ + ⇧ + K', '清屏'),
    ('Ctrl/⌘ + + / - / 0', '放大 / 缩小 / 重置字号'),
    ('Alt + Enter', '最大化 / 还原当前窗格'),
    ('Ctrl/⌘ + ⇧ + M', '展开/收起服务器监控面板'),
    ('Ctrl/⌘ + Alt + F', '展开/收起 SFTP 面板'),
  ];

  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Row(
        children: [
          Icon(
            Icons.keyboard_outlined,
            size: 18,
            color: TxColors.textSecondary,
          ),
          SizedBox(width: 8),
          Text(
            '终端快捷键',
            style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: shortcuts.map((item) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: TxColors.bgChrome,
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: TxColors.borderDefault),
                      ),
                      child: Text(
                        item.$1,
                        style: const TextStyle(
                          fontFamily: TxColors.monoFamily,
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: TxColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        item.$2,
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: TxColors.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
