import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/ui_tokens.dart';
import 'command_output_models.dart';

Color semanticHealthColor(SemanticHealth h) => switch (h) {
  SemanticHealth.healthy => TxColors.success,
  SemanticHealth.warning => TxColors.warning,
  SemanticHealth.danger => TxColors.danger,
  SemanticHealth.info => TxColors.accent,
  SemanticHealth.neutral => TxColors.textMuted,
};

class _SortSpec {
  final String id;
  final String label;
  final bool defaultDescending;

  const _SortSpec(this.id, this.label, {this.defaultDescending = false});
}

/// 卡片与胶囊的实时几何状态（独立于重型卡片列表渲染，确保 120Hz/240Hz 鼠标零延迟 1:1 跟手）
class _OverlayGeometry {
  final Offset? cardPosition;
  final Offset? capsulePosition;
  final double? customWidth;
  final double? customMaxHeight;
  final bool isDragging;
  final bool isResizing;
  final bool isDraggingCapsule;

  const _OverlayGeometry({
    this.cardPosition,
    this.capsulePosition,
    this.customWidth,
    this.customMaxHeight,
    this.isDragging = false,
    this.isResizing = false,
    this.isDraggingCapsule = false,
  });

  bool get hasCustomCardGeometry =>
      cardPosition != null || customWidth != null || customMaxHeight != null;

  _OverlayGeometry copyWith({
    Offset? cardPosition,
    bool clearCardPosition = false,
    Offset? capsulePosition,
    bool clearCapsulePosition = false,
    double? customWidth,
    bool clearCustomWidth = false,
    double? customMaxHeight,
    bool clearCustomMaxHeight = false,
    bool? isDragging,
    bool? isResizing,
    bool? isDraggingCapsule,
  }) {
    return _OverlayGeometry(
      cardPosition: clearCardPosition
          ? null
          : (cardPosition ?? this.cardPosition),
      capsulePosition: clearCapsulePosition
          ? null
          : (capsulePosition ?? this.capsulePosition),
      customWidth: clearCustomWidth ? null : (customWidth ?? this.customWidth),
      customMaxHeight: clearCustomMaxHeight
          ? null
          : (customMaxHeight ?? this.customMaxHeight),
      isDragging: isDragging ?? this.isDragging,
      isResizing: isResizing ?? this.isResizing,
      isDraggingCapsule: isDraggingCapsule ?? this.isDraggingCapsule,
    );
  }
}

/// 挂载在每个终端窗格画布上方的美化卡片贴片组件
/// - 支持按住卡片顶栏/底栏（或原文胶囊左侧）1:1 零延迟全局坐标跟手拖拽，双击顶栏一键复位
/// - 支持按住卡片右下角 1:1 拖拽缩放卡片宽高
/// - 拖拽与缩放过程通过 ValueNotifier + RepaintBoundary 隔离，零重绘底层百行数据列表
/// - 非卡片区域 100% 鼠标/触摸穿透，绝不遮挡底层终端滚动、选词与输入
class TerminalBeautyOverlay extends StatefulWidget {
  const TerminalBeautyOverlay({
    super.key,
    required this.card,
    required this.displayMode,
    required this.pinned,
    required this.historyIndex,
    required this.historyTotal,
    required this.onToggleDisplayMode,
    required this.onTogglePin,
    required this.onDismiss,
    required this.onStepHistory,
    required this.onSendCommand,
    required this.onCopyToast,
    this.savedOffset,
    this.onOffsetChanged,
  });

  final BeautifiedOutputCard card;
  final CardDisplayMode displayMode;
  final bool pinned;
  final int historyIndex;
  final int historyTotal;
  final ValueChanged<CardDisplayMode> onToggleDisplayMode;
  final VoidCallback onTogglePin;
  final VoidCallback onDismiss;
  final ValueChanged<int> onStepHistory;
  final void Function(String command, {bool appendNewline}) onSendCommand;
  final ValueChanged<String> onCopyToast;
  final Offset? savedOffset;
  final ValueChanged<Offset?>? onOffsetChanged;

  @override
  State<TerminalBeautyOverlay> createState() => _TerminalBeautyOverlayState();
}

class _TerminalBeautyOverlayState extends State<TerminalBeautyOverlay> {
  final TextEditingController _filterCtrl = TextEditingController();
  final GlobalKey _cardContainerKey = GlobalKey();
  late final ValueNotifier<_OverlayGeometry> _geometry;

  bool _showFilter = false;
  bool _expandedHeight = false;
  bool _showInlineRawCompare = false;

  // 全局屏幕坐标 1:1 拖拽锚点（彻底消除移动 Positioned 导致的局部坐标半速反馈及手势竞技场 18px 启动粘滞）
  int? _activeDragPointer;
  Offset _dragStartGlobal = Offset.zero;
  Offset _dragStartCardOrigin = Offset.zero;
  DateTime? _lastHeaderTapUpAt;
  Offset _lastHeaderTapGlobal = Offset.zero;

  int? _activeResizePointer;
  Offset _resizeStartGlobal = Offset.zero;
  double _resizeStartWidth = 0;
  double _resizeStartHeight = 0;

  int? _activeCapsulePointer;
  Offset _capsuleStartGlobal = Offset.zero;
  Offset _capsuleStartOrigin = Offset.zero;

  @override
  void initState() {
    super.initState();
    _geometry = ValueNotifier<_OverlayGeometry>(
      _OverlayGeometry(cardPosition: widget.savedOffset),
    );
  }

  @override
  void didUpdateWidget(covariant TerminalBeautyOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.id != widget.card.id && !widget.card.isLiveInteractive) {
      _filterCtrl.clear();
      _showInlineRawCompare = false;
    }
    if (widget.savedOffset != oldWidget.savedOffset &&
        !_geometry.value.isDragging) {
      _geometry.value = _geometry.value.copyWith(
        cardPosition: widget.savedOffset,
        clearCardPosition: widget.savedOffset == null,
      );
    }
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    _geometry.dispose();
    super.dispose();
  }

  bool _isPrimaryPointerDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse) {
      return (e.buttons & kPrimaryMouseButton) != 0;
    }
    return true;
  }

  void _resetPositionAndSize() {
    _activeDragPointer = null;
    _activeResizePointer = null;
    _geometry.value = _geometry.value.copyWith(
      clearCardPosition: true,
      clearCustomWidth: true,
      clearCustomMaxHeight: true,
      isDragging: false,
      isResizing: false,
    );
    widget.onOffsetChanged?.call(null);
  }

  void _startCardDrag(
    PointerDownEvent e, {
    required Offset currentOrigin,
  }) {
    if (_activeDragPointer != null || !_isPrimaryPointerDown(e)) return;
    _activeDragPointer = e.pointer;
    _dragStartGlobal = e.position;
    _dragStartCardOrigin = currentOrigin;
    _geometry.value = _geometry.value.copyWith(
      cardPosition: currentOrigin,
      isDragging: true,
    );
  }

  void _updateCardDrag(
    PointerMoveEvent e, {
    required double minLeft,
    required double maxLeft,
    required double minTop,
    required double maxTop,
  }) {
    if (e.pointer != _activeDragPointer) return;
    final rawNext = _dragStartCardOrigin + (e.position - _dragStartGlobal);
    final clamped = Offset(
      rawNext.dx.clamp(minLeft, maxLeft).toDouble(),
      rawNext.dy.clamp(minTop, maxTop).toDouble(),
    );
    if (_geometry.value.cardPosition != clamped) {
      _geometry.value = _geometry.value.copyWith(cardPosition: clamped);
    }
  }

  void _endCardDrag(
    int pointer, {
    Offset? upGlobalPosition,
    bool allowDoubleTapReset = false,
  }) {
    if (pointer != _activeDragPointer) return;
    _activeDragPointer = null;
    final movedDistance = upGlobalPosition == null
        ? 999.0
        : (upGlobalPosition - _dragStartGlobal).distance;
    _geometry.value = _geometry.value.copyWith(isDragging: false);

    if (allowDoubleTapReset && upGlobalPosition != null && movedDistance < 4.0) {
      final now = DateTime.now();
      if (_lastHeaderTapUpAt != null &&
          now.difference(_lastHeaderTapUpAt!).inMilliseconds <= 300 &&
          (upGlobalPosition - _lastHeaderTapGlobal).distance <= 14.0) {
        _lastHeaderTapUpAt = null;
        _resetPositionAndSize();
        return;
      }
      _lastHeaderTapUpAt = now;
      _lastHeaderTapGlobal = upGlobalPosition;
    }

    widget.onOffsetChanged?.call(_geometry.value.cardPosition);
  }

  void _startCardResize(
    PointerDownEvent e, {
    required double fallbackWidth,
    required double fallbackMaxHeight,
  }) {
    if (_activeResizePointer != null || !_isPrimaryPointerDown(e)) return;
    final renderedSize =
        (_cardContainerKey.currentContext?.findRenderObject() as RenderBox?)
            ?.size;
    _activeResizePointer = e.pointer;
    _resizeStartGlobal = e.position;
    _resizeStartWidth = renderedSize?.width ?? fallbackWidth;
    _resizeStartHeight = renderedSize?.height ?? fallbackMaxHeight;
    _geometry.value = _geometry.value.copyWith(isResizing: true);
  }

  void _updateCardResize(
    PointerMoveEvent e, {
    required double minWidth,
    required double maxWidth,
    required double minHeight,
    required double maxHeight,
  }) {
    if (e.pointer != _activeResizePointer) return;
    final delta = e.position - _resizeStartGlobal;
    final nextW =
        (_resizeStartWidth + delta.dx).clamp(minWidth, maxWidth).toDouble();
    final nextH =
        (_resizeStartHeight + delta.dy).clamp(minHeight, maxHeight).toDouble();
    _geometry.value = _geometry.value.copyWith(
      customWidth: nextW,
      customMaxHeight: nextH,
    );
  }

  void _endCardResize(int pointer) {
    if (pointer != _activeResizePointer) return;
    _activeResizePointer = null;
    _geometry.value = _geometry.value.copyWith(isResizing: false);
  }

  Future<void> _copyText(String text, String label) async {
    await Clipboard.setData(ClipboardData(text: text));
    widget.onCopyToast('已复制$label');
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final paneW = constraints.maxWidth;
        final paneH = constraints.maxHeight;
        if (paneH < 90 || paneW < 180) {
          return const SizedBox.shrink();
        }

        final isMobilePane = paneW < 520;
        final bodyPadding = EdgeInsets.all(isMobilePane ? 10 : 12);
        final Widget responsiveCardBody = Flexible(
          child: RepaintBoundary(
            child: _showInlineRawCompare
                ? _buildInlineRawPreview()
                : SingleChildScrollView(
                    padding: bodyPadding,
                    child: BeautyCardBody(
                      card: widget.card,
                      filterQuery: _filterCtrl.text.trim(),
                      onCopyValue: (val, label) => _copyText(val, label),
                      onRunQuickCmd: (cmd) => widget.onSendCommand(cmd),
                    ),
                  ),
          ),
        );

        return ValueListenableBuilder<_OverlayGeometry>(
          valueListenable: _geometry,
          child: responsiveCardBody,
          builder: (context, geo, bodyChild) {
            // 原文视图：悬浮轻量胶囊（同样 1:1 全局坐标跟手拖动，0 遮挡展示底层真实终端文字）
            if (widget.displayMode == CardDisplayMode.raw) {
              final defaultCapsuleLeft = isMobilePane
                  ? max(6.0, paneW - 268.0)
                  : max(8.0, paneW - 380.0);
              final maxCapX = max(6.0, paneW - (isMobilePane ? 176.0 : 220.0));
              final maxCapY = max(6.0, paneH - 46.0);
              final pos = geo.capsulePosition ??
                  Offset(defaultCapsuleLeft, isMobilePane ? 8.0 : 10.0);
              final clampedX = pos.dx.clamp(6.0, maxCapX).toDouble();
              final clampedY = pos.dy.clamp(6.0, maxCapY).toDouble();
              final currentCapOrigin = Offset(clampedX, clampedY);

              return Stack(
                children: [
                  Positioned(
                    left: clampedX,
                    top: clampedY,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: max(180.0, paneW - 12.0),
                      ),
                      child: _buildRawModeFloatingCapsule(
                        isMobile: isMobilePane,
                        isDragging: geo.isDraggingCapsule,
                        onPointerDown: (e) {
                          if (_activeCapsulePointer != null ||
                              !_isPrimaryPointerDown(e)) {
                            return;
                          }
                          _activeCapsulePointer = e.pointer;
                          _capsuleStartGlobal = e.position;
                          _capsuleStartOrigin = currentCapOrigin;
                          _geometry.value = _geometry.value.copyWith(
                            capsulePosition: currentCapOrigin,
                            isDraggingCapsule: true,
                          );
                        },
                        onPointerMove: (e) {
                          if (e.pointer != _activeCapsulePointer) return;
                          final raw = _capsuleStartOrigin +
                              (e.position - _capsuleStartGlobal);
                          _geometry.value = _geometry.value.copyWith(
                            capsulePosition: Offset(
                              raw.dx.clamp(6.0, maxCapX).toDouble(),
                              raw.dy.clamp(6.0, maxCapY).toDouble(),
                            ),
                          );
                        },
                        onPointerEnd: (pointer) {
                          if (pointer != _activeCapsulePointer) return;
                          _activeCapsulePointer = null;
                          _geometry.value = _geometry.value.copyWith(
                            isDraggingCapsule: false,
                          );
                        },
                      ),
                    ),
                  ),
                ],
              );
            }

            // 美化卡片视图：手机窄屏下充分利用横向可视宽度；桌面端预留舒适侧边距并支持右下角自由缩放
            final edgeGap = isMobilePane ? 10.0 : 16.0;
            final minCardW = min(
              isMobilePane ? 250.0 : 320.0,
              max(180.0, paneW - edgeGap),
            );
            final maxCardW = max(minCardW, paneW - edgeGap);
            final defaultWidth = isMobilePane
                ? max(minCardW, paneW - 10.0)
                : min(920.0, max(minCardW, paneW - 72.0));
            final cardWidth = (geo.customWidth ?? defaultWidth)
                .clamp(minCardW, maxCardW)
                .toDouble();

            final defaultMaxHeight = _expandedHeight
                ? (paneH - (isMobilePane ? 8.0 : 20.0))
                      .clamp(140.0, 2200.0)
                      .toDouble()
                : (paneH * (isMobilePane ? 0.80 : 0.68))
                      .clamp(170.0, 620.0)
                      .toDouble();
            final maxCardHeight = (geo.customMaxHeight ?? defaultMaxHeight)
                .clamp(145.0, max(155.0, paneH - (isMobilePane ? 8.0 : 12.0)))
                .toDouble();

            final defaultLeft = max(
              isMobilePane ? 5.0 : 8.0,
              (paneW - cardWidth) * 0.5,
            );
            final defaultTop = isMobilePane ? 5.0 : 14.0;
            final rawPos = geo.cardPosition ?? Offset(defaultLeft, defaultTop);

            // 允许向左/向右自由拖出部分窗口以露出底层任意位置文字，同时保证至少 140~160px 顶栏留在屏内可随时拖回
            final keepVisibleX = min(isMobilePane ? 136.0 : 160.0, cardWidth);
            final minLeft = min(0.0, keepVisibleX - cardWidth);
            final maxLeft = max(minLeft, paneW - keepVisibleX);
            const minTop = 0.0;
            final maxTop = max(0.0, paneH - 46.0);

            final left = rawPos.dx.clamp(minLeft, maxLeft).toDouble();
            final top = rawPos.dy.clamp(minTop, maxTop).toDouble();
            final currentCardOrigin = Offset(left, top);
            final hasCustomGeometry = geo.hasCustomCardGeometry;
            final activeHighlight = geo.isDragging || geo.isResizing;

            return Stack(
              children: [
                Positioned(
                  left: left,
                  top: top,
                  width: cardWidth,
                  child: ConstrainedBox(
                    key: _cardContainerKey,
                    constraints: BoxConstraints(maxHeight: maxCardHeight),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xF715181F),
                          borderRadius: BorderRadius.circular(
                            isMobilePane ? 10 : 9,
                          ),
                          border: Border.all(
                            color: activeHighlight
                                ? TxColors.accent
                                : widget.pinned
                                ? TxColors.accent.withValues(alpha: 0.68)
                                : TxColors.borderDefault,
                            width: activeHighlight ? 1.4 : 1.0,
                          ),
                          boxShadow: const [
                            BoxShadow(
                              color: Color(0x88000000),
                              blurRadius: 22,
                              offset: Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Stack(
                          children: [
                            Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildDraggableCardHeader(
                                  availableWidth: cardWidth,
                                  isDragging: geo.isDragging,
                                  hasCustomGeometry: hasCustomGeometry,
                                  onDragDown: (e) => _startCardDrag(
                                    e,
                                    currentOrigin: currentCardOrigin,
                                  ),
                                  onDragMove: (e) => _updateCardDrag(
                                    e,
                                    minLeft: minLeft,
                                    maxLeft: maxLeft,
                                    minTop: minTop,
                                    maxTop: maxTop,
                                  ),
                                  onDragUp: (e) => _endCardDrag(
                                    e.pointer,
                                    upGlobalPosition: e.position,
                                    allowDoubleTapReset: true,
                                  ),
                                  onDragCancel: (e) => _endCardDrag(e.pointer),
                                ),
                                if (_showFilter) _buildFilterBar(),
                                ?bodyChild,
                                _buildCardFooter(
                                  availableWidth: cardWidth,
                                  isDragging: geo.isDragging,
                                  hasCustomGeometry: hasCustomGeometry,
                                  onDragDown: (e) => _startCardDrag(
                                    e,
                                    currentOrigin: currentCardOrigin,
                                  ),
                                  onDragMove: (e) => _updateCardDrag(
                                    e,
                                    minLeft: minLeft,
                                    maxLeft: maxLeft,
                                    minTop: minTop,
                                    maxTop: maxTop,
                                  ),
                                  onDragUp: (e) => _endCardDrag(
                                    e.pointer,
                                    upGlobalPosition: e.position,
                                  ),
                                  onDragCancel: (e) => _endCardDrag(e.pointer),
                                ),
                              ],
                            ),
                            // 右下角 1:1 全局坐标自由缩放手柄（仅桌面/平板大屏开启，避免手机拇指误触）
                            if (!isMobilePane)
                              Positioned(
                                right: 0,
                                bottom: 0,
                                child: MouseRegion(
                                  cursor:
                                      SystemMouseCursors.resizeUpLeftDownRight,
                                  child: Listener(
                                    behavior: HitTestBehavior.opaque,
                                    onPointerDown: (e) => _startCardResize(
                                      e,
                                      fallbackWidth: cardWidth,
                                      fallbackMaxHeight: maxCardHeight,
                                    ),
                                    onPointerMove: (e) => _updateCardResize(
                                      e,
                                      minWidth: minCardW,
                                      maxWidth: maxCardW,
                                      minHeight: 160.0,
                                      maxHeight: max(170.0, paneH - top - 8.0),
                                    ),
                                    onPointerUp: (e) =>
                                        _endCardResize(e.pointer),
                                    onPointerCancel: (e) =>
                                        _endCardResize(e.pointer),
                                    child: const Tooltip(
                                      message: '按住拖动可自由调整卡片宽高',
                                      child: SizedBox(
                                        width: 22,
                                        height: 22,
                                        child: Align(
                                          alignment: Alignment.bottomRight,
                                          child: Padding(
                                            padding: EdgeInsets.all(3),
                                            child: Icon(
                                              Icons.south_east_rounded,
                                              size: 13,
                                              color: TxColors.textMuted,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _openFullScreenCardSheet(BuildContext context) {
    final sheetSearchCtrl = TextEditingController(text: _filterCtrl.text);
    bool showRawInSheet = _showInlineRawCompare;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: const Color(0xFF15181F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
      ),
      builder: (sheetCtx) => StatefulBuilder(
        builder: (sheetCtx, setSheetState) {
          final c = widget.card;
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.92,
            minChildSize: 0.52,
            maxChildSize: 0.96,
            builder: (sheetCtx, scrollController) => SafeArea(
              top: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      margin: const EdgeInsets.only(top: 8, bottom: 6),
                      width: 36,
                      height: 3.5,
                      decoration: BoxDecoration(
                        color: TxColors.borderStrong,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 4, 8, 8),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: TxColors.borderSubtle),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: TxColors.bgElevated,
                            borderRadius: BorderRadius.circular(7),
                            border: Border.all(color: TxColors.borderSubtle),
                          ),
                          child: Icon(
                            c.category.icon,
                            size: 16,
                            color: TxColors.accent,
                          ),
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                c.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color: TxColors.textPrimary,
                                ),
                              ),
                              if (c.summaryBadge.isNotEmpty ||
                                  c.command.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  [
                                    if (c.summaryBadge.isNotEmpty)
                                      c.summaryBadge,
                                    if (c.command.isNotEmpty) '\$ ${c.command}',
                                  ].join('  ·  '),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontFamily: TxColors.monoFamily,
                                    color: TxColors.textMuted,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 6),
                        _mobileToolChip(
                          icon: showRawInSheet
                              ? Icons.auto_awesome_outlined
                              : Icons.notes_rounded,
                          label: showRawInSheet ? '美化视图' : '对照原文',
                          active: showRawInSheet,
                          onTap: () => setSheetState(
                            () => showRawInSheet = !showRawInSheet,
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          width: 34,
                          height: 34,
                          child: IconButton(
                            tooltip: '复制原始输出',
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.copy_rounded,
                              size: 17,
                              color: TxColors.textSecondary,
                            ),
                            onPressed: () => _copyText(c.rawOutput, '原始输出'),
                          ),
                        ),
                        SizedBox(
                          width: 34,
                          height: 34,
                          child: IconButton(
                            tooltip: '关闭全屏视图',
                            padding: EdgeInsets.zero,
                            icon: const Icon(
                              Icons.close_rounded,
                              size: 20,
                              color: TxColors.textSecondary,
                            ),
                            onPressed: () => Navigator.of(sheetCtx).pop(),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!showRawInSheet)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: const BoxDecoration(
                        color: TxColors.bgSidebar,
                        border: Border(
                          bottom: BorderSide(color: TxColors.borderSubtle),
                        ),
                      ),
                      child: SizedBox(
                        height: 34,
                        child: TextField(
                          controller: sheetSearchCtrl,
                          onChanged: (_) => setSheetState(() {}),
                          style: const TextStyle(
                            fontSize: 13,
                            color: TxColors.textPrimary,
                          ),
                          decoration: InputDecoration(
                            hintText: '过滤名称、端口、状态、PID 或文件路径…',
                            prefixIcon: const Icon(
                              Icons.search_rounded,
                              size: 16,
                            ),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 34,
                              minHeight: 34,
                            ),
                            suffixIcon: sheetSearchCtrl.text.isNotEmpty
                                ? IconButton(
                                    padding: EdgeInsets.zero,
                                    icon: const Icon(
                                      Icons.clear_rounded,
                                      size: 16,
                                    ),
                                    onPressed: () {
                                      sheetSearchCtrl.clear();
                                      setSheetState(() {});
                                    },
                                  )
                                : null,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 6,
                            ),
                            isDense: true,
                          ),
                        ),
                      ),
                    ),
                  Expanded(
                    child: showRawInSheet
                        ? SingleChildScrollView(
                            controller: scrollController,
                            padding: const EdgeInsets.all(12),
                            child: SelectableText(
                              c.rawOutput,
                              style: const TextStyle(
                                fontFamily: TxColors.monoFamily,
                                fontSize: 12.5,
                                height: 1.45,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          )
                        : SingleChildScrollView(
                            controller: scrollController,
                            padding: const EdgeInsets.all(12),
                            child: BeautyCardBody(
                              card: c,
                              filterQuery: sheetSearchCtrl.text.trim(),
                              onCopyValue: (val, label) =>
                                  _copyText(val, label),
                              onRunQuickCmd: (cmd) {
                                Navigator.of(sheetCtx).pop();
                                widget.onSendCommand(cmd);
                              },
                            ),
                          ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    ).whenComplete(() {
      Future<void>.delayed(
        const Duration(milliseconds: 250),
        sheetSearchCtrl.dispose,
      );
    });
  }

  Widget _buildRawModeFloatingCapsule({
    required bool isMobile,
    required bool isDragging,
    required PointerDownEventListener onPointerDown,
    required PointerMoveEventListener onPointerMove,
    required ValueChanged<int> onPointerEnd,
  }) {
    final c = widget.card;
    final cmdText = c.command.isEmpty ? c.title : c.command;
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: isMobile ? 8 : 10,
          vertical: isMobile ? 5 : 6,
        ),
        decoration: BoxDecoration(
          color: TxColors.bgElevated.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isDragging ? TxColors.accent : TxColors.borderStrong,
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
            Flexible(
              fit: FlexFit.loose,
              child: MouseRegion(
                cursor: isDragging
                    ? SystemMouseCursors.grabbing
                    : SystemMouseCursors.grab,
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: onPointerDown,
                  onPointerMove: onPointerMove,
                  onPointerUp: (e) => onPointerEnd(e.pointer),
                  onPointerCancel: (e) => onPointerEnd(e.pointer),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.drag_indicator_rounded,
                          size: 15,
                          color: TxColors.textMuted,
                        ),
                        const SizedBox(width: 3),
                        Icon(c.category.icon, size: 15, color: TxColors.accent),
                        const SizedBox(width: 5),
                        Flexible(
                          fit: FlexFit.loose,
                          child: ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: isMobile ? 112 : 190,
                            ),
                            child: Text(
                              isMobile ? cmdText : '原文模式 · $cmdText',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () =>
                  widget.onToggleDisplayMode(CardDisplayMode.beautified),
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 9 : 10,
                  vertical: isMobile ? 5.5 : 5,
                ),
                decoration: BoxDecoration(
                  color: TxColors.accentSoft,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: TxColors.accent.withValues(alpha: 0.65),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 14,
                      color: TxColors.accent,
                    ),
                    SizedBox(width: 4),
                    Text(
                      '显示美化卡片',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: TxColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 3),
            Tooltip(
              message: '关闭提示胶囊',
              child: InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: widget.onDismiss,
                child: Padding(
                  padding: EdgeInsets.all(isMobile ? 6 : 5),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 16,
                    color: TxColors.textMuted,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileToolChip({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    String? tooltip,
  }) {
    final chip = InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: active ? TxColors.accentSoft : TxColors.bgElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active
                ? TxColors.accent.withValues(alpha: 0.65)
                : TxColors.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: active ? TxColors.accent : TxColors.textSecondary,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                color: active ? TxColors.textPrimary : TxColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip, child: chip);
  }

  Widget _buildDraggableCardHeader({
    required double availableWidth,
    required bool isDragging,
    required bool hasCustomGeometry,
    required PointerDownEventListener onDragDown,
    required PointerMoveEventListener onDragMove,
    required PointerUpEventListener onDragUp,
    required PointerCancelEventListener onDragCancel,
  }) {
    final c = widget.card;
    final isMobileHeader = availableWidth < 520;
    final compact = availableWidth < 760;
    final showCommandPill = availableWidth >= 830 && c.command.isNotEmpty;
    final showBadge =
        availableWidth >= (isMobileHeader ? 230 : 280) &&
        c.summaryBadge.isNotEmpty;

    final dragHandleArea = MouseRegion(
      cursor: isDragging
          ? SystemMouseCursors.grabbing
          : SystemMouseCursors.grab,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: onDragDown,
        onPointerMove: onDragMove,
        onPointerUp: onDragUp,
        onPointerCancel: onDragCancel,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Tooltip(
                message: '按住顶栏空白或标题处自由拖动，双击复位位置',
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 16,
                  color: TxColors.textMuted,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: TxColors.bgElevated,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: TxColors.borderSubtle),
                ),
                child: Icon(
                  c.category.icon,
                  size: 15.5,
                  color: TxColors.accent,
                ),
              ),
              const SizedBox(width: 7),
              Flexible(
                child: Text(
                  c.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isMobileHeader ? 13 : 13.5,
                    fontWeight: FontWeight.w600,
                    color: TxColors.textPrimary,
                  ),
                ),
              ),
              if (showCommandPill) ...[
                const SizedBox(width: 8),
                Container(
                  constraints: const BoxConstraints(maxWidth: 190),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: TxColors.bgPanel,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: TxColors.borderSubtle),
                  ),
                  child: Text(
                    '\$ ${c.command}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontFamily: TxColors.monoFamily,
                      color: TxColors.textSecondary,
                    ),
                  ),
                ),
              ],
              if (showBadge) ...[
                const SizedBox(width: 6),
                Container(
                  constraints: BoxConstraints(
                    maxWidth: isMobileHeader ? 92 : 140,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6.5,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: TxColors.accentSoft,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: Text(
                    c.summaryBadge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: TxColors.monoFamily,
                      fontWeight: FontWeight.w600,
                      color: TxColors.accent,
                    ),
                  ),
                ),
              ],
              if (!isMobileHeader &&
                  c.isLiveInteractive &&
                  availableWidth >= 340) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: TxColors.success.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '实时刷新',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: TxColors.success,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (isMobileHeader) {
      return Container(
        padding: const EdgeInsets.fromLTRB(9, 5, 7, 6),
        decoration: const BoxDecoration(
          color: TxColors.bgChrome,
          borderRadius: BorderRadius.vertical(top: Radius.circular(9)),
          border: Border(bottom: BorderSide(color: TxColors.borderSubtle)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: dragHandleArea),
                const SizedBox(width: 6),
                _mobileToolChip(
                  icon: Icons.terminal_rounded,
                  label: '显示原文',
                  onTap: () => widget.onToggleDisplayMode(CardDisplayMode.raw),
                ),
                const SizedBox(width: 3),
                _headerIconBtn(
                  tooltip: '全屏查看美化卡片',
                  icon: Icons.open_in_full_rounded,
                  size: 32,
                  iconSize: 16,
                  onTap: () => _openFullScreenCardSheet(context),
                ),
                _headerIconBtn(
                  tooltip: '关闭此贴片（显示底层终端）',
                  icon: Icons.close_rounded,
                  size: 32,
                  iconSize: 18,
                  onTap: widget.onDismiss,
                ),
              ],
            ),
            const SizedBox(height: 5),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (widget.historyTotal > 1) ...[
                    _headerIconBtn(
                      tooltip: '上一张捕获卡片',
                      icon: Icons.chevron_left_rounded,
                      size: 28,
                      enabled: widget.historyIndex > 0,
                      onTap: () => widget.onStepHistory(-1),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Text(
                        '${widget.historyIndex + 1}/${widget.historyTotal}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textSecondary,
                        ),
                      ),
                    ),
                    _headerIconBtn(
                      tooltip: '下一张捕获卡片',
                      icon: Icons.chevron_right_rounded,
                      size: 28,
                      enabled: widget.historyIndex + 1 < widget.historyTotal,
                      onTap: () => widget.onStepHistory(1),
                    ),
                    const SizedBox(width: 5),
                  ],
                  _mobileToolChip(
                    icon: Icons.search_rounded,
                    label: '过滤',
                    active: _showFilter,
                    onTap: () => setState(() {
                      _showFilter = !_showFilter;
                      if (!_showFilter) _filterCtrl.clear();
                    }),
                  ),
                  const SizedBox(width: 5),
                  _mobileToolChip(
                    icon: widget.pinned
                        ? Icons.push_pin_rounded
                        : Icons.push_pin_outlined,
                    label: widget.pinned ? '已固定' : '固定',
                    active: widget.pinned,
                    onTap: widget.onTogglePin,
                  ),
                  const SizedBox(width: 5),
                  _mobileToolChip(
                    icon: Icons.compare_arrows_rounded,
                    label: _showInlineRawCompare ? '美化卡片' : '对照原文',
                    active: _showInlineRawCompare,
                    onTap: () => setState(
                      () => _showInlineRawCompare = !_showInlineRawCompare,
                    ),
                  ),
                  const SizedBox(width: 5),
                  _mobileToolChip(
                    icon: _expandedHeight
                        ? Icons.unfold_less_rounded
                        : Icons.unfold_more_rounded,
                    label: _expandedHeight ? '收起高度' : '展开高度',
                    active: _expandedHeight,
                    onTap: () {
                      _geometry.value = _geometry.value.copyWith(
                        clearCustomMaxHeight: true,
                      );
                      setState(() => _expandedHeight = !_expandedHeight);
                    },
                  ),
                  const SizedBox(width: 5),
                  _mobileToolChip(
                    icon: Icons.copy_rounded,
                    label: '复制原文',
                    onTap: () => _copyText(c.rawOutput, '原始输出'),
                  ),
                  if (hasCustomGeometry) ...[
                    const SizedBox(width: 5),
                    _mobileToolChip(
                      tooltip: '复位卡片默认居中位置与尺寸',
                      icon: Icons.filter_center_focus_rounded,
                      label: '复位位置',
                      onTap: _resetPositionAndSize,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );
    }

    final actionButtons = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildModeSegmentedSwitch(),
        const SizedBox(width: 8),
        if (widget.historyTotal > 1) ...[
          _headerIconBtn(
            tooltip: '上一张捕获卡片',
            icon: Icons.chevron_left_rounded,
            enabled: widget.historyIndex > 0,
            onTap: () => widget.onStepHistory(-1),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Text(
              '${widget.historyIndex + 1}/${widget.historyTotal}',
              style: const TextStyle(
                fontSize: 12,
                fontFamily: TxColors.monoFamily,
                color: TxColors.textSecondary,
              ),
            ),
          ),
          _headerIconBtn(
            tooltip: '下一张捕获卡片',
            icon: Icons.chevron_right_rounded,
            enabled: widget.historyIndex + 1 < widget.historyTotal,
            onTap: () => widget.onStepHistory(1),
          ),
          const SizedBox(width: 4),
        ],
        _headerIconBtn(
          tooltip: '卡片内关键字过滤',
          icon: Icons.search_rounded,
          active: _showFilter,
          onTap: () => setState(() {
            _showFilter = !_showFilter;
            if (!_showFilter) _filterCtrl.clear();
          }),
        ),
        _headerIconBtn(
          tooltip: widget.pinned
              ? '取消固定卡片'
              : '固定卡片（后续运行其他命令时不自动收起）',
          icon: widget.pinned
              ? Icons.push_pin_rounded
              : Icons.push_pin_outlined,
          active: widget.pinned,
          onTap: widget.onTogglePin,
        ),
        if (hasCustomGeometry)
          _headerIconBtn(
            tooltip: '复位卡片默认居中位置与尺寸',
            icon: Icons.filter_center_focus_rounded,
            onTap: _resetPositionAndSize,
          ),
        _headerIconBtn(
          tooltip: _expandedHeight ? '还原默认高度' : '展开最大高度',
          icon: _expandedHeight
              ? Icons.unfold_less_rounded
              : Icons.unfold_more_rounded,
          active: _expandedHeight,
          onTap: () {
            _geometry.value = _geometry.value.copyWith(
              clearCustomMaxHeight: true,
            );
            setState(() => _expandedHeight = !_expandedHeight);
          },
        ),
        _headerIconBtn(
          tooltip: '复制原始终端文本',
          icon: Icons.copy_rounded,
          onTap: () => _copyText(c.rawOutput, '原始输出'),
        ),
        _headerIconBtn(
          tooltip: '关闭此贴片（显示底层终端）',
          icon: Icons.close_rounded,
          onTap: widget.onDismiss,
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: const BoxDecoration(
        color: TxColors.bgChrome,
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
        border: Border(bottom: BorderSide(color: TxColors.borderSubtle)),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                dragHandleArea,
                const SizedBox(height: 4),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: actionButtons,
                ),
              ],
            )
          : Row(
              children: [
                Expanded(child: dragHandleArea),
                const SizedBox(width: 10),
                actionButtons,
              ],
            ),
    );
  }

  Widget _buildModeSegmentedSwitch() {
    return Container(
      padding: const EdgeInsets.all(2.5),
      decoration: BoxDecoration(
        color: TxColors.bgElevated,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: TxColors.borderDefault),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _segmentChip(
            label: '美化卡片',
            icon: Icons.auto_awesome_outlined,
            selected: !_showInlineRawCompare,
            onTap: () {
              if (_showInlineRawCompare) {
                setState(() => _showInlineRawCompare = false);
              }
            },
          ),
          _segmentChip(
            label: '显示原文',
            icon: Icons.terminal_rounded,
            selected: false,
            onTap: () => widget.onToggleDisplayMode(CardDisplayMode.raw),
          ),
        ],
      ),
    );
  }

  Widget _segmentChip({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? TxColors.bgSelected : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected ? TxColors.borderStrong : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 13.5,
              color: selected ? TxColors.accent : TxColors.textSecondary,
            ),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                color: selected ? TxColors.textPrimary : TxColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _headerIconBtn({
    required String tooltip,
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
    bool enabled = true,
    double size = 30,
    double iconSize = 16.5,
  }) {
    return SizedBox(
      width: size,
      height: size,
      child: IconButton(
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        style: IconButton.styleFrom(
          backgroundColor: active ? TxColors.accentSoft : Colors.transparent,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
        onPressed: enabled ? onTap : null,
        icon: Icon(
          icon,
          size: iconSize,
          color: !enabled
              ? TxColors.textMuted.withValues(alpha: 0.35)
              : active
              ? TxColors.accent
              : TxColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildFilterBar() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: TxColors.bgSidebar,
        border: Border(bottom: BorderSide(color: TxColors.borderSubtle)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.search_rounded,
            size: 15.5,
            color: TxColors.textMuted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _filterCtrl,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 12.5, color: TxColors.textPrimary),
              decoration: const InputDecoration(
                hintText: '输入关键字过滤名称、端口、状态、PID 或文件路径…',
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          if (_filterCtrl.text.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: () => setState(() => _filterCtrl.clear()),
              child: const Padding(
                padding: EdgeInsets.all(5),
                child: Icon(
                  Icons.clear_rounded,
                  size: 15,
                  color: TxColors.textSecondary,
                ),
              ),
            ),
          InkWell(
            borderRadius: BorderRadius.circular(4),
            onTap: () => setState(() {
              _showFilter = false;
              _filterCtrl.clear();
            }),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 5),
              child: Text(
                '收起',
                style: TextStyle(fontSize: 11.5, color: TxColors.textMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInlineRawPreview() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      color: TxColors.bgCanvas,
      child: SingleChildScrollView(
        child: SelectableText(
          widget.card.rawOutput,
          style: const TextStyle(
            fontFamily: TxColors.monoFamily,
            fontSize: 12.5,
            height: 1.42,
            color: TxColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _buildCardFooter({
    required double availableWidth,
    required bool isDragging,
    required bool hasCustomGeometry,
    required PointerDownEventListener onDragDown,
    required PointerMoveEventListener onDragMove,
    required PointerUpEventListener onDragUp,
    required PointerCancelEventListener onDragCancel,
  }) {
    final c = widget.card;
    final isMobileFooter = availableWidth < 520;
    final hh = c.capturedAt.hour.toString().padLeft(2, '0');
    final mm = c.capturedAt.minute.toString().padLeft(2, '0');
    final ss = c.capturedAt.second.toString().padLeft(2, '0');

    if (isMobileFooter) {
      return Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: const BoxDecoration(
          color: TxColors.bgChrome,
          borderRadius: BorderRadius.vertical(bottom: Radius.circular(9)),
          border: Border(top: BorderSide(color: TxColors.borderSubtle)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: onDragDown,
                onPointerMove: onDragMove,
                onPointerUp: onDragUp,
                onPointerCancel: onDragCancel,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${c.category.shortLabel} · $hh:$mm:$ss · 可拖动顶栏移位',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: TxColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
            if (c.isLiveInteractive) ...[
              const SizedBox(width: 6),
              InkWell(
                borderRadius: BorderRadius.circular(5),
                onTap: () => widget.onSendCommand('q', appendNewline: false),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3.5,
                  ),
                  decoration: BoxDecoration(
                    color: TxColors.warning.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    '退出交互 (q)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: TxColors.warning,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () => _openFullScreenCardSheet(context),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Text(
                  '全屏阅读',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: TxColors.accent,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      height: 30,
      padding: const EdgeInsets.only(left: 12, right: 26),
      decoration: const BoxDecoration(
        color: TxColors.bgChrome,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
        border: Border(top: BorderSide(color: TxColors.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: MouseRegion(
              cursor: isDragging
                  ? SystemMouseCursors.grabbing
                  : SystemMouseCursors.grab,
              child: Listener(
                behavior: HitTestBehavior.opaque,
                onPointerDown: onDragDown,
                onPointerMove: onDragMove,
                onPointerUp: onDragUp,
                onPointerCancel: onDragCancel,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${c.category.title} · $hh:$mm:$ss · 按住顶栏/底栏可任意拖动',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: TxColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          if (c.isLiveInteractive) ...[
            InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () => widget.onSendCommand('q', appendNewline: false),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                child: Text(
                  '发送 q 退出交互视图',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: TxColors.warning,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          if (hasCustomGeometry) ...[
            InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: _resetPositionAndSize,
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  '复位位置',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: TxColors.accent,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
          ],
          InkWell(
            borderRadius: BorderRadius.circular(5),
            onTap: () =>
                setState(() => _showInlineRawCompare = !_showInlineRawCompare),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              child: Text(
                _showInlineRawCompare ? '切回美化内容' : '内联对照原文',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: TxColors.textSecondary,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            'Alt+B 切换',
            style: TextStyle(
              fontSize: 11,
              fontFamily: TxColors.monoFamily,
              color: TxColors.textMuted,
            ),
          ),
        ],
      ),
    );
  }
}

/// 可复用的卡片主体渲染器（内置全分类多维度交互排序引擎）
class BeautyCardBody extends StatefulWidget {
  const BeautyCardBody({
    super.key,
    required this.card,
    this.filterQuery = '',
    this.onCopyValue,
    this.onRunQuickCmd,
  });

  final BeautifiedOutputCard card;
  final String filterQuery;
  final void Function(String value, String label)? onCopyValue;
  final ValueChanged<String>? onRunQuickCmd;

  @override
  State<BeautyCardBody> createState() => _BeautyCardBodyState();
}

class _BeautyCardBodyState extends State<BeautyCardBody> {
  String _sortKey = 'default';
  bool _sortDesc = false;
  double _bodyWidth = 800;

  bool get _isNarrow => _bodyWidth < 460;

  @override
  void didUpdateWidget(covariant BeautyCardBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.card.payload.runtimeType != widget.card.payload.runtimeType) {
      _sortKey = 'default';
      _sortDesc = false;
    }
  }

  void _selectSort(_SortSpec spec) {
    setState(() {
      if (_sortKey == spec.id) {
        _sortDesc = !_sortDesc;
      } else {
        _sortKey = spec.id;
        _sortDesc = spec.defaultDescending;
      }
    });
  }

  bool _matches(Iterable<String> fields) {
    final q = widget.filterQuery.toLowerCase();
    if (q.isEmpty) return true;
    return fields.any((f) => f.toLowerCase().contains(q));
  }

  int _applyDir(int cmp) => _sortDesc ? -cmp : cmp;

  static int _healthRank(SemanticHealth h) => switch (h) {
    SemanticHealth.danger => 0,
    SemanticHealth.warning => 1,
    SemanticHealth.healthy => 2,
    SemanticHealth.info => 3,
    SemanticHealth.neutral => 4,
  };

  static double _parseHumanSize(String raw) {
    final t = raw.trim().replaceAll(',', '');
    if (t.isEmpty || t == '-' || t == '目录') return -1;
    final m = RegExp(
      r'^([\d.]+)\s*([KMGTPkmgtp])?i?[Bb]?\b',
    ).firstMatch(t);
    if (m == null) return double.tryParse(t) ?? 0;
    final v = double.tryParse(m.group(1)!) ?? 0;
    return switch ((m.group(2) ?? '').toUpperCase()) {
      'K' => v * 1024,
      'M' => v * 1048576,
      'G' => v * 1073741824,
      'T' => v * 1099511627776,
      'P' => v * 1125899906842624,
      _ => v,
    };
  }

  static double _parseDurationSec(String raw) {
    final t = raw.trim();
    if (t.isEmpty || t == '-') return 0;
    // MM:SS.xx 或 HH:MM:SS
    final colonParts = t.split(':');
    if (colonParts.length == 2) {
      final m = double.tryParse(colonParts[0]) ?? 0;
      final s = double.tryParse(colonParts[1]) ?? 0;
      return m * 60 + s;
    }
    if (colonParts.length == 3) {
      final h = double.tryParse(colonParts[0]) ?? 0;
      final m = double.tryParse(colonParts[1]) ?? 0;
      final s = double.tryParse(colonParts[2]) ?? 0;
      return h * 3600 + m * 60 + s;
    }
    // K8s 风格: 14d / 35m / 2d4h / 58.9s
    var total = 0.0;
    final matches = RegExp(r'([\d.]+)\s*([dhmsy])', caseSensitive: false)
        .allMatches(t);
    if (matches.isNotEmpty) {
      for (final m in matches) {
        final v = double.tryParse(m.group(1)!) ?? 0;
        total += switch (m.group(2)!.toLowerCase()) {
          'y' => v * 31536000,
          'd' => v * 86400,
          'h' => v * 3600,
          'm' => v * 60,
          _ => v,
        };
      }
      return total;
    }
    return double.tryParse(t.replaceAll(',', '')) ?? 0;
  }

  static int _smartCellCompare(String a, String b) {
    final ta = a.trim();
    final tb = b.trim();
    final na = double.tryParse(ta.replaceAll(',', '').replaceAll('%', ''));
    final nb = double.tryParse(tb.replaceAll(',', '').replaceAll('%', ''));
    if (na != null && nb != null) return na.compareTo(nb);
    if (RegExp(r'^\d+(?:\.\d+)?\s*[KMGTPkmgtp]i?[Bb]?$').hasMatch(ta) &&
        RegExp(r'^\d+(?:\.\d+)?\s*[KMGTPkmgtp]i?[Bb]?$').hasMatch(tb)) {
      return _parseHumanSize(ta).compareTo(_parseHumanSize(tb));
    }
    return ta.toLowerCase().compareTo(tb.toLowerCase());
  }

  Widget _buildSortToolbar(List<_SortSpec> specs, {int totalCount = 0}) {
    if (specs.isEmpty || totalCount < 2) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Icon(Icons.sort_rounded, size: 15, color: TxColors.textMuted),
            const SizedBox(width: 5),
            const Text(
              '排序：',
              style: TextStyle(fontSize: 12, color: TxColors.textMuted),
            ),
            for (final spec in specs)
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: _buildSortChip(spec),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortChip(_SortSpec spec) {
    final active = _sortKey == spec.id;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _selectSort(spec),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: _isNarrow ? 10 : 9,
          vertical: _isNarrow ? 6 : 4.5,
        ),
        decoration: BoxDecoration(
          color: active ? TxColors.accentSoft : TxColors.bgElevated,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: active
                ? TxColors.accent.withValues(alpha: 0.65)
                : TxColors.borderSubtle,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              spec.label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                color: active ? TxColors.textPrimary : TxColors.textSecondary,
              ),
            ),
            if (active && spec.id != 'default') ...[
              const SizedBox(width: 3),
              Icon(
                _sortDesc
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded,
                size: 13,
                color: TxColors.accent,
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth.isFinite && constraints.maxWidth > 0) {
          _bodyWidth = constraints.maxWidth;
        } else {
          _bodyWidth = MediaQuery.sizeOf(context).width;
        }
        final payload = widget.card.payload;
        return switch (payload) {
          DockerContainersPayload(:final containers) =>
            _buildDockerContainers(containers),
          DockerStatsPayload(:final stats) => _buildDockerStats(stats),
          DockerImagesPayload(:final images) => _buildDockerImages(images),
          K8sResourcesPayload(:final items) => _buildK8sPods(items),
          SystemTopPayload() => _buildSystemTop(payload),
          ProcessListPayload() => _buildProcessListPayload(payload),
          DiskUsagePayload(:final mounts) => _buildDiskMounts(mounts),
          DirSizeRankPayload(:final items) => _buildDirSizeRank(items),
          MemoryUsagePayload() => _buildMemoryUsage(payload),
          GpuStatusPayload() => _buildGpuStatus(payload),
          NetworkSocketsPayload(:final sockets) =>
            _buildNetworkSockets(sockets),
          NetworkInterfacesPayload(:final interfaces) =>
            _buildNetworkInterfaces(interfaces),
          PingStatsPayload() => _buildPingStats(payload),
          ServiceStatusPayload() => _buildServiceStatus(payload),
          DirectoryListingPayload() => _buildDirectoryListing(payload),
          GitStatusPayload() => _buildGitStatus(payload),
          GitLogPayload(:final commits) => _buildGitLog(commits),
          SystemInfoPayload(:final facts) => _buildSystemFacts(facts),
          GenericTablePayload(:final columns, :final rows) =>
            _buildGenericTable(columns, rows),
        };
      },
    );
  }

  // -------------------- 1. Docker 容器 --------------------

  Widget _buildDockerContainers(List<ContainerItem> list) {
    final filtered = list
        .where((c) => _matches([c.id, c.name, c.image, c.status, c.ports]))
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'status' => _healthRank(a.health).compareTo(_healthRank(b.health)),
          'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          'image' => a.image.toLowerCase().compareTo(b.image.toLowerCase()),
          'ports' => b.ports.length.compareTo(a.ports.length),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) {
      return _emptyHint(list.isEmpty ? '当前没有匹配的运行容器' : '无匹配的过滤结果');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('status', '运行状态'),
            _SortSpec('name', '容器名称'),
            _SortSpec('image', '镜像名称'),
            _SortSpec('ports', '端口映射'),
          ],
          totalCount: filtered.length,
        ),
        for (final c in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: EdgeInsets.symmetric(
              horizontal: _isNarrow ? 10 : 12,
              vertical: _isNarrow ? 10 : 9,
            ),
            decoration: _rowBoxDecoration(),
            child: _isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _statusDot(c.health),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              c.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                          if (c.id.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            _copyChip(c.id, '容器 ID'),
                          ],
                          if (widget.onRunQuickCmd != null &&
                              (c.name.isNotEmpty || c.id.isNotEmpty)) ...[
                            const SizedBox(width: 6),
                            InkWell(
                              borderRadius: BorderRadius.circular(5),
                              onTap: () => _runDockerLogsFor(c),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: TxColors.bgElevated,
                                  borderRadius: BorderRadius.circular(5),
                                  border: Border.all(
                                    color: TxColors.borderSubtle,
                                  ),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.article_outlined,
                                      size: 13.5,
                                      color: TxColors.accent,
                                    ),
                                    SizedBox(width: 3),
                                    Text(
                                      '日志',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: TxColors.textSecondary,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 5,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          _monoTag(c.image, color: TxColors.accent),
                          Text(
                            c.status,
                            style: TextStyle(
                              fontSize: 12,
                              color: semanticHealthColor(c.health),
                            ),
                          ),
                        ],
                      ),
                      if (c.ports.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 5,
                          runSpacing: 4,
                          children: [
                            for (final p in c.ports.split(',').take(4))
                              _monoTag(p.trim()),
                          ],
                        ),
                      ],
                    ],
                  )
                : Row(
                    children: [
                      _statusDot(c.health),
                      const SizedBox(width: 10),
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    c.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: TxColors.textPrimary,
                                    ),
                                  ),
                                ),
                                if (c.id.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  _copyChip(c.id, '容器 ID'),
                                ],
                              ],
                            ),
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 7,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                _monoTag(c.image, color: TxColors.accent),
                                Text(
                                  c.status,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: semanticHealthColor(c.health),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      if (c.ports.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          flex: 2,
                          child: Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            alignment: WrapAlignment.end,
                            children: [
                              for (final p in c.ports.split(',').take(3))
                                _monoTag(p.trim()),
                            ],
                          ),
                        ),
                      ],
                      if (widget.onRunQuickCmd != null &&
                          (c.name.isNotEmpty || c.id.isNotEmpty)) ...[
                        const SizedBox(width: 6),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 30,
                            minHeight: 30,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '查看容器日志 (docker logs)',
                          icon: const Icon(
                            Icons.article_outlined,
                            size: 16,
                            color: TxColors.iconDefault,
                          ),
                          onPressed: () => _runDockerLogsFor(c),
                        ),
                      ],
                    ],
                  ),
          ),
      ],
    );
  }

  void _runDockerLogsFor(ContainerItem c) {
    final ref = c.name.isNotEmpty ? c.name : c.id;
    final safeRef = RegExp(r'^[A-Za-z0-9_.:-]+$').hasMatch(ref)
        ? ref
        : "'${ref.replaceAll("'", r"'\''")}'";
    widget.onRunQuickCmd?.call('docker logs --tail 50 $safeRef');
  }

  Widget _buildDockerStats(List<ContainerStatItem> stats) {
    final filtered = stats.where((s) => _matches([s.id, s.name])).toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'cpu' => a.cpuPercent.compareTo(b.cpuPercent),
          'memPct' => a.memPercent.compareTo(b.memPercent),
          'memSize' => _parseHumanSize(
            a.memUsage.split('/').first,
          ).compareTo(_parseHumanSize(b.memUsage.split('/').first)),
          'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          'pids' => (int.tryParse(a.pids) ?? 0).compareTo(
            int.tryParse(b.pids) ?? 0,
          ),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('无匹配的容器监控项');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('cpu', 'CPU %', defaultDescending: true),
            _SortSpec('memPct', '内存 %', defaultDescending: true),
            _SortSpec('memSize', '内存用量', defaultDescending: true),
            _SortSpec('pids', 'PIDs 数', defaultDescending: true),
            _SortSpec('name', '容器名'),
          ],
          totalCount: filtered.length,
        ),
        for (final s in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.all(11),
            decoration: _rowBoxDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: TxColors.textPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    _copyChip(s.id, '容器 ID'),
                    if (!_isNarrow) ...[
                      const SizedBox(width: 8),
                      Text(
                        'Net ${s.netIo}  ·  PIDs ${s.pids}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textMuted,
                        ),
                      ),
                    ],
                  ],
                ),
                if (_isNarrow) ...[
                  const SizedBox(height: 4),
                  Text(
                    'Net ${s.netIo}  ·  PIDs ${s.pids}',
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontFamily: TxColors.monoFamily,
                      color: TxColors.textMuted,
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                if (_isNarrow) ...[
                  _metricBarItem(
                    label: 'CPU',
                    valueText: '${s.cpuPercent.toStringAsFixed(1)}%',
                    ratio: (s.cpuPercent / 100.0).clamp(0.0, 1.0),
                  ),
                  const SizedBox(height: 8),
                  _metricBarItem(
                    label: 'MEM (${s.memUsage})',
                    valueText: '${s.memPercent.toStringAsFixed(1)}%',
                    ratio: (s.memPercent / 100.0).clamp(0.0, 1.0),
                  ),
                ] else
                  Row(
                    children: [
                      Expanded(
                        child: _metricBarItem(
                          label: 'CPU',
                          valueText: '${s.cpuPercent.toStringAsFixed(1)}%',
                          ratio: (s.cpuPercent / 100.0).clamp(0.0, 1.0),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: _metricBarItem(
                          label: 'MEM (${s.memUsage})',
                          valueText: '${s.memPercent.toStringAsFixed(1)}%',
                          ratio: (s.memPercent / 100.0).clamp(0.0, 1.0),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDockerImages(List<DockerImageItem> images) {
    final filtered = images
        .where((i) => _matches([i.repository, i.tag, i.imageId, i.size]))
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'size' => _parseHumanSize(a.size).compareTo(_parseHumanSize(b.size)),
          'repo' => a.repository.toLowerCase().compareTo(
            b.repository.toLowerCase(),
          ),
          'tag' => a.tag.toLowerCase().compareTo(b.tag.toLowerCase()),
          'created' => a.created.compareTo(b.created),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('无匹配的镜像');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('size', '镜像体积', defaultDescending: true),
            _SortSpec('repo', '镜像仓库'),
            _SortSpec('tag', '版本标签'),
            _SortSpec('created', '创建时间'),
          ],
          totalCount: filtered.length,
        ),
        for (final img in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: EdgeInsets.symmetric(
              horizontal: _isNarrow ? 10 : 12,
              vertical: _isNarrow ? 9 : 8,
            ),
            decoration: _rowBoxDecoration(),
            child: _isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(
                            Icons.layers_outlined,
                            size: 15.5,
                            color: TxColors.accent,
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              img.repository,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _monoTag(img.size, color: TxColors.accent),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          _monoTag(img.tag),
                          const SizedBox(width: 6),
                          _copyChip(img.imageId, '镜像 ID'),
                          const Spacer(),
                          Flexible(
                            child: Text(
                              img.created,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: TxColors.textMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  )
                : Row(
                    children: [
                      const Icon(
                        Icons.layers_outlined,
                        size: 15.5,
                        color: TxColors.accent,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Wrap(
                          spacing: 7,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              img.repository,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                            _monoTag(img.tag, color: TxColors.accent),
                            _copyChip(img.imageId, '镜像 ID'),
                          ],
                        ),
                      ),
                      Text(
                        img.created,
                        style: const TextStyle(
                          fontSize: 12,
                          color: TxColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 10),
                      _monoTag(img.size),
                    ],
                  ),
          ),
      ],
    );
  }

  // -------------------- 2. Kubernetes Pods --------------------

  Widget _buildK8sPods(List<K8sResourceItem> items) {
    final filtered = items
        .where((i) => _matches([i.namespace, i.name, i.status, i.extra]))
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'health' => _healthRank(a.health).compareTo(_healthRank(b.health)),
          'restarts' => (int.tryParse(a.restarts.split(' ').first) ?? 0)
              .compareTo(int.tryParse(b.restarts.split(' ').first) ?? 0),
          'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          'ns' => a.namespace.toLowerCase().compareTo(
            b.namespace.toLowerCase(),
          ),
          'age' => _parseDurationSec(a.age).compareTo(_parseDurationSec(b.age)),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('无匹配的 Kubernetes 资源');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('health', '异常告警优先'),
            _SortSpec('restarts', '重启次数', defaultDescending: true),
            _SortSpec('name', '资源名称'),
            _SortSpec('ns', '命名空间'),
            _SortSpec('age', '运行时长', defaultDescending: true),
          ],
          totalCount: filtered.length,
        ),
        for (final item in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: EdgeInsets.symmetric(
              horizontal: _isNarrow ? 10 : 12,
              vertical: _isNarrow ? 9 : 8,
            ),
            decoration: _rowBoxDecoration(),
            child: _isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _statusDot(item.health),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontFamily: TxColors.monoFamily,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          _statusPill(item.status, item.health),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (item.namespace.isNotEmpty)
                            _monoTag(item.namespace),
                          if (item.ready.isNotEmpty)
                            _monoTag('Ready ${item.ready}'),
                          if (item.restarts != '0' &&
                              item.restarts.isNotEmpty)
                            _monoTag(
                              '重启 ${item.restarts}',
                              color: TxColors.warning,
                            ),
                          if (item.age.isNotEmpty)
                            Text(
                              item.age,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textMuted,
                              ),
                            ),
                          if (item.extra.isNotEmpty)
                            Text(
                              item.extra,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textMuted,
                              ),
                            ),
                        ],
                      ),
                    ],
                  )
                : Row(
                    children: [
                      _statusDot(item.health),
                      const SizedBox(width: 8),
                      if (item.namespace.isNotEmpty) ...[
                        _monoTag(item.namespace),
                        const SizedBox(width: 8),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontFamily: TxColors.monoFamily,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                            if (item.extra.isNotEmpty)
                              Text(
                                item.extra,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontFamily: TxColors.monoFamily,
                                  color: TxColors.textMuted,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (item.ready.isNotEmpty) ...[
                        _monoTag('Ready ${item.ready}'),
                        const SizedBox(width: 6),
                      ],
                      _statusPill(item.status, item.health),
                      if (item.restarts != '0' && item.restarts.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _monoTag(
                          '重启 ${item.restarts}',
                          color: TxColors.warning,
                        ),
                      ],
                      const SizedBox(width: 8),
                      Text(
                        item.age,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textMuted,
                        ),
                      ),
                    ],
                  ),
          ),
      ],
    );
  }

  // -------------------- 3. top / htop 实时负载 --------------------

  Widget _buildSystemTop(SystemTopPayload top) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _kpiTile(
              title: 'CPU 总负载',
              headline: '${top.cpuBusyPercent.toStringAsFixed(1)}%',
              sub:
                  'us ${top.cpuUser.toStringAsFixed(1)}% · sy ${top.cpuSys.toStringAsFixed(1)}% · wa ${top.cpuWait.toStringAsFixed(1)}%',
              ratio: top.cpuBusyPercent / 100.0,
            ),
            if (top.memTotalMb > 0)
              _kpiTile(
                title: '物理内存',
                headline:
                    '${(top.memUsedMb / 1024).toStringAsFixed(1)} / ${(top.memTotalMb / 1024).toStringAsFixed(1)} GB',
                sub:
                    '缓存 ${(top.memCacheMb / 1024).toStringAsFixed(1)} GB · 占用 ${(top.memRatio * 100).toStringAsFixed(0)}%',
                ratio: top.memRatio,
              ),
            _kpiTile(
              title: 'Load Average & 任务',
              headline: top.loadAverages
                  .map((v) => v.toStringAsFixed(2))
                  .join(' / '),
              sub:
                  '进程 ${top.tasksTotal} (${top.tasksRunning} 运行 · ${top.tasksZombie} 僵尸) · 已运行 ${top.uptimeText}',
            ),
          ],
        ),
        if (top.processes.isNotEmpty) ...[
          const SizedBox(height: 12),
          _buildProcessRows(top.processes, sourceKind: 'top'),
        ],
      ],
    );
  }

  Widget _kpiTile({
    required String title,
    required String headline,
    required String sub,
    double? ratio,
  }) {
    final barColor = ratio == null
        ? TxColors.accent
        : ratio >= 0.88
        ? TxColors.danger
        : ratio >= 0.72
        ? TxColors.warning
        : TxColors.accent;
    final tile = Container(
      width: _isNarrow ? double.infinity : null,
      padding: const EdgeInsets.all(11),
      decoration: _rowBoxDecoration(),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 11.5, color: TxColors.textMuted),
          ),
          const SizedBox(height: 4),
          Text(
            headline,
            style: const TextStyle(
              fontSize: 14.5,
              fontFamily: TxColors.monoFamily,
              fontWeight: FontWeight.w600,
              color: TxColors.textPrimary,
            ),
          ),
          if (ratio != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: ratio.clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: TxColors.borderSubtle,
                valueColor: AlwaysStoppedAnimation<Color>(barColor),
              ),
            ),
          ],
          const SizedBox(height: 5),
          Text(
            sub,
            maxLines: _isNarrow ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              fontFamily: TxColors.monoFamily,
              color: TxColors.textSecondary,
            ),
          ),
        ],
      ),
    );
    if (_isNarrow) return tile;
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 350),
      child: tile,
    );
  }

  // -------------------- 4. 进程排行 (ps / Get-Process / tasklist / pm2) --------------------

  Widget _buildProcessListPayload(ProcessListPayload payload) =>
      _buildProcessRows(payload.processes, sourceKind: payload.sourceKind);

  Widget _buildProcessRows(
    List<ProcessRowItem> list, {
    required String sourceKind,
  }) {
    final isGetProcess = sourceKind == 'Get-Process';
    final filtered = list
        .where((p) => _matches([p.pid, p.user, p.command, p.state]))
        .toList();

    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'cpu' => a.cpuPercent.compareTo(b.cpuPercent),
          'mem' => (a.memoryText.isNotEmpty
                  ? _parseHumanSize(a.memoryText)
                  : a.memPercent)
              .compareTo(
                b.memoryText.isNotEmpty
                    ? _parseHumanSize(b.memoryText)
                    : b.memPercent,
              ),
          'pid' => (int.tryParse(a.pid) ?? 0).compareTo(
            int.tryParse(b.pid) ?? 0,
          ),
          'cmd' => a.command.toLowerCase().compareTo(b.command.toLowerCase()),
          'time' => _parseDurationSec(a.timeText).compareTo(
            _parseDurationSec(b.timeText),
          ),
          'user' => a.user.toLowerCase().compareTo(b.user.toLowerCase()),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }

    final display = filtered.take(60).toList();
    if (display.isEmpty) return _emptyHint('无匹配的进程');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          [
            const _SortSpec('default', '默认'),
            _SortSpec(
              'cpu',
              isGetProcess ? 'CPU 累计秒数' : 'CPU 占用',
              defaultDescending: true,
            ),
            const _SortSpec('mem', '内存占用', defaultDescending: true),
            const _SortSpec('pid', 'PID'),
            const _SortSpec('cmd', '进程名'),
            if (list.any((p) => p.timeText.isNotEmpty && p.timeText != '-'))
              const _SortSpec('time', '运行时长', defaultDescending: true),
            if (list.any((p) => p.user.isNotEmpty))
              const _SortSpec('user', '用户/会话'),
          ],
          totalCount: filtered.length,
        ),
        for (final p in display)
          Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: EdgeInsets.symmetric(
              horizontal: _isNarrow ? 10 : 11,
              vertical: _isNarrow ? 8 : 7,
            ),
            decoration: _rowBoxDecoration(),
            child: _isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              p.command,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontFamily: TxColors.monoFamily,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                          if (p.cpuPercent > 0) ...[
                            const SizedBox(width: 6),
                            _monoTag(
                              isGetProcess
                                  ? '${p.cpuPercent.toStringAsFixed(1)}s'
                                  : 'CPU ${p.cpuPercent.toStringAsFixed(1)}%',
                              color: (!isGetProcess && p.cpuPercent >= 50)
                                  ? TxColors.danger
                                  : (!isGetProcess && p.cpuPercent >= 15)
                                  ? TxColors.warning
                                  : TxColors.accent,
                            ),
                          ],
                          if (p.memoryText.isNotEmpty || p.memPercent > 0) ...[
                            const SizedBox(width: 5),
                            _monoTag(
                              p.memoryText.isNotEmpty
                                  ? p.memoryText
                                  : 'MEM ${p.memPercent.toStringAsFixed(1)}%',
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 5),
                      Row(
                        children: [
                          _copyChip('PID ${p.pid}', 'PID ${p.pid}'),
                          if (p.user.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                p.user,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: TxColors.textMuted,
                                ),
                              ),
                            ),
                          ],
                          if (p.timeText.isNotEmpty && p.timeText != '-') ...[
                            const Spacer(),
                            Text(
                              p.timeText,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  )
                : Row(
                    children: [
                      SizedBox(
                        width: 68,
                        child: _copyChip(p.pid, 'PID ${p.pid}'),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          p.command,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontFamily: TxColors.monoFamily,
                            color: TxColors.textPrimary,
                          ),
                        ),
                      ),
                      if (p.user.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          p.user,
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: TxColors.textMuted,
                          ),
                        ),
                      ],
                      if (p.cpuPercent > 0) ...[
                        const SizedBox(width: 10),
                        _monoTag(
                          isGetProcess
                              ? 'CPU ${p.cpuPercent.toStringAsFixed(1)}s'
                              : 'CPU ${p.cpuPercent.toStringAsFixed(1)}%',
                          color: (!isGetProcess && p.cpuPercent >= 50)
                              ? TxColors.danger
                              : (!isGetProcess && p.cpuPercent >= 15)
                              ? TxColors.warning
                              : TxColors.accent,
                        ),
                      ],
                      if (p.memoryText.isNotEmpty || p.memPercent > 0) ...[
                        const SizedBox(width: 7),
                        _monoTag(
                          p.memoryText.isNotEmpty
                              ? p.memoryText
                              : 'MEM ${p.memPercent.toStringAsFixed(1)}%',
                        ),
                      ],
                    ],
                  ),
          ),
      ],
    );
  }

  // -------------------- 5. 磁盘挂载与目录体积 --------------------

  Widget _buildDiskMounts(List<DiskMountItem> mounts) {
    final filtered = mounts
        .where((m) => _matches([m.filesystem, m.mountPoint, m.fsType]))
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'use' => a.useRatio.compareTo(b.useRatio),
          'size' => _parseHumanSize(a.sizeText).compareTo(
            _parseHumanSize(b.sizeText),
          ),
          'used' => _parseHumanSize(a.usedText).compareTo(
            _parseHumanSize(b.usedText),
          ),
          'avail' => _parseHumanSize(a.availText).compareTo(
            _parseHumanSize(b.availText),
          ),
          'mount' => a.mountPoint.toLowerCase().compareTo(
            b.mountPoint.toLowerCase(),
          ),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('无匹配的挂载分区');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('use', '使用率 %', defaultDescending: true),
            _SortSpec('size', '总容量', defaultDescending: true),
            _SortSpec('used', '已用空间', defaultDescending: true),
            _SortSpec('avail', '可用空间', defaultDescending: true),
            _SortSpec('mount', '挂载点'),
          ],
          totalCount: filtered.length,
        ),
        for (final m in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.all(11),
            decoration: _rowBoxDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isNarrow) ...[
                  Row(
                    children: [
                      const Icon(
                        Icons.storage_rounded,
                        size: 15,
                        color: TxColors.iconDefault,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          m.mountPoint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontFamily: TxColors.monoFamily,
                            fontWeight: FontWeight.w600,
                            color: TxColors.textPrimary,
                          ),
                        ),
                      ),
                      if (m.fsType.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _monoTag(m.fsType),
                      ],
                      const SizedBox(width: 7),
                      Text(
                        '${(m.useRatio * 100).toStringAsFixed(0)}%',
                        style: TextStyle(
                          fontSize: 12.5,
                          fontFamily: TxColors.monoFamily,
                          fontWeight: FontWeight.w700,
                          color: m.useRatio >= 0.9
                              ? TxColors.danger
                              : m.useRatio >= 0.8
                              ? TxColors.warning
                              : TxColors.accent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      if (m.filesystem.isNotEmpty)
                        Expanded(
                          child: Text(
                            m.filesystem,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11,
                              fontFamily: TxColors.monoFamily,
                              color: TxColors.textMuted,
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      Text(
                        '已用 ${m.usedText} / ${m.sizeText} · 余 ${m.availText}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ] else
                  Row(
                    children: [
                      const Icon(
                        Icons.storage_rounded,
                        size: 15,
                        color: TxColors.iconDefault,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          m.mountPoint,
                          style: const TextStyle(
                            fontSize: 13,
                            fontFamily: TxColors.monoFamily,
                            fontWeight: FontWeight.w600,
                            color: TxColors.textPrimary,
                          ),
                        ),
                      ),
                      if (m.fsType.isNotEmpty) ...[
                        _monoTag(m.fsType),
                        const SizedBox(width: 6),
                      ],
                      Text(
                        m.filesystem,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textMuted,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        '已用 ${m.usedText} / ${m.sizeText} (可用 ${m.availText} · ${(m.useRatio * 100).toStringAsFixed(0)}%)',
                        style: TextStyle(
                          fontSize: 12,
                          fontFamily: TxColors.monoFamily,
                          fontWeight: FontWeight.w600,
                          color: m.useRatio >= 0.9
                              ? TxColors.danger
                              : m.useRatio >= 0.8
                              ? TxColors.warning
                              : TxColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: m.useRatio,
                    minHeight: 6,
                    backgroundColor: TxColors.borderSubtle,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      m.useRatio >= 0.9
                          ? TxColors.danger
                          : m.useRatio >= 0.8
                          ? TxColors.warning
                          : TxColors.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildDirSizeRank(List<DirSizeItem> items) {
    final filtered = items.where((i) => _matches([i.path, i.sizeText])).toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'bytes' => a.bytesEstimate.compareTo(b.bytesEstimate),
          'path' => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('无匹配的目录项');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('bytes', '占用大小', defaultDescending: true),
            _SortSpec('path', '目录名称'),
          ],
          totalCount: filtered.length,
        ),
        for (final item in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: _rowBoxDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.folder_rounded,
                      size: 15.5,
                      color: TxColors.folderAmber,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        item.path,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textPrimary,
                        ),
                      ),
                    ),
                    _monoTag(item.sizeText, color: TxColors.accent),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2.5),
                  child: LinearProgressIndicator(
                    value: item.ratioOfMax,
                    minHeight: 4.5,
                    backgroundColor: TxColors.borderSubtle,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      TxColors.accent,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // -------------------- 6. 物理内存与 NVIDIA GPU --------------------

  Widget _buildMemoryUsage(MemoryUsagePayload mem) {
    final freeRatio = (1.0 - mem.ramUsedRatio - mem.ramCacheRatio).clamp(
      0.0,
      1.0,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: _rowBoxDecoration(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 6,
                children: [
                  _legendDot('总内存', mem.ramTotal, TxColors.textPrimary),
                  _legendDot('已使用', mem.ramUsed, TxColors.accent),
                  _legendDot(
                    '缓存 Buff/Cache',
                    mem.ramBuffCache,
                    const Color(0xFF56637A),
                  ),
                  _legendDot('可用 Available', mem.ramAvailable, TxColors.success),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 9,
                  child: Row(
                    children: [
                      Expanded(
                        flex: max(1, (mem.ramUsedRatio * 100).round()),
                        child: Container(color: TxColors.accent),
                      ),
                      if (mem.ramCacheRatio > 0.01)
                        Expanded(
                          flex: max(1, (mem.ramCacheRatio * 100).round()),
                          child: Container(color: const Color(0xFF4B5565)),
                        ),
                      Expanded(
                        flex: max(1, (freeRatio * 100).round()),
                        child: Container(color: TxColors.borderSubtle),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (mem.swapTotal != null) ...[
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: _rowBoxDecoration(),
            child: _metricBarItem(
              label: 'Swap 交换分区 (${mem.swapUsed} / ${mem.swapTotal})',
              valueText: '${(mem.swapUsedRatio * 100).toStringAsFixed(0)}%',
              ratio: mem.swapUsedRatio,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildGpuStatus(GpuStatusPayload gpu) {
    final gpus = List<GpuCardItem>.of(gpu.gpus);
    final procs = List<GpuProcessItem>.of(gpu.processes);
    if (_sortKey != 'default') {
      gpus.sort((a, b) {
        final cmp = switch (_sortKey) {
          'mem' => a.memRatio.compareTo(b.memRatio),
          'util' => a.utilPercent.compareTo(b.utilPercent),
          'temp' => a.tempC.compareTo(b.tempC),
          _ => a.index.compareTo(b.index),
        };
        return _applyDir(cmp);
      });
      procs.sort((a, b) {
        final cmp = switch (_sortKey) {
          'mem' => _parseHumanSize(a.usedMemory).compareTo(
            _parseHumanSize(b.usedMemory),
          ),
          'proc' => a.processName.toLowerCase().compareTo(
            b.processName.toLowerCase(),
          ),
          _ => (int.tryParse(a.pid) ?? 0).compareTo(int.tryParse(b.pid) ?? 0),
        };
        return _applyDir(cmp);
      });
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('mem', '显存占用', defaultDescending: true),
            _SortSpec('util', '算力利用率', defaultDescending: true),
            _SortSpec('temp', '核心温度', defaultDescending: true),
            _SortSpec('proc', '进程名'),
          ],
          totalCount: max(gpus.length, procs.length),
        ),
        for (final g in gpus)
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.all(11),
            decoration: _rowBoxDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_isNarrow) ...[
                  Row(
                    children: [
                      _monoTag('GPU ${g.index}', color: TxColors.success),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          g.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: TxColors.textPrimary,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _monoTag(
                        '${g.tempC}°C',
                        color: g.tempC >= 80
                            ? TxColors.danger
                            : g.tempC >= 68
                            ? TxColors.warning
                            : TxColors.success,
                      ),
                      if (g.powerUsage.isNotEmpty) _monoTag(g.powerUsage),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _metricBarItem(
                    label: '显存 (${g.memUsedMiB} / ${g.memTotalMiB} MiB)',
                    valueText: '${(g.memRatio * 100).toStringAsFixed(0)}%',
                    ratio: g.memRatio,
                  ),
                  const SizedBox(height: 8),
                  _metricBarItem(
                    label: 'GPU 核心算力利用率',
                    valueText: '${g.utilPercent}%',
                    ratio: (g.utilPercent / 100.0).clamp(0.0, 1.0),
                  ),
                ] else ...[
                  Row(
                    children: [
                      _monoTag('GPU ${g.index}', color: TxColors.success),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          g.name,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: TxColors.textPrimary,
                          ),
                        ),
                      ),
                      _monoTag(
                        '${g.tempC}°C',
                        color: g.tempC >= 80
                            ? TxColors.danger
                            : g.tempC >= 68
                            ? TxColors.warning
                            : TxColors.success,
                      ),
                      const SizedBox(width: 6),
                      _monoTag(g.powerUsage),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: _metricBarItem(
                          label: '显存 (${g.memUsedMiB} / ${g.memTotalMiB} MiB)',
                          valueText:
                              '${(g.memRatio * 100).toStringAsFixed(0)}%',
                          ratio: g.memRatio,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _metricBarItem(
                          label: 'GPU 核心算力利用率',
                          valueText: '${g.utilPercent}%',
                          ratio: (g.utilPercent / 100.0).clamp(0.0, 1.0),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        if (procs.isNotEmpty) ...[
          const SizedBox(height: 4),
          for (final p in procs)
            Container(
              margin: const EdgeInsets.only(bottom: 5),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: _rowBoxDecoration(),
              child: Row(
                children: [
                  _monoTag('GPU ${p.gpuIndex}'),
                  const SizedBox(width: 8),
                  _copyChip(p.pid, 'PID ${p.pid}'),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      p.processName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontFamily: TxColors.monoFamily,
                        color: TxColors.textPrimary,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  _monoTag(p.usedMemory, color: TxColors.accent),
                ],
              ),
            ),
        ],
      ],
    );
  }

  // -------------------- 7. 网络端口、网卡地址与 Ping --------------------

  Widget _buildNetworkSockets(List<SocketPortItem> sockets) {
    final filtered = sockets
        .where(
          (s) => _matches([
            s.proto,
            s.state,
            s.localAddress,
            s.localPort,
            s.peerAddress,
            s.process,
          ]),
        )
        .toList();

    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'port' => (int.tryParse(a.localPort) ?? 999999).compareTo(
            int.tryParse(b.localPort) ?? 999999,
          ),
          'state' => a.state.toUpperCase().compareTo(b.state.toUpperCase()),
          'proto' => a.proto.compareTo(b.proto),
          'proc' => a.process.toLowerCase().compareTo(b.process.toLowerCase()),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }

    final display = filtered.take(80).toList();
    if (display.isEmpty) return _emptyHint('无匹配的端口记录');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('port', '端口号'),
            _SortSpec('state', '连接状态'),
            _SortSpec('proto', '协议 (TCP/UDP)'),
            _SortSpec('proc', '所属进程/PID'),
          ],
          totalCount: filtered.length,
        ),
        for (final s in display)
          Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: _rowBoxDecoration(),
            child: _isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _monoTag(s.proto),
                          const SizedBox(width: 6),
                          _statusPill(s.state, s.health),
                          const SizedBox(width: 6),
                          _copyChip(
                            ':${s.localPort}',
                            '端口 ${s.localPort}',
                            accent: true,
                          ),
                          if (s.process.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                s.process,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.right,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: TxColors.monoFamily,
                                  color: TxColors.textPrimary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        '${s.localAddress}:${s.localPort}  →  ${s.peerAddress}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textSecondary,
                        ),
                      ),
                    ],
                  )
                : Row(
                    children: [
                      _monoTag(s.proto),
                      const SizedBox(width: 6),
                      _statusPill(s.state, s.health),
                      const SizedBox(width: 8),
                      _copyChip(
                        ':${s.localPort}',
                        '端口 ${s.localPort}',
                        accent: true,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${s.localAddress}:${s.localPort}  →  ${s.peerAddress}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: TxColors.monoFamily,
                            color: TxColors.textSecondary,
                          ),
                        ),
                      ),
                      if (s.process.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 210),
                          child: Text(
                            s.process,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              fontFamily: TxColors.monoFamily,
                              color: TxColors.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
          ),
      ],
    );
  }

  Widget _buildNetworkInterfaces(List<NetInterfaceItem> list) {
    final filtered = list
        .where(
          (i) => _matches([i.name, ...i.ipv4List, ...i.ipv6List, i.macAddress]),
        )
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'up' => (b.isUp ? 1 : 0).compareTo(a.isUp ? 1 : 0),
          'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          'ipCnt' => (a.ipv4List.length + a.ipv6List.length).compareTo(
            b.ipv4List.length + b.ipv6List.length,
          ),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('无匹配的网络接口');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('up', 'UP 在线优先'),
            _SortSpec('name', '网卡名称'),
            _SortSpec('ipCnt', 'IP 地址数', defaultDescending: true),
          ],
          totalCount: filtered.length,
        ),
        for (final iface in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 7),
            padding: const EdgeInsets.all(11),
            decoration: _rowBoxDecoration(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: _statusDot(
                    iface.isUp
                        ? SemanticHealth.healthy
                        : SemanticHealth.neutral,
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              iface.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 7),
                          _statusPill(
                            iface.isUp ? 'UP' : 'DOWN',
                            iface.isUp
                                ? SemanticHealth.healthy
                                : SemanticHealth.neutral,
                          ),
                          if (!_isNarrow && iface.macAddress.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              'MAC ${iface.macAddress}',
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (iface.ipv4List.isNotEmpty ||
                          iface.ipv6List.isNotEmpty ||
                          iface.gatewayOrMask.isNotEmpty ||
                          (_isNarrow && iface.macAddress.isNotEmpty)) ...[
                        const SizedBox(height: 7),
                        Wrap(
                          spacing: 6,
                          runSpacing: 5,
                          children: [
                            for (final ip in iface.ipv4List)
                              _copyChip(ip, 'IPv4 $ip', accent: true),
                            for (final ip6 in iface.ipv6List.take(2))
                              _monoTag('IPv6 $ip6'),
                            if (iface.gatewayOrMask.isNotEmpty)
                              _monoTag(iface.gatewayOrMask),
                            if (_isNarrow && iface.macAddress.isNotEmpty)
                              _monoTag('MAC ${iface.macAddress}'),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildPingStats(PingStatsPayload ping) {
    final replies = List<PingReplySample>.of(ping.replies);
    if (_sortKey != 'default') {
      replies.sort((a, b) {
        final cmp = switch (_sortKey) {
          'rtt' => a.timeMs.compareTo(b.timeMs),
          'ttl' => (int.tryParse(a.ttl) ?? 0).compareTo(
            int.tryParse(b.ttl) ?? 0,
          ),
          _ => a.seq.compareTo(b.seq),
        };
        return _applyDir(cmp);
      });
    }

    final maxRtt = replies.isEmpty
        ? 100.0
        : max(10.0, replies.map((r) => r.timeMs).reduce(max) * 1.2);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _kpiTile(
              title: '平均往返延迟 (RTT)',
              headline: ping.avgMs != null
                  ? '${ping.avgMs!.toStringAsFixed(2)} ms'
                  : '-',
              sub:
                  '最短 ${ping.minMs?.toStringAsFixed(1) ?? '-'}ms · 最长 ${ping.maxMs?.toStringAsFixed(1) ?? '-'}ms',
            ),
            _kpiTile(
              title: '连通性与丢包率',
              headline: '${ping.lossPercent.toStringAsFixed(1)}% 丢包',
              sub: '已发 ${ping.transmitted} 包 · 已收 ${ping.received} 包',
              ratio: (1.0 - ping.lossPercent / 100.0).clamp(0.0, 1.0),
            ),
          ],
        ),
        if (replies.isNotEmpty) ...[
          const SizedBox(height: 10),
          _buildSortToolbar(
            const [
              _SortSpec('default', '按发包序号'),
              _SortSpec('rtt', '按延迟峰值 (ms)', defaultDescending: true),
              _SortSpec('ttl', '按 TTL'),
            ],
            totalCount: replies.length,
          ),
          Container(
            padding: const EdgeInsets.all(11),
            decoration: _rowBoxDecoration(),
            child: Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                for (final r in replies)
                  Container(
                    width: _isNarrow
                        ? max(124.0, (_bodyWidth - 56) / 2)
                        : 126,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: TxColors.bgChrome,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: TxColors.borderSubtle),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              '#${r.seq}',
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textMuted,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Flexible(
                              child: Text(
                                '${r.timeMs.toStringAsFixed(1)}ms',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontFamily: TxColors.monoFamily,
                                  fontWeight: FontWeight.w600,
                                  color: r.timeMs > 150
                                      ? TxColors.warning
                                      : TxColors.success,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: (r.timeMs / maxRtt).clamp(0.06, 1.0),
                            minHeight: 4,
                            backgroundColor: TxColors.borderSubtle,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              r.timeMs > 150
                                  ? TxColors.warning
                                  : TxColors.success,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // -------------------- 8. 系统服务状态 --------------------

  Widget _buildServiceStatus(ServiceStatusPayload svc) {
    final filtered = svc.services
        .where((s) => _matches([s.name, s.state, s.subState, s.description]))
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'health' => _healthRank(a.health).compareTo(_healthRank(b.health)),
          'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          'desc' => a.description.toLowerCase().compareTo(
            b.description.toLowerCase(),
          ),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    final display = filtered.take(80).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('health', '运行状态'),
            _SortSpec('name', '服务/规则名'),
            _SortSpec('desc', '服务描述'),
          ],
          totalCount: filtered.length,
        ),
        for (final s in display)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: _rowBoxDecoration(),
            child: _isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          _statusDot(s.health),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              s.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12.5,
                                fontFamily: TxColors.monoFamily,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          _statusPill(
                            s.subState.isNotEmpty
                                ? '${s.state} (${s.subState})'
                                : s.state,
                            s.health,
                          ),
                        ],
                      ),
                      if (s.description.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 16),
                          child: Text(
                            s.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: TxColors.textSecondary,
                            ),
                          ),
                        ),
                    ],
                  )
                : Row(
                    children: [
                      _statusDot(s.health),
                      const SizedBox(width: 9),
                      Expanded(
                        flex: 2,
                        child: Text(
                          s.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontFamily: TxColors.monoFamily,
                            fontWeight: FontWeight.w600,
                            color: TxColors.textPrimary,
                          ),
                        ),
                      ),
                      if (s.description.isNotEmpty)
                        Expanded(
                          flex: 3,
                          child: Text(
                            s.description,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 12,
                              color: TxColors.textSecondary,
                            ),
                          ),
                        ),
                      const SizedBox(width: 8),
                      _statusPill(
                        s.subState.isNotEmpty
                            ? '${s.state} (${s.subState})'
                            : s.state,
                        s.health,
                      ),
                    ],
                  ),
          ),
        if (svc.singleUnitDetails.isNotEmpty) ...[
          const SizedBox(height: 5),
          _buildSystemFacts([
            for (final e in svc.singleUnitDetails.entries)
              KeyValueFact(key: e.key, value: e.value),
          ]),
        ],
        if (svc.recentLogs.isNotEmpty) ...[
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.all(10),
            decoration: _rowBoxDecoration(),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '最近服务日志摘要',
                  style: TextStyle(fontSize: 11.5, color: TxColors.textMuted),
                ),
                const SizedBox(height: 5),
                for (final l in svc.recentLogs.take(6))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      l,
                      style: const TextStyle(
                        fontSize: 11.5,
                        fontFamily: TxColors.monoFamily,
                        color: TxColors.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  // -------------------- 9. 目录文件列表 --------------------

  Widget _buildDirectoryListing(DirectoryListingPayload dir) {
    final filtered = dir.entries
        .where((e) => _matches([e.name, e.permissions, e.owner]))
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'type' => (b.isDirectory ? 1 : 0).compareTo(a.isDirectory ? 1 : 0) !=
                  0
              ? (b.isDirectory ? 1 : 0).compareTo(a.isDirectory ? 1 : 0)
              : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          'size' => _parseHumanSize(a.sizeText).compareTo(
            _parseHumanSize(b.sizeText),
          ),
          'name' => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          'date' => a.modifiedText.compareTo(b.modifiedText),
          'perm' => a.permissions.compareTo(b.permissions),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('目录为空或无匹配文件');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认'),
            _SortSpec('type', '文件夹优先'),
            _SortSpec('size', '文件大小', defaultDescending: true),
            _SortSpec('name', '文件名称'),
            _SortSpec('date', '修改时间', defaultDescending: true),
            _SortSpec('perm', '权限模式'),
          ],
          totalCount: filtered.length,
        ),
        for (final f in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
            decoration: _rowBoxDecoration(),
            child: _isNarrow
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            f.isDirectory
                                ? Icons.folder_rounded
                                : f.isSymlink
                                ? Icons.shortcut_rounded
                                : f.isExecutable
                                ? Icons.terminal_rounded
                                : Icons.insert_drive_file_outlined,
                            size: 16,
                            color: f.isDirectory
                                ? TxColors.folderAmber
                                : f.isExecutable
                                ? TxColors.success
                                : TxColors.fileSlate,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              f.linkTarget.isNotEmpty
                                  ? '${f.name} → ${f.linkTarget}'
                                  : f.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontFamily: TxColors.monoFamily,
                                fontWeight: f.isDirectory
                                    ? FontWeight.w600
                                    : FontWeight.w400,
                                color: f.isDirectory
                                    ? TxColors.textPrimary
                                    : f.isExecutable
                                    ? TxColors.success
                                    : TxColors.textPrimary,
                              ),
                            ),
                          ),
                          if (f.sizeText.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              f.sizeText,
                              style: const TextStyle(
                                fontSize: 12,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textSecondary,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (f.permissions.isNotEmpty ||
                          f.owner.isNotEmpty ||
                          f.modifiedText.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4, left: 24),
                          child: Wrap(
                            spacing: 8,
                            runSpacing: 3,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              if (f.octalPerm.isNotEmpty)
                                _monoTag('${f.octalPerm} ${f.permissions}')
                              else if (f.permissions.isNotEmpty)
                                _monoTag(f.permissions),
                              if (f.owner.isNotEmpty)
                                Text(
                                  f.owner,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: TxColors.monoFamily,
                                    color: TxColors.textMuted,
                                  ),
                                ),
                              if (f.modifiedText.isNotEmpty)
                                Text(
                                  f.modifiedText,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontFamily: TxColors.monoFamily,
                                    color: TxColors.textMuted,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  )
                : Row(
                    children: [
                      Icon(
                        f.isDirectory
                            ? Icons.folder_rounded
                            : f.isSymlink
                            ? Icons.shortcut_rounded
                            : f.isExecutable
                            ? Icons.terminal_rounded
                            : Icons.insert_drive_file_outlined,
                        size: 16,
                        color: f.isDirectory
                            ? TxColors.folderAmber
                            : f.isExecutable
                            ? TxColors.success
                            : TxColors.fileSlate,
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                f.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontFamily: TxColors.monoFamily,
                                  fontWeight: f.isDirectory
                                      ? FontWeight.w600
                                      : FontWeight.w400,
                                  color: f.isDirectory
                                      ? TxColors.textPrimary
                                      : f.isExecutable
                                      ? TxColors.success
                                      : TxColors.textPrimary,
                                ),
                              ),
                            ),
                            if (f.linkTarget.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  '→ ${f.linkTarget}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    fontFamily: TxColors.monoFamily,
                                    color: TxColors.textMuted,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (f.octalPerm.isNotEmpty) ...[
                        _monoTag('${f.octalPerm} ${f.permissions}'),
                        const SizedBox(width: 8),
                      ] else if (f.permissions.isNotEmpty) ...[
                        _monoTag(f.permissions),
                        const SizedBox(width: 8),
                      ],
                      if (f.owner.isNotEmpty) ...[
                        Text(
                          f.owner,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: TxColors.monoFamily,
                            color: TxColors.textMuted,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      if (f.modifiedText.isNotEmpty) ...[
                        Text(
                          f.modifiedText,
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: TxColors.monoFamily,
                            color: TxColors.textMuted,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      SizedBox(
                        width: 76,
                        child: Text(
                          f.sizeText,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 12,
                            fontFamily: TxColors.monoFamily,
                            color: TxColors.textSecondary,
                          ),
                        ),
                      ),
                    ],
                  ),
          ),
      ],
    );
  }

  // -------------------- 10. Git 状态与日志 --------------------

  Widget _buildGitStatus(GitStatusPayload git) {
    final filtered = git.changes
        .where((c) => _matches([c.path, c.badgeLabel]))
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'kind' => a.changeKind.compareTo(b.changeKind),
          'path' => a.path.toLowerCase().compareTo(b.path.toLowerCase()),
          'ext' => (a.path.contains('.') ? a.path.split('.').last : '')
              .toLowerCase()
              .compareTo(
                (b.path.contains('.') ? b.path.split('.').last : '')
                    .toLowerCase(),
              ),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: _rowBoxDecoration(),
          child: Row(
            children: [
              const Icon(
                Icons.call_split_rounded,
                size: 15.5,
                color: TxColors.accent,
              ),
              const SizedBox(width: 7),
              _monoTag('分支 ${git.branch}', color: TxColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  git.syncSummary.isNotEmpty
                      ? git.syncSummary
                      : (git.isClean ? '工作区干净，无未提交变更' : '存在本地变更'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: TxColors.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (filtered.isNotEmpty) ...[
          const SizedBox(height: 8),
          _buildSortToolbar(
            const [
              _SortSpec('default', '默认分组'),
              _SortSpec('kind', '变更状态'),
              _SortSpec('path', '文件路径'),
              _SortSpec('ext', '扩展名'),
            ],
            totalCount: filtered.length,
          ),
          for (final item in filtered)
            Container(
              margin: const EdgeInsets.only(bottom: 5),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
              decoration: _rowBoxDecoration(),
              child: Row(
                children: [
                  _statusPill(item.badgeLabel, item.health),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      item.path,
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontFamily: TxColors.monoFamily,
                        color: TxColors.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildGitLog(List<GitCommitItem> commits) {
    final indexed = [
      for (var i = 0; i < commits.length; i++) (idx: i, item: commits[i]),
    ];
    final filtered = indexed
        .where(
          (e) => _matches([
            e.item.hash,
            e.item.refs,
            e.item.message,
            e.item.author,
          ]),
        )
        .toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'order' => a.idx.compareTo(b.idx),
          'author' => a.item.author.toLowerCase().compareTo(
            b.item.author.toLowerCase(),
          ),
          'msg' => a.item.message.toLowerCase().compareTo(
            b.item.message.toLowerCase(),
          ),
          'hash' => a.item.hash.compareTo(b.item.hash),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('无匹配的提交记录');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '最新优先'),
            _SortSpec('order', '时间顺序', defaultDescending: true),
            _SortSpec('author', '提交作者'),
            _SortSpec('msg', '提交信息'),
            _SortSpec('hash', 'Hash'),
          ],
          totalCount: filtered.length,
        ),
        for (final entry in filtered)
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: _rowBoxDecoration(),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _copyChip(
                  entry.item.hash,
                  'Commit ${entry.item.hash}',
                  accent: true,
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (entry.item.refs.isNotEmpty)
                            _monoTag(entry.item.refs, color: TxColors.success),
                          Text(
                            entry.item.message,
                            style: const TextStyle(
                              fontSize: 12.5,
                              color: TxColors.textPrimary,
                            ),
                          ),
                        ],
                      ),
                      if (entry.item.author.isNotEmpty ||
                          entry.item.date.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          [entry.item.author, entry.item.date]
                              .where((s) => s.isNotEmpty)
                              .join('  ·  '),
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: TxColors.textMuted,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  // -------------------- 11. 系统键值信息与通用对齐表格 --------------------

  Widget _buildSystemFacts(List<KeyValueFact> facts) {
    final filtered = facts.where((f) => _matches([f.key, f.value])).toList();
    if (_sortKey != 'default') {
      filtered.sort((a, b) {
        final cmp = switch (_sortKey) {
          'key' => a.key.toLowerCase().compareTo(b.key.toLowerCase()),
          'val' => a.value.toLowerCase().compareTo(b.value.toLowerCase()),
          _ => 0,
        };
        return _applyDir(cmp);
      });
    }
    if (filtered.isEmpty) return _emptyHint('无匹配的指标项');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(
          const [
            _SortSpec('default', '默认顺序'),
            _SortSpec('key', '属性名称'),
            _SortSpec('val', '属性值'),
          ],
          totalCount: filtered.length,
        ),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            for (final f in filtered)
              Container(
                width: _isNarrow ? double.infinity : null,
                constraints: _isNarrow
                    ? null
                    : const BoxConstraints(minWidth: 200, maxWidth: 440),
                padding: const EdgeInsets.symmetric(
                  horizontal: 11,
                  vertical: 8,
                ),
                decoration: _rowBoxDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.key,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: TxColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      f.value,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontFamily: TxColors.monoFamily,
                        fontWeight: FontWeight.w500,
                        color: f.highlight != null
                            ? semanticHealthColor(f.highlight!)
                            : TxColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildGenericTable(List<String> columns, List<List<String>> rows) {
    final filtered = rows.where((r) => _matches(r)).toList();
    if (_sortKey.startsWith('col_')) {
      final colIdx = int.tryParse(_sortKey.substring(4)) ?? 0;
      filtered.sort((a, b) {
        final va = colIdx < a.length ? a[colIdx] : '';
        final vb = colIdx < b.length ? b[colIdx] : '';
        return _applyDir(_smartCellCompare(va, vb));
      });
    }
    final display = filtered.take(100).toList();
    if (display.isEmpty) return _emptyHint('无匹配的表格行');

    final specs = <_SortSpec>[
      const _SortSpec('default', '默认'),
      for (var i = 0; i < columns.length; i++) _SortSpec('col_$i', columns[i]),
    ];

    final tableBox = Container(
      decoration: _rowBoxDecoration(),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 11,
              vertical: 8,
            ),
            decoration: const BoxDecoration(
              color: TxColors.bgChrome,
              borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
              border: Border(
                bottom: BorderSide(color: TxColors.borderSubtle),
              ),
            ),
            child: Row(
              children: [
                for (var cIdx = 0; cIdx < columns.length; cIdx++)
                  Expanded(
                    child: InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () =>
                          _selectSort(_SortSpec('col_$cIdx', columns[cIdx])),
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              columns[cIdx],
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                fontFamily: TxColors.monoFamily,
                                color: _sortKey == 'col_$cIdx'
                                    ? TxColors.accent
                                    : TxColors.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 3),
                          Icon(
                            _sortKey == 'col_$cIdx'
                                ? (_sortDesc
                                      ? Icons.arrow_downward_rounded
                                      : Icons.arrow_upward_rounded)
                                : Icons.unfold_more_rounded,
                            size: 13,
                            color: _sortKey == 'col_$cIdx'
                                ? TxColors.accent
                                : TxColors.textMuted,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          for (var i = 0; i < display.length; i++)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 11,
                vertical: 7,
              ),
              decoration: BoxDecoration(
                border: i + 1 < display.length
                    ? const Border(
                        bottom: BorderSide(color: TxColors.borderSubtle),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  for (var cIdx = 0; cIdx < columns.length; cIdx++)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: Text(
                          cIdx < display[i].length ? display[i][cIdx] : '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontFamily: TxColors.monoFamily,
                            color: cIdx == 0
                                ? TxColors.textPrimary
                                : TxColors.textSecondary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSortToolbar(specs, totalCount: filtered.length),
        if (_isNarrow && columns.length >= 4)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: max(_bodyWidth, columns.length * 108.0),
              child: tableBox,
            ),
          )
        else
          tableBox,
      ],
    );
  }

  // -------------------- 原子 UI 组件 --------------------

  BoxDecoration _rowBoxDecoration() => BoxDecoration(
    color: TxColors.bgPanel,
    borderRadius: BorderRadius.circular(7),
    border: Border.all(color: TxColors.borderSubtle),
  );

  Widget _statusDot(SemanticHealth h) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: semanticHealthColor(h),
      shape: BoxShape.circle,
    ),
  );

  Widget _statusPill(String text, SemanticHealth h) {
    final c = semanticHealthColor(h);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: c.withValues(alpha: 0.36)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontFamily: TxColors.monoFamily,
          fontWeight: FontWeight.w600,
          color: h == SemanticHealth.neutral ? TxColors.textSecondary : c,
        ),
      ),
    );
  }

  Widget _monoTag(String text, {Color? color}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
    decoration: BoxDecoration(
      color: TxColors.bgElevated,
      borderRadius: BorderRadius.circular(5),
      border: Border.all(color: TxColors.borderSubtle),
    ),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontFamily: TxColors.monoFamily,
        color: color ?? TxColors.textSecondary,
      ),
    ),
  );

  Widget _copyChip(String value, String label, {bool accent = false}) {
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: widget.onCopyValue != null
          ? () => widget.onCopyValue!(value, label)
          : null,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: _isNarrow ? 8 : 7,
          vertical: _isNarrow ? 3.5 : 2.5,
        ),
        decoration: BoxDecoration(
          color: accent ? TxColors.accentSoft : TxColors.bgChrome,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: accent
                ? TxColors.accent.withValues(alpha: 0.5)
                : TxColors.borderSubtle,
          ),
        ),
        child: Text(
          value,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 11.5,
            fontFamily: TxColors.monoFamily,
            color: accent ? TxColors.accent : TxColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _metricBarItem({
    required String label,
    required String valueText,
    required double ratio,
  }) {
    final c = ratio >= 0.88
        ? TxColors.danger
        : ratio >= 0.72
        ? TxColors.warning
        : TxColors.accent;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: TxColors.monoFamily,
                  color: TxColors.textSecondary,
                ),
              ),
            ),
            Text(
              valueText,
              style: TextStyle(
                fontSize: 11.5,
                fontFamily: TxColors.monoFamily,
                fontWeight: FontWeight.w600,
                color: c,
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: ratio.clamp(0.0, 1.0),
            minHeight: 5,
            backgroundColor: TxColors.borderSubtle,
            valueColor: AlwaysStoppedAnimation<Color>(c),
          ),
        ),
      ],
    );
  }

  Widget _legendDot(String label, String val, Color dotColor) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
      ),
      const SizedBox(width: 5),
      Text(
        '$label ',
        style: const TextStyle(fontSize: 12, color: TxColors.textMuted),
      ),
      Text(
        val,
        style: const TextStyle(
          fontSize: 12,
          fontFamily: TxColors.monoFamily,
          fontWeight: FontWeight.w600,
          color: TxColors.textPrimary,
        ),
      ),
    ],
  );

  Widget _emptyHint(String text) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 16),
    child: Center(
      child: Text(
        text,
        style: const TextStyle(fontSize: 12.5, color: TxColors.textMuted),
      ),
    ),
  );
}
