import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../core/models/shortcut_settings.dart';
import '../../core/models/terminal_workspace.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../../core/theme/ui_tokens.dart';
import '../mobile/mobile_accessory_keyboard.dart';
import 'os_logo_icon.dart';

Color connectionColor(SessionConnectionState state) => switch (state) {
  SessionConnectionState.connected => TxColors.success,
  SessionConnectionState.connecting ||
  SessionConnectionState.reconnecting => TxColors.warning,
  SessionConnectionState.error => TxColors.danger,
  SessionConnectionState.disconnected => TxColors.textMuted,
};

class TerminalPaneView extends StatefulWidget {
  const TerminalPaneView({
    super.key,
    required this.pane,
    required this.title,
    required this.theme,
    required this.accent,
    required this.active,
    required this.maximized,
    required this.onActivate,
    required this.onSplit,
    required this.onClose,
    required this.onRestart,
    required this.onMaximize,
    required this.onWorkspaceKey,
    this.canAcceptDrop,
    this.onAcceptDrop,
    this.payloadLabelBuilder,
    this.headerDragPayload,
    this.headerDragTitle,
    this.terminalOverlay,
    this.onToggleBeautyCard,
    this.shortcutConfig,
    this.onOpenShortcutSettings,
    this.cursorType = TerminalCursorType.block,
    this.onCursorTypeChanged,
    this.onFontSizeChanged,
    this.virtualModifierController,
    this.hideHeaderBar = false,
  });
  final TerminalPane pane;
  final String title;
  final TerminalTheme theme;
  final Color accent;
  final bool active;
  final bool maximized;
  final VoidCallback onActivate, onClose, onRestart, onMaximize;
  final ValueChanged<Axis> onSplit;
  final KeyEventResult Function(KeyEvent) onWorkspaceKey;
  final bool Function(PaneDockPayload payload)? canAcceptDrop;
  final void Function(PaneDockPayload payload, SplitDockPosition position)?
  onAcceptDrop;
  final String Function(PaneDockPayload payload)? payloadLabelBuilder;
  final PaneDockPayload? headerDragPayload;
  final String? headerDragTitle;
  final Widget? terminalOverlay;
  final VoidCallback? onToggleBeautyCard;
  final ShortcutConfig? shortcutConfig;
  final VoidCallback? onOpenShortcutSettings;
  final TerminalCursorType cursorType;
  final ValueChanged<TerminalCursorType>? onCursorTypeChanged;
  final VoidCallback? onFontSizeChanged;
  final VirtualModifierController? virtualModifierController;
  final bool hideHeaderBar;

  @override
  State<TerminalPaneView> createState() => TerminalPaneViewState();
}

class TerminalPaneViewState extends State<TerminalPaneView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  final _TerminalObservableBridge _cursorBridge = _TerminalObservableBridge();
  final _CursorGlyphCache _cursorGlyphCache = _CursorGlyphCache();
  TerminalTheme? _cachedSourceTheme;
  TerminalTheme? _cachedNoCursorTheme;
  bool _searching = false;
  final List<BufferRangeLine> _matches = [];
  int _matchIndex = -1;
  SplitDockPosition? _hoverDockPosition;
  PaneDockPayload? _hoverPayload;
  TerminalPane get pane => widget.pane;
  TerminalStyle _textStyle = const TerminalStyle(
    fontSize: 13.5,
    height: 1.28,
    fontFamily: 'Consolas',
    fontFamilyFallback: [
      'Cascadia Mono',
      'Consolas',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Menlo',
      'Monaco',
      'Noto Sans Mono CJK SC',
      'monospace',
    ],
  );

  TerminalStyle get _effectiveTextStyle {
    // xterm 4 compares TerminalStyle by identity. A new instance on each tab
    // activation would invalidate its font cache and relayout the scrollback.
    if (_textStyle.fontSize != pane.fontSize) {
      _textStyle = _textStyle.copyWith(fontSize: pane.fontSize);
    }
    return _textStyle;
  }

  /// 关闭 xterm 4 原生不绘制反色字符的光标（避免回退光标时实心块完全遮挡下方文字），改由高精度反色光标层渲染
  TerminalTheme get _viewThemeWithoutNativeCursor {
    if (!identical(_cachedSourceTheme, widget.theme) ||
        _cachedNoCursorTheme == null) {
      _cachedSourceTheme = widget.theme;
      final t = widget.theme;
      _cachedNoCursorTheme = TerminalTheme(
        cursor: const Color(0x00000000),
        selection: t.selection,
        foreground: t.foreground,
        background: t.background,
        black: t.black,
        white: t.white,
        red: t.red,
        green: t.green,
        yellow: t.yellow,
        blue: t.blue,
        magenta: t.magenta,
        cyan: t.cyan,
        brightBlack: t.brightBlack,
        brightRed: t.brightRed,
        brightGreen: t.brightGreen,
        brightYellow: t.brightYellow,
        brightBlue: t.brightBlue,
        brightMagenta: t.brightMagenta,
        brightCyan: t.brightCyan,
        brightWhite: t.brightWhite,
        searchHitBackground: t.searchHitBackground,
        searchHitBackgroundCurrent: t.searchHitBackgroundCurrent,
        searchHitForeground: t.searchHitForeground,
      );
    }
    return _cachedNoCursorTheme!;
  }

  @override
  void initState() {
    super.initState();
    pane.focus.addListener(_focusChanged);
    _cursorBridge.attach(pane.session.terminal);
  }

  void _focusChanged() {
    if (pane.focus.hasFocus && !widget.active) widget.onActivate();
  }

  Future<void> copy() async {
    final selection = pane.controller.selection;
    if (selection == null) return;
    await Clipboard.setData(
      ClipboardData(text: pane.session.terminal.buffer.getText(selection)),
    );
  }

  Future<void> paste() async {
    final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted || pane.disposed || clipboard?.text == null) return;
    pane.session.terminal.paste(clipboard!.text!);
    pane.focus.requestFocus();
  }

  void selectAll() {
    final buffer = pane.session.terminal.buffer;
    pane.controller.setSelection(
      buffer.createAnchor(0, 0),
      buffer.createAnchor(buffer.viewWidth, buffer.height - 1),
    );
  }

  void clear() {
    pane.controller.clearSelection();
    pane.session.clearTerminalScreen();
    if (_searching) _find(_search.text);
  }

  void showSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
    _find(_search.text);
  }

  void _closeSearch() {
    setState(() {
      _searching = false;
      _matches.clear();
      _matchIndex = -1;
    });
    pane.controller.clearSelection();
    pane.focus.requestFocus();
  }

  void zoom(double delta) {
    setState(() => pane.fontSize = (pane.fontSize + delta).clamp(8, 32));
    widget.onFontSizeChanged?.call();
  }

  void _find(String query) {
    _matches.clear();
    _matchIndex = -1;
    if (query.isNotEmpty) {
      // Map UTF-16 string positions back to terminal cells, including wide
      // characters, surrogate pairs and lines wrapped by the terminal.
      final buffer = pane.session.terminal.buffer;
      final text = StringBuffer();
      final starts = <CellOffset>[];
      final ends = <CellOffset>[];
      for (var y = 0; y < buffer.height; y++) {
        final line = buffer.lines[y];
        if (y > 0 && !line.isWrapped) {
          text.write('\n');
          starts.add(CellOffset(0, y));
          ends.add(CellOffset(0, y));
        }
        var last = buffer.viewWidth;
        if (y + 1 >= buffer.height || !buffer.lines[y + 1].isWrapped) {
          while (last > 0 && line.getCodePoint(last - 1) == 0) {
            last--;
          }
        }
        for (var x = 0; x < last; x++) {
          final code = line.getCodePoint(x);
          final width = line.getWidth(x);
          if (code == 0 && width == 0 && x > 0 && line.getWidth(x - 1) == 2) {
            continue;
          }
          final character = code == 0 ? ' ' : String.fromCharCode(code);
          text.write(character);
          for (var i = 0; i < character.length; i++) {
            starts.add(CellOffset(x, y));
            ends.add(CellOffset(x + (width > 0 ? width : 1), y));
          }
        }
      }
      final haystack = text.toString();
      var offset = 0;
      while (offset <= haystack.length - query.length &&
          _matches.length < 1000) {
        final index = haystack.indexOf(query, offset);
        if (index < 0) break;
        _matches.add(
          BufferRangeLine(starts[index], ends[index + query.length - 1]),
        );
        offset = index + query.length;
      }
    }
    if (_matches.isNotEmpty) {
      _matchIndex = 0;
      _selectMatch();
    } else {
      pane.controller.clearSelection();
    }
    setState(() {});
  }

  void _nextMatch(int delta) {
    if (_matches.isEmpty) return;
    setState(() => _matchIndex = (_matchIndex + delta) % _matches.length);
    _selectMatch();
  }

  void _selectMatch() {
    final buffer = pane.session.terminal.buffer;
    final range = _matches[_matchIndex];
    if (range.end.y >= buffer.height) {
      _find(_search.text);
      return;
    }
    pane.controller.setSelection(
      buffer.createAnchorFromOffset(range.begin),
      buffer.createAnchorFromOffset(range.end),
    );
    if (pane.scroll.hasClients && buffer.scrollBack > 0) {
      pane.scroll.jumpTo(
        (pane.scroll.position.maxScrollExtent *
                range.begin.y /
                buffer.scrollBack)
            .clamp(0, pane.scroll.position.maxScrollExtent),
      );
    }
  }

  ShortcutConfig get _shortcuts =>
      widget.shortcutConfig ?? ShortcutConfig.defaults();

  static String? _logicalKeyToRawSequence(LogicalKeyboardKey key) {
    final id = key.keyId;
    if (id >= LogicalKeyboardKey.keyA.keyId &&
        id <= LogicalKeyboardKey.keyZ.keyId) {
      return String.fromCharCode(
        65 + (id - LogicalKeyboardKey.keyA.keyId),
      );
    }
    if (key == LogicalKeyboardKey.arrowUp) return '\x1b[A';
    if (key == LogicalKeyboardKey.arrowDown) return '\x1b[B';
    if (key == LogicalKeyboardKey.arrowRight) return '\x1b[C';
    if (key == LogicalKeyboardKey.arrowLeft) return '\x1b[D';
    if (key == LogicalKeyboardKey.home) return '\x1b[H';
    if (key == LogicalKeyboardKey.end) return '\x1b[F';
    if (key == LogicalKeyboardKey.slash) return '/';
    if (key == LogicalKeyboardKey.minus) return '-';
    if (key == LogicalKeyboardKey.bracketLeft) return '[';
    if (key == LogicalKeyboardKey.backslash) return '\\';
    if (key == LogicalKeyboardKey.bracketRight) return ']';
    if (key == LogicalKeyboardKey.space) return ' ';
    return null;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final vMod = widget.virtualModifierController;
    final vCtrl = vMod?.isCtrlActive ?? false;
    final vAlt = vMod?.isAltActive ?? false;
    final modifier =
        keyboard.isControlPressed || keyboard.isMetaPressed || vCtrl;
    final shift = keyboard.isShiftPressed;
    final alt = keyboard.isAltPressed || vAlt;
    final cfg = _shortcuts;

    // 1. 优先匹配用户自定义的终端内动作快捷键（复制/粘贴/全选/查找/清屏）
    final matched = cfg.matchAction(
      event,
      isCmdOrCtrlPressed: modifier,
      isShiftPressed: shift,
      isAltPressed: alt,
    );
    switch (matched) {
      case ShortcutAction.copy:
        vMod?.consumeOneShot();
        copy();
        return KeyEventResult.handled;
      case ShortcutAction.paste:
        vMod?.consumeOneShot();
        paste();
        return KeyEventResult.handled;
      case ShortcutAction.selectAll:
        vMod?.consumeOneShot();
        selectAll();
        return KeyEventResult.handled;
      case ShortcutAction.find:
        vMod?.consumeOneShot();
        showSearch();
        return KeyEventResult.handled;
      case ShortcutAction.clear:
        vMod?.consumeOneShot();
        clear();
        return KeyEventResult.handled;
      default:
        break;
    }

    // 2. 处理 Ctrl+A 行为（默认：光标定位到当前命令行开头，不再误全选整个屏幕）
    if (modifier && !shift && !alt && event.logicalKey == LogicalKeyboardKey.keyA) {
      if (vCtrl) vMod?.recordHardwareKeyHandled('a');
      vMod?.consumeOneShot();
      switch (cfg.ctrlABehavior) {
        case CtrlABehavior.selectAllText:
          selectAll();
          return KeyEventResult.handled;
        case CtrlABehavior.moveToLineStart:
          pane.controller.clearSelection();
          if (pane.session.isLocalSession &&
              Platform.isWindows &&
              !pane.session.terminal.isUsingAltBuffer) {
            pane.session.terminal.keyInput(TerminalKey.home);
          } else {
            pane.session.terminal.keyInput(TerminalKey.keyA, ctrl: true);
          }
          return KeyEventResult.handled;
        case CtrlABehavior.passthroughCtrlA:
          pane.controller.clearSelection();
          pane.session.terminal.keyInput(TerminalKey.keyA, ctrl: true);
          return KeyEventResult.handled;
      }
    }

    // 3. 本机 Windows PowerShell 下 Ctrl+E 光标定位到命令行末尾（与 Ctrl+A 配对）
    if (cfg.powershellCtrlELineEnd &&
        modifier &&
        !shift &&
        !alt &&
        event.logicalKey == LogicalKeyboardKey.keyE &&
        pane.session.isLocalSession &&
        Platform.isWindows &&
        !pane.session.terminal.isUsingAltBuffer) {
      if (vCtrl) vMod?.recordHardwareKeyHandled('e');
      vMod?.consumeOneShot();
      pane.session.terminal.keyInput(TerminalKey.end);
      return KeyEventResult.handled;
    }

    // 4. 智能 Ctrl+C：有鼠标划选文本时复制并清除选区，无选区时正常向终端发送 ^C 中断信号
    if (cfg.smartCtrlCCopy &&
        modifier &&
        !shift &&
        !alt &&
        event.logicalKey == LogicalKeyboardKey.keyC &&
        pane.controller.selection != null) {
      if (vCtrl) vMod?.recordHardwareKeyHandled('c');
      vMod?.consumeOneShot();
      copy();
      pane.controller.clearSelection();
      return KeyEventResult.handled;
    }

    // 5. 智能 Ctrl+V：非全屏交替缓冲区（如普通命令行）下直接粘贴，Vim 等全屏模式下透传 ^V
    if (cfg.ctrlVPaste &&
        modifier &&
        !shift &&
        !alt &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        !pane.session.terminal.isUsingAltBuffer) {
      if (vCtrl) vMod?.recordHardwareKeyHandled('v');
      vMod?.consumeOneShot();
      paste();
      return KeyEventResult.handled;
    }

    // 6. 若底部虚拟 CTRL / ALT 处于激活态，将当前物理键盘按键合成为对应的控制序列发送
    if ((vCtrl || vAlt) &&
        !keyboard.isControlPressed &&
        !keyboard.isMetaPressed) {
      final rawSeq = _logicalKeyToRawSequence(event.logicalKey);
      if (rawSeq != null) {
        if (rawSeq.length == 1) {
          vMod!.recordHardwareKeyHandled(rawSeq);
        }
        final out = vMod!.applyAndConsume(rawSeq);
        pane.session.sendRawInput(out);
        return KeyEventResult.handled;
      }
    }

    if (modifier &&
        (event.logicalKey == LogicalKeyboardKey.equal ||
            event.logicalKey == LogicalKeyboardKey.add)) {
      vMod?.consumeOneShot();
      zoom(1);
      return KeyEventResult.handled;
    }
    if (modifier && event.logicalKey == LogicalKeyboardKey.minus) {
      vMod?.consumeOneShot();
      zoom(-1);
      return KeyEventResult.handled;
    }
    if (modifier && event.logicalKey == LogicalKeyboardKey.digit0) {
      vMod?.consumeOneShot();
      setState(() => pane.fontSize = 13.5);
      widget.onFontSizeChanged?.call();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.f3) {
      if (!_searching) {
        showSearch();
      } else {
        _nextMatch(shift ? -1 : 1);
      }
      return KeyEventResult.handled;
    }
    return widget.onWorkspaceKey(event);
  }

  Future<void> _menu(Offset position) async {
    widget.onActivate();
    final cfg = _shortcuts;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final point = overlay.globalToLocal(position);
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
          value: 'copy',
          enabled: pane.controller.selection != null,
          child: Text('复制    ${cfg.chordFor(ShortcutAction.copy).displayLabel}'),
        ),
        PopupMenuItem(
          value: 'paste',
          child: Text('粘贴    ${cfg.chordFor(ShortcutAction.paste).displayLabel}'),
        ),
        PopupMenuItem(
          value: 'all',
          child: Text('全选    ${cfg.chordFor(ShortcutAction.selectAll).displayLabel}'),
        ),
        PopupMenuItem(
          value: 'find',
          child: Text('查找    ${cfg.chordFor(ShortcutAction.find).displayLabel}'),
        ),
        PopupMenuItem(
          value: 'clear',
          child: Text('清屏    ${cfg.chordFor(ShortcutAction.clear).displayLabel}'),
        ),
        if (widget.onToggleBeautyCard != null)
          PopupMenuItem(
            value: 'toggleBeauty',
            child: Text(
              '切换美化卡片 / 原文    ${cfg.chordFor(ShortcutAction.toggleBeauty).displayLabel}',
            ),
          ),
        if (widget.onOpenShortcutSettings != null)
          PopupMenuItem(
            value: 'shortcuts',
            child: Text(
              '快捷键设置…    ${cfg.chordFor(ShortcutAction.openShortcuts).displayLabel}',
            ),
          ),
        if (widget.onCursorTypeChanged != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: 'cursor_block',
            child: Text(
              '${widget.cursorType == TerminalCursorType.block ? '✓ ' : '   '}光标：实心反色方块 (█)',
            ),
          ),
          PopupMenuItem(
            value: 'cursor_beam',
            child: Text(
              '${widget.cursorType == TerminalCursorType.verticalBar ? '✓ ' : '   '}光标：纤细竖线 (|)',
            ),
          ),
          PopupMenuItem(
            value: 'cursor_underline',
            child: Text(
              '${widget.cursorType == TerminalCursorType.underline ? '✓ ' : '   '}光标：底部下划线 (_)',
            ),
          ),
        ],
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'right',
          child: Text(
            '向右分屏    ${cfg.chordFor(ShortcutAction.splitRight).displayLabel}',
          ),
        ),
        PopupMenuItem(
          value: 'down',
          child: Text(
            '向下分屏    ${cfg.chordFor(ShortcutAction.splitDown).displayLabel}',
          ),
        ),
        PopupMenuItem(
          value: 'maximize',
          child: Text(widget.maximized ? '还原窗格' : '最大化窗格'),
        ),
        const PopupMenuItem(value: 'restart', child: Text('重新连接 / 重启终端')),
        const PopupMenuItem(value: 'close', child: Text('关闭此窗格')),
      ],
    );
    if (!mounted) return;
    switch (action) {
      case 'copy':
        await copy();
      case 'paste':
        await paste();
      case 'all':
        selectAll();
      case 'find':
        showSearch();
      case 'clear':
        clear();
      case 'toggleBeauty':
        widget.onToggleBeautyCard?.call();
      case 'shortcuts':
        widget.onOpenShortcutSettings?.call();
      case 'cursor_block':
        widget.onCursorTypeChanged?.call(TerminalCursorType.block);
      case 'cursor_beam':
        widget.onCursorTypeChanged?.call(TerminalCursorType.verticalBar);
      case 'cursor_underline':
        widget.onCursorTypeChanged?.call(TerminalCursorType.underline);
      case 'right':
        widget.onSplit(Axis.horizontal);
      case 'down':
        widget.onSplit(Axis.vertical);
      case 'restart':
        widget.onRestart();
      case 'maximize':
        widget.onMaximize();
      case 'close':
        widget.onClose();
    }
  }

  @override
  void didUpdateWidget(covariant TerminalPaneView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pane != widget.pane) {
      oldWidget.pane.focus.removeListener(_focusChanged);
      widget.pane.focus.addListener(_focusChanged);
      _cursorBridge.attach(widget.pane.session.terminal);
    }
  }

  SplitDockPosition _resolveDockPosition(Offset globalOffset) {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) {
      return SplitDockPosition.right;
    }
    final local = box.globalToLocal(globalOffset);
    final w = box.size.width <= 0 ? 1.0 : box.size.width;
    final h = box.size.height <= 0 ? 1.0 : box.size.height;
    final rx = (local.dx / w).clamp(0.0, 1.0);
    final ry = (local.dy / h).clamp(0.0, 1.0);
    if (ry < 0.20 && rx > 0.28 && rx < 0.72) {
      return SplitDockPosition.top;
    }
    if (ry > 0.80 && rx > 0.28 && rx < 0.72) {
      return SplitDockPosition.bottom;
    }
    return rx < 0.5 ? SplitDockPosition.left : SplitDockPosition.right;
  }

  void _clearDockHover() {
    if (_hoverDockPosition != null || _hoverPayload != null) {
      setState(() {
        _hoverDockPosition = null;
        _hoverPayload = null;
      });
    }
  }

  Widget _buildHeaderTitleRow() {
    final content = GestureDetector(
      onDoubleTap: widget.onMaximize,
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          if (widget.headerDragPayload != null) ...[
            Icon(
              Icons.drag_indicator,
              size: 13,
              color: widget.active
                  ? TxColors.textMuted
                  : TxColors.textMuted.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 4),
          ],
          SessionOsStatusBadge(
            session: pane.session,
            size: 14.5,
            badgeBorderColor: const Color(0xFF15181F),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                fontFamily: TxColors.monoFamily,
                color: widget.active
                    ? TxColors.textSecondary
                    : TxColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );

    final payload = widget.headerDragPayload;
    if (payload == null) return content;

    final dragLabel = widget.headerDragTitle ?? widget.title;
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: Draggable<PaneDockPayload>(
        data: payload,
        dragAnchorStrategy: pointerDragAnchorStrategy,
        feedback: FractionalTranslation(
          translation: const Offset(-0.5, -0.5),
          child: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: TxColors.bgElevated,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: TxColors.accent.withValues(alpha: 0.7)),
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
                  SessionOsStatusBadge(session: pane.session, size: 13),
                  const SizedBox(width: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 180),
                    child: Text(
                      dragLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w600,
                        color: TxColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        childWhenDragging: Opacity(opacity: 0.4, child: content),
        child: content,
      ),
    );
  }

  Widget _buildDockPreviewOverlay(SplitDockPosition pos) {
    final Alignment alignment;
    final double? widthFactor;
    final double? heightFactor;
    final IconData icon;
    switch (pos) {
      case SplitDockPosition.left:
        alignment = Alignment.centerLeft;
        widthFactor = 0.5;
        heightFactor = 1.0;
        icon = Icons.vertical_split_outlined;
      case SplitDockPosition.right:
        alignment = Alignment.centerRight;
        widthFactor = 0.5;
        heightFactor = 1.0;
        icon = Icons.vertical_split_outlined;
      case SplitDockPosition.top:
        alignment = Alignment.topCenter;
        widthFactor = 1.0;
        heightFactor = 0.5;
        icon = Icons.horizontal_split_outlined;
      case SplitDockPosition.bottom:
        alignment = Alignment.bottomCenter;
        widthFactor = 1.0;
        heightFactor = 0.5;
        icon = Icons.horizontal_split_outlined;
    }

    final payload = _hoverPayload;
    final itemName = payload != null && widget.payloadLabelBuilder != null
        ? widget.payloadLabelBuilder!(payload)
        : null;
    final badgeText = (itemName != null && itemName.isNotEmpty)
        ? '${pos.label} · $itemName'
        : pos.label;

    return Positioned.fill(
      child: IgnorePointer(
        child: Align(
          alignment: alignment,
          child: FractionallySizedBox(
            widthFactor: widthFactor,
            heightFactor: heightFactor,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: TxColors.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: TxColors.accent.withValues(alpha: 0.85),
                    width: 1.5,
                  ),
                ),
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: TxColors.bgChrome.withValues(alpha: 0.92),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: TxColors.borderStrong),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 14, color: TxColors.accent),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            badgeText,
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
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final paneContent = Listener(
      onPointerDown: (_) => widget.onActivate(),
      child: Container(
        color: widget.theme.background,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                if (!widget.hideHeaderBar)
                  Container(
                    height: 34,
                  decoration: BoxDecoration(
                    color: widget.active
                        ? const Color(0xFF15181F)
                        : const Color(0xFF101217),
                    border: const Border(
                      bottom: BorderSide(color: TxColors.borderSubtle),
                    ),
                  ),
                  padding: const EdgeInsets.only(left: 10, right: 6),
                  child: ListenableBuilder(
                    listenable: pane.session,
                    builder: (context, _) {
                      final isDisconnectedOrError =
                          pane.session.state ==
                              SessionConnectionState.disconnected ||
                          pane.session.state == SessionConnectionState.error;
                      return LayoutBuilder(
                        builder: (context, constraints) => Row(
                          children: [
                            Expanded(child: _buildHeaderTitleRow()),
                            if (isDisconnectedOrError)
                              Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Tooltip(
                                  message: '重新连接 / 重启终端',
                                  child: InkWell(
                                    key: const ValueKey(
                                      'pane_header_reconnect_chip',
                                    ),
                                    borderRadius: BorderRadius.circular(5),
                                    onTap: widget.onRestart,
                                    child: Container(
                                      height: 24,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                      ),
                                      decoration: BoxDecoration(
                                        color: TxColors.accent.withValues(
                                          alpha: 0.18,
                                        ),
                                        borderRadius: BorderRadius.circular(5),
                                        border: Border.all(
                                          color: TxColors.accent.withValues(
                                            alpha: 0.55,
                                          ),
                                        ),
                                      ),
                                      child: const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.refresh_rounded,
                                            size: 13.5,
                                            color: TxColors.accent,
                                          ),
                                          SizedBox(width: 4),
                                          Text(
                                            '重连',
                                            style: TextStyle(
                                              fontSize: 11.5,
                                              fontWeight: FontWeight.w600,
                                              color: TxColors.textPrimary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              _button(
                                '重新连接 / 重启终端',
                                Icons.refresh_rounded,
                                widget.onRestart,
                              ),
                            if (constraints.maxWidth >= 260) ...[
                              if (widget.onToggleBeautyCard != null)
                                _button(
                                  '切换美化卡片 / 终端原文 (${_shortcuts.chordFor(ShortcutAction.toggleBeauty).displayLabel})',
                                  Icons.auto_awesome_outlined,
                                  widget.onToggleBeautyCard!,
                                ),
                              _button('查找', Icons.search_rounded, showSearch),
                              _button(
                                '向右分屏',
                                Icons.vertical_split_outlined,
                                () => widget.onSplit(Axis.horizontal),
                              ),
                              _button(
                                '向下分屏',
                                Icons.horizontal_split_outlined,
                                () => widget.onSplit(Axis.vertical),
                              ),
                              _button(
                                widget.maximized ? '还原窗格' : '最大化窗格',
                                widget.maximized
                                    ? Icons.fullscreen_exit_rounded
                                    : Icons.fullscreen_rounded,
                                widget.onMaximize,
                              ),
                            ] else
                              _button('窗格菜单', Icons.more_horiz_rounded, () {
                                final box =
                                    this.context.findRenderObject()!
                                        as RenderBox;
                                _menu(
                                  box.localToGlobal(
                                    Offset(box.size.width - 30, 34),
                                  ),
                                );
                              }),
                            _button(
                              '关闭此窗格',
                              Icons.close_rounded,
                              widget.onClose,
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                if (_searching)
                  Focus(
                    onKeyEvent: (_, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.escape) {
                        _closeSearch();
                        return KeyEventResult.handled;
                      }
                      return KeyEventResult.ignored;
                    },
                    child: Container(
                      height: 38,
                      padding: const EdgeInsets.only(left: 10, right: 6),
                      decoration: const BoxDecoration(
                        color: TxColors.bgSidebar,
                        border: Border(
                          bottom: BorderSide(color: TxColors.borderSubtle),
                        ),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.search_rounded,
                            size: 15,
                            color: TxColors.textMuted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _search,
                              focusNode: _searchFocus,
                              style: const TextStyle(fontSize: 13),
                              decoration: const InputDecoration(
                                hintText: '查找终端输出（区分大小写）',
                                filled: false,
                                border: InputBorder.none,
                                enabledBorder: InputBorder.none,
                                focusedBorder: InputBorder.none,
                                contentPadding: EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                isDense: true,
                              ),
                              onChanged: _find,
                              onSubmitted: (_) {
                                _nextMatch(
                                  HardwareKeyboard.instance.isShiftPressed
                                      ? -1
                                      : 1,
                                );
                                _searchFocus.requestFocus();
                              },
                            ),
                          ),
                          Text(
                            '${_matchIndex + 1}/${_matches.length}',
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: TxColors.monoFamily,
                              color: TxColors.textMuted,
                            ),
                          ),
                          const SizedBox(width: 4),
                          _button(
                            '上一个匹配',
                            Icons.keyboard_arrow_up_rounded,
                            () => _nextMatch(-1),
                          ),
                          _button(
                            '下一个匹配',
                            Icons.keyboard_arrow_down_rounded,
                            () => _nextMatch(1),
                          ),
                          _button('关闭查找', Icons.close_rounded, _closeSearch),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: Stack(
                    key: ValueKey(pane.id),
                    fit: StackFit.expand,
                    children: [
                      TerminalView(
                        pane.session.terminal,
                        key: _terminalViewKey,
                        controller: pane.controller,
                        scrollController: pane.scroll,
                        focusNode: pane.focus,
                        shortcuts: const {},
                        onKeyEvent: _onKey,
                        onSecondaryTapUp: (details, _) =>
                            _menu(details.globalPosition),
                        theme: _viewThemeWithoutNativeCursor,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        textStyle: _effectiveTextStyle,
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: ClipRect(
                              child: RepaintBoundary(
                                child: CustomPaint(
                                  key: const ValueKey(
                                    'termx_inverse_cursor_paint',
                                  ),
                                  painter: _TerminalCursorPainter(
                                    repaint: Listenable.merge([
                                      _cursorBridge,
                                      pane.scroll,
                                      pane.focus,
                                      pane.controller,
                                    ]),
                                    terminalViewKey: _terminalViewKey,
                                    terminal: pane.session.terminal,
                                    focusNode: pane.focus,
                                    theme: widget.theme,
                                    textStyle: _effectiveTextStyle,
                                    textScaler: MediaQuery.textScalerOf(
                                      context,
                                    ),
                                    cursorType: widget.cursorType,
                                    glyphCache: _cursorGlyphCache,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (widget.terminalOverlay != null)
                        Positioned.fill(child: widget.terminalOverlay!),
                      ListenableBuilder(
                        listenable: pane.session,
                        builder: (context, _) {
                          final state = pane.session.state;
                          if (state != SessionConnectionState.disconnected &&
                              state != SessionConnectionState.error) {
                            return const SizedBox.shrink();
                          }
                          final isError = state == SessionConnectionState.error;
                          return Positioned(
                            left: 12,
                            right: 12,
                            bottom: 12,
                            child: Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 460),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  decoration: BoxDecoration(
                                    color: TxColors.bgSidebar.withValues(
                                      alpha: 0.96,
                                    ),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isError
                                          ? TxColors.danger.withValues(
                                              alpha: 0.55,
                                            )
                                          : TxColors.borderStrong,
                                    ),
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
                                      Icon(
                                        isError
                                            ? Icons.error_outline_rounded
                                            : Icons.link_off_rounded,
                                        size: 16,
                                        color: isError
                                            ? TxColors.danger
                                            : TxColors.warning,
                                      ),
                                      const SizedBox(width: 8),
                                      Flexible(
                                        child: Text(
                                          isError
                                              ? '连接失败或已中断'
                                              : '终端会话已断开',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 12.5,
                                            color: TxColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      FilledButton.icon(
                                        key: const ValueKey(
                                          'terminal_reconnect_banner_btn',
                                        ),
                                        style: FilledButton.styleFrom(
                                          visualDensity: VisualDensity.compact,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 10,
                                            vertical: 4,
                                          ),
                                        ),
                                        onPressed: widget.onRestart,
                                        icon: const Icon(
                                          Icons.refresh_rounded,
                                          size: 14,
                                        ),
                                        label: const Text(
                                          '重新连接',
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (_hoverDockPosition != null)
              _buildDockPreviewOverlay(_hoverDockPosition!),
          ],
        ),
      ),
    );

    if (widget.onAcceptDrop == null) return paneContent;

    return DragTarget<PaneDockPayload>(
      onWillAcceptWithDetails: (details) =>
          widget.canAcceptDrop?.call(details.data) ?? true,
      onMove: (details) {
        final nextPos = _resolveDockPosition(details.offset);
        if (_hoverDockPosition != nextPos || _hoverPayload != details.data) {
          setState(() {
            _hoverDockPosition = nextPos;
            _hoverPayload = details.data;
          });
        }
      },
      onLeave: (_) => _clearDockHover(),
      onAcceptWithDetails: (details) {
        final dropPos = _resolveDockPosition(details.offset);
        _clearDockHover();
        widget.onAcceptDrop!(details.data, dropPos);
      },
      builder: (context, _, _) => paneContent,
    );
  }

  Widget _button(String tooltip, IconData icon, VoidCallback action) =>
      SizedBox(
        width: 30,
        height: 28,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          style: IconButton.styleFrom(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(5),
            ),
          ),
          icon: Icon(icon, size: 16, color: TxColors.textSecondary),
          hoverColor: TxColors.bgHover,
          onPressed: action,
        ),
      );

  @override
  void dispose() {
    pane.focus.removeListener(_focusChanged);
    _cursorBridge.dispose();
    _cursorGlyphCache.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }
}

/// 将 xterm [Terminal] 的 `Observable` 变更桥接为 Flutter [Listenable]
class _TerminalObservableBridge extends ChangeNotifier {
  Terminal? _terminal;

  void attach(Terminal next) {
    if (identical(_terminal, next)) return;
    _terminal?.removeListener(_onTerminalChanged);
    _terminal = next;
    _terminal?.addListener(_onTerminalChanged);
  }

  void _onTerminalChanged() {
    notifyListeners();
  }

  @override
  void dispose() {
    _terminal?.removeListener(_onTerminalChanged);
    _terminal = null;
    super.dispose();
  }
}

/// 缓存光标下方单个反色字符的 [ui.Paragraph]，避免逐帧重复排版并及时释放原生纹理
class _CursorGlyphCache {
  int? _cachedKey;
  ui.Paragraph? _cachedParagraph;

  ui.Paragraph resolve({
    required int charCode,
    required Color color,
    required TerminalStyle textStyle,
    required TextScaler textScaler,
    required bool bold,
    required bool italic,
    required bool underline,
  }) {
    final key = Object.hash(
      charCode,
      color.toARGB32(),
      textStyle.fontSize,
      textStyle.height,
      textStyle.fontFamily,
      textScaler,
      bold,
      italic,
      underline,
    );
    if (_cachedKey == key && _cachedParagraph != null) {
      return _cachedParagraph!;
    }
    _cachedParagraph?.dispose();
    final style = textStyle.toTextStyle(
      color: color,
      bold: bold,
      italic: italic,
      underline: underline,
    );
    var charStr = String.fromCharCode(charCode);
    if (underline && charCode == 0x20) {
      charStr = String.fromCharCode(0xA0);
    }
    final builder = ui.ParagraphBuilder(style.getParagraphStyle());
    builder.pushStyle(style.getTextStyle(textScaler: textScaler));
    builder.addText(charStr);
    final paragraph = builder.build();
    paragraph.layout(const ui.ParagraphConstraints(width: double.infinity));
    _cachedKey = key;
    _cachedParagraph = paragraph;
    return paragraph;
  }

  void dispose() {
    _cachedParagraph?.dispose();
    _cachedParagraph = null;
    _cachedKey = null;
  }
}

/// 高精度反色终端光标绘制器：
/// 1. 解决 xterm 4.0.0 实心方块光标直接覆盖在文字上方、回退光标时完全遮挡下方字符的缺陷（自动绘制高对比度反色字符，支持 CJK 双宽字符整格包裹）；
/// 2. 修复 xterm 4.0.0 竖线光标 (`verticalBar`) 与下划线光标 (`underline`) 遗漏 `offset.dy` 导致始终画在第 0 行的上游 Bug。
class _TerminalCursorPainter extends CustomPainter {
  _TerminalCursorPainter({
    required super.repaint,
    required this.terminalViewKey,
    required this.terminal,
    required this.focusNode,
    required this.theme,
    required this.textStyle,
    required this.textScaler,
    required this.cursorType,
    required this.glyphCache,
  });

  final GlobalKey<TerminalViewState> terminalViewKey;
  final Terminal terminal;
  final FocusNode focusNode;
  final TerminalTheme theme;
  final TerminalStyle textStyle;
  final TextScaler textScaler;
  final TerminalCursorType cursorType;
  final _CursorGlyphCache glyphCache;

  static Color _pickInverseGlyphColor(
    Color cursorBg, {
    required Color preferredDark,
    required Color preferredLight,
  }) => cursorBg.computeLuminance() > 0.35 ? preferredDark : preferredLight;

  @override
  void paint(Canvas canvas, Size size) {
    if (!terminal.cursorVisibleMode) return;
    final viewState = terminalViewKey.currentState;
    if (viewState == null || !viewState.mounted) return;

    final dynamic rt;
    try {
      rt = viewState.renderTerminal;
    } catch (_) {
      return;
    }
    if (rt.attached != true || rt.hasSize != true) return;

    final Size cellSize = rt.cellSize as Size;
    if (cellSize.width <= 0 || cellSize.height <= 0) return;

    final buffer = terminal.buffer;
    final absY = buffer.absoluteCursorY;
    if (absY < 0 || absY >= buffer.lines.length) return;

    final line = buffer.lines[absY];
    var col = buffer.cursorX;
    // 若光标落在双宽字符（如中文）的右半格占位单元，自动对齐到左半格完整包裹整个宽字符
    if (col > 0 &&
        col < line.length &&
        line.getCodePoint(col) == 0 &&
        line.getWidth(col - 1) == 2) {
      col -= 1;
    }

    var charCode = 0;
    var charWidth = 1;
    var cellFlags = 0;
    if (col >= 0 && col < line.length) {
      charCode = line.getCodePoint(col);
      final rawW = line.getWidth(col);
      charWidth = rawW == 2 ? 2 : 1;
      cellFlags = line.getAttributes(col);
    }

    final Offset rawCursorOffset = rt.cursorOffset as Offset;
    final dx = col * cellSize.width;
    // 与 RenderTerminal._paint 中 paintLine 的 truncateToDouble() 严格保持同一像素行基准
    final dy = rawCursorOffset.dy.truncateToDouble();
    if (dy + cellSize.height < 0 || dy > size.height) return;

    final spanWidth = cellSize.width * charWidth;
    final cursorColor = theme.cursor.a > 0
        ? theme.cursor.withValues(alpha: 1.0)
        : const Color(0xFFD5DAE2);

    if (!focusNode.hasFocus) {
      final strokePaint = Paint()
        ..color = cursorColor.withValues(alpha: 0.72)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawRect(
        Rect.fromLTWH(
          dx + 0.6,
          dy + 0.6,
          (spanWidth - 1.2).clamp(1.0, double.infinity),
          (cellSize.height - 1.2).clamp(1.0, double.infinity),
        ),
        strokePaint,
      );
      return;
    }

    switch (cursorType) {
      case TerminalCursorType.verticalBar:
        final barPaint = Paint()
          ..color = cursorColor
          ..style = PaintingStyle.fill;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(
              dx,
              dy + 1.0,
              2.0,
              (cellSize.height - 2.0).clamp(2.0, double.infinity),
            ),
            const Radius.circular(1.0),
          ),
          barPaint,
        );
        return;

      case TerminalCursorType.underline:
        final linePaint = Paint()
          ..color = cursorColor
          ..style = PaintingStyle.fill;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(dx, dy + cellSize.height - 2.2, spanWidth, 2.2),
            const Radius.circular(1.0),
          ),
          linePaint,
        );
        return;

      case TerminalCursorType.block:
        final fillPaint = Paint()
          ..color = cursorColor
          ..style = PaintingStyle.fill;
        canvas.drawRect(
          Rect.fromLTWH(dx, dy, spanWidth, cellSize.height),
          fillPaint,
        );

        // 当光标回退到已有可见字符上方时，以高对比度反色重绘该字符，彻底消除实心块遮挡
        if (charCode > 0x20 && charCode <= 0x10FFFF) {
          final inverseFg = _pickInverseGlyphColor(
            cursorColor,
            preferredDark: theme.background,
            preferredLight: theme.brightWhite,
          );
          final paragraph = glyphCache.resolve(
            charCode: charCode,
            color: inverseFg,
            textStyle: textStyle,
            textScaler: textScaler,
            bold: (cellFlags & CellFlags.bold) != 0,
            italic: (cellFlags & CellFlags.italic) != 0,
            underline: (cellFlags & CellFlags.underline) != 0,
          );
          canvas.drawParagraph(paragraph, Offset(dx, dy));
        }
        return;
    }
  }

  @override
  bool shouldRepaint(covariant _TerminalCursorPainter oldDelegate) =>
      oldDelegate.terminal != terminal ||
      oldDelegate.focusNode != focusNode ||
      oldDelegate.theme != theme ||
      oldDelegate.textStyle != textStyle ||
      oldDelegate.textScaler != textScaler ||
      oldDelegate.cursorType != cursorType;
}

class ResizablePaneSplit extends StatefulWidget {
  const ResizablePaneSplit({
    super.key,
    required this.split,
    required this.first,
    required this.second,
    this.onRatioChanged,
  });
  final PaneSplit split;
  final Widget first, second;
  final VoidCallback? onRatioChanged;
  @override
  State<ResizablePaneSplit> createState() => _ResizablePaneSplitState();
}

class _ResizablePaneSplitState extends State<ResizablePaneSplit> {
  bool _hovered = false;
  int? _activePointer;
  double _dragStartGlobalPos = 0.0;
  double _dragStartRatio = 0.5;

  bool get _dragging => _activePointer != null;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final horizontal = widget.split.axis == Axis.horizontal;
      final rawExtent =
          horizontal ? constraints.maxWidth : constraints.maxHeight;
      final usableExtent = (rawExtent - 7.0).clamp(1.0, double.infinity);
      final highlight = _hovered || _dragging;
      return Flex(
        direction: widget.split.axis,
        children: [
          Expanded(
            flex: (widget.split.ratio * 10000).round(),
            child: widget.first,
          ),
          MouseRegion(
            cursor: horizontal
                ? SystemMouseCursors.resizeLeftRight
                : SystemMouseCursors.resizeUpDown,
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onDoubleTap: () {
                setState(() {
                  _activePointer = null;
                  widget.split.ratio = 0.5;
                });
                widget.onRatioChanged?.call();
              },
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: (event) {
                  if (event.kind == PointerDeviceKind.mouse &&
                      event.buttons != 1) {
                    return;
                  }
                  setState(() {
                    _activePointer = event.pointer;
                    _dragStartGlobalPos = horizontal
                        ? event.position.dx
                        : event.position.dy;
                    _dragStartRatio = widget.split.ratio;
                  });
                },
                onPointerMove: (event) {
                  if (event.pointer != _activePointer) return;
                  final currentPos = horizontal
                      ? event.position.dx
                      : event.position.dy;
                  final delta = currentPos - _dragStartGlobalPos;
                  final nextRatio = (_dragStartRatio + delta / usableExtent)
                      .clamp(0.15, 0.85);
                  if ((nextRatio - widget.split.ratio).abs() > 0.0001) {
                    setState(() => widget.split.ratio = nextRatio);
                  }
                },
                onPointerUp: (event) {
                  if (event.pointer == _activePointer) {
                    setState(() => _activePointer = null);
                    widget.onRatioChanged?.call();
                  }
                },
                onPointerCancel: (event) {
                  if (event.pointer == _activePointer) {
                    setState(() => _activePointer = null);
                    widget.onRatioChanged?.call();
                  }
                },
                child: SizedBox(
                  width: horizontal ? 7 : double.infinity,
                  height: horizontal ? double.infinity : 7,
                  child: Center(
                    child: Container(
                      width: horizontal
                          ? (highlight ? 2 : 1)
                          : double.infinity,
                      height: horizontal
                          ? double.infinity
                          : (highlight ? 2 : 1),
                      color:
                          highlight ? TxColors.accent : TxColors.borderSubtle,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            flex: ((1 - widget.split.ratio) * 10000).round(),
            child: widget.second,
          ),
        ],
      );
    },
  );
}
