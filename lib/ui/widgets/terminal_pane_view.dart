import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../core/models/terminal_workspace.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../../core/theme/ui_tokens.dart';
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

  @override
  State<TerminalPaneView> createState() => TerminalPaneViewState();
}

class TerminalPaneViewState extends State<TerminalPaneView> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
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
  );

  TerminalStyle get _effectiveTextStyle {
    // xterm 4 compares TerminalStyle by identity. A new instance on each tab
    // activation would invalidate its font cache and relayout the scrollback.
    if (_textStyle.fontSize != pane.fontSize) {
      _textStyle = _textStyle.copyWith(fontSize: pane.fontSize);
    }
    return _textStyle;
  }

  @override
  void initState() {
    super.initState();
    pane.focus.addListener(_focusChanged);
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
    pane.session.terminal.write('\x1b[3J\x1b[2J\x1b[H');
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

  void zoom(double delta) =>
      setState(() => pane.fontSize = (pane.fontSize + delta).clamp(8, 32));

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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifier = keyboard.isControlPressed || keyboard.isMetaPressed;
    if (modifier && keyboard.isShiftPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyC) {
        copy();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyV) {
        paste();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyA) {
        selectAll();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyF) {
        showSearch();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.keyK) {
        clear();
        return KeyEventResult.handled;
      }
    }
    if (modifier &&
        (event.logicalKey == LogicalKeyboardKey.equal ||
            event.logicalKey == LogicalKeyboardKey.add)) {
      zoom(1);
      return KeyEventResult.handled;
    }
    if (modifier && event.logicalKey == LogicalKeyboardKey.minus) {
      zoom(-1);
      return KeyEventResult.handled;
    }
    if (modifier && event.logicalKey == LogicalKeyboardKey.digit0) {
      setState(() => pane.fontSize = 13.5);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.f3) {
      if (!_searching) {
        showSearch();
      } else {
        _nextMatch(keyboard.isShiftPressed ? -1 : 1);
      }
      return KeyEventResult.handled;
    }
    return widget.onWorkspaceKey(event);
  }

  Future<void> _menu(Offset position) async {
    widget.onActivate();
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
          child: const Text('复制    Ctrl+Shift+C'),
        ),
        const PopupMenuItem(value: 'paste', child: Text('粘贴    Ctrl+Shift+V')),
        const PopupMenuItem(value: 'all', child: Text('全选    Ctrl+Shift+A')),
        const PopupMenuItem(value: 'find', child: Text('查找    Ctrl+Shift+F')),
        const PopupMenuItem(value: 'clear', child: Text('清屏    Ctrl+Shift+K')),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'right', child: Text('向右分屏')),
        const PopupMenuItem(value: 'down', child: Text('向下分屏')),
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
              size: 11,
              color: widget.active
                  ? TxColors.textMuted
                  : TxColors.textMuted.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 4),
          ],
          SessionOsStatusBadge(
            session: pane.session,
            size: 13,
            badgeBorderColor: const Color(0xFF15181F),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
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
                Container(
                  height: 28,
                  decoration: BoxDecoration(
                    color: widget.active
                        ? const Color(0xFF15181F)
                        : const Color(0xFF101217),
                    border: const Border(
                      bottom: BorderSide(color: TxColors.borderSubtle),
                    ),
                  ),
                  padding: const EdgeInsets.only(left: 10, right: 4),
                  child: LayoutBuilder(
                    builder: (context, constraints) => Row(
                      children: [
                        Expanded(child: _buildHeaderTitleRow()),
                        if (constraints.maxWidth >= 240) ...[
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
                                this.context.findRenderObject()! as RenderBox;
                            _menu(
                              box.localToGlobal(Offset(box.size.width - 28, 28)),
                            );
                          }),
                        _button('关闭此窗格', Icons.close_rounded, widget.onClose),
                      ],
                    ),
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
                      height: 34,
                      padding: const EdgeInsets.only(left: 8, right: 4),
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
                            size: 13.5,
                            color: TxColors.textMuted,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: TextField(
                              controller: _search,
                              focusNode: _searchFocus,
                              style: const TextStyle(fontSize: 12),
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
                              fontSize: 11,
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
                  child: TerminalView(
                    pane.session.terminal,
                    key: ValueKey(pane.id),
                    controller: pane.controller,
                    scrollController: pane.scroll,
                    focusNode: pane.focus,
                    onKeyEvent: _onKey,
                    onSecondaryTapUp: (details, _) =>
                        _menu(details.globalPosition),
                    theme: widget.theme,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    textStyle: _effectiveTextStyle,
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
        width: 24,
        height: 24,
        child: IconButton(
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          icon: Icon(icon, size: 13.5, color: TxColors.textMuted),
          hoverColor: TxColors.bgHover,
          onPressed: action,
        ),
      );

  @override
  void dispose() {
    pane.focus.removeListener(_focusChanged);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }
}

class ResizablePaneSplit extends StatefulWidget {
  const ResizablePaneSplit({
    super.key,
    required this.split,
    required this.first,
    required this.second,
  });
  final PaneSplit split;
  final Widget first, second;
  @override
  State<ResizablePaneSplit> createState() => _ResizablePaneSplitState();
}

class _ResizablePaneSplitState extends State<ResizablePaneSplit> {
  bool _hovered = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final horizontal = widget.split.axis == Axis.horizontal;
      final extent = horizontal ? constraints.maxWidth : constraints.maxHeight;
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
              behavior: HitTestBehavior.opaque,
              onDoubleTap: () => setState(() => widget.split.ratio = 0.5),
              onPanStart: (_) => setState(() => _dragging = true),
              onPanEnd: (_) => setState(() => _dragging = false),
              onPanCancel: () => setState(() => _dragging = false),
              onPanUpdate: (details) => setState(
                () => widget.split.ratio =
                    (widget.split.ratio +
                            (horizontal ? details.delta.dx : details.delta.dy) /
                                extent)
                        .clamp(0.15, 0.85),
              ),
              child: SizedBox(
                width: horizontal ? 5 : double.infinity,
                height: horizontal ? double.infinity : 5,
                child: Center(
                  child: Container(
                    width: horizontal
                        ? (highlight ? 2 : 1)
                        : double.infinity,
                    height: horizontal
                        ? double.infinity
                        : (highlight ? 2 : 1),
                    color: highlight ? TxColors.accent : TxColors.borderSubtle,
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
