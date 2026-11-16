import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../core/plugin_system/plugin_interface.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../../core/theme/ui_tokens.dart';
import 'linux_telemetry.dart';
import 'local_host_telemetry.dart';

enum ProcessSortBy {
  cpu('CPU'),
  memory('内存'),
  disk('磁盘'),
  network('网络');

  final String label;
  const ProcessSortBy(this.label);
}

class ProcessMetric {
  final int pid;
  final String command;
  final double cpuPercent;
  final double memPercent;
  final double? memMb;
  final double diskKbps;
  final double netKbps;
  final int netConns;

  const ProcessMetric({
    required this.pid,
    required this.command,
    required this.cpuPercent,
    required this.memPercent,
    this.memMb,
    this.diskKbps = 0.0,
    this.netKbps = 0.0,
    this.netConns = 0,
  });
}

class DiskMountMetric {
  final String mountPoint;
  final String device;
  final double usedGb;
  final double totalGb;
  final double? reportedRatio;

  const DiskMountMetric({
    required this.mountPoint,
    required this.device,
    required this.usedGb,
    required this.totalGb,
    this.reportedRatio,
  });

  double get ratio =>
      reportedRatio ?? (totalGb <= 0 ? 0 : (usedGb / totalGb).clamp(0.0, 1.0));
}

class ServerLoadSnapshot {
  final double cpuTotalPercent;
  final List<double> perCorePercents;
  final double load1m;
  final double load5m;
  final double load15m;
  final double memUsedGb;
  final double memCachedGb;
  final double memTotalGb;
  final double netUpKbps;
  final double netDownKbps;
  final List<DiskMountMetric> disks;
  final List<ProcessMetric> topProcesses;

  const ServerLoadSnapshot({
    required this.cpuTotalPercent,
    required this.perCorePercents,
    required this.load1m,
    required this.load5m,
    required this.load15m,
    required this.memUsedGb,
    required this.memCachedGb,
    required this.memTotalGb,
    required this.netUpKbps,
    required this.netDownKbps,
    required this.disks,
    required this.topProcesses,
  });
}

class _ServerTelemetryState {
  LinuxTelemetrySampler sampler = LinuxTelemetrySampler();
  LocalHostTelemetrySampler localSampler = LocalHostTelemetrySampler();
  ServerLoadSnapshot snapshot;
  List<double> cpuHistory;
  List<double> netDownHistory;
  String? samplingError;
  bool pollInFlight = false;
  bool hasFreshProcessSample;
  SshSessionController? primarySession;
  final Set<SshSessionController> knownSessions = {};

  _ServerTelemetryState({required bool isDemoMode})
    : snapshot = isDemoMode
          ? ServerMonitorPlugin._demoSnapshot
          : ServerMonitorPlugin._emptySnapshot,
      cpuHistory = isDemoMode
          ? List<double>.unmodifiable(List<double>.filled(32, 18.0))
          : const <double>[],
      netDownHistory = isDemoMode
          ? List<double>.unmodifiable(List<double>.filled(32, 320.0))
          : const <double>[],
      hasFreshProcessSample = isDemoMode;

  void attachSession(SshSessionController session) {
    knownSessions.removeWhere((s) => s.isDisposed || identical(s, session));
    knownSessions.add(session);
    primarySession = session;
  }

  SshSessionController? get pollableSession {
    knownSessions.removeWhere((s) => s.isDisposed);
    final primary = primarySession;
    if (primary != null &&
        !primary.isDisposed &&
        (primary.isLocalSession ||
            primary.state == SessionConnectionState.connected)) {
      return primary;
    }
    for (final candidate in knownSessions.toList().reversed) {
      if (candidate.isLocalSession ||
          candidate.state == SessionConnectionState.connected) {
        return candidate;
      }
    }
    return null;
  }
}

/// [核心插件 1] 本机与服务器负载实时监控插件 (`plugin.server_monitor`)
/// - 本地 PowerShell / 本地终端会话：零子进程开销实时采集本机 CPU、物理内存、磁盘、网卡流量与活跃进程
/// - 远端 SSH 会话：复用独立 Exec 通道实时采集远端服务器资源与活跃进程
/// - 活跃进程支持按「CPU / 内存 / 磁盘 / 网络」四维升降序实时排序
class ServerMonitorPlugin extends TermXPlugin {
  static const String pluginId = 'plugin.server_monitor';
  static const String _localHostKey = '__local_host__';

  ServerMonitorPlugin({this.localSamplerOverride});

  /// 供单元测试注入确定性的本地资源采样回调
  @visibleForTesting
  final Future<LinuxTelemetry> Function(Duration elapsed)? localSamplerOverride;

  Timer? _pollTimer;
  static const refreshInterval = Duration(seconds: 1);
  Duration? _scheduledInterval;
  bool _unloaded = false;
  final Stopwatch _sampleClock = Stopwatch()..start();
  SshSessionController? _currentSession;
  String? _currentServerKey;
  final Map<String, _ServerTelemetryState> _states = {};
  final Random _rng = Random();

  ProcessSortBy _processSortBy = ProcessSortBy.cpu;
  bool _processSortDescending = true;

  ProcessSortBy get processSortBy => _processSortBy;
  bool get processSortDescending => _processSortDescending;

  void setProcessSort(ProcessSortBy sortBy) {
    if (_processSortBy == sortBy) {
      _processSortDescending = !_processSortDescending;
    } else {
      _processSortBy = sortBy;
      _processSortDescending = true;
    }
    notifyListeners();
  }

  static const _emptySnapshot = ServerLoadSnapshot(
    cpuTotalPercent: 0,
    perCorePercents: [],
    load1m: 0,
    load5m: 0,
    load15m: 0,
    memUsedGb: 0,
    memCachedGb: 0,
    memTotalGb: 0,
    netUpKbps: 0,
    netDownKbps: 0,
    disks: [],
    topProcesses: [],
  );

  static const _demoSnapshot = ServerLoadSnapshot(
    cpuTotalPercent: 21.4,
    perCorePercents: [28.0, 19.5, 31.0, 14.2, 22.8, 17.0, 25.4, 13.5],
    load1m: 0.48,
    load5m: 0.39,
    load15m: 0.31,
    memUsedGb: 6.4,
    memCachedGb: 4.8,
    memTotalGb: 16.0,
    netUpKbps: 412.0,
    netDownKbps: 1280.0,
    disks: [
      DiskMountMetric(
        mountPoint: '/',
        device: '/dev/vda1',
        usedGb: 46.2,
        totalGb: 120.0,
      ),
      DiskMountMetric(
        mountPoint: '/data/storage',
        device: '/dev/vdb1',
        usedGb: 435.0,
        totalGb: 500.0,
      ),
    ],
    topProcesses: [
      ProcessMetric(
        pid: 1042,
        command: 'nginx: worker process',
        cpuPercent: 8.4,
        memPercent: 3.2,
        memMb: 524.0,
        diskKbps: 18.0,
        netKbps: 1120.0,
        netConns: 48,
      ),
      ProcessMetric(
        pid: 2190,
        command: 'postgres: walwriter',
        cpuPercent: 5.1,
        memPercent: 18.6,
        memMb: 3047.0,
        diskKbps: 2480.0,
        netKbps: 145.0,
        netConns: 14,
      ),
      ProcessMetric(
        pid: 1884,
        command: 'redis-server *:6379',
        cpuPercent: 3.8,
        memPercent: 9.4,
        memMb: 1540.0,
        diskKbps: 64.0,
        netKbps: 380.0,
        netConns: 26,
      ),
      ProcessMetric(
        pid: 3412,
        command: 'dockerd --containerd',
        cpuPercent: 2.2,
        memPercent: 6.1,
        memMb: 999.0,
        diskKbps: 512.0,
        netKbps: 42.0,
        netConns: 6,
      ),
    ],
  );

  static String? _serverKey(SshSessionController? session) {
    if (session == null) return null;
    if (session.isLocalSession) return _localHostKey;
    final h = session.host;
    return '${session.isDemoMode}|${h.authMethod.name}|${h.id}|${h.username}@${h.host}:${h.port}|${h.jumpHostId ?? ''}';
  }

  static List<double> _appendMetric(List<double> history, double value) {
    final start = history.length >= 32 ? history.length - 31 : 0;
    return List<double>.unmodifiable([...history.sublist(start), value]);
  }

  _ServerTelemetryState? get _currentState {
    final key = _currentServerKey;
    return key != null ? _states[key] : null;
  }

  ServerLoadSnapshot get snapshot => _currentState?.snapshot ?? _emptySnapshot;
  List<double> get cpuHistory => _currentState?.cpuHistory ?? const <double>[];
  List<double> get netDownHistory =>
      _currentState?.netDownHistory ?? const <double>[];

  @override
  PluginManifest get manifest => const PluginManifest(
    id: pluginId,
    name: '服务器负载监控',
    version: '1.3.0',
    author: 'TermX Core Team',
    description:
        '实时监控本地主机（Windows PowerShell / Unix）与远端 SSH 服务器的 CPU、物理内存、磁盘、网络吞吐及活跃进程四维排行。',
    icon: Icons.monitor_heart_outlined,
    accentColor: Color(0xFF4ADE80),
    permissions: [
      PluginPermission.sshExec,
      PluginPermission.uiStatusBar,
      PluginPermission.uiPanel,
    ],
    isCorePlugin: true,
  );

  @override
  Future<void> onInit() async {
    _unloaded = false;
    _startPolling();
  }

  @override
  void onActiveSessionChanged(SshSessionController? session) {
    final prevKey = _currentServerKey;
    final nextKey = _serverKey(session);
    _currentSession = session;
    _currentServerKey = nextKey;

    if (nextKey == null || session == null) {
      if (prevKey != null) {
        notifyListeners();
      }
      return;
    }

    final state = _states.putIfAbsent(nextKey, () {
      if (_states.length >= 32) {
        _states.remove(_states.keys.first);
      }
      return _ServerTelemetryState(isDemoMode: session.isDemoMode);
    });
    state.attachSession(session);

    if (prevKey != nextKey) {
      state.hasFreshProcessSample =
          session.isDemoMode || state.snapshot.memTotalGb > 0;
      notifyListeners();
      _pollOnce();
      return;
    }

    // 同一台服务器或本机不同分屏窗格切换：保留快照、趋势曲线与计数器基线，无闪烁衔接
    if (state.snapshot.memTotalGb <= 0 || state.samplingError != null) {
      _pollOnce();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _scheduledInterval = refreshInterval;
    _pollTimer = Timer.periodic(refreshInterval, (_) {
      _pollOnce();
    });
  }

  Future<void> _pollOnce() async {
    if (_unloaded) return;
    if (_scheduledInterval != refreshInterval) _startPolling();
    final key = _currentServerKey;
    if (key == null) return;
    final state = _states[key];
    if (state == null || state.pollInFlight) return;
    final session = state.pollableSession;
    if (session == null) return;

    // 1. 本机 PowerShell / 本地终端会话采样
    if (session.isLocalSession) {
      state.pollInFlight = true;
      try {
        final elapsed = _sampleClock.elapsed;
        final sample = localSamplerOverride != null
            ? await localSamplerOverride!(elapsed)
            : await state.localSampler.sample(elapsed);
        if (_unloaded || _currentServerKey != key) return;
        _applyLinuxTelemetry(state, sample);
        state.samplingError = null;
        state.hasFreshProcessSample = true;
        notifyListeners();
      } catch (_) {
        if (!_unloaded && _currentServerKey == key && !session.isDisposed) {
          state.samplingError = '本机资源采样失败，当前显示上次成功的数据，稍后自动重试。';
          notifyListeners();
        }
      } finally {
        state.pollInFlight = false;
      }
      return;
    }

    // 2. 远端真实 SSH 会话采样
    if (!session.isDemoMode) {
      state.pollInFlight = true;
      try {
        final raw = await session.execBackgroundCommand(
          LinuxTelemetrySampler.command,
        );
        if (_unloaded || _currentServerKey != key) return;
        final sample = state.sampler.sample(raw, _sampleClock.elapsed);
        _applyLinuxTelemetry(state, sample);
        state.samplingError = null;
        state.hasFreshProcessSample = true;
        notifyListeners();
      } catch (_) {
        if (!_unloaded && _currentServerKey == key && !session.isDisposed) {
          state.samplingError = '监控采样失败，当前显示上次成功的数据，稍后自动重试。';
          notifyListeners();
        }
      } finally {
        state.pollInFlight = false;
      }
      return;
    }

    // 3. 演示沙盒平滑波动数据
    final prev = state.snapshot;
    final delta = (_rng.nextDouble() - 0.48) * 7.5;
    final nextCpu = (prev.cpuTotalPercent + delta).clamp(6.0, 94.0);
    final cores = List<double>.generate(8, (i) {
      final base = nextCpu + (_rng.nextDouble() - 0.5) * 18.0;
      return base.clamp(3.0, 99.0);
    });
    final nextUp = (320.0 + _rng.nextDouble() * 480.0);
    final nextDown = (680.0 + _rng.nextDouble() * 1450.0);

    state.cpuHistory = _appendMetric(state.cpuHistory, nextCpu);
    state.netDownHistory = _appendMetric(state.netDownHistory, nextDown);
    state.hasFreshProcessSample = true;

    state.snapshot = ServerLoadSnapshot(
      cpuTotalPercent: nextCpu,
      perCorePercents: cores,
      load1m: double.parse((0.35 + nextCpu / 120.0).toStringAsFixed(2)),
      load5m: prev.load5m,
      load15m: prev.load15m,
      memUsedGb: double.parse(
        (prev.memUsedGb + (_rng.nextDouble() - 0.5) * 0.12)
            .clamp(4.2, 13.8)
            .toStringAsFixed(2),
      ),
      memCachedGb: prev.memCachedGb,
      memTotalGb: prev.memTotalGb,
      netUpKbps: nextUp,
      netDownKbps: nextDown,
      disks: prev.disks,
      topProcesses: prev.topProcesses,
    );
    notifyListeners();
  }

  void _applyLinuxTelemetry(
    _ServerTelemetryState state,
    LinuxTelemetry sample,
  ) {
    state.cpuHistory = _appendMetric(state.cpuHistory, sample.cpu);
    state.netDownHistory = _appendMetric(state.netDownHistory, sample.downKbps);
    state.snapshot = ServerLoadSnapshot(
      cpuTotalPercent: sample.cpu,
      perCorePercents: sample.cores,
      load1m: sample.loads[0],
      load5m: sample.loads[1],
      load15m: sample.loads[2],
      memUsedGb: sample.usedGb,
      memCachedGb: sample.cachedGb,
      memTotalGb: sample.totalGb,
      netUpKbps: sample.upKbps,
      netDownKbps: sample.downKbps,
      disks: sample.disks
          .map(
            (disk) => DiskMountMetric(
              mountPoint: disk.mountPoint,
              device: disk.device,
              usedGb: disk.usedGb,
              totalGb: disk.totalGb,
              reportedRatio: disk.ratio,
            ),
          )
          .toList(),
      topProcesses: sample.processes
          .map(
            (process) => ProcessMetric(
              pid: process.pid,
              command: process.command,
              cpuPercent: process.cpuPercent,
              memPercent: process.memPercent,
              memMb: process.memMb,
              diskKbps: process.diskKbps,
              netKbps: process.netKbps,
              netConns: process.netConns,
            ),
          )
          .toList(),
    );
  }

  List<ProcessMetric> _sortedTopProcesses(
    List<ProcessMetric> all, {
    int limit = 15,
  }) {
    if (all.isEmpty) return const [];
    final sorted = List<ProcessMetric>.of(all);
    final dir = _processSortDescending ? -1 : 1;

    sorted.sort((a, b) {
      int cmp;
      switch (_processSortBy) {
        case ProcessSortBy.cpu:
          cmp = a.cpuPercent.compareTo(b.cpuPercent);
          if (cmp == 0) {
            cmp = (a.memMb ?? a.memPercent).compareTo(b.memMb ?? b.memPercent);
          }
        case ProcessSortBy.memory:
          cmp = (a.memMb ?? a.memPercent).compareTo(b.memMb ?? b.memPercent);
          if (cmp == 0) {
            cmp = a.cpuPercent.compareTo(b.cpuPercent);
          }
        case ProcessSortBy.disk:
          cmp = a.diskKbps.compareTo(b.diskKbps);
          if (cmp == 0) {
            cmp = a.cpuPercent.compareTo(b.cpuPercent);
          }
        case ProcessSortBy.network:
          cmp = a.netKbps.compareTo(b.netKbps);
          if (cmp == 0) {
            cmp = a.netConns.compareTo(b.netConns);
          }
          if (cmp == 0) {
            cmp = a.cpuPercent.compareTo(b.cpuPercent);
          }
      }
      if (cmp != 0) return cmp * dir;
      return a.pid.compareTo(b.pid);
    });

    return sorted.take(limit).toList();
  }

  static String _formatRateKbps(double kbps) {
    if (kbps < 0.05) return '0 KB/s';
    if (kbps < 1024.0) {
      return kbps >= 10.0
          ? '${kbps.toStringAsFixed(0)} KB/s'
          : '${kbps.toStringAsFixed(1)} KB/s';
    }
    return '${(kbps / 1024.0).toStringAsFixed(1)} MB/s';
  }

  static String _formatMemMetric(ProcessMetric p) {
    final mb = p.memMb;
    if (mb == null) {
      return '${p.memPercent.toStringAsFixed(1)}%';
    }
    if (mb >= 1024.0) {
      return '${(mb / 1024.0).toStringAsFixed(1)} GB (${p.memPercent.toStringAsFixed(1)}%)';
    }
    return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB (${p.memPercent.toStringAsFixed(1)}%)';
  }

  static String _formatNetMetric(ProcessMetric p) {
    if (p.netKbps >= 0.05) {
      final rate = _formatRateKbps(p.netKbps);
      return p.netConns > 0 ? '$rate (${p.netConns})' : rate;
    }
    if (p.netConns > 0) {
      return '0 KB/s (${p.netConns}连接)';
    }
    return '0 KB/s';
  }

  @override
  void onUnload() {
    _unloaded = true;
    _pollTimer?.cancel();
  }

  @override
  Widget buildStatusBarWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) {
    final activeSession = pluginContext.activeSession;
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        final targetSession = activeSession ?? _currentSession;
        if (targetSession == null) {
          return const SizedBox.shrink();
        }
        final targetKey = _serverKey(targetSession);
        final state = targetKey != null ? _states[targetKey] : null;
        final s =
            state?.snapshot ??
            (targetSession.isDemoMode ? _demoSnapshot : _emptySnapshot);
        final isLocal = targetSession.isLocalSession;
        final cpuColor = s.cpuTotalPercent > 85
            ? TxColors.danger
            : s.cpuTotalPercent > 65
            ? TxColors.warning
            : TxColors.textSecondary;

        return InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => pluginContext.requestOpenPanel(pluginId),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isLocal) ...[
                    const Text(
                      '本机',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                        color: TxColors.accent,
                      ),
                    ),
                    const Text(
                      '  ·  ',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: TxColors.textMuted,
                      ),
                    ),
                  ],
                  Text(
                    'CPU ${s.cpuTotalPercent.toStringAsFixed(0)}%',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontFamily: TxColors.monoFamily,
                      fontWeight: FontWeight.w600,
                      color: cpuColor,
                    ),
                  ),
                  const Text(
                    '  ·  ',
                    style: TextStyle(fontSize: 10.5, color: TxColors.textMuted),
                  ),
                  Text(
                    'RAM ${s.memUsedGb.toStringAsFixed(1)}/${s.memTotalGb.toStringAsFixed(0)}G',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontFamily: TxColors.monoFamily,
                      color: TxColors.textSecondary,
                    ),
                  ),
                  const Text(
                    '  ·  ',
                    style: TextStyle(fontSize: 10.5, color: TxColors.textMuted),
                  ),
                  Text(
                    '↓${(s.netDownKbps / 1024).toStringAsFixed(2)}M ↑${(s.netUpKbps / 1024).toStringAsFixed(2)}M',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontFamily: TxColors.monoFamily,
                      color: TxColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget buildPanelWidget(BuildContext context, PluginContext pluginContext) {
    final activeSession = pluginContext.activeSession;
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        final targetSession = activeSession ?? _currentSession;
        final isLocal = targetSession?.isLocalSession == true;
        final isLocalWindows = isLocal && Platform.isWindows;
        final targetKey = _serverKey(targetSession);
        final state = targetKey != null ? _states[targetKey] : null;
        final s =
            state?.snapshot ??
            (targetSession?.isDemoMode == true
                ? _demoSnapshot
                : _emptySnapshot);
        final samplingError = state?.samplingError;
        final cpuValues =
            state?.cpuHistory ??
            (targetSession?.isDemoMode == true
                ? List<double>.unmodifiable(List<double>.filled(32, 18.0))
                : const <double>[]);
        final netValues =
            state?.netDownHistory ??
            (targetSession?.isDemoMode == true
                ? List<double>.unmodifiable(List<double>.filled(32, 320.0))
                : const <double>[]);
        if (s.memTotalGb <= 0) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                samplingError ??
                    (isLocal ? '正在读取本机监控数据…' : '正在读取服务器监控数据…'),
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12,
                  color: TxColors.textMuted,
                ),
              ),
            ),
          );
        }
        final cpuHeadlineColor = s.cpuTotalPercent > 85
            ? TxColors.danger
            : s.cpuTotalPercent > 65
            ? TxColors.warning
            : TxColors.textPrimary;
        final netPeakKbps = netValues.isEmpty
            ? 2500.0
            : max(1024.0, netValues.reduce(max) * 1.18);
        final sortedProcesses = _sortedTopProcesses(s.topProcesses);

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            if (isLocal)
              Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: TxColors.accentSoft,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: TxColors.accent.withValues(alpha: 0.35),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.computer_rounded,
                      size: 14,
                      color: TxColors.accent,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        isLocalWindows
                            ? '本机资源监控 (Windows PowerShell)'
                            : '本机资源监控 (Local Shell)',
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                          color: TxColors.textPrimary,
                        ),
                      ),
                    ),
                    const Text(
                      '1s 实时',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontFamily: TxColors.monoFamily,
                        color: TxColors.accent,
                      ),
                    ),
                  ],
                ),
              ),
            if (samplingError != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  samplingError,
                  style: const TextStyle(
                    fontSize: 11,
                    color: TxColors.warning,
                  ),
                ),
              ),
            _buildSectionHeader(
              icon: Icons.speed_rounded,
              title: 'CPU 与负载',
              trailing: 'Load ${s.load1m} / ${s.load5m} / ${s.load15m}',
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: _cardDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      Text(
                        '总使用率 ${s.cpuTotalPercent.toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: cpuHeadlineColor,
                        ),
                      ),
                      Text(
                        '${s.perCorePercents.length} 核心',
                        style: const TextStyle(
                          fontSize: 11,
                          fontFamily: TxColors.monoFamily,
                          color: TxColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  SizedBox(
                    height: 58,
                    width: double.infinity,
                    child: CustomPaint(
                      painter: _SparklinePainter(
                        values: cpuValues,
                        lineColor: TxColors.accent,
                        maxVal: 100.0,
                      ),
                    ),
                  ),
                  if (s.perCorePercents.isNotEmpty) ...[
                    const SizedBox(height: 11),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: List.generate(s.perCorePercents.length, (idx) {
                        final val = s.perCorePercents[idx];
                        return SizedBox(
                          width: 72,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    'C$idx',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontFamily: TxColors.monoFamily,
                                      color: TxColors.textMuted,
                                    ),
                                  ),
                                  Text(
                                    '${val.toStringAsFixed(0)}%',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontFamily: TxColors.monoFamily,
                                      color: TxColors.textSecondary,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: LinearProgressIndicator(
                                  value: val / 100.0,
                                  minHeight: 4,
                                  backgroundColor: TxColors.borderSubtle,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    val > 85
                                        ? TxColors.danger
                                        : val > 65
                                        ? TxColors.warning
                                        : TxColors.accent,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      }),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 14),
            _buildSectionHeader(
              icon: Icons.memory_rounded,
              title: '物理内存',
              trailing:
                  '${(s.memUsedGb / s.memTotalGb * 100).toStringAsFixed(0)}%',
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: _cardDecoration(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 14,
                    runSpacing: 6,
                    children: [
                      _buildMemLegend(
                        '已用',
                        '${s.memUsedGb.toStringAsFixed(1)} GB',
                        TxColors.accent,
                      ),
                      _buildMemLegend(
                        '缓存',
                        '${s.memCachedGb.toStringAsFixed(1)} GB',
                        const Color(0xFF4B5565),
                      ),
                      _buildMemLegend(
                        '可用',
                        '${(s.memTotalGb - s.memUsedGb - s.memCachedGb).clamp(0, 9999).toStringAsFixed(1)} GB',
                        TxColors.borderStrong,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: SizedBox(
                      height: 7,
                      child: Row(
                        children: [
                          Expanded(
                            flex: max(1, (s.memUsedGb * 10).round()),
                            child: Container(color: TxColors.accent),
                          ),
                          if (s.memCachedGb > 0.05)
                            Expanded(
                              flex: max(1, (s.memCachedGb * 10).round()),
                              child: Container(color: const Color(0xFF4B5565)),
                            ),
                          Expanded(
                            flex: max(
                              1,
                              ((s.memTotalGb - s.memUsedGb - s.memCachedGb)
                                          .clamp(0.0, double.infinity) *
                                      10)
                                  .round(),
                            ),
                            child: Container(color: TxColors.borderSubtle),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _buildSectionHeader(
              icon: Icons.swap_vert_rounded,
              title: '网络吞吐',
              trailing:
                  '↓${_formatRateKbps(s.netDownKbps)}  ↑${_formatRateKbps(s.netUpKbps)}',
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(11),
              decoration: _cardDecoration(),
              child: SizedBox(
                height: 48,
                width: double.infinity,
                child: CustomPaint(
                  painter: _SparklinePainter(
                    values: netValues,
                    lineColor: const Color(0xFF4AB8C4),
                    maxVal: netPeakKbps,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _buildSectionHeader(
              icon: Icons.storage_rounded,
              title: '磁盘存储',
              trailing: isLocal
                  ? '${s.disks.length} 个磁盘分区'
                  : '${s.disks.length} 个挂载点',
            ),
            const SizedBox(height: 6),
            ...s.disks.map((d) {
              final barColor = d.ratio >= 0.90
                  ? TxColors.danger
                  : d.ratio >= 0.80
                  ? TxColors.warning
                  : TxColors.accent;
              return Container(
                margin: const EdgeInsets.only(bottom: 6),
                padding: const EdgeInsets.all(10),
                decoration: _cardDecoration(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        Text(
                          '${d.mountPoint} (${d.device})',
                          style: const TextStyle(
                            fontSize: 11.5,
                            fontFamily: TxColors.monoFamily,
                            fontWeight: FontWeight.w500,
                            color: TxColors.textPrimary,
                          ),
                        ),
                        Text(
                          '${d.usedGb.toStringAsFixed(1)} / ${d.totalGb.toStringAsFixed(0)} GB (${(d.ratio * 100).toStringAsFixed(0)}%)',
                          style: TextStyle(
                            fontSize: 10.5,
                            fontFamily: TxColors.monoFamily,
                            color: d.ratio >= 0.80
                                ? barColor
                                : TxColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2.5),
                      child: LinearProgressIndicator(
                        value: d.ratio,
                        minHeight: 5,
                        backgroundColor: TxColors.borderSubtle,
                        valueColor: AlwaysStoppedAnimation<Color>(barColor),
                      ),
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 8),
            _buildSectionHeader(
              icon: Icons.layers_outlined,
              title: '活跃进程',
              trailing: isLocalWindows ? 'Stop-Process' : 'SIGTERM',
            ),
            const SizedBox(height: 6),
            _buildProcessSortToolbar(),
            const SizedBox(height: 6),
            Container(
              decoration: _cardDecoration(),
              child: Column(
                children: [
                  for (var i = 0; i < sortedProcesses.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, color: TxColors.borderSubtle),
                    Builder(
                      builder: (context) {
                        final p = sortedProcesses[i];
                        final stopCmd = isLocalWindows
                            ? 'Stop-Process -Id ${p.pid}'
                            : 'kill -15 ${p.pid}';
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(11, 8, 6, 8),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
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
                                              fontWeight: FontWeight.w500,
                                              color: TxColors.textPrimary,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 6),
                                        Text(
                                          'PID ${p.pid}',
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                            fontFamily: TxColors.monoFamily,
                                            color: TxColors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Wrap(
                                      spacing: 9,
                                      runSpacing: 3,
                                      children: [
                                        _buildProcMetricSpan(
                                          'CPU ${p.cpuPercent.toStringAsFixed(1)}%',
                                          highlighted:
                                              _processSortBy ==
                                              ProcessSortBy.cpu,
                                        ),
                                        _buildProcMetricSpan(
                                          '内存 ${_formatMemMetric(p)}',
                                          highlighted:
                                              _processSortBy ==
                                              ProcessSortBy.memory,
                                        ),
                                        _buildProcMetricSpan(
                                          '磁盘 ${_formatRateKbps(p.diskKbps)}',
                                          highlighted:
                                              _processSortBy ==
                                              ProcessSortBy.disk,
                                        ),
                                        _buildProcMetricSpan(
                                          '网络 ${_formatNetMetric(p)}',
                                          highlighted:
                                              _processSortBy ==
                                              ProcessSortBy.network,
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: 32,
                                height: 32,
                                child: IconButton(
                                  padding: EdgeInsets.zero,
                                  style: IconButton.styleFrom(
                                    hoverColor: TxColors.bgHover,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                  ),
                                  tooltip: '结束进程 ($stopCmd)',
                                  icon: const Icon(
                                    Icons.stop_circle_outlined,
                                    size: 17,
                                    color: TxColors.iconDefault,
                                  ),
                                    onPressed: () {
                                      final currentActive =
                                          pluginContext.activeSession;
                                      final activeKey = _serverKey(
                                        currentActive,
                                      );
                                      if (currentActive == null ||
                                          currentActive.isDisposed ||
                                          currentActive.state !=
                                              SessionConnectionState
                                                  .connected ||
                                          activeKey == null ||
                                          activeKey != targetKey ||
                                          activeKey != _currentServerKey ||
                                          state == null ||
                                          !state.hasFreshProcessSample) {
                                        pluginContext.showToast(
                                          '会话已切换或断开，请等待最新进程列表后重试',
                                        );
                                        return;
                                      }
                                      pluginContext.writeToTerminal(stopCmd);
                                      pluginContext.showToast(
                                        '已向终端注入命令: $stopCmd',
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      );
    }

  Widget _buildProcessSortToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
      decoration: BoxDecoration(
        color: TxColors.bgPanel,
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: TxColors.borderSubtle),
      ),
      child: Row(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 5),
            child: Text(
              '排序',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: TxColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: 2),
          for (final dim in ProcessSortBy.values) ...[
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2.5),
                child: InkWell(
                  key: ValueKey<String>('proc-sort-${dim.name}'),
                  borderRadius: BorderRadius.circular(6),
                  hoverColor: TxColors.bgHover,
                  onTap: () => setProcessSort(dim),
                  child: Container(
                    height: 30,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _processSortBy == dim
                          ? TxColors.accentSoft
                          : TxColors.bgChrome,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _processSortBy == dim
                            ? TxColors.accent.withValues(alpha: 0.7)
                            : TxColors.borderSubtle,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              dim.label,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: _processSortBy == dim
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                color: _processSortBy == dim
                                    ? TxColors.textPrimary
                                    : TxColors.textSecondary,
                              ),
                            ),
                            if (_processSortBy == dim) ...[
                              const SizedBox(width: 2),
                              Icon(
                                _processSortDescending
                                    ? Icons.arrow_downward_rounded
                                    : Icons.arrow_upward_rounded,
                                size: 13.5,
                                color: TxColors.accent,
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProcMetricSpan(String text, {required bool highlighted}) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11.5,
        fontFamily: TxColors.monoFamily,
        fontWeight: highlighted ? FontWeight.w600 : FontWeight.w400,
        color: highlighted ? TxColors.accent : TxColors.textMuted,
      ),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required String trailing,
  }) {
    return Row(
      children: [
        Icon(icon, size: 15, color: TxColors.textSecondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
              color: TxColors.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            trailing,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 11.5,
              fontFamily: TxColors.monoFamily,
              color: TxColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMemLegend(String label, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 10, color: TxColors.textMuted),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: TxColors.monoFamily,
                fontWeight: FontWeight.w600,
                color: TxColors.textPrimary,
              ),
            ),
          ],
        ),
      ],
    );
  }

  BoxDecoration _cardDecoration() {
    return BoxDecoration(
      color: TxColors.bgPanel,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: TxColors.borderSubtle),
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color lineColor;
  final double maxVal;

  const _SparklinePainter({
    required this.values,
    required this.lineColor,
    required this.maxVal,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(0, size.height * 0.33),
      Offset(size.width, size.height * 0.33),
      gridPaint,
    );
    canvas.drawLine(
      Offset(0, size.height * 0.66),
      Offset(size.width, size.height * 0.66),
      gridPaint,
    );

    if (values.length < 2) return;

    final path = Path();
    final fillPath = Path();
    final stepX = size.width / (values.length - 1);

    for (var i = 0; i < values.length; i++) {
      final normalized = (values[i] / maxVal).clamp(0.0, 1.0);
      final x = i * stepX;
      final y = size.height - (normalized * size.height);
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, size.height);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }

    fillPath.lineTo(size.width, size.height);
    fillPath.close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          lineColor.withValues(alpha: 0.16),
          lineColor.withValues(alpha: 0.0),
        ],
      ).createShader(Offset.zero & size);

    final strokePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.6
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    canvas.drawPath(fillPath, fillPaint);
    canvas.drawPath(path, strokePaint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) =>
      !identical(values, oldDelegate.values) ||
      lineColor != oldDelegate.lineColor ||
      maxVal != oldDelegate.maxVal;
}
