import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/models/host_store.dart';
import 'package:termx/core/models/remote_os.dart';
import 'package:termx/core/models/terminal_workspace.dart';
import 'package:termx/ui/termx_workbench.dart';
import 'package:termx/ui/widgets/terminal_pane_view.dart';
import 'package:xterm/xterm.dart';

class _InMemoryHostStore extends HostStore {
  _InMemoryHostStore(this.initial);
  final List<HostConfig> initial;

  @override
  Future<List<HostConfig>> load() async => List<HostConfig>.of(initial);

  @override
  Future<void> save(List<HostConfig> hosts) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  const psHost = HostConfig(
    id: 'local_ps',
    name: '本地 PowerShell',
    host: 'localhost',
    authMethod: AuthMethod.localShell,
  );

  const mixHost = HostConfig(
    id: 'mix_ubuntu',
    name: 'Mix',
    host: '192.0.2.62',
    username: 'devops',
    authMethod: AuthMethod.demoSandbox,
    detectedOs: RemoteOsType.ubuntu,
  );

  test(
    'dockTabIntoPane merges tabs on left/right, rearranges, and detaches without disposing sessions',
    () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);

      final psPane = workspace.open(psHost);
      final psTab = workspace.activeTab!;
      final mixPane = workspace.open(mixHost);
      final mixTab = workspace.activeTab!;

      expect(workspace.tabs.length, 2);

      // 1. 将 Mix 停靠到本地 PowerShell 右侧
      final ok = workspace.dockTabIntoPane(
        sourceTab: mixTab,
        targetTab: psTab,
        targetPaneId: psPane.id,
        position: SplitDockPosition.right,
      );
      expect(ok, isTrue);
      expect(workspace.tabs.length, 1);
      expect(psPane.disposed, isFalse);
      expect(mixPane.disposed, isFalse);
      expect(psTab.root, isA<PaneSplit>());
      final splitRight = psTab.root as PaneSplit;
      expect(splitRight.axis, Axis.horizontal);
      expect(splitRight.paneIds, [psPane.id, mixPane.id]);
      expect(workspace.title(psTab), '本地 PowerShell · Mix');

      // 2. 在同一分屏内把右侧的 Mix 拖到左侧
      final moved = workspace.movePaneToSplit(
        sourceTab: psTab,
        sourcePaneId: mixPane.id,
        targetTab: psTab,
        targetPaneId: psPane.id,
        position: SplitDockPosition.left,
      );
      expect(moved, isTrue);
      expect(psTab.root.paneIds, [mixPane.id, psPane.id]);
      expect(workspace.title(psTab), 'Mix · 本地 PowerShell');
      expect(psPane.disposed, isFalse);
      expect(mixPane.disposed, isFalse);

      // 3. 将 Mix 窗格拆回顶部独立标签
      final detached = workspace.detachPaneToNewTab(psTab, mixPane.id);
      expect(detached, isNotNull);
      expect(workspace.tabs.length, 2);
      expect(psTab.root.paneIds, [psPane.id]);
      expect(detached!.root.paneIds, [mixPane.id]);
      expect(psPane.disposed, isFalse);
      expect(mixPane.disposed, isFalse);
    },
  );

  testWidgets(
    'Dragging an inactive or active top tab onto left/right terminal area splits live panes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = _InMemoryHostStore([mixHost]);
      await tester.pumpWidget(
        MaterialApp(
          home: TermXWorkbench(
            hostStore: store,
            autoStartLocalShell: false,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // 打开第一个会话（本地 PowerShell 或 Mix）与第二个会话
      if (Platform.isWindows) {
        await tester.tap(
          find.descendant(
            of: find.byType(HostSidebarItem),
            matching: find.text('本地 PowerShell'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
      }
      await tester.tap(
        find.descendant(
          of: find.byType(HostSidebarItem),
          matching: find.text('Mix'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 250));

      if (!Platform.isWindows) {
        // 非 Windows 环境下再开第二个 Mix 会话做双标签测试
        await tester.tap(
          find.descendant(
            of: find.byType(HostSidebarItem),
            matching: find.text('Mix'),
          ),
        );
        await tester.pump(const Duration(milliseconds: 250));
        await tester.pumpWidget(const SizedBox.shrink());
        return;
      }

      // 此时有两个标签：[本地 PowerShell] 与 [Mix]，且当前激活的是 [Mix]
      expect(
        find.byType(TerminalPaneView, skipOffstage: false),
        findsNWidgets(2),
      );
      final initialStates = tester
          .stateList<TerminalPaneViewState>(
            find.byType(TerminalPaneView, skipOffstage: false),
          )
          .toList();

      // 场景 A：直接按住当前激活的 [Mix] 标签向下拖到终端窗口左半侧 -> 自动露出底层 本地 PowerShell 并向左分屏！
      final mixTabFinder = find.descendant(
        of: find.byType(ReorderableListView),
        matching: find.text('Mix'),
      );
      expect(mixTabFinder, findsOneWidget);

      final paneFinder = find.byType(TerminalPaneView);
      final paneRect = tester.getRect(paneFinder);
      final leftDropTarget = Offset(
        paneRect.left + paneRect.width * 0.22,
        paneRect.top + paneRect.height * 0.50,
      );

      final drag1 = await tester.startGesture(
        tester.getCenter(mixTabFinder),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag1.moveBy(const Offset(0, 36));
      await tester.pump();
      await drag1.moveTo(leftDropTarget);
      await tester.pump();

      // 悬停时应出现左半屏预览提示
      expect(find.textContaining('向左分屏'), findsOneWidget);

      await drag1.up();
      await tester.pump(const Duration(milliseconds: 200));

      // 两个标签已无损合并为同一分屏下的左右两个可见 TerminalView，且原 State 完全保留
      expect(find.byType(TerminalView), findsNWidgets(2));
      expect(find.byType(TerminalPaneView), findsNWidgets(2));
      final mergedStates = tester
          .stateList<TerminalPaneViewState>(find.byType(TerminalPaneView))
          .toList();
      expect(mergedStates.toSet(), equals(initialStates.toSet()));

      final mixPaneHeaderTitle = find.descendant(
        of: find.byType(TerminalPaneView),
        matching: find.text('devops@192.0.2.62:22'),
      );
      final mixPaneWidget = find.ancestor(
        of: mixPaneHeaderTitle,
        matching: find.byType(TerminalPaneView),
      );
      final psPaneWidget = find.ancestor(
        of: find.descendant(
          of: find.byType(TerminalPaneView),
          matching: find.text('本地 PowerShell'),
        ),
        matching: find.byType(TerminalPaneView),
      );
      expect(
        tester.getRect(mixPaneWidget).left,
        lessThan(tester.getRect(psPaneWidget).left),
      );

      // 场景 B：把左侧 Mix 分屏窗格的标题栏向上拖回顶部标签栏 -> 拆回两个独立标签
      final tabBarRect = tester.getRect(find.byType(ReorderableListView));
      final dragDetach = await tester.startGesture(
        tester.getCenter(mixPaneHeaderTitle),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await dragDetach.moveBy(const Offset(0, -30));
      await tester.pump();
      await dragDetach.moveTo(
        Offset(tabBarRect.right - 24, tabBarRect.center.dy),
      );
      await tester.pump();
      await dragDetach.up();
      await tester.pump(const Duration(milliseconds: 200));

      // 拆回后顶部恢复 2 个标签，当前显示单窗格
      expect(find.byType(TerminalPaneView), findsOneWidget);
      expect(
        find.byType(TerminalPaneView, skipOffstage: false),
        findsNWidgets(2),
      );

      // 场景 C：切回 [本地 PowerShell]，按住未激活的 [Mix] 标签向下拖到终端窗口右半侧 -> 向右分屏！
      final psTabFinder = find.descendant(
        of: find.byType(ReorderableListView),
        matching: find.text('本地 PowerShell'),
      );
      await tester.tap(psTabFinder);
      await tester.pump(const Duration(milliseconds: 100));

      final mixInactiveTab = find.descendant(
        of: find.byType(ReorderableListView),
        matching: find.text('Mix'),
      );
      final activePaneRect = tester.getRect(find.byType(TerminalPaneView));
      final rightDropTarget = Offset(
        activePaneRect.left + activePaneRect.width * 0.78,
        activePaneRect.top + activePaneRect.height * 0.50,
      );

      final drag2 = await tester.startGesture(
        tester.getCenter(mixInactiveTab),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await drag2.moveBy(const Offset(0, 36));
      await tester.pump();
      await drag2.moveTo(rightDropTarget);
      await tester.pump();

      expect(find.textContaining('向右分屏'), findsOneWidget);

      await drag2.up();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.byType(TerminalPaneView), findsNWidgets(2));
      final mixAfterRight = find.ancestor(
        of: find.descendant(
          of: find.byType(TerminalPaneView),
          matching: find.text('devops@192.0.2.62:22'),
        ),
        matching: find.byType(TerminalPaneView),
      );
      final psAfterRight = find.ancestor(
        of: find.descendant(
          of: find.byType(TerminalPaneView),
          matching: find.text('本地 PowerShell'),
        ),
        matching: find.byType(TerminalPaneView),
      );
      expect(
        tester.getRect(psAfterRight).left,
        lessThan(tester.getRect(mixAfterRight).left),
      );
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
