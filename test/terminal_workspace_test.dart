import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/models/terminal_workspace.dart';
import 'package:termx/ui/widgets/terminal_pane_view.dart';
import 'package:xterm/xterm.dart';

void main() {
  const host = HostConfig(
    id: 'test',
    name: 'Test terminal',
    host: 'localhost',
    authMethod: AuthMethod.localShell,
  );

  test('Nested splits own distinct sessions and collapse on close', () {
    final workspace = TerminalWorkspace();
    addTearDown(workspace.dispose);
    final first = workspace.open(host);
    final tab = workspace.activeTab!;
    final second = workspace.split(tab, first.id, Axis.horizontal);
    final third = workspace.split(tab, second.id, Axis.vertical);
    expect(tab.root.paneIds.toSet().length, 3);
    expect(first.session.terminal, isNot(same(second.session.terminal)));
    expect(tab.focusedPaneId, third.id);
    workspace.closePane(tab, second.id);
    expect(second.disposed, isTrue);
    expect(tab.root.paneIds, [first.id, third.id]);
    expect(tab.focusedPaneId, third.id);
    workspace.closePane(tab, third.id);
    expect(tab.root, isA<PaneLeaf>());
    expect(workspace.activePane, first);
  });

  test('Closing an earlier tab and reordering preserve the active session', () {
    final workspace = TerminalWorkspace();
    addTearDown(workspace.dispose);
    final first = workspace.open(host);
    final firstTab = workspace.activeTab!;
    final second = workspace.open(host);
    workspace.open(host);
    final thirdTab = workspace.activeTab!;
    workspace.activate(workspace.tabs[1]);
    workspace.closeTab(firstTab);
    expect(first.disposed, isTrue);
    expect(workspace.activePane, second);
    workspace.reorder(0, 2);
    expect(workspace.activePane, second);
    expect(workspace.tabs.first, thirdTab);
  });

  test(
    'Restart replaces only the chosen pane and close-all releases resources',
    () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      final first = workspace.open(host);
      final tab = workspace.activeTab!;
      final second = workspace.split(tab, first.id, Axis.horizontal);
      workspace.toggleMaximize(tab, second.id);
      workspace.rename(tab, 'Renamed');
      final fresh = workspace.restart(tab, second.id);
      expect(second.disposed, isTrue);
      expect(first.disposed, isFalse);
      expect(tab.maximizedPaneId, fresh.id);
      expect(workspace.title(tab), 'Renamed');
      workspace.closeTab(tab);
      expect(first.disposed, isTrue);
      expect(fresh.disposed, isTrue);
      expect(workspace.activePane, isNull);
      expect(workspace.tabs, isEmpty);
    },
  );

  test(
    'Close-other and close-right tabs preserve the entire chosen split tree',
    () {
      final workspace = TerminalWorkspace();
      addTearDown(workspace.dispose);
      workspace.open(host);
      workspace.open(host);
      final chosen = workspace.activeTab!;
      workspace.split(chosen, chosen.focusedPaneId, Axis.vertical);
      final right = workspace.open(host);
      workspace.closeOthers(chosen, onlyRight: true);
      expect(right.disposed, isTrue);
      expect(workspace.tabs.length, 2);
      workspace.closeOthers(chosen);
      expect(workspace.tabs.single, chosen);
      expect(workspace.panes.length, 2);
    },
  );

  testWidgets('Find maps Chinese and emoji text to the right terminal cells', (
    tester,
  ) async {
    final workspace = TerminalWorkspace();
    final pane = workspace.open(host);
    final key = GlobalKey<TerminalPaneViewState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalPaneView(
            key: key,
            pane: pane,
            title: 'Test',
            theme: TerminalThemes.defaultTheme,
            accent: Colors.blue,
            active: true,
            maximized: false,
            onActivate: () {},
            onSplit: (_) {},
            onClose: () {},
            onRestart: () {},
            onMaximize: () {},
            onWorkspaceKey: (_) => KeyEventResult.ignored,
          ),
        ),
      ),
    );
    pane.session.terminal.write('first 中文😀 match\r\nsecond 中文😀 match\r\n');
    key.currentState!.showSearch();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '中文😀');
    await tester.pump();
    expect(find.text('1/2'), findsOneWidget);
    expect(
      pane.session.terminal.buffer.getText(pane.controller.selection),
      '中文😀',
    );
    await tester.tap(find.byTooltip('下一个匹配'));
    await tester.pump();
    expect(find.text('2/2'), findsOneWidget);
    expect(
      pane.session.terminal.buffer.getText(pane.controller.selection),
      '中文😀',
    );
    await tester.pumpWidget(const SizedBox());
    workspace.dispose();
  });

  testWidgets(
    'Split divider adjusts size and double click restores equal sizes',
    (tester) async {
      final split = PaneSplit(Axis.horizontal, PaneLeaf('a'), PaneLeaf('b'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ResizablePaneSplit(
              split: split,
              first: const ColoredBox(color: Colors.red),
              second: const ColoredBox(color: Colors.blue),
            ),
          ),
        ),
      );
      final divider = find.byType(GestureDetector);
      await tester.drag(divider, const Offset(100, 0));
      await tester.pump();
      expect(split.ratio, greaterThan(0.5));
      await tester.tap(divider);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tap(divider);
      await tester.pump();
      expect(split.ratio, 0.5);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
