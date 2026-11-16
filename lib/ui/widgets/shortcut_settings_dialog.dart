import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/shortcut_settings.dart';
import '../../core/theme/ui_tokens.dart';

Future<void> showShortcutSettingsDialog({
  required BuildContext context,
  required ShortcutConfig initialConfig,
  required ValueChanged<ShortcutConfig> onChanged,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _ShortcutSettingsDialog(
      initialConfig: initialConfig,
      onChanged: onChanged,
    ),
  );
}

class _ShortcutSettingsDialog extends StatefulWidget {
  const _ShortcutSettingsDialog({
    required this.initialConfig,
    required this.onChanged,
  });

  final ShortcutConfig initialConfig;
  final ValueChanged<ShortcutConfig> onChanged;

  @override
  State<_ShortcutSettingsDialog> createState() =>
      _ShortcutSettingsDialogState();
}

class _ShortcutSettingsDialogState extends State<_ShortcutSettingsDialog> {
  late ShortcutConfig _config = widget.initialConfig;
  ShortcutAction? _recordingAction;
  final FocusNode _captureFocus = FocusNode();

  @override
  void dispose() {
    _captureFocus.dispose();
    super.dispose();
  }

  void _applyConfig(ShortcutConfig next) {
    setState(() => _config = next);
    widget.onChanged(next);
  }

  KeyEventResult _handleKeyCapture(FocusNode node, KeyEvent event) {
    final targetAction = _recordingAction;
    if (targetAction == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;

    if (event.logicalKey == LogicalKeyboardKey.escape &&
        !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      setState(() => _recordingAction = null);
      return KeyEventResult.handled;
    }

    if (KeyChord.isModifierOnly(event.logicalKey)) {
      return KeyEventResult.handled;
    }

    final kb = HardwareKeyboard.instance;
    final ctrl = kb.isControlPressed || kb.isMetaPressed;
    final shift = kb.isShiftPressed;
    final alt = kb.isAltPressed;

    // 防止普通单字母无修饰键误绑成全局快捷键（允许 F1-F12 功能键无修饰）
    final isFnKey = event.logicalKey.keyLabel.startsWith('F') &&
        event.logicalKey.keyLabel.length <= 3;
    if (!ctrl && !alt && !isFnKey) {
      return KeyEventResult.handled;
    }

    final newChord = KeyChord.fromLogical(
      event.logicalKey,
      ctrl: ctrl,
      shift: shift,
      alt: alt,
    );
    final updatedBindings = Map<ShortcutAction, KeyChord>.of(_config.bindings);
    updatedBindings[targetAction] = newChord;

    setState(() => _recordingAction = null);
    _applyConfig(_config.copyWith(bindings: updatedBindings));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final categories = <String, List<ShortcutAction>>{};
    for (final a in ShortcutAction.values) {
      categories.putIfAbsent(a.category, () => []).add(a);
    }

    return Focus(
      focusNode: _captureFocus,
      autofocus: true,
      onKeyEvent: _handleKeyCapture,
      child: AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
        contentPadding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        actionsPadding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: TxColors.accentSoft,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(
                  color: TxColors.accent.withValues(alpha: 0.45),
                ),
              ),
              child: const Icon(
                Icons.keyboard_alt_outlined,
                size: 18,
                color: TxColors.accent,
              ),
            ),
            const SizedBox(width: 10),
            const Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '终端快捷键',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: TxColors.textPrimary,
                    ),
                  ),
                  SizedBox(height: 2),
                  Text(
                    '支持自定义组合键与按键习惯，默认按下 Ctrl+A 光标定位到命令行开头',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                      color: TxColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: () {
                setState(() => _recordingAction = null);
                _applyConfig(ShortcutConfig.defaults());
              },
              icon: const Icon(Icons.restart_alt_rounded, size: 16),
              label: const Text('恢复默认', style: TextStyle(fontSize: 12.5)),
            ),
          ],
        ),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 660,
            maxHeight: (MediaQuery.sizeOf(context).height * 0.72).clamp(
              260.0,
              560.0,
            ),
          ),
          child: SizedBox(
            width: 660,
            child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSectionHeader('终端命令行按键习惯（Shell / Emacs 兼容）'),
                const SizedBox(height: 8),
                _buildCtrlASelector(),
                const SizedBox(height: 8),
                _buildToggleTile(
                  title: '本机 PowerShell 支持 Ctrl+E 光标移至行尾',
                  subtitle: '与 Ctrl+A 行首配对使用（在 SSH Linux/macOS 下本身原生支持 ^E 行尾）',
                  value: _config.powershellCtrlELineEnd,
                  onChanged: (v) =>
                      _applyConfig(_config.copyWith(powershellCtrlELineEnd: v)),
                ),
                const SizedBox(height: 6),
                _buildToggleTile(
                  title: '智能 Ctrl+C：有鼠标选中文本时复制，无选中时发送中断 (^C)',
                  subtitle: '复制后自动取消选区，再次按 Ctrl+C 即可立即中断正在运行的终端程序',
                  value: _config.smartCtrlCCopy,
                  onChanged: (v) =>
                      _applyConfig(_config.copyWith(smartCtrlCCopy: v)),
                ),
                const SizedBox(height: 6),
                _buildToggleTile(
                  title: '智能 Ctrl+V 粘贴剪贴板',
                  subtitle: '普通命令行下 Ctrl+V 直接粘贴；进入 Vim 等全屏交替缓冲区时自动透传 ^V',
                  value: _config.ctrlVPaste,
                  onChanged: (v) =>
                      _applyConfig(_config.copyWith(ctrlVPaste: v)),
                ),
                const SizedBox(height: 16),
                for (final catEntry in categories.entries) ...[
                  _buildSectionHeader('${catEntry.key}（点击右侧键帽录制新快捷键）'),
                  const SizedBox(height: 8),
                  Container(
                    decoration: BoxDecoration(
                      color: TxColors.bgPanel,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: TxColors.borderSubtle),
                    ),
                    child: Column(
                      children: [
                        for (var i = 0; i < catEntry.value.length; i++) ...[
                          if (i > 0)
                            const Divider(
                              height: 1,
                              color: TxColors.borderSubtle,
                            ),
                          _buildShortcutRow(catEntry.value[i]),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
              ],
            ),
          ),
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        color: TxColors.textSecondary,
      ),
    );
  }

  Widget _buildCtrlASelector() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TxColors.bgPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TxColors.borderDefault),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.first_page_rounded, size: 17, color: TxColors.accent),
              SizedBox(width: 6),
              Text(
                '按下 Ctrl+A 时的动作',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TxColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          for (final mode in CtrlABehavior.values)
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _applyConfig(_config.copyWith(ctrlABehavior: mode)),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _config.ctrlABehavior == mode
                        ? TxColors.bgSelected
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _config.ctrlABehavior == mode
                          ? TxColors.accent.withValues(alpha: 0.65)
                          : TxColors.borderSubtle,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        _config.ctrlABehavior == mode
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_off_rounded,
                        size: 16,
                        color: _config.ctrlABehavior == mode
                            ? TxColors.accent
                            : TxColors.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              mode.title,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: _config.ctrlABehavior == mode
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: TxColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              mode.subtitle,
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
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildToggleTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: TxColors.bgPanel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: TxColors.borderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: TxColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: TxColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _buildShortcutRow(ShortcutAction action) {
    final chord = _config.chordFor(action);
    final isRecording = _recordingAction == action;

    // 检测是否与其他动作存在相同按键冲突
    ShortcutAction? conflict;
    for (final other in ShortcutAction.values) {
      if (other != action && _config.chordFor(other) == chord) {
        conflict = other;
        break;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    action.label,
                    style: const TextStyle(
                      fontSize: 13,
                      color: TxColors.textPrimary,
                    ),
                  ),
                ),
                if (conflict != null) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: TxColors.warning.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '与「${conflict.label}」冲突',
                      style: const TextStyle(
                        fontSize: 11,
                        color: TxColors.warning,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: () {
              setState(() {
                _recordingAction = isRecording ? null : action;
              });
              _captureFocus.requestFocus();
            },
            child: Container(
              constraints: const BoxConstraints(minWidth: 128),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: isRecording ? TxColors.accentSoft : TxColors.bgElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isRecording ? TxColors.accent : TxColors.borderDefault,
                  width: isRecording ? 1.4 : 1.0,
                ),
              ),
              child: Text(
                isRecording ? '请按下组合键… (Esc取消)' : chord.displayLabel,
                style: TextStyle(
                  fontSize: 12.5,
                  fontFamily: TxColors.monoFamily,
                  fontWeight: FontWeight.w600,
                  color: isRecording ? TxColors.accent : TxColors.textPrimary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
