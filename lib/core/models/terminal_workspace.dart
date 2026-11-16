import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../ssh/ssh_session_controller.dart';
import 'host_config.dart';

/// 拖拽分屏停靠方位
enum SplitDockPosition {
  left,
  right,
  top,
  bottom;

  Axis get axis => switch (this) {
    SplitDockPosition.left || SplitDockPosition.right => Axis.horizontal,
    SplitDockPosition.top || SplitDockPosition.bottom => Axis.vertical,
  };

  bool get insertFirst => switch (this) {
    SplitDockPosition.left || SplitDockPosition.top => true,
    SplitDockPosition.right || SplitDockPosition.bottom => false,
  };

  String get label => switch (this) {
    SplitDockPosition.left => '向左分屏',
    SplitDockPosition.right => '向右分屏',
    SplitDockPosition.top => '向上分屏',
    SplitDockPosition.bottom => '向下分屏',
  };
}

/// 跨标签 / 窗格 / 主机侧边栏的分屏拖拽载荷
sealed class PaneDockPayload {
  const PaneDockPayload();
}

/// 从顶部标签栏拖出的整个会话标签
class TabDockPayload extends PaneDockPayload {
  const TabDockPayload(this.tab);
  final TerminalTab tab;
}

/// 从分屏窗格标题栏拖出的单个终端窗格
class PaneItemDockPayload extends PaneDockPayload {
  const PaneItemDockPayload(this.tab, this.paneId);
  final TerminalTab tab;
  final String paneId;
}

/// 从左侧服务器列表拖出的主机配置
class HostDockPayload extends PaneDockPayload {
  const HostDockPayload(this.host);
  final HostConfig host;
}

sealed class PaneLayout {
  List<String> get paneIds;
  PaneLayout replace(String id, PaneLayout replacement);
  PaneLayout? remove(String id);
}

class PaneLeaf extends PaneLayout {
  PaneLeaf(this.id);
  final String id;
  @override
  List<String> get paneIds => [id];
  @override
  PaneLayout replace(String id, PaneLayout replacement) =>
      this.id == id ? replacement : this;
  @override
  PaneLayout? remove(String id) => this.id == id ? null : this;
}

class PaneSplit extends PaneLayout {
  PaneSplit(this.axis, this.first, this.second);
  final Axis axis;
  PaneLayout first;
  PaneLayout second;
  double ratio = 0.5;
  @override
  List<String> get paneIds => [...first.paneIds, ...second.paneIds];
  @override
  PaneLayout replace(String id, PaneLayout replacement) {
    first = first.replace(id, replacement);
    second = second.replace(id, replacement);
    return this;
  }

  @override
  PaneLayout? remove(String id) {
    final a = first.remove(id);
    final b = second.remove(id);
    if (a == null) return b;
    if (b == null) return a;
    first = a;
    second = b;
    return this;
  }
}

class TerminalPane {
  TerminalPane(this.session) : id = session.sessionId;
  final String id;
  final SshSessionController session;
  final FocusNode focus = FocusNode();
  final TerminalController controller = TerminalController();
  final ScrollController scroll = ScrollController();
  double fontSize = 13.5;
  bool disposed = false;

  void dispose() {
    disposed = true;
    session.dispose();
    focus.dispose();
    controller.dispose();
    scroll.dispose();
  }
}

class TerminalTab {
  TerminalTab(TerminalPane pane, {String? id, this.customColor})
    : id = id ?? pane.id,
      root = PaneLeaf(pane.id),
      focusedPaneId = pane.id;
  final String id;
  PaneLayout root;
  String focusedPaneId;
  String? customTitle;
  Color? customColor;
  String? maximizedPaneId;
}

/// Tabs own split trees; every leaf owns exactly one independent session.
class TerminalWorkspace extends ChangeNotifier {
  final List<TerminalTab> tabs = [];
  final Map<String, TerminalPane> panes = {};
  String? _activeTabId;
  int _sequence = 0;

  String _nextTabId() =>
      'tab_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}';

  TerminalTab? get activeTab =>
      tabs.where((t) => t.id == _activeTabId).firstOrNull;
  TerminalPane? get activePane => panes[activeTab?.focusedPaneId];

  String title(TerminalTab tab) {
    if (tab.customTitle != null) return tab.customTitle!;
    final names = <String>[];
    for (final id in tab.root.paneIds) {
      final hostName = panes[id]?.session.host.name;
      if (hostName != null && !names.contains(hostName)) {
        names.add(hostName);
      }
    }
    if (names.isEmpty) return 'Terminal';
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} · ${names[1]}';
    return '${names[0]} · ${names[1]} …';
  }

  static PaneLayout _insertAroundPane(
    PaneLayout root,
    String targetPaneId,
    PaneLayout inserted,
    SplitDockPosition position,
  ) {
    final targetLeaf = PaneLeaf(targetPaneId);
    final split = position.insertFirst
        ? PaneSplit(position.axis, inserted, targetLeaf)
        : PaneSplit(position.axis, targetLeaf, inserted);
    return root.replace(targetPaneId, split);
  }

  TerminalPane _create(HostConfig host) {
    final pane = TerminalPane(
      SshSessionController(
        sessionId:
            'sess_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
        host: host,
      ),
    );
    panes[pane.id] = pane;
    return pane;
  }

  TerminalPane open(HostConfig host) {
    final pane = _create(host);
    final tab = TerminalTab(
      pane,
      id: _nextTabId(),
      customColor: host.tabColorValue != null
          ? Color(host.tabColorValue!)
          : null,
    );
    tabs.add(tab);
    _activeTabId = tab.id;
    notifyListeners();
    return pane;
  }

  void activate(TerminalTab tab, [String? paneId]) {
    if (!tabs.contains(tab)) return;
    final nextPaneId = paneId != null && tab.root.paneIds.contains(paneId)
        ? paneId
        : tab.focusedPaneId;
    // Pointer-down and accessibility taps may target the same tab in one click.
    if (_activeTabId == tab.id && tab.focusedPaneId == nextPaneId) return;
    _activeTabId = tab.id;
    if (paneId != null && tab.root.paneIds.contains(paneId)) {
      tab.focusedPaneId = paneId;
    }
    notifyListeners();
  }

  TerminalPane splitAt(
    TerminalTab tab,
    String paneId,
    SplitDockPosition position, {
    HostConfig? host,
  }) {
    final pane = _create(host ?? panes[paneId]!.session.host);
    tab.root = _insertAroundPane(
      tab.root,
      paneId,
      PaneLeaf(pane.id),
      position,
    );
    tab.maximizedPaneId = null;
    _activeTabId = tab.id;
    tab.focusedPaneId = pane.id;
    notifyListeners();
    return pane;
  }

  TerminalPane split(TerminalTab tab, String paneId, Axis axis) => splitAt(
    tab,
    paneId,
    axis == Axis.horizontal
        ? SplitDockPosition.right
        : SplitDockPosition.bottom,
  );

  /// 将整个 `sourceTab` 无损停靠合并到 `targetTab` 的指定窗格一侧（不中断 SSH / PTY 会话）
  bool dockTabIntoPane({
    required TerminalTab sourceTab,
    required TerminalTab targetTab,
    required String targetPaneId,
    required SplitDockPosition position,
  }) {
    if (sourceTab == targetTab) return false;
    if (!tabs.contains(sourceTab) || !tabs.contains(targetTab)) return false;
    if (!targetTab.root.paneIds.contains(targetPaneId)) return false;

    tabs.remove(sourceTab);
    targetTab.root = _insertAroundPane(
      targetTab.root,
      targetPaneId,
      sourceTab.root,
      position,
    );
    targetTab.maximizedPaneId = null;
    targetTab.focusedPaneId = sourceTab.focusedPaneId;
    _activeTabId = targetTab.id;
    notifyListeners();
    return true;
  }

  /// 将单个窗格在同标签分屏间移动重排（如右移到左、左右改上下）或跨标签停靠
  bool movePaneToSplit({
    required TerminalTab sourceTab,
    required String sourcePaneId,
    required TerminalTab targetTab,
    required String targetPaneId,
    required SplitDockPosition position,
  }) {
    if (!tabs.contains(sourceTab) || !tabs.contains(targetTab)) return false;
    if (!sourceTab.root.paneIds.contains(sourcePaneId)) return false;
    if (!targetTab.root.paneIds.contains(targetPaneId)) return false;
    if (sourceTab == targetTab && sourcePaneId == targetPaneId) return false;

    if (sourceTab == targetTab) {
      final withoutSource = sourceTab.root.remove(sourcePaneId);
      if (withoutSource == null) return false;
      sourceTab.root = _insertAroundPane(
        withoutSource,
        targetPaneId,
        PaneLeaf(sourcePaneId),
        position,
      );
      sourceTab.maximizedPaneId = null;
      sourceTab.focusedPaneId = sourcePaneId;
      _activeTabId = sourceTab.id;
      notifyListeners();
      return true;
    }

    if (sourceTab.root.paneIds.length == 1) {
      return dockTabIntoPane(
        sourceTab: sourceTab,
        targetTab: targetTab,
        targetPaneId: targetPaneId,
        position: position,
      );
    }

    sourceTab.root = sourceTab.root.remove(sourcePaneId)!;
    if (sourceTab.focusedPaneId == sourcePaneId) {
      sourceTab.focusedPaneId = sourceTab.root.paneIds.first;
    }
    if (sourceTab.maximizedPaneId == sourcePaneId) {
      sourceTab.maximizedPaneId = null;
    }

    targetTab.root = _insertAroundPane(
      targetTab.root,
      targetPaneId,
      PaneLeaf(sourcePaneId),
      position,
    );
    targetTab.maximizedPaneId = null;
    targetTab.focusedPaneId = sourcePaneId;
    _activeTabId = targetTab.id;
    notifyListeners();
    return true;
  }

  /// 将分屏中的某个窗格拖回顶部标签栏，拆分为独立标签（不中断会话）
  TerminalTab? detachPaneToNewTab(
    TerminalTab sourceTab,
    String paneId, {
    int? insertIndex,
  }) {
    if (!tabs.contains(sourceTab)) return null;
    if (!sourceTab.root.paneIds.contains(paneId)) return null;
    if (sourceTab.root.paneIds.length <= 1) return null;

    final pane = panes[paneId];
    if (pane == null) return null;

    sourceTab.root = sourceTab.root.remove(paneId)!;
    if (sourceTab.focusedPaneId == paneId) {
      sourceTab.focusedPaneId = sourceTab.root.paneIds.first;
    }
    if (sourceTab.maximizedPaneId == paneId) {
      sourceTab.maximizedPaneId = null;
    }

    final newTab = TerminalTab(
      pane,
      id: _nextTabId(),
      customColor: pane.session.host.tabColorValue != null
          ? Color(pane.session.host.tabColorValue!)
          : null,
    );
    final srcIdx = tabs.indexOf(sourceTab);
    final targetIdx = (insertIndex ?? (srcIdx + 1)).clamp(0, tabs.length);
    tabs.insert(targetIdx, newTab);
    _activeTabId = newTab.id;
    notifyListeners();
    return newTab;
  }

  TerminalPane restart(TerminalTab tab, String paneId) {
    final old = panes[paneId]!;
    final replacement = _create(old.session.host);
    replacement.fontSize = old.fontSize;
    tab.root = tab.root.replace(paneId, PaneLeaf(replacement.id));
    if (tab.maximizedPaneId == paneId) tab.maximizedPaneId = replacement.id;
    panes.remove(paneId);
    old.dispose();
    activate(tab, replacement.id);
    return replacement;
  }

  void closePane(TerminalTab tab, String paneId) {
    if (!tab.root.paneIds.contains(paneId)) return;
    if (tab.root.paneIds.length == 1) {
      closeTab(tab);
      return;
    }
    tab.root = tab.root.remove(paneId)!;
    panes.remove(paneId)?.dispose();
    if (tab.focusedPaneId == paneId) tab.focusedPaneId = tab.root.paneIds.first;
    if (tab.maximizedPaneId == paneId) tab.maximizedPaneId = null;
    notifyListeners();
  }

  void closeTab(TerminalTab tab) {
    final index = tabs.indexOf(tab);
    if (index < 0) return;
    tabs.removeAt(index);
    for (final id in tab.root.paneIds) {
      panes.remove(id)?.dispose();
    }
    if (_activeTabId == tab.id) {
      _activeTabId = tabs.isEmpty
          ? null
          : tabs[index.clamp(0, tabs.length - 1)].id;
    }
    notifyListeners();
  }

  void closeOthers(TerminalTab tab, {bool onlyRight = false}) {
    final index = tabs.indexOf(tab);
    for (final other in List<TerminalTab>.of(tabs)) {
      if (other != tab &&
          (!onlyRight || tabs.indexOf(other) > tabs.indexOf(tab))) {
        closeTab(other);
      }
    }
    if (index >= 0) activate(tab);
  }

  void reorder(int oldIndex, int newIndex) {
    final active = _activeTabId;
    if (newIndex > oldIndex) newIndex--;
    tabs.insert(newIndex, tabs.removeAt(oldIndex));
    _activeTabId = active;
    notifyListeners();
  }

  void rename(TerminalTab tab, String title) {
    tab.customTitle = title.trim().isEmpty ? null : title.trim();
    notifyListeners();
  }

  void setTabColor(TerminalTab tab, Color? color) {
    if (!tabs.contains(tab)) return;
    tab.customColor = color;
    notifyListeners();
  }

  void toggleMaximize(TerminalTab tab, String paneId) {
    tab.maximizedPaneId = tab.maximizedPaneId == paneId ? null : paneId;
    _activeTabId = tab.id;
    tab.focusedPaneId = paneId;
    notifyListeners();
  }

  /// 捕获当前所有打开的会话标签、嵌套分屏树、分屏比例、字号与焦点状态快照
  WorkspaceLayoutSnapshot captureSnapshot() {
    final tabSnapshots = <WorkspaceTabSnapshot>[];
    var activeIdx = 0;
    for (var i = 0; i < tabs.length; i++) {
      final tab = tabs[i];
      if (tab.id == _activeTabId) {
        activeIdx = tabSnapshots.length;
      }
      final rootSnap = _captureLayoutNode(
        tab.root,
        focusedPaneId: tab.focusedPaneId,
        maximizedPaneId: tab.maximizedPaneId,
      );
      if (rootSnap != null) {
        tabSnapshots.add(
          WorkspaceTabSnapshot(
            root: rootSnap,
            customTitle: tab.customTitle,
            customColorValue: tab.customColor?.toARGB32(),
          ),
        );
      }
    }
    return WorkspaceLayoutSnapshot(
      tabs: tabSnapshots,
      activeTabIndex: tabSnapshots.isEmpty
          ? 0
          : activeIdx.clamp(0, tabSnapshots.length - 1),
    );
  }

  WorkspacePaneNodeSnapshot? _captureLayoutNode(
    PaneLayout layout, {
    required String focusedPaneId,
    required String? maximizedPaneId,
  }) {
    switch (layout) {
      case PaneLeaf(:final id):
        final pane = panes[id];
        if (pane == null) return null;
        return WorkspacePaneLeafSnapshot(
          hostId: pane.session.host.id,
          fontSize: pane.fontSize,
          isFocused: id == focusedPaneId,
          isMaximized: id == maximizedPaneId,
        );
      case PaneSplit(:final axis, :final ratio, :final first, :final second):
        final firstSnap = _captureLayoutNode(
          first,
          focusedPaneId: focusedPaneId,
          maximizedPaneId: maximizedPaneId,
        );
        final secondSnap = _captureLayoutNode(
          second,
          focusedPaneId: focusedPaneId,
          maximizedPaneId: maximizedPaneId,
        );
        if (firstSnap == null) return secondSnap;
        if (secondSnap == null) return firstSnap;
        return WorkspacePaneSplitSnapshot(
          axis: axis,
          ratio: ratio,
          first: firstSnap,
          second: secondSnap,
        );
    }
  }

  /// 从持久化快照一键还原多标签与嵌套分屏布局，返回新建的所有 [TerminalPane] 以供并发建连
  List<TerminalPane> restoreFromSnapshot(
    WorkspaceLayoutSnapshot snapshot,
    HostConfig? Function(String hostId) resolveHost,
  ) {
    final createdPanes = <TerminalPane>[];
    final restoredTabs = <TerminalTab>[];

    for (final tabSnap in snapshot.tabs) {
      String? focusedId;
      String? maximizedId;

      PaneLayout? buildNode(WorkspacePaneNodeSnapshot node) {
        switch (node) {
          case WorkspacePaneLeafSnapshot(
            :final hostId,
            :final fontSize,
            :final isFocused,
            :final isMaximized,
          ):
            final host = resolveHost(hostId);
            if (host == null) return null;
            final pane = _create(host);
            pane.fontSize = fontSize.clamp(8.0, 32.0);
            createdPanes.add(pane);
            if (isFocused) focusedId = pane.id;
            if (isMaximized) maximizedId = pane.id;
            return PaneLeaf(pane.id);

          case WorkspacePaneSplitSnapshot(
            :final axis,
            :final ratio,
            :final first,
            :final second,
          ):
            final leftLayout = buildNode(first);
            final rightLayout = buildNode(second);
            if (leftLayout == null) return rightLayout;
            if (rightLayout == null) return leftLayout;
            final split = PaneSplit(axis, leftLayout, rightLayout)
              ..ratio = ratio.clamp(0.15, 0.85);
            return split;
        }
      }

      final rootLayout = buildNode(tabSnap.root);
      if (rootLayout == null || rootLayout.paneIds.isEmpty) continue;
      final firstPane = panes[rootLayout.paneIds.first]!;
      final tab = TerminalTab(
        firstPane,
        id: _nextTabId(),
        customColor: tabSnap.customColorValue != null
            ? Color(tabSnap.customColorValue!)
            : (firstPane.session.host.tabColorValue != null
                  ? Color(firstPane.session.host.tabColorValue!)
                  : null),
      )
        ..root = rootLayout
        ..customTitle = tabSnap.customTitle
        ..focusedPaneId =
            (focusedId != null && rootLayout.paneIds.contains(focusedId))
            ? focusedId!
            : rootLayout.paneIds.first
        ..maximizedPaneId =
            (maximizedId != null && rootLayout.paneIds.contains(maximizedId))
            ? maximizedId
            : null;
      restoredTabs.add(tab);
    }

    if (restoredTabs.isEmpty) {
      return const [];
    }

    tabs.addAll(restoredTabs);
    final activeIndex = snapshot.activeTabIndex.clamp(
      0,
      restoredTabs.length - 1,
    );
    _activeTabId = restoredTabs[activeIndex].id;
    notifyListeners();
    return createdPanes;
  }

  @override
  void dispose() {
    for (final pane in panes.values) {
      pane.dispose();
    }
    super.dispose();
  }
}

/// 工作区完整标签与分屏树持久化快照
class WorkspaceLayoutSnapshot {
  const WorkspaceLayoutSnapshot({
    required this.tabs,
    this.activeTabIndex = 0,
  });

  final List<WorkspaceTabSnapshot> tabs;
  final int activeTabIndex;

  Map<String, dynamic> toJson() => {
    'activeTabIndex': activeTabIndex,
    'tabs': [for (final t in tabs) t.toJson()],
  };

  factory WorkspaceLayoutSnapshot.fromJson(Map<String, dynamic> json) {
    final rawTabs = json['tabs'];
    final parsedTabs = <WorkspaceTabSnapshot>[];
    if (rawTabs is List) {
      for (final item in rawTabs) {
        if (item is Map) {
          final snap = WorkspaceTabSnapshot.tryFromJson(
            item.cast<String, dynamic>(),
          );
          if (snap != null) parsedTabs.add(snap);
        }
      }
    }
    final activeIdx = (json['activeTabIndex'] as num?)?.toInt() ?? 0;
    return WorkspaceLayoutSnapshot(
      tabs: parsedTabs,
      activeTabIndex: parsedTabs.isEmpty
          ? 0
          : activeIdx.clamp(0, parsedTabs.length - 1),
    );
  }
}

class WorkspaceTabSnapshot {
  const WorkspaceTabSnapshot({
    required this.root,
    this.customTitle,
    this.customColorValue,
  });

  final WorkspacePaneNodeSnapshot root;
  final String? customTitle;
  final int? customColorValue;

  Map<String, dynamic> toJson() => {
    'root': root.toJson(),
    if (customTitle != null && customTitle!.isNotEmpty)
      'customTitle': customTitle,
    if (customColorValue != null) 'customColorValue': customColorValue,
  };

  static WorkspaceTabSnapshot? tryFromJson(Map<String, dynamic> json) {
    final rawRoot = json['root'];
    if (rawRoot is! Map) return null;
    final root = WorkspacePaneNodeSnapshot.tryFromJson(
      rawRoot.cast<String, dynamic>(),
    );
    if (root == null) return null;
    return WorkspaceTabSnapshot(
      root: root,
      customTitle: json['customTitle'] as String?,
      customColorValue: (json['customColorValue'] as num?)?.toInt(),
    );
  }
}

sealed class WorkspacePaneNodeSnapshot {
  const WorkspacePaneNodeSnapshot();

  Map<String, dynamic> toJson();

  static WorkspacePaneNodeSnapshot? tryFromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    if (type == 'leaf') {
      final hostId = json['hostId'] as String?;
      if (hostId == null || hostId.isEmpty) return null;
      return WorkspacePaneLeafSnapshot(
        hostId: hostId,
        fontSize: ((json['fontSize'] as num?)?.toDouble() ?? 13.5).clamp(
          8.0,
          32.0,
        ),
        isFocused: json['isFocused'] == true,
        isMaximized: json['isMaximized'] == true,
      );
    }
    if (type == 'split') {
      final rawFirst = json['first'];
      final rawSecond = json['second'];
      if (rawFirst is! Map || rawSecond is! Map) return null;
      final first = tryFromJson(rawFirst.cast<String, dynamic>());
      final second = tryFromJson(rawSecond.cast<String, dynamic>());
      if (first == null) return second;
      if (second == null) return first;
      final axis = (json['axis'] as String?) == 'vertical'
          ? Axis.vertical
          : Axis.horizontal;
      final ratio = ((json['ratio'] as num?)?.toDouble() ?? 0.5).clamp(
        0.15,
        0.85,
      );
      return WorkspacePaneSplitSnapshot(
        axis: axis,
        ratio: ratio,
        first: first,
        second: second,
      );
    }
    return null;
  }
}

class WorkspacePaneLeafSnapshot extends WorkspacePaneNodeSnapshot {
  const WorkspacePaneLeafSnapshot({
    required this.hostId,
    this.fontSize = 13.5,
    this.isFocused = false,
    this.isMaximized = false,
  });

  final String hostId;
  final double fontSize;
  final bool isFocused;
  final bool isMaximized;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'leaf',
    'hostId': hostId,
    'fontSize': fontSize,
    if (isFocused) 'isFocused': true,
    if (isMaximized) 'isMaximized': true,
  };
}

class WorkspacePaneSplitSnapshot extends WorkspacePaneNodeSnapshot {
  const WorkspacePaneSplitSnapshot({
    required this.axis,
    required this.ratio,
    required this.first,
    required this.second,
  });

  final Axis axis;
  final double ratio;
  final WorkspacePaneNodeSnapshot first;
  final WorkspacePaneNodeSnapshot second;

  @override
  Map<String, dynamic> toJson() => {
    'type': 'split',
    'axis': axis == Axis.vertical ? 'vertical' : 'horizontal',
    'ratio': ratio,
    'first': first.toJson(),
    'second': second.toJson(),
  };
}
