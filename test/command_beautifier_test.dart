import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/models/shortcut_settings.dart';
import 'package:termx/core/models/terminal_workspace.dart';
import 'package:termx/core/plugin_system/plugin_interface.dart';
import 'package:termx/core/plugin_system/plugin_manager.dart';
import 'package:termx/core/theme/adaptive_layout.dart';
import 'package:termx/core/theme/ui_tokens.dart';
import 'package:termx/plugins/command_beautifier/beauty_card_widgets.dart';
import 'package:termx/plugins/command_beautifier/command_beautifier_plugin.dart';
import 'package:termx/plugins/command_beautifier/command_catalog.dart';
import 'package:termx/plugins/command_beautifier/command_output_models.dart';
import 'package:termx/plugins/command_beautifier/command_output_parser.dart';
import 'package:termx/ui/widgets/terminal_pane_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CommandOutputParser 12 大分类解析覆盖测试', () {
    test('内置命令清单 12 个分类样例全部准确识别并生成对应结构化卡片', () {
      expect(BeautyCommandCatalog.specs.length, 12);
      for (final spec in BeautyCommandCatalog.specs) {
        final card = CommandOutputParser.parse(
          command: spec.sampleCommand,
          rawOutput: spec.sampleRawOutput,
          isAltScreen: spec.category == BeautyCategoryId.systemTop,
        );
        expect(
          card,
          isNotNull,
          reason: '分类 ${spec.category.id} (${spec.sampleCommand}) 应当解析成功',
        );
        expect(card!.category, spec.category);
      }
    });

    test('识别 Docker stats 与 Docker images 输出', () {
      const statsOut = '''
CONTAINER ID   NAME          CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O        PIDS
a81f940b2c19   api-gateway   12.45%    128.4MiB / 2GiB       6.27%     1.2GB / 890MB     14.2MB / 0B      16
79c20e1b55d1   redis-cache   1.80%     64.0MiB / 512MiB      12.50%    420MB / 310MB     8.1MB / 2.4MB    6
''';
      final statsCard = CommandOutputParser.parse(
        command: 'docker stats --no-stream',
        rawOutput: statsOut,
      );
      expect(statsCard?.category, BeautyCategoryId.containers);
      expect(statsCard?.payload, isA<DockerStatsPayload>());
      final statsPayload = statsCard!.payload as DockerStatsPayload;
      expect(statsPayload.stats.length, 2);
      expect(statsPayload.stats.first.name, 'api-gateway');

      const imagesOut = '''
REPOSITORY          TAG           IMAGE ID       CREATED        SIZE
nginx               1.27-alpine   f876bfc1cc63   2 weeks ago    43.2MB
postgres            16-bookworm   c3d9a81209ee   3 weeks ago    419MB
''';
      final imgCard = CommandOutputParser.parse(
        command: 'docker images',
        rawOutput: imagesOut,
      );
      expect(imgCard?.category, BeautyCategoryId.containers);
      expect(imgCard?.payload, isA<DockerImagesPayload>());
    });

    test('兼容 Windows 中文与英文 ipconfig / ping / netstat / PowerShell 输出', () {
      const winIpconfigZh = '''
Windows IP 配置

无线局域网适配器 WLAN:

   连接特定的 DNS 后缀 . . . . . . . : lan
   IPv4 地址 . . . . . . . . . . . . : 192.168.31.108
   子网掩码  . . . . . . . . . . . . : 255.255.255.0
   默认网关. . . . . . . . . . . . . : 192.168.31.1
''';
      final ipCard = CommandOutputParser.parse(
        command: 'ipconfig',
        rawOutput: winIpconfigZh,
      );
      expect(ipCard?.category, BeautyCategoryId.networkInterfaces);
      expect(ipCard?.payload, isA<NetworkInterfacesPayload>());

      const winPingZh = '''
正在 Ping 8.8.8.8 具有 32 字节的数据:
来自 8.8.8.8 的回复: 字节=32 时间=18ms TTL=116
来自 8.8.8.8 的回复: 字节=32 时间=21ms TTL=116

8.8.8.8 的 Ping 统计信息:
    数据包: 已发送 = 2，已接收 = 2，丢失 = 0 (0% 丢失)，
往返行程的估计时间(以毫秒为单位):
    最短 = 18ms，最长 = 21ms，平均 = 19ms
''';
      final pingCard = CommandOutputParser.parse(
        command: 'ping 8.8.8.8',
        rawOutput: winPingZh,
      );
      expect(pingCard?.category, BeautyCategoryId.networkInterfaces);
      expect(pingCard?.payload, isA<PingStatsPayload>());

      const winNetstat = '''
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:8080           0.0.0.0:0              LISTENING       14920
  TCP    127.0.0.1:5432         0.0.0.0:0              LISTENING       6824
''';
      final netCard = CommandOutputParser.parse(
        command: 'netstat -ano',
        rawOutput: winNetstat,
      );
      expect(netCard?.category, BeautyCategoryId.networkPorts);
      expect(netCard?.payload, isA<NetworkSocketsPayload>());
    });

    test('过滤欢迎横幅与普通命令报错，绝不误触发美化卡片', () {
      const banner = '''
Windows PowerShell
版权所有（C） Microsoft Corporation。保留所有权利。
安装最新的 PowerShell，了解新功能和改进！https://aka.ms/PSWindows
''';
      expect(
        CommandOutputParser.parse(command: '', rawOutput: banner),
        isNull,
      );

      const errOut = 'bash: docker: command not found';
      expect(
        CommandOutputParser.parse(command: 'docker ps', rawOutput: errOut),
        isNull,
      );
    });
  });

  testWidgets('终端执行常见命令自动贴合美化卡片，并支持随时切换「显示原文 / 美化卡片」', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final workspace = TerminalWorkspace();
    final pluginManager = PluginManager();
    final beautifier = CommandBeautifierPlugin();
    await pluginManager.registerPlugin(beautifier);

    const demoHost = HostConfig(
      id: 'demo_beauty_01',
      name: 'Ubuntu Sandbox',
      host: '10.0.0.99',
      username: 'root',
      authMethod: AuthMethod.demoSandbox,
    );

    final pane = workspace.open(demoHost);
    pluginManager.notifySessionAttached(pane.session);
    unawaited(pane.session.connect(null));
    await tester.pump(const Duration(milliseconds: 350));
    pluginManager.notifyActiveSessionChanged(pane.session);

    final pluginContext = PluginContext(
      activeSession: pane.session,
      showToast: (_) {},
      requestOpenPanel: (_) {},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 760,
            child: TerminalPaneView(
              pane: pane,
              title: 'root@10.0.0.99:22',
              theme: TermXColorPalette.presets.first.terminalTheme,
              accent: TxColors.accent,
              active: true,
              maximized: false,
              onActivate: () {},
              onSplit: (_) {},
              onClose: () {},
              onRestart: () {},
              onMaximize: () {},
              onWorkspaceKey: (_) => KeyEventResult.ignored,
              terminalOverlay: ListenableBuilder(
                listenable: pluginManager,
                builder: (ctx, _) =>
                    pluginManager.buildTerminalOverlay(
                      ctx,
                      pluginContext,
                      pane.session,
                    ) ??
                    const SizedBox.shrink(),
              ),
              onToggleBeautyCard: () =>
                  beautifier.toggleSessionDisplayMode(pane.session.sessionId),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 120));

    // 初始刚进入终端欢迎页时，不应误弹美化卡片
    expect(find.byType(TerminalBeautyOverlay), findsNothing);

    // 1. 执行 `docker ps` -> 自动检测并在终端上方贴合渲染 Docker 卡片
    pane.session.sendRawInput('docker ps\r');
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.byType(TerminalBeautyOverlay), findsOneWidget);
    expect(find.text('美化卡片'), findsOneWidget);
    expect(find.text('显示原文'), findsOneWidget);
    expect(find.textContaining('api-gateway'), findsWidgets);

    // 2. 点击「显示原文」 -> 卡片立即收起为右上角轻量悬浮胶囊，展示底层真实终端文字
    await tester.tap(find.text('显示原文'));
    await tester.pump();

    expect(find.text('显示美化卡片'), findsOneWidget);
    expect(find.text('美化卡片'), findsNothing);

    // 3. 点击胶囊上的「显示美化卡片」 -> 随时一键恢复美化卡片视图
    await tester.tap(find.text('显示美化卡片'));
    await tester.pump();

    expect(find.text('美化卡片'), findsOneWidget);
    expect(find.text('显示原文'), findsOneWidget);

    // 4. 再执行 `top` -> 自动切换为系统实时负载美化卡片，并记录 2/2 历史卡片
    pane.session.sendRawInput('top\r');
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('2/2'), findsOneWidget);

    // 5. 动态停用插件 -> 终端贴片立即无感卸载
    pluginManager.setPluginEnabled(CommandBeautifierPlugin.pluginId, false);
    await tester.pump();
    expect(find.byType(TerminalBeautyOverlay), findsNothing);

    workspace.dispose();
    pluginManager.dispose();
    await tester.pump();
  });

  test('真实 Windows 11 PowerShell 命令输出解析（含带空格进程名、逗号千分位、UTF-16LE wsl）', () {
    const getProcOut = '''
Handles  NPM(K)    PM(K)      WS(K)     CPU(s)     Id  SI ProcessName
-------  ------    -----      -----     ------     --  -- -----------
      0      42   128400     512000               184   0 Memory Compression
   1420      88   342100     480200   8,232.05   9204   1 chrome
    612      34    98200     145000      45.20   4412   1 powershell
''';
    final procCard = CommandOutputParser.parse(
      command: 'Get-Process',
      rawOutput: getProcOut,
    );
    expect(procCard, isNotNull);
    expect(procCard!.category, BeautyCategoryId.processes);
    final procPayload = procCard.payload as ProcessListPayload;
    expect(procPayload.processes.length, 3);
    expect(procPayload.processes[0].command, 'Memory Compression');
    expect(procPayload.processes[1].cpuPercent, closeTo(8232.05, 0.01));

    const psDriveOut = r'''
Name           Used (GB)     Free (GB) Provider      Root                                               CurrentLocation
----           ---------     --------- --------      ----                                               ---------------
C                 245.50        230.12 FileSystem    C:\                                                   Users\dupen
D                 612.80        318.20 FileSystem    D:\                                                   github\TermX
''';
    final driveCard = CommandOutputParser.parse(
      command: 'Get-PSDrive -PSProvider FileSystem',
      rawOutput: psDriveOut,
    );
    expect(driveCard, isNotNull);
    expect(driveCard!.category, BeautyCategoryId.diskStorage);
    final disks = (driveCard.payload as DiskUsagePayload).mounts;
    expect(disks.length, 2);
    expect(disks[1].mountPoint, r'D:\ (github\TermX)');

    const wslSpaced =
        '  N A M E                   S T A T E                       V E R S I O N\n'
        '* U b u n t u - 2 4 . 0 4   R u n n i n g                   2\n'
        '  D e b i a n               S t o p p e d                   2\n';
    final wslCard = CommandOutputParser.parse(
      command: 'wsl -l -v',
      rawOutput: wslSpaced,
    );
    expect(wslCard, isNotNull);
    expect(wslCard!.category, BeautyCategoryId.systemEnv);
  });

  testWidgets('弹出卡片支持按住顶栏自由拖动移位、一键复位位置以及多维度升降序排序', (
    tester,
  ) async {
    const imgOut = '''
REPOSITORY          TAG       IMAGE ID       CREATED        SIZE
alpine              3.20      a606584aa9aa   3 weeks ago    7.8MB
postgres            16        903922fc507c   2 weeks ago    432MB
redis               7         e40d29b297f3   5 days ago     41.2MB
''';
    final card = CommandOutputParser.parse(
      command: 'docker images',
      rawOutput: imgOut,
    )!;

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Offset? latestSavedOffset;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: 720,
            child: TerminalBeautyOverlay(
              card: card,
              displayMode: CardDisplayMode.beautified,
              pinned: false,
              historyIndex: 0,
              historyTotal: 1,
              onToggleDisplayMode: (_) {},
              onTogglePin: () {},
              onDismiss: () {},
              onStepHistory: (_) {},
              onSendCommand: (_, {bool appendNewline = true}) {},
              onCopyToast: (_) {},
              onOffsetChanged: (offset) => latestSavedOffset = offset,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    // 1. 验证拖动卡片顶栏严格 1:1 跟手（含向左负向跨出左边界 + 向右下拖动，0 丢像素、无半速漂移）
    final titleFinder = find.text(card.title);
    final beforeTopLeft = tester.getTopLeft(titleFinder);
    await tester.drag(titleFinder, const Offset(-260, 120));
    await tester.pump();

    final afterDrag1 = tester.getTopLeft(titleFinder);
    expect(afterDrag1.dx, closeTo(beforeTopLeft.dx - 260.0, 0.01));
    expect(afterDrag1.dy, closeTo(beforeTopLeft.dy + 120.0, 0.01));
    expect(latestSavedOffset, isNotNull);

    // 即使卡片左侧已部分移出左边界 (< 0)，按住屏幕内可见顶栏空白处反向拖回 (+195, -55) 依然严格 1:1 对齐
    await tester.dragFrom(
      Offset(120.0, afterDrag1.dy + 6.0),
      const Offset(195, -55),
    );
    await tester.pump();
    final afterDrag2 = tester.getTopLeft(titleFinder);
    expect(afterDrag2.dx, closeTo(afterDrag1.dx + 195.0, 0.01));
    expect(afterDrag2.dy, closeTo(afterDrag1.dy - 55.0, 0.01));

    // 右下角缩放手柄拖动 (-240, +40) 同样严格 1:1 改变宽度（且缩窄后顶栏自动切换紧凑布局不溢出）
    final resizeGrip = find.byIcon(Icons.south_east_rounded);
    final gripBefore = tester.getTopLeft(resizeGrip);
    await tester.drag(resizeGrip, const Offset(-240, 40));
    await tester.pump();
    final gripAfter = tester.getTopLeft(resizeGrip);
    expect(gripAfter.dx, closeTo(gripBefore.dx - 240.0, 0.01));

    // 2. 点击「复位卡片默认居中位置与尺寸」按钮恢复默认位置与尺寸
    await tester.tap(find.byTooltip('复位卡片默认居中位置与尺寸'));
    await tester.pump();
    final resetTopLeft = tester.getTopLeft(titleFinder);
    expect(resetTopLeft.dx, closeTo(beforeTopLeft.dx, 0.01));
    expect(resetTopLeft.dy, closeTo(beforeTopLeft.dy, 0.01));

    // 3. 验证多维度排序：点击「镜像体积」默认降序 -> postgres (432MB) 排在最上方，alpine (7.8MB) 在最下方
    expect(find.text('排序：'), findsOneWidget);
    await tester.tap(find.text('镜像体积'));
    await tester.pump();

    final pgYDesc = tester.getTopLeft(find.textContaining('postgres')).dy;
    final redisYDesc = tester.getTopLeft(find.textContaining('redis')).dy;
    final alpineYDesc = tester.getTopLeft(find.textContaining('alpine')).dy;
    expect(pgYDesc, lessThan(redisYDesc));
    expect(redisYDesc, lessThan(alpineYDesc));

    // 4. 再次点击「镜像体积」切换升序 -> alpine 排在最上方，postgres 排在最下方
    await tester.tap(find.text('镜像体积'));
    await tester.pump();

    final pgYAsc = tester.getTopLeft(find.textContaining('postgres')).dy;
    final alpineYAsc = tester.getTopLeft(find.textContaining('alpine')).dy;
    expect(alpineYAsc, lessThan(pgYAsc));
  });

  testWidgets('Ctrl+A 默认将光标定位到命令行开头而不再全选屏幕文字，且支持 Ctrl+Shift+A 全选与自定义快捷键持久化', (
    tester,
  ) async {
    // 验证 ShortcutConfig JSON 序列化往返
    final customCfg = ShortcutConfig.defaults().copyWith(
      ctrlABehavior: CtrlABehavior.moveToLineStart,
      bindings: {
        ...ShortcutConfig.defaultBindings(),
        ShortcutAction.toggleBeauty: KeyChord.fromLogical(
          LogicalKeyboardKey.keyJ,
          ctrl: true,
        ),
      },
    );
    final restored = ShortcutConfig.fromJson(customCfg.toJson());
    expect(restored.ctrlABehavior, CtrlABehavior.moveToLineStart);
    expect(
      restored.chordFor(ShortcutAction.toggleBeauty).displayLabel,
      'Ctrl+J',
    );

    final workspace = TerminalWorkspace();
    const sandboxHost = HostConfig(
      id: 'ctrl_a_test_node',
      name: 'ctrl-a-node',
      host: '10.0.0.108',
      username: 'root',
      authMethod: AuthMethod.demoSandbox,
    );
    final pane = workspace.open(sandboxHost);
    final capturedInputs = <String>[];
    pane.session.addTerminalInputListener(capturedInputs.add);
    unawaited(pane.session.connect(null));
    await tester.pump(const Duration(milliseconds: 350));

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 600,
            child: TerminalPaneView(
              pane: pane,
              title: 'root@10.0.0.108:22',
              theme: TermXColorPalette.presets.first.terminalTheme,
              accent: TxColors.accent,
              active: true,
              maximized: false,
              shortcutConfig: ShortcutConfig.defaults(),
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
    );
    await tester.pump();
    pane.focus.requestFocus();
    await tester.pump();

    capturedInputs.clear();

    // 1. 按下 Ctrl+A：不应全选终端文字（selection 保持为 null），且向终端发送行首控制符 \x01
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(pane.controller.selection, isNull);
    expect(capturedInputs, contains('\x01'));

    // 2. 按下 Ctrl+Shift+A：执行全选终端文字（selection 不为 null）
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(pane.controller.selection, isNotNull);

    // 3. 再次按下 Ctrl+A：自动清除已有选区并定位行首
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    expect(pane.controller.selection, isNull);

    workspace.dispose();
    await tester.pump();
  });

  test('Docker 损坏空字节 (\\x00) 日志报错识别、命令解析与容错回退脚本生成', () {
    const daemonErr =
        r"error from daemon in stream: Error grabbing logs: invalid character '\x00' looking for beginning of value";
    expect(CommandBeautifierPlugin.isDockerNullByteLogError(daemonErr), isTrue);
    expect(
      CommandBeautifierPlugin.isDockerNullByteLogError(
        '2026-11-15 INFO normal container log line',
      ),
      isFalse,
    );

    final parsed1 = CommandBeautifierPlugin.parseDockerLogsCommand(
      'docker logs --tail 50 clash_gateway',
    );
    expect(parsed1, isNotNull);
    expect(parsed1!.container, 'clash_gateway');
    expect(parsed1.tail, 50);

    final parsed2 = CommandBeautifierPlugin.parseDockerLogsCommand(
      'sudo -u root docker container logs -f --tail=120 "clash_gateway"',
    );
    expect(parsed2, isNotNull);
    expect(parsed2!.container, 'clash_gateway');
    expect(parsed2.tail, 120);

    final fallback = CommandBeautifierPlugin.buildDockerNullByteFallbackCommand(
      'clash_gateway',
      tail: 50,
    );
    expect(fallback.startsWith(' '), isTrue);
    expect(fallback, contains('clash_gateway'));
    expect(fallback, contains(r"tr -d '\000'"));
    expect(fallback, contains('tail -n 50'));
    // 确保容错脚本自身绝不会被再次识别为 docker logs 命令（防止死循环）
    expect(CommandBeautifierPlugin.parseDockerLogsCommand(fallback), isNull);
  });

  testWidgets('从 Docker 美化卡片点击查看容器日志自动切回原文态并注入命令', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final workspace = TerminalWorkspace();
    final pluginManager = PluginManager();
    final beautifier = CommandBeautifierPlugin();
    await pluginManager.registerPlugin(beautifier);

    const sandboxHost = HostConfig(
      id: 'sandbox-docker-logs-1',
      name: 'Docker Sandbox',
      host: '10.0.0.109',
      username: 'root',
      authMethod: AuthMethod.demoSandbox,
    );
    final pane = workspace.open(sandboxHost);
    final sentCommands = <String>[];
    pane.session.addTerminalInputListener(sentCommands.add);
    pluginManager.notifySessionAttached(pane.session);
    unawaited(pane.session.connect(null));
    await tester.pump(const Duration(milliseconds: 350));
    pluginManager.notifyActiveSessionChanged(pane.session);

    beautifier.previewCatalogSample(BeautyCategoryId.containers, pane.session);
    // 即使固定了卡片，点击查看容器日志也应自动收起卡片切回原文态，方便直接看到终端输出的日志
    beautifier.toggleSessionPin(pane.session.sessionId);

    final pluginContext = PluginContext(
      activeSession: pane.session,
      showToast: (_) {},
      requestOpenPanel: (_) {},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 1100,
            height: 700,
            child: Builder(
              builder: (ctx) => Stack(
                children: [
                  const SizedBox.expand(),
                  beautifier.buildTerminalOverlayWidget(
                    ctx,
                    pluginContext,
                    pane.session,
                  )!,
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('显示原文'), findsOneWidget);
    sentCommands.clear();

    final logButtons = find.byTooltip('查看容器日志 (docker logs)');
    expect(logButtons, findsWidgets);
    await tester.tap(logButtons.first);
    await tester.pump(const Duration(milliseconds: 120));

    // 已切换为右上角轻量胶囊态，不再遮挡终端日志，且成功注入 docker logs 命令
    expect(find.text('显示美化卡片'), findsOneWidget);
    expect(
      sentCommands.any((c) => c.startsWith('docker logs --tail 50 ')),
      isTrue,
    );

    workspace.dispose();
    pluginManager.dispose();
    await tester.pump();
  });

  testWidgets('手机端窄屏 (390x844) 渲染全部 12 类美化卡片、全屏阅读与原文胶囊零溢出', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final workspace = TerminalWorkspace();
    final pluginManager = PluginManager();
    final beautifier = CommandBeautifierPlugin();
    await pluginManager.registerPlugin(beautifier);

    const sandboxHost = HostConfig(
      id: 'sandbox-mobile-beauty-1',
      name: 'Mobile Beauty Sandbox',
      host: '10.0.0.119',
      username: 'root',
      authMethod: AuthMethod.demoSandbox,
    );
    final pane = workspace.open(sandboxHost);
    pluginManager.notifySessionAttached(pane.session);
    unawaited(pane.session.connect(null));
    await tester.pump(const Duration(milliseconds: 350));
    pluginManager.notifyActiveSessionChanged(pane.session);

    final pluginContext = PluginContext(
      activeSession: pane.session,
      showToast: (_) {},
      requestOpenPanel: (_) {},
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: SizedBox(
            width: 390,
            height: 580,
            child: ListenableBuilder(
              listenable: beautifier,
              builder: (ctx, _) => Stack(
                children: [
                  const SizedBox.expand(),
                  if (beautifier.buildTerminalOverlayWidget(
                        ctx,
                        pluginContext,
                        pane.session,
                      )
                      case final overlay?)
                    overlay,
                ],
              ),
            ),
          ),
        ),
      ),
    );

    for (final spec in BeautyCommandCatalog.specs) {
      beautifier.previewCatalogSample(spec.category, pane.session);
      await tester.pump(const Duration(milliseconds: 80));
      expect(
        tester.takeException(),
        isNull,
        reason: '分类 ${spec.category.title} 在手机窄屏下不应发生布局溢出',
      );
      // 手机端隐藏右下角桌面缩放手柄，且提供全屏按钮与工具栏芯片
      expect(find.byIcon(Icons.south_east_rounded), findsNothing);
      expect(find.byTooltip('全屏查看美化卡片'), findsOneWidget);
      expect(find.text('全屏阅读'), findsOneWidget);
      expect(find.text('显示原文'), findsOneWidget);
    }

    // 测试手机端打开全屏阅读抽屉
    beautifier.previewCatalogSample(BeautyCategoryId.containers, pane.session);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.byTooltip('全屏查看美化卡片'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('对照原文'), findsWidgets);
    await tester.tap(find.byTooltip('关闭全屏视图'));
    await tester.pumpAndSettle();

    // 测试手机端切回原文态悬浮胶囊（即使超长命令也不溢出）
    await tester.tap(find.text('显示原文'));
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.takeException(), isNull);
    expect(find.text('显示美化卡片'), findsOneWidget);

    workspace.dispose();
    pluginManager.dispose();
    await tester.pump();
  });

  testWidgets('手机端底部模态面板点击预览卡片后自动关闭抽屉回到终端', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final workspace = TerminalWorkspace();
    final pluginManager = PluginManager();
    final beautifier = CommandBeautifierPlugin();
    await pluginManager.registerPlugin(beautifier);

    const sandboxHost = HostConfig(
      id: 'sandbox-mobile-sheet-1',
      name: 'Mobile Sheet Sandbox',
      host: '10.0.0.120',
      username: 'root',
      authMethod: AuthMethod.demoSandbox,
    );
    final pane = workspace.open(sandboxHost);
    pluginManager.notifySessionAttached(pane.session);
    unawaited(pane.session.connect(null));
    await tester.pump(const Duration(milliseconds: 350));
    pluginManager.notifyActiveSessionChanged(pane.session);

    final pluginContext = PluginContext(
      activeSession: pane.session,
      showToast: (_) {},
      requestOpenPanel: (_) {},
    );

    late BuildContext hostContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: Scaffold(
          body: Builder(
            builder: (ctx) {
              hostContext = ctx;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );

    unawaited(
      showModalBottomSheet<void>(
        context: hostContext,
        isScrollControlled: true,
        builder: (sheetCtx) => SizedBox(
          height: 640,
          child: beautifier.buildPanelWidget(sheetCtx, pluginContext),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('预览卡片'), findsWidgets);

    await tester.tap(find.text('预览卡片').first);
    await tester.pumpAndSettle();

    // 模态底部抽屉已自动收起，且当前会话已生成美化卡片
    expect(find.text('预览卡片'), findsNothing);
    expect(beautifier.cardsForSession(pane.session.sessionId), isNotEmpty);

    workspace.dispose();
    pluginManager.dispose();
    await tester.pump();
  });
}
