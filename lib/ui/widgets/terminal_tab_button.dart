import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/theme/ui_tokens.dart';

/// 顶部终端标签预设色彩表
class TabColorPreset {
  final String name;
  final Color color;

  const TabColorPreset(this.name, this.color);

  static const List<TabColorPreset> presets = [
    TabColorPreset('珊瑚红', Color(0xFFF7768E)),
    TabColorPreset('琥珀橙', Color(0xFFE59256)),
    TabColorPreset('流金黄', Color(0xFFD9A557)),
    TabColorPreset('翡翠绿', Color(0xFF56C271)),
    TabColorPreset('薄荷青', Color(0xFF4AB8C4)),
    TabColorPreset('天际蓝', Color(0xFF58A6FF)),
    TabColorPreset('皇家蓝', Color(0xFF4C8DFF)),
    TabColorPreset('极光紫', Color(0xFFA78BFA)),
    TabColorPreset('樱花粉', Color(0xFFEC7FA9)),
  ];
}

/// Immediate pointer-down activation bypasses the double-tap recognition timeout.
/// The close button and drag handle live outside the activation region.
class TerminalTabButton extends StatefulWidget {
  const TerminalTabButton({
    super.key,
    required this.active,
    required this.accent,
    required this.title,
    required this.status,
    required this.dragHandle,
    required this.onActivate,
    required this.onClose,
    required this.onRename,
    required this.onMenu,
    this.customColor,
    this.paneCount = 1,
    this.insertionEdge,
  });

  final bool active;
  final Color accent;
  final Color? customColor;
  final String title;
  final Widget status, dragHandle;
  final int paneCount;
  final AxisDirection? insertionEdge;
  final VoidCallback onActivate, onClose, onRename;
  final ValueChanged<Offset> onMenu;

  @override
  State<TerminalTabButton> createState() => _TerminalTabButtonState();
}

class _TerminalTabButtonState extends State<TerminalTabButton> {
  bool _hovered = false;
  bool _closeHovered = false;

  @override
  Widget build(BuildContext context) {
    final custom = widget.customColor;
    final hasCustom = custom != null;
    final active = widget.active;

    final Color bgColor;
    if (hasCustom) {
      bgColor = Color.lerp(
        active ? TxColors.bgElevated : TxColors.bgSidebar,
        custom,
        active ? 0.18 : (_hovered ? 0.12 : 0.07),
      )!;
    } else if (active) {
      bgColor = TxColors.bgElevated;
    } else if (_hovered) {
      bgColor = const Color(0xFF15181F);
    } else {
      bgColor = Colors.transparent;
    }

    final Color borderColor;
    if (hasCustom) {
      borderColor = custom.withValues(alpha: active ? 0.55 : 0.24);
    } else if (active) {
      borderColor = TxColors.borderDefault;
    } else if (_hovered) {
      borderColor = TxColors.borderSubtle;
    } else {
      borderColor = Colors.transparent;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerDown: (event) {
          if (event.buttons == kMiddleMouseButton) widget.onClose();
        },
        child: GestureDetector(
          onSecondaryTapUp: (details) => widget.onMenu(details.globalPosition),
          child: GestureDetector(
            supportedDevices: const {
              PointerDeviceKind.touch,
              PointerDeviceKind.stylus,
              PointerDeviceKind.invertedStylus,
            },
            onLongPressStart: (details) =>
                widget.onMenu(details.globalPosition),
            child: Container(
              decoration: BoxDecoration(
                color: bgColor,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: borderColor),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    if (hasCustom)
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          height: 2,
                          color: custom.withValues(alpha: active ? 0.95 : 0.65),
                        ),
                      ),
                    if (widget.insertionEdge == AxisDirection.left)
                      const Positioned(
                        left: 0,
                        top: 3,
                        bottom: 3,
                        child: SizedBox(
                          width: 2,
                          child: ColoredBox(color: TxColors.accent),
                        ),
                      ),
                    if (widget.insertionEdge == AxisDirection.right)
                      const Positioned(
                        right: 0,
                        top: 3,
                        bottom: 3,
                        child: SizedBox(
                          width: 2,
                          child: ColoredBox(color: TxColors.accent),
                        ),
                      ),
                  Padding(
                    padding: const EdgeInsets.only(left: 8, right: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Opacity(
                          opacity: (active || _hovered) ? 0.80 : 0.32,
                          child: widget.dragHandle,
                        ),
                        Listener(
                          onPointerDown: (event) {
                            if (event.buttons == kPrimaryMouseButton) {
                              widget.onActivate();
                            }
                          },
                          child: GestureDetector(
                            onDoubleTap: widget.onRename,
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 6,
                                horizontal: 4,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  widget.status,
                                  const SizedBox(width: 7),
                                  ConstrainedBox(
                                    constraints: const BoxConstraints(
                                      maxWidth: 176,
                                    ),
                                    child: Text(
                                      widget.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: active
                                            ? FontWeight.w600
                                            : FontWeight.w400,
                                        color: active
                                            ? TxColors.textPrimary
                                            : (_hovered
                                                  ? const Color(0xFFC8CDD6)
                                                  : TxColors.textSecondary),
                                      ),
                                    ),
                                  ),
                                  if (widget.paneCount > 1)
                                    Container(
                                      margin: const EdgeInsets.only(left: 6),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 1,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.08,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        '${widget.paneCount}',
                                        style: const TextStyle(
                                          fontSize: 11,
                                          fontFamily: TxColors.monoFamily,
                                          color: TxColors.textSecondary,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        MouseRegion(
                          onEnter: (_) => setState(() => _closeHovered = true),
                          onExit: (_) => setState(() => _closeHovered = false),
                          child: Tooltip(
                            message: '关闭标签',
                            child: InkWell(
                              borderRadius: BorderRadius.circular(5),
                              onTap: widget.onClose,
                              child: Container(
                                padding: const EdgeInsets.all(4.5),
                                decoration: BoxDecoration(
                                  color: _closeHovered
                                      ? Colors.white.withValues(alpha: 0.12)
                                      : Colors.transparent,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                child: Icon(
                                  Icons.close,
                                  size: 15,
                                  color: _closeHovered
                                      ? TxColors.textPrimary
                                      : ((active || _hovered)
                                            ? TxColors.textSecondary
                                            : TxColors.textMuted),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }
}
