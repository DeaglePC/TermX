import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/plugin_system/plugin_interface.dart';
import 'package:termx/core/ssh/ssh_session_controller.dart';
import 'package:termx/plugins/server_monitor/linux_telemetry.dart';
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
}
