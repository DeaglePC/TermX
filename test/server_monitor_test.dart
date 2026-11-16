import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/plugin_system/plugin_interface.dart';
import 'package:termx/core/ssh/ssh_session_controller.dart';
import 'package:termx/plugins/server_monitor/linux_telemetry.dart';
import 'package:termx/plugins/server_monitor/local_host_telemetry.dart';
import 'package:termx/plugins/server_monitor/server_monitor_plugin.dart';

String sample({
  int user = 100,
  int idle = 900,
  int rx = 1000,
  int tx = 2000,
  int processTicks = 10,
  int processStart = 100,
}) =>
    '''
[STAT]
cpu $user 0 0 $idle 0 0 0 0 100 0
cpu0 $user 0 0 $idle 0 0 0 0 100 0
[MEM]
MemTotal: 1048576 kB
MemAvailable: 524288 kB
Cached: 131072 kB
SReclaimable: 65536 kB
Shmem: 32768 kB
[NET]
eth0: $rx 0 0 0 0 0 0 0 $tx 0 0 0 0 0 0 0
lo: 9999999 0 0 0 0 0 0 0 9999999 0 0 0 0 0 0 0
[ROUTE]
eth0 00000000 01000000 0003
[LOAD]
0.03 0.02 0.01 1/100 42
[DISK]
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/root 10485760 4194304 5767168 43% /
/dev/disk1 2097152 1048576 1048576 50% /data with spaces
[PAGE]
4096
[PROCESS]
42	$processStart	$processTicks	131072	worker process
99	200	5	1024	idle worker
''';

class SlowMonitorSession extends SshSessionController {
  SlowMonitorSession({
    super.sessionId = 'monitor-test',
    super.host = const HostConfig(
      id: 'test',
      name: 'test',
      host: '192.0.2.1',
    ),
    this.connectionState = SessionConnectionState.connected,
  });
  SessionConnectionState connectionState;
  final List<Completer<String>> requests = [];
  @override
  SessionConnectionState get state => connectionState;
  @override
  Future<String> execBackgroundCommand(String command) {
    final request = Completer<String>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  test('CPU, memory and network rates use real cumulative counter deltas', () {
    final sampler = LinuxTelemetrySampler();
    final baseline = sampler.sample(sample(), Duration.zero);
    expect(baseline.cpu, 0);
    expect(baseline.downKbps, 0);
    final next = sampler.sample(
      sample(user: 150, idle: 950, rx: 3048, tx: 3024, processTicks: 35),
      const Duration(seconds: 1),
    );
    expect(next.cpu, 50);
    expect(next.cores, [50]);
    expect(next.totalGb, 1);
    expect(next.usedGb, .5);
    expect(next.cachedGb, .15625);
    expect(next.downKbps, 2);
    expect(next.upKbps, 1);
    expect(next.loads, [.03, .02, .01]);
    expect(next.disks.length, 2);
    expect(next.disks.first.device, '/dev/root');
    expect(next.disks.first.totalGb, 10);
    expect(next.disks.first.usedGb, 4);
    expect(next.disks.first.ratio, .43);
    expect(next.disks.last.mountPoint, '/data with spaces');
    expect(next.processes.first.pid, 42);
    expect(next.processes.first.command, 'worker process');
    expect(next.processes.first.cpuPercent, 25);
    expect(next.processes.first.memPercent, 50);
    final reset = sampler.sample(
      sample(
        user: 1,
        idle: 1,
        rx: 1,
        tx: 1,
        processTicks: 1000,
        processStart: 999,
      ),
      const Duration(seconds: 2),
    );
    expect(reset.cpu, 0);
    expect(reset.downKbps, 0);
    expect(reset.upKbps, 0);
    expect(reset.processes.first.cpuPercent, 0);
  });

  testWidgets(
    'Monitor polls every second without overlapping or accepting stale results',
    (tester) async {
      final monitor = ServerMonitorPlugin();
      final first = SlowMonitorSession(
        sessionId: 'monitor-1',
        host: const HostConfig(id: 'test-1', name: 'test-1', host: '192.0.2.1'),
      );
      final second = SlowMonitorSession(
        sessionId: 'monitor-2',
        host: const HostConfig(id: 'test-2', name: 'test-2', host: '192.0.2.2'),
      );
      await monitor.onInit();
      monitor.onActiveSessionChanged(first);
      expect(first.requests.length, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(first.requests.length, 1);
      first.requests[0].complete(sample());
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(first.requests.length, 2);
      monitor.onActiveSessionChanged(second);
      first.requests[1].complete(sample(user: 500, idle: 1000));
      await tester.pump();
      expect(monitor.cpuHistory, isEmpty);
      await tester.pump(const Duration(seconds: 1));
      expect(second.requests.length, 1);
      monitor.onUnload();
      second.requests[0].complete(sample());
      await tester.pump();
      expect(monitor.cpuHistory, isEmpty);
      monitor.dispose();
      first.dispose();
      second.dispose();
    },
  );

  testWidgets(
    'Switching split panes on the same server preserves telemetry without flickering',
    (tester) async {
      const sharedHost = HostConfig(
        id: 'prod-node-1',
        name: 'prod-node-1',
        host: '192.0.2.10',
      );
      final monitor = ServerMonitorPlugin();
      final leftPane = SlowMonitorSession(
        sessionId: 'pane-left',
        host: sharedHost,
      );
      final rightPane = SlowMonitorSession(
        sessionId: 'pane-right',
        host: sharedHost,
      );
      final connectingSplitPane = SlowMonitorSession(
        sessionId: 'pane-connecting',
        host: sharedHost,
        connectionState: SessionConnectionState.connecting,
      );

      await monitor.onInit();
      monitor.onActiveSessionChanged(leftPane);
      leftPane.requests[0].complete(sample(user: 100, idle: 900));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      leftPane.requests[1].complete(sample(user: 150, idle: 950));
      await tester.pump();

      expect(monitor.snapshot.cpuTotalPercent, 50);
      expect(monitor.snapshot.memTotalGb, 1);
      expect(monitor.cpuHistory, [0, 50]);

      var active = leftPane;
      var notifyCount = 0;
      monitor.addListener(() => notifyCount++);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                final ctx = PluginContext(
                  activeSession: active,
                  showToast: (_) {},
                  requestOpenPanel: (_) {},
                );
                return Column(
                  children: [
                    TextButton(
                      onPressed: () {
                        setState(() => active = rightPane);
                        monitor.onActiveSessionChanged(rightPane);
                      },
                      child: const Text('switch-right'),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() => active = connectingSplitPane);
                        monitor.onActiveSessionChanged(connectingSplitPane);
                      },
                      child: const Text('switch-connecting'),
                    ),
                    Expanded(child: monitor.buildPanelWidget(context, ctx)),
                  ],
                );
              },
            ),
          ),
        ),
      );

      expect(find.textContaining('总使用率 50.0%'), findsOneWidget);
      expect(find.text('正在读取服务器监控数据…'), findsNothing);

      // Switching to another split pane on the same server does not clear
      // snapshot/history, fire extra polls, or flash the loading state.
      await tester.tap(find.text('switch-right'));
      await tester.pump();
      expect(notifyCount, 0);
      expect(rightPane.requests, isEmpty);
      expect(monitor.snapshot.cpuTotalPercent, 50);
      expect(monitor.cpuHistory, [0, 50]);
      expect(find.textContaining('总使用率 50.0%'), findsOneWidget);
      expect(find.text('正在读取服务器监控数据…'), findsNothing);

      // Next scheduled 1s poll runs on the newly focused pane and preserves
      // cumulative /proc counter deltas across panes of the same server.
      await tester.pump(const Duration(seconds: 1));
      expect(rightPane.requests.length, 1);
      rightPane.requests[0].complete(sample(user: 210, idle: 990));
      await tester.pump();
      await tester.pump();
      expect(monitor.snapshot.cpuTotalPercent, 60);
      expect(monitor.cpuHistory, [0, 50, 60]);
      expect(find.textContaining('总使用率 60.0%'), findsOneWidget);

      // Splitting into a pane that is still connecting keeps displaying data
      // and falls back to an already-connected sibling pane to continue polling.
      await tester.tap(find.text('switch-connecting'));
      await tester.pump();
      expect(find.textContaining('总使用率 60.0%'), findsOneWidget);
      expect(find.text('正在读取服务器监控数据…'), findsNothing);
      await tester.pump(const Duration(seconds: 1));
      expect(rightPane.requests.length, 2);

      monitor.onUnload();
      await tester.pumpWidget(const SizedBox.shrink());
      monitor.dispose();
      leftPane.dispose();
      rightPane.dispose();
      connectingSplitPane.dispose();
    },
  );

  test(
    'Darwin (macOS Apple Silicon) telemetry parses CPU, 16K vm_stat memory, APFS disk and netstat deltas',
    () {
      String darwinSample({required int rxBytes, required int txBytes}) => '''
[OS]
Darwin
[MAC_SYS]
NCPU:8
MEMSIZE:17179869184
LOAD:{ 1.60 1.25 0.98 }
[MAC_VM]
Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                              120000.
Pages active:                            320000.
Pages inactive:                          210000.
Pages speculative:                        10000.
Pages wired down:                        131072.
Pages purgeable:                          16384.
File-backed pages:                       114688.
Anonymous pages:                         278528.
Pages occupied by compressor:             65536.
[MAC_ROUTE]
en0
[MAC_NET]
en0 $rxBytes $txBytes
[DISK]
Filesystem 1024-blocks Used Available Capacity Mounted on
/dev/disk3s1s1 488281250 10485760 195312500 6% /
devfs 210 210 0 100% /dev
/dev/disk3s6 488281250 2097152 195312500 2% /System/Volumes/VM
/dev/disk3s5 488281250 262144000 195312500 58% /System/Volumes/Data
/dev/disk4s2 104857600 52428800 52428800 50% /Volumes/ExternalSSD
[MAC_PROC]
  512 120.0  8.5 WindowServer
 1024  40.0  4.2 node
  301   0.5  1.1 launchd
''';

      final sampler = LinuxTelemetrySampler();
      final first = sampler.sample(
        darwinSample(rxBytes: 10000, txBytes: 5000),
        Duration.zero,
      );
      expect(first.totalGb, 16.0);
      // App(278528 - 16384 = 262144) + Wired(131072) + Compressed(65536) = 458752 pages * 16KB = 7.0 GiB
      expect(first.usedGb, 7.0);
      // Cached: (114688 + 16384) = 131072 pages * 16KB = 2.0 GiB
      expect(first.cachedGb, 2.0);
      // Total CPU: (120 + 40 + 0.5) / 8 = 20.0625%
      expect(first.cpu, closeTo(20.0625, 0.01));
      expect(first.cores, hasLength(8));
      expect(first.loads, [1.60, 1.25, 0.98]);
      // APFS '/' + '/System/Volumes/Data' merged into '/', '/System/Volumes/VM' & 'devfs' filtered, ExternalSSD kept
      expect(first.disks, hasLength(2));
      expect(first.disks.first.mountPoint, '/');
      expect(first.disks.last.mountPoint, '/Volumes/ExternalSSD');
      expect(first.processes.first.command, 'WindowServer');
      expect(first.downKbps, 0.0);

      final second = sampler.sample(
        darwinSample(rxBytes: 10000 + 204800, txBytes: 5000 + 102400),
        const Duration(seconds: 2),
      );
      expect(second.downKbps, closeTo(100.0, 0.01));
      expect(second.upKbps, closeTo(50.0, 0.01));
    },
  );

  test(
    'Linux PROC_IO and PROC_NET sections compute per-process disk & network KB/s',
    () {
      String richLinuxSample({
        required int diskBytes,
        required int netBytes,
      }) => '''
${sample(user: 150, idle: 950)}
[PROC_IO]
42\t$diskBytes
[PROC_NET]
99\t$netBytes\t6
''';
      final sampler = LinuxTelemetrySampler();
      sampler.sample(
        richLinuxSample(diskBytes: 102400, netBytes: 51200),
        Duration.zero,
      );
      final second = sampler.sample(
        richLinuxSample(
          diskBytes: 102400 + 512 * 1024,
          netBytes: 51200 + 256 * 1024,
        ),
        const Duration(seconds: 1),
      );
      final proc42 = second.processes.firstWhere((p) => p.pid == 42);
      final proc99 = second.processes.firstWhere((p) => p.pid == 99);
      expect(proc42.diskKbps, closeTo(512.0, 0.01));
      expect(proc99.netKbps, closeTo(256.0, 0.01));
      expect(proc99.netConns, 6);
    },
  );

  test('LocalHostTelemetrySampler reads real Windows CPU, RAM, disks and processes', () async {
    if (!Platform.isWindows) return;
    final localSampler = LocalHostTelemetrySampler();
    final t0 = await localSampler.sample(Duration.zero);
    expect(t0.totalGb, greaterThan(1.0));
    expect(t0.usedGb, greaterThan(0.2));
    expect(t0.cores, isNotEmpty);
    expect(t0.disks, isNotEmpty);
    expect(t0.processes, isNotEmpty);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    final t1 = await localSampler.sample(const Duration(milliseconds: 80));
    expect(t1.cpu, inInclusiveRange(0.0, 100.0));
    expect(t1.downKbps, greaterThanOrEqualTo(0.0));
    expect(t1.upKbps, greaterThanOrEqualTo(0.0));
    expect(
      t1.processes.any((p) => (p.memMb ?? 0) > 1.0),
      isTrue,
    );
  });

  testWidgets(
    'Local PowerShell displays host telemetry and sorts active processes by CPU, Memory, Disk, Network',
    (tester) async {
      String? lastSentInput;
      final localSession = _FakeConnectedLocalSession(
        onInput: (cmd) => lastSentInput = cmd,
      );
      final monitor = ServerMonitorPlugin(
        localSamplerOverride: (_) async => LinuxTelemetry(
          cpu: 34.5,
          cores: const [42.0, 27.0, 38.0, 31.0],
          loads: const [1.38, 1.12, 0.95],
          usedGb: 14.2,
          cachedGb: 6.4,
          totalGb: 32.0,
          upKbps: 256.0,
          downKbps: 2048.0,
          disks: [
            LinuxDiskUsage('System · NTFS', r'C:\', 500.0, 240.0, 0.48),
            LinuxDiskUsage('Work · NTFS', r'D:\', 1000.0, 620.0, 0.62),
          ],
          processes: [
            LinuxProcessUsage(
              1001,
              'cpu-heavy.exe',
              48.0,
              2.0,
              memMb: 650.0,
              diskKbps: 12.0,
              netKbps: 0.0,
            ),
            LinuxProcessUsage(
              1002,
              'mem-heavy.exe',
              3.5,
              15.0,
              memMb: 4915.0,
              diskKbps: 0.0,
              netKbps: 20.0,
              netConns: 3,
            ),
            LinuxProcessUsage(
              1003,
              'disk-heavy.exe',
              6.0,
              1.5,
              memMb: 480.0,
              diskKbps: 9216.0,
              netKbps: 0.0,
            ),
            LinuxProcessUsage(
              1004,
              'net-heavy.exe',
              4.2,
              3.0,
              memMb: 980.0,
              diskKbps: 40.0,
              netKbps: 4096.0,
              netConns: 28,
            ),
          ],
        ),
      );

      await monitor.onInit();
      monitor.onActiveSessionChanged(localSession);
      await tester.pump();
      await tester.pump();

      final ctx = PluginContext(
        activeSession: localSession,
        showToast: (_) {},
        requestOpenPanel: (_) {},
      );

      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            body: Builder(
              builder: (context) => SizedBox(
                width: 420,
                height: 1300,
                child: Column(
                  children: [
                    monitor.buildStatusBarWidget(context, ctx),
                    Expanded(child: monitor.buildPanelWidget(context, ctx)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 1. 本地会话不再提示“需要连接 SSH 服务器”，状态栏与面板均展示本机真实负载
      expect(find.textContaining('当前为本地 PowerShell 会话'), findsNothing);
      expect(find.text('本机'), findsOneWidget);
      expect(find.textContaining('总使用率 34.5%'), findsOneWidget);
      expect(find.textContaining(r'C:\ (System · NTFS)'), findsOneWidget);

      // 2. 默认按 CPU 降序：cpu-heavy.exe 排在第一位
      expect(
        tester.getTopLeft(find.text('cpu-heavy.exe')).dy,
        lessThan(tester.getTopLeft(find.text('mem-heavy.exe')).dy),
      );

      // 3. 点击「内存」：mem-heavy.exe (4.8 GB) 跃升至第一位
      await tester.tap(find.byKey(const ValueKey<String>('proc-sort-memory')));
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('mem-heavy.exe')).dy,
        lessThan(tester.getTopLeft(find.text('cpu-heavy.exe')).dy),
      );

      // 4. 点击「磁盘」：disk-heavy.exe (9.0 MB/s) 跃升至第一位
      await tester.tap(find.byKey(const ValueKey<String>('proc-sort-disk')));
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('disk-heavy.exe')).dy,
        lessThan(tester.getTopLeft(find.text('mem-heavy.exe')).dy),
      );

      // 5. 点击「网络」：net-heavy.exe (4.0 MB/s, 28 连接) 跃升至第一位
      await tester.tap(find.byKey(const ValueKey<String>('proc-sort-network')));
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('net-heavy.exe')).dy,
        lessThan(tester.getTopLeft(find.text('disk-heavy.exe')).dy),
      );

      // 再次点击「网络」切换升序：net-heavy.exe 排到最底部
      await tester.tap(find.byKey(const ValueKey<String>('proc-sort-network')));
      await tester.pump();
      expect(
        tester.getTopLeft(find.text('cpu-heavy.exe')).dy,
        lessThan(tester.getTopLeft(find.text('net-heavy.exe')).dy),
      );

      // 6. 在本地 Windows PowerShell 下点击结束进程按钮会注入 Stop-Process -Id <PID>
      if (Platform.isWindows) {
        await tester.tap(find.byTooltip('结束进程 (Stop-Process -Id 1004)'));
        await tester.pump();
        expect(lastSentInput, 'Stop-Process -Id 1004\r');
      }

      monitor.onUnload();
      await tester.pumpWidget(const SizedBox.shrink());
      monitor.dispose();
      localSession.dispose();
    },
  );
}

class _FakeConnectedLocalSession extends SshSessionController {
  _FakeConnectedLocalSession({required this.onInput})
    : super(
        sessionId: 'local-ps-test',
        host: const HostConfig(
          id: 'local_ps',
          name: '本地 PowerShell',
          host: 'localhost',
          authMethod: AuthMethod.localShell,
        ),
      );

  final ValueChanged<String> onInput;

  @override
  SessionConnectionState get state => SessionConnectionState.connected;

  @override
  void sendRawInput(String data) {
    onInput(data);
  }
}
