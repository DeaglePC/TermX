import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/models/host_store.dart';
import 'package:termx/core/models/shortcut_settings.dart';
import 'package:termx/core/models/terminal_workspace.dart';
import 'package:termx/core/models/ui_preferences.dart';
import 'package:termx/core/platform/desktop_native_bridge.dart';
import 'package:termx/core/ssh/ssh_session_controller.dart';
import 'package:termx/core/theme/adaptive_layout.dart';
import 'package:termx/plugins/sftp_manager/sftp_manager_plugin.dart';
import 'package:termx/ui/termx_workbench.dart';
import 'package:termx/ui/widgets/terminal_pane_view.dart';
import 'package:termx/ui/widgets/terminal_tab_button.dart';
import 'package:xterm/xterm.dart';

class _MemoryHostStore extends HostStore {
  List<HostConfig> saved = const [];

  @override
  Future<List<HostConfig>> load() async => List<HostConfig>.of(saved);

  @override
  Future<void> save(List<HostConfig> hosts) async {
    saved = List<HostConfig>.of(hosts);
  }
}

class _MemoryShortcutStore extends ShortcutStore {
  ShortcutConfig saved = ShortcutConfig.defaults();

  @override
  Future<ShortcutConfig> load() async => saved;

  @override
  Future<void> save(ShortcutConfig config) async {
    saved = config;
  }
}

class _MemoryUiPreferencesStore extends UiPreferencesStore {
  UiPreferences saved = const UiPreferences();

  @override
  Future<UiPreferences> load() async => saved;

  @override
  Future<void> save(UiPreferences prefs) async {
    saved = prefs;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    DesktopNativeBridge.instance.debugSetWindowOpacityOverride = null;
  });

  test('UiPreferencesStore clamps window opacity and persists settings to disk', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'termx_ui_prefs_test_',
    );
    try {
      final store = UiPreferencesStore(directoryProvider: () async => tempDir);

      await store.save(
        const UiPreferences(
          windowOpacity: 0.12,
          colorPaletteName: 'nord_frost',
          rightPanelWidth: 512.0,
        ),
      );

      final loaded = await store.load();
      expect(loaded.windowOpacity, closeTo(UiPreferences.minOpacity, 0.0001));
      expect(loaded.colorPaletteName, equals('nord_frost'));
      expect(loaded.rightPanelWidth, closeTo(512.0, 0.0001));
    } finally {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    }
  });

  testWidgets(
    'Window opacity popover updates native window opacity and persists preset',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final appliedOpacities = <double>[];
      DesktopNativeBridge.instance.debugSetWindowOpacityOverride =
          (opacity) async {
            appliedOpacities.add(opacity);
            return opacity;
          };

      final hostStore = _MemoryHostStore();
      final shortcutStore = _MemoryShortcutStore();
      final uiPrefsStore = _MemoryUiPreferencesStore();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: TermXWorkbench(
            hostStore: hostStore,
            shortcutStore: shortcutStore,
            uiPreferencesStore: uiPrefsStore,
            autoStartLocalShell: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 打开顶部“透明度”弹窗
      final opacityBtn = find.byIcon(Icons.opacity_rounded);
      expect(opacityBtn, findsOneWidget);
      await tester.tap(opacityBtn);
      await tester.pumpAndSettle();

      expect(find.text('窗口透明度'), findsOneWidget);
      expect(find.text('85% 舒适'), findsOneWidget);

      // 选择 85% 舒适预设
      await tester.tap(find.text('85% 舒适'));
      await tester.pumpAndSettle();

      expect(appliedOpacities, isNotEmpty);
      expect(appliedOpacities.last, closeTo(0.85, 0.001));
      expect(find.text('85%'), findsWidgets);
      expect(uiPrefsStore.saved.windowOpacity, closeTo(0.85, 0.001));

      // 点击恢复 100%
      await tester.tap(find.text('恢复 100%'));
      await tester.pumpAndSettle();
      expect(appliedOpacities.last, closeTo(1.0, 0.001));
      expect(uiPrefsStore.saved.windowOpacity, closeTo(1.0, 0.001));

      // 关闭弹窗并销毁工作台
      await tester.tapAt(const Offset(20, 20));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Right panel resize handle tracks mouse 1:1 with zero lag and resets on double tap',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final hostStore = _MemoryHostStore();
      final shortcutStore = _MemoryShortcutStore();
      final uiPrefsStore = _MemoryUiPreferencesStore();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: TermXWorkbench(
            hostStore: hostStore,
            shortcutStore: shortcutStore,
            uiPreferencesStore: uiPrefsStore,
            autoStartLocalShell: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // 展开右侧辅助面板
      final panelToggle = find.byIcon(Icons.space_dashboard_outlined);
      if (find
          .byKey(const ValueKey('right_panel_resize_handle'))
          .evaluate()
          .isEmpty) {
        await tester.tap(panelToggle);
        await tester.pump(const Duration(milliseconds: 100));
      }

      final handleFinder = find.byKey(
        const ValueKey('right_panel_resize_handle'),
      );
      expect(handleFinder, findsOneWidget);

      final initialCenter = tester.getCenter(handleFinder);

      // 模拟鼠标左键按住分隔条，分 6 步向左移动共 120px，验证每一步都严格 1:1 跟随鼠标！
      final gesture = await tester.startGesture(
        initialCenter,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await tester.pump();

      for (var i = 1; i <= 6; i++) {
        await gesture.moveBy(const Offset(-20.0, 0.0));
        await tester.pump();
        final currentCenter = tester.getCenter(handleFinder);
        expect(
          currentCenter.dx,
          closeTo(initialCenter.dx - 20.0 * i, 0.5),
          reason: '第 $i 步拖拽后分隔条必须严格跟随鼠标偏移 -${20 * i}px',
        );
      }

      await gesture.up();
      await tester.pump(const Duration(milliseconds: 350));

      expect(uiPrefsStore.saved.rightPanelWidth, closeTo(430.0 + 120.0, 0.5));

      // 双击分隔条恢复默认宽度
      final draggedCenter = tester.getCenter(handleFinder);
      await tester.tapAt(draggedCenter);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(draggedCenter);
      await tester.pump(const Duration(milliseconds: 350));

      final resetCenter = tester.getCenter(handleFinder);
      expect(resetCenter.dx, closeTo(initialCenter.dx, 0.5));
      expect(uiPrefsStore.saved.rightPanelWidth, isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Moving cursor backward over existing text renders high-contrast inverse glyph instead of opaque block',
    (tester) async {
      final session = SshSessionController(
        sessionId: 'cursor_inverse_test',
        host: const HostConfig(
          id: 'h_cursor',
          name: 'Mix',
          host: '192.0.2.62',
          username: 'dpc',
        ),
      );
      final pane = TerminalPane(session);
      final captureKey = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: RepaintBoundary(
              key: captureKey,
              child: SizedBox(
                width: 480,
                height: 240,
                child: TerminalPaneView(
                  pane: pane,
                  title: 'dpc@192.0.2.62:22',
                  theme: TermXColorPalette.presets.first.terminalTheme,
                  accent: TermXColorPalette.presets.first.accentColor,
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
          ),
        ),
      );
      await tester.pump();
      pane.focus.requestFocus();
      await tester.pump();

      // 模拟输入 pwd 后按左方向键回退光标到中间字符 'w' 上（\x1b[2D）
      session.terminal.write('pwd\x1b[2D');
      await tester.pump();

      expect(session.terminal.buffer.cursorX, equals(1));
      expect(
        String.fromCharCode(
          session.terminal.buffer.currentLine.getCodePoint(1),
        ),
        equals('w'),
      );

      // 校验 TerminalView 原生遮挡光标已被透明禁用，并由反色光标层接管
      final tv = tester.widget<TerminalView>(find.byType(TerminalView));
      expect(tv.theme.cursor.a, equals(0.0));
      expect(
        find.byKey(const ValueKey('termx_inverse_cursor_paint')),
        findsOneWidget,
      );

      // 像素级采样验证：光标所在的反色绘制层同时包含亮色光标底块像素与深色反色字符像素
      final cursorPaintFinder = find.ancestor(
        of: find.byKey(const ValueKey('termx_inverse_cursor_paint')),
        matching: find.byType(RepaintBoundary),
      );
      final boundary =
          tester.renderObject<RenderRepaintBoundary>(cursorPaintFinder.first);
      final ui.Image image = await tester.runAsync(
        () => boundary.toImage(pixelRatio: 1.0),
      ) as ui.Image;
      final byteData = await tester.runAsync(
        () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
      );
      image.dispose();
      expect(byteData, isNotNull);

      final bytes = byteData!.buffer.asUint8List();
      var brightCursorBlockPixels = 0;
      var darkInverseGlyphPixels = 0;
      for (var i = 0; i < bytes.length; i += 4) {
        final r = bytes[i];
        final g = bytes[i + 1];
        final b = bytes[i + 2];
        final a = bytes[i + 3];
        if (a < 200) continue;
        if (r > 180 && g > 180 && b > 180) {
          brightCursorBlockPixels++;
        } else if (r < 50 && g < 50 && b < 50) {
          darkInverseGlyphPixels++;
        }
      }

      expect(
        brightCursorBlockPixels,
        greaterThan(0),
        reason: '光标格应绘制亮色块底色',
      );
      expect(
        darkInverseGlyphPixels,
        greaterThan(0),
        reason: '回退到已有字符上时必须在光标块内重绘深色反色字符，绝不能被纯白块遮盖',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      pane.focus.dispose();
      pane.controller.dispose();
      pane.scroll.dispose();
      session.dispose();
    },
  );

  test(
    'WorkspaceLayoutSnapshot and UiPreferences persist nested split trees, ratios, font sizes, and prune deleted hosts',
    () async {
      const hostA = HostConfig(
        id: 'host_a',
        name: 'Gateway-A',
        group: '生产环境',
        host: '10.0.0.1',
        username: 'ops',
        authMethod: AuthMethod.demoSandbox,
      );
      const hostB = HostConfig(
        id: 'host_b',
        name: 'Worker-B',
        group: '生产环境',
        host: '10.0.0.2',
        username: 'ops',
        authMethod: AuthMethod.demoSandbox,
      );
      const hostC = HostConfig(
        id: 'host_c',
        name: 'Redis-C',
        group: '缓存层',
        host: '10.0.0.3',
        username: 'ops',
        authMethod: AuthMethod.demoSandbox,
      );

      final tempDir = await Directory.systemTemp.createTemp(
        'termx_layout_snapshot_test_',
      );
      final wsOrigin = TerminalWorkspace();
      final wsRestoredFull = TerminalWorkspace();
      final wsRestoredPruned = TerminalWorkspace();

      try {
        final firstPane = wsOrigin.open(hostA);
        firstPane.fontSize = 16.5;
        final tab1 = wsOrigin.activeTab!;
        wsOrigin.rename(tab1, '核心集群巡检');
        wsOrigin.setTabColor(tab1, const Color(0xFFE06C75));

        final secondPane = wsOrigin.splitAt(
          tab1,
          firstPane.id,
          SplitDockPosition.right,
          host: hostB,
        );
        (tab1.root as PaneSplit).ratio = 0.64;

        wsOrigin.splitAt(
          tab1,
          secondPane.id,
          SplitDockPosition.bottom,
          host: hostC,
        );
        final nestedSplit = (tab1.root as PaneSplit).second as PaneSplit;
        nestedSplit.ratio = 0.38;

        // 再打开第 2 个标签页，然后切回第 1 个标签页
        wsOrigin.open(hostB);
        wsOrigin.activate(tab1, secondPane.id);

        final store = UiPreferencesStore(
          directoryProvider: () async => tempDir,
        );
        await store.save(
          UiPreferences(
            windowOpacity: 0.88,
            colorPaletteName: 'catppuccin_mocha',
            rightPanelWidth: 518.0,
            cursorType: TerminalCursorType.verticalBar,
            leftSidebarCollapsed: true,
            collapsedHostGroups: const ['生产环境'],
            rightPanelOpen: true,
            activeRightPluginId: 'com.termx.plugin.sftp',
            enabledExtraPluginIds: const ['com.termx.community.docker'],
            workspaceLayout: wsOrigin.captureSnapshot(),
          ),
        );

        final loaded = await store.load();
        expect(loaded.leftSidebarCollapsed, isTrue);
        expect(loaded.collapsedHostGroups, equals(['生产环境']));
        expect(loaded.rightPanelOpen, isTrue);
        expect(loaded.activeRightPluginId, equals('com.termx.plugin.sftp'));
        expect(
          loaded.enabledExtraPluginIds,
          equals(['com.termx.community.docker']),
        );
        expect(loaded.cursorType, equals(TerminalCursorType.verticalBar));
        expect(loaded.workspaceLayout, isNotNull);

        // 1. 所有主机均存在时：完整还原 2 个标签页与 3 窗格嵌套分屏树
        final hostMap = {hostA.id: hostA, hostB.id: hostB, hostC.id: hostC};
        final panesFull = wsRestoredFull.restoreFromSnapshot(
          loaded.workspaceLayout!,
          (id) => hostMap[id],
        );
        expect(panesFull.length, equals(4));
        expect(wsRestoredFull.tabs.length, equals(2));
        expect(
          wsRestoredFull.activeTab,
          same(wsRestoredFull.tabs.first),
        );
        final restoredTab1 = wsRestoredFull.tabs.first;
        expect(restoredTab1.customTitle, equals('核心集群巡检'));
        expect(restoredTab1.customColor?.toARGB32(), equals(0xFFE06C75));
        expect(restoredTab1.root, isA<PaneSplit>());
        final rootSplit = restoredTab1.root as PaneSplit;
        expect(rootSplit.axis, equals(Axis.horizontal));
        expect(rootSplit.ratio, closeTo(0.64, 0.0001));
        expect(rootSplit.second, isA<PaneSplit>());
        expect(
          (rootSplit.second as PaneSplit).ratio,
          closeTo(0.38, 0.0001),
        );
        final restoredFirstLeaf = rootSplit.first as PaneLeaf;
        expect(
          wsRestoredFull.panes[restoredFirstLeaf.id]!.fontSize,
          closeTo(16.5, 0.0001),
        );

        // 2. 若 hostC 已被用户删除：自动优雅折叠嵌套分屏，保留 hostA + hostB
        final partialMap = {hostA.id: hostA, hostB.id: hostB};
        final panesPruned = wsRestoredPruned.restoreFromSnapshot(
          loaded.workspaceLayout!,
          (id) => partialMap[id],
        );
        expect(panesPruned.length, equals(3));
        final prunedRoot = wsRestoredPruned.tabs.first.root as PaneSplit;
        expect(prunedRoot.paneIds.length, equals(2));
        expect(prunedRoot.ratio, closeTo(0.64, 0.0001));
      } finally {
        wsOrigin.dispose();
        wsRestoredFull.dispose();
        wsRestoredPruned.dispose();
        if (await tempDir.exists()) {
          await tempDir.delete(recursive: true);
        }
      }
    },
  );

  testWidgets(
    'TermXWorkbench automatically records and restores tabs, split ratios, sidebar, and right panel on reopen',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      const demoHost1 = HostConfig(
        id: 'demo_srv_1',
        name: 'Tokyo-Edge',
        group: '海外节点',
        host: '198.51.100.10',
        username: 'ubuntu',
        authMethod: AuthMethod.demoSandbox,
      );
      const demoHost2 = HostConfig(
        id: 'demo_srv_2',
        name: 'Frankfurt-DB',
        group: '海外节点',
        host: '198.51.100.20',
        username: 'ubuntu',
        authMethod: AuthMethod.demoSandbox,
      );

      final hostStore = _MemoryHostStore()..saved = [demoHost1, demoHost2];
      final shortcutStore = _MemoryShortcutStore();
      final uiPrefsStore = _MemoryUiPreferencesStore();

      // 第一次打开工作台：创建多标签 + 左右分屏 + 调整分屏比例 + 切换右侧面板为「文件」并拉宽 + 收起左侧栏
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: TermXWorkbench(
            hostStore: hostStore,
            shortcutStore: shortcutStore,
            uiPreferencesStore: uiPrefsStore,
            autoStartLocalShell: false,
            restoreSavedWorkspace: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 点击左侧服务器列表打开 Tokyo-Edge，并向右分屏
      await tester.tap(find.text('Tokyo-Edge'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TerminalPaneView), findsOneWidget);

      await tester.tap(find.byTooltip('向右分屏'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TerminalPaneView), findsNWidgets(2));
      expect(find.byType(ResizablePaneSplit), findsOneWidget);

      // 拖动中间分屏分隔线向右偏移 +90px，使分屏比例偏离默认 0.5
      final splitBox = tester.getRect(find.byType(ResizablePaneSplit));
      final splitDividerPos = Offset(splitBox.center.dx, splitBox.center.dy);
      final splitDrag = await tester.startGesture(
        splitDividerPos,
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await tester.pump();
      await splitDrag.moveBy(const Offset(90, 0));
      await tester.pump();
      await splitDrag.up();
      await tester.pump(const Duration(milliseconds: 100));

      final savedSplitBeforeClose = tester
          .widget<ResizablePaneSplit>(find.byType(ResizablePaneSplit))
          .split
          .ratio;
      expect(savedSplitBeforeClose, greaterThan(0.54));

      // 再点击 Frankfurt-DB 打开第 2 个独立标签页，再切回第 1 个分屏标签页
      await tester.tap(find.text('Frankfurt-DB'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TerminalTabButton), findsNWidgets(2));
      await tester.tap(
        find.descendant(
          of: find.byType(TerminalTabButton),
          matching: find.text('Tokyo-Edge'),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      // 切换右侧面板到「文件」插件，并将右侧面板向左拉宽 80px（430 -> 510）
      await tester.tap(find.text('文件'));
      await tester.pump(const Duration(milliseconds: 100));
      final rightHandle = find.byKey(
        const ValueKey('right_panel_resize_handle'),
      );
      final rightDrag = await tester.startGesture(
        tester.getCenter(rightHandle),
        kind: PointerDeviceKind.mouse,
        buttons: kPrimaryMouseButton,
      );
      await tester.pump();
      await rightDrag.moveBy(const Offset(-80, 0));
      await tester.pump();
      await rightDrag.up();
      await tester.pump(const Duration(milliseconds: 100));

      // 收起左侧服务器栏
      await tester.tap(find.byTooltip('显示/隐藏服务器栏'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.menu_open_rounded), findsOneWidget);

      // 模拟关闭整个应用
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));

      // 模拟重新打开应用：挂载全新的 TermXWorkbench 实例，仅传入同一份持久化存储
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: TermXWorkbench(
            hostStore: hostStore,
            shortcutStore: shortcutStore,
            uiPreferencesStore: uiPrefsStore,
            autoStartLocalShell: false,
            restoreSavedWorkspace: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));

      // 验证：1) 两个标签页与第 1 个标签页的 2 窗格左右分屏及精确比例全部恢复！
      expect(find.byType(TerminalTabButton), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byType(TerminalTabButton),
          matching: find.text('Tokyo-Edge'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(TerminalTabButton),
          matching: find.text('Frankfurt-DB'),
        ),
        findsOneWidget,
      );
      expect(find.byType(TerminalPaneView), findsNWidgets(2));
      expect(find.byType(ResizablePaneSplit), findsOneWidget);
      final restoredRatio = tester
          .widget<ResizablePaneSplit>(find.byType(ResizablePaneSplit))
          .split
          .ratio;
      expect(restoredRatio, closeTo(savedSplitBeforeClose, 0.005));

      // 验证：2) 左侧服务器栏保持收起状态！
      expect(find.byIcon(Icons.menu_open_rounded), findsOneWidget);

      // 验证：3) 右侧面板保持打开在「文件」插件，且宽度保持 510px！
      expect(
        uiPrefsStore.saved.activeRightPluginId,
        SftpManagerPlugin.pluginId,
      );
      expect(uiPrefsStore.saved.rightPanelWidth, closeTo(510.0, 0.5));
      expect(
        find.byKey(const ValueKey('right_panel_resize_handle')),
        findsOneWidget,
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 350));
    },
  );

  testWidgets(
    'Mobile edge-to-edge layout respects top punch-hole status bar, bottom gesture bar, and soft keyboard without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      tester.view.padding = const FakeViewPadding(top: 48, bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(top: 48, bottom: 34);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.view.resetPadding();
        tester.view.resetViewPadding();
        tester.view.resetViewInsets();
      });

      final hostStore = _MemoryHostStore();
      final shortcutStore = _MemoryShortcutStore();
      final uiPrefsStore = _MemoryUiPreferencesStore();

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: TermXWorkbench(
            hostStore: hostStore,
            shortcutStore: shortcutStore,
            uiPreferencesStore: uiPrefsStore,
            autoStartLocalShell: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // 1. 顶部菜单按钮与标题必须严格位于系统状态栏安全区 (top = 48) 以下
      final menuRect = tester.getRect(find.byIcon(Icons.menu_rounded));
      expect(menuRect.top, greaterThanOrEqualTo(48.0));

      // 2. 底部状态栏锁图标必须严格位于系统手势小白条 (844 - 34 = 810) 以上，且无中间断层
      final lockRect = tester.getRect(find.byIcon(Icons.lock_outline_rounded));
      expect(lockRect.bottom, lessThanOrEqualTo(844.0 - 34.0));

      final escRect = tester.getRect(find.text('ESC'));
      expect(escRect.bottom, lessThan(lockRect.top));

      // 3. 打开左侧抽屉菜单，验证抽屉顶部标题也避开了状态栏安全区
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();
      final drawerTitleRect = tester.getRect(find.text('服务器'));
      expect(drawerTitleRect.top, greaterThanOrEqualTo(48.0));
      Navigator.of(tester.element(find.text('服务器'))).pop();
      await tester.pumpAndSettle();

      // 4. 点击右上角更多菜单打开「终端配色与光标」底部面板
      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('终端配色与光标'));
      await tester.pumpAndSettle();
      expect(find.text('终端配色主题'), findsOneWidget);
      Navigator.of(tester.element(find.text('终端配色主题'))).pop();
      await tester.pumpAndSettle();

      // 5. 模拟手机软键盘弹起 (viewInsets.bottom = 320)，打开「新建 SSH 主机」弹窗无任何溢出异常
      tester.view.viewInsets = const FakeViewPadding(bottom: 320);
      tester.view.padding = const FakeViewPadding(top: 48, bottom: 0);
      await tester.pump();

      await tester.tap(find.byIcon(Icons.more_vert_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('新建 SSH 主机'));
      await tester.pumpAndSettle();
      expect(find.text('新建 SSH 服务器连接'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
