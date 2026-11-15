import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 手机端 (iOS / Android) 专属双层虚拟扩展键盘栏 + 弱网本地草稿箱 (Command Composer)
class MobileAccessoryKeyboardBar extends StatefulWidget {
  final void Function(String rawSequence) onSendRaw;
  final VoidCallback onOpenSnippets;
  final VoidCallback onOpenSftp;
  final VoidCallback onOpenMonitor;

  const MobileAccessoryKeyboardBar({
    super.key,
    required this.onSendRaw,
    required this.onOpenSnippets,
    required this.onOpenSftp,
    required this.onOpenMonitor,
  });

  @override
  State<MobileAccessoryKeyboardBar> createState() =>
      _MobileAccessoryKeyboardBarState();
}

class _MobileAccessoryKeyboardBarState
    extends State<MobileAccessoryKeyboardBar> {
  bool _ctrlArmed = false;
  bool _ctrlLocked = false;
  bool _altArmed = false;
  bool _composerVisible = false;
  final TextEditingController _composerCtrl = TextEditingController();

  void _triggerKey(String label, String sequence) {
    HapticFeedback.lightImpact();
    if (_ctrlArmed || _ctrlLocked) {
      if (sequence.length == 1) {
        final code = sequence.toUpperCase().codeUnitAt(0);
        if (code >= 64 && code <= 95) {
          widget.onSendRaw(String.fromCharCode(code - 64));
        } else {
          widget.onSendRaw(sequence);
        }
      } else {
        widget.onSendRaw(sequence);
      }
      if (!_ctrlLocked) {
        setState(() => _ctrlArmed = false);
      }
      return;
    }

    if (_altArmed) {
      widget.onSendRaw('\x1b$sequence');
      setState(() => _altArmed = false);
      return;
    }

    widget.onSendRaw(sequence);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF13141C),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
      ),
      child: SafeArea(
        top: false,
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

            // 第一层：核心控制键与方向键
            SizedBox(
              height: 38,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                children: [
                  _buildKeyButton('ESC', '\x1b', isAccent: true),
                  _buildKeyButton('TAB', '\t'),
                  _buildModifierButton(
                    label: _ctrlLocked ? 'CTRL🔒' : 'CTRL',
                    active: _ctrlArmed || _ctrlLocked,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() {
                        if (_ctrlLocked) {
                          _ctrlLocked = false;
                          _ctrlArmed = false;
                        } else {
                          _ctrlArmed = !_ctrlArmed;
                        }
                      });
                    },
                    onDoubleTap: () {
                      HapticFeedback.mediumImpact();
                      setState(() {
                        _ctrlLocked = !_ctrlLocked;
                        _ctrlArmed = _ctrlLocked;
                      });
                    },
                  ),
                  _buildModifierButton(
                    label: 'ALT',
                    active: _altArmed,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      setState(() => _altArmed = !_altArmed);
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
              height: 36,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 4),
                children: [
                  _buildActionChip(
                    icon: Icons.edit_road_rounded,
                    label: _composerVisible ? '收起草稿' : '命令草稿箱',
                    active: _composerVisible,
                    onTap: () =>
                        setState(() => _composerVisible = !_composerVisible),
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
    required String label,
    required bool active,
    required VoidCallback onTap,
    VoidCallback? onDoubleTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 5),
      child: GestureDetector(
        onDoubleTap: onDoubleTap,
        child: Material(
          color: active
              ? const Color(0xFFBB9AF7)
              : const Color(0xFF1F2335),
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: onTap,
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
