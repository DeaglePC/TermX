import 'dart:async';
import 'dart:math';

import 'linux_telemetry.dart';

import 'package:flutter/material.dart';

import '../../core/plugin_system/plugin_interface.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../../core/theme/ui_tokens.dart';

class ProcessMetric {
  final int pid;
  final String command;
  final double cpuPercent;
  final double memPercent;

  const ProcessMetric({
    required this.pid,
    required this.command,
    required this.cpuPercent,
    required this.memPercent,
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
        !primary.isLocalSession &&
        primary.state == SessionConnectionState.connected) {
      return primary;
    }
    for (final candidate in knownSessions.toList().reversed) {
      if (!candidate.isLocalSession &&
          candidate.state == SessionConnectionState.connected) {
        return candidate;
      }
    }
    return null;
  }
}

/// [核心插件 1] 服务器负载实时监控插件 (`plugin.server_monitor`)
/// 复用当前活跃 SSH 会话的独立 Exec 通道采集 CPU、内存、磁盘、网卡流量与 Top 进程
class ServerMonitorPlugin extends TermXPlugin {
  static const String pluginId = 'plugin.server_monitor';

  Timer? _pollTimer;
  static const refreshInterval = Duration(seconds: 1);
  Duration? _scheduledInterval;
  bool _unloaded = false;
  final Stopwatch _sampleClock = Stopwatch()..start();
  SshSessionController? _currentSession;
  String? _currentServerKey;
  final Map<String, _ServerTelemetryState> _states = {};
  final Random _rng = Random();

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
      ),
      ProcessMetric(
        pid: 2190,
        command: 'postgres: walwriter',
        cpuPercent: 5.1,
        memPercent: 18.6,
      ),
      ProcessMetric(
        pid: 1884,
        command: 'redis-server *:6379',
        cpuPercent: 3.8,
        memPercent: 9.4,
      ),
      ProcessMetric(
        pid: 3412,
        command: 'dockerd --containerd',
        cpuPercent: 2.2,
        memPercent: 6.1,
      ),
    ],
  );

  static String? _serverKey(SshSessionController? session) {
    if (session == null || session.isLocalSession) return null;
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
    version: '1.2.0',
    author: 'TermX Core Team',
    description:
        '无需在远端安装 Agent，通过 SSH 独立 Exec 通道实时监控服务器 CPU、内存、磁盘、网络吞吐与 Top 进程。',
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
      state.hasFreshProcessSample = session.isDemoMode;
      notifyListeners();
      _pollOnce();
      return;
    }

    // 同一台服务器（例如切换分屏窗格、新建分屏或刚完成重连）：
    // 保留现有快照、趋势曲线与采样基线，避免右侧负载面板闪烁或归零。
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
    // Keep an already-running timer in sync when the interval changes.
    if (_scheduledInterval != refreshInterval) _startPolling();
    final key = _currentServerKey;
    if (key == null) return;
    final state = _states[key];
    if (state == null || state.pollInFlight) return;
    final session = state.pollableSession;
    if (session == null) return;

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

    // 仿真平滑波动数据
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
            ),
          )
          .toList(),
    );
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
    if (activeSession?.isLocalSession == true) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        final targetSession = activeSession ?? _currentSession;
        final targetKey = _serverKey(targetSession);
        final state = targetKey != null ? _states[targetKey] : null;
        final s = state?.snapshot ??
            (targetSession?.isDemoMode == true ? _demoSnapshot : _emptySnapshot);
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
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
        );
      },
    );
  }

  @override
  Widget buildPanelWidget(BuildContext context, PluginContext pluginContext) {
    final activeSession = pluginContext.activeSession;
    if (activeSession?.isLocalSession == true) {
      return localSessionNotice();
    }
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        final targetSession = activeSession ?? _currentSession;
        final targetKey = _serverKey(targetSession);
        final state = targetKey != null ? _states[targetKey] : null;
        final s = state?.snapshot ??
            (targetSession?.isDemoMode == true ? _demoSnapshot : _emptySnapshot);
        final samplingError = state?.samplingError;
        final cpuValues = state?.cpuHistory ??
            (targetSession?.isDemoMode == true
                ? List<double>.unmodifiable(List<double>.filled(32, 18.0))
                : const <double>[]);
        final netValues = state?.netDownHistory ??
            (targetSession?.isDemoMode == true
                ? List<double>.unmodifiable(List<double>.filled(32, 320.0))
                : const <double>[]);
        if (s.memTotalGb <= 0) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                samplingError ?? '正在读取服务器监控数据…',
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

        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
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
                  '↓${s.netDownKbps.toStringAsFixed(0)} KB/s  ↑${s.netUpKbps.toStringAsFixed(0)} KB/s',
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
                    maxVal: 2500.0,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _buildSectionHeader(
              icon: Icons.storage_rounded,
              title: '磁盘存储',
              trailing: '${s.disks.length} 个挂载点',
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
              trailing: 'SIGTERM',
            ),
            const SizedBox(height: 6),
            Container(
              decoration: _cardDecoration(),
              child: Column(
                children: [
                  for (var i = 0; i < s.topProcesses.length; i++) ...[
                    if (i > 0)
                      const Divider(height: 1, color: TxColors.borderSubtle),
                    Builder(
                      builder: (context) {
                        final p = s.topProcesses[i];
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      p.command,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11.5,
                                        fontFamily: TxColors.monoFamily,
                                        color: TxColors.textPrimary,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      'PID ${p.pid}  ·  CPU ${p.cpuPercent.toStringAsFixed(1)}%  ·  MEM ${p.memPercent.toStringAsFixed(1)}%',
                                      style: const TextStyle(
                                        fontSize: 10.5,
                                        fontFamily: TxColors.monoFamily,
                                        color: TxColors.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.compact,
                                constraints: const BoxConstraints(
                                  minWidth: 28,
                                  minHeight: 28,
                                ),
                                padding: EdgeInsets.zero,
                                tooltip: '结束进程 (kill -15 ${p.pid})',
                                icon: const Icon(
                                  Icons.stop_circle_outlined,
                                  size: 15,
                                  color: TxColors.textMuted,
                                ),
                                onPressed: () {
                                  final currentActive =
                                      pluginContext.activeSession;
                                  final activeKey = _serverKey(currentActive);
                                  if (currentActive == null ||
                                      currentActive.isDisposed ||
                                      currentActive.state !=
                                          SessionConnectionState.connected ||
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
                                  pluginContext.writeToTerminal(
                                    'kill -15 ${p.pid}',
                                  );
                                  pluginContext.showToast(
                                    '已向终端注入命令: kill -15 ${p.pid}',
                                  );
                                },
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

  Widget _buildSectionHeader({
    required IconData icon,
    required String title,
    required String trailing,
  }) {
    return Row(
      children: [
        Icon(icon, size: 13.5, color: TxColors.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: TxColors.textSecondary,
            ),
          ),
        ),
        Text(
          trailing,
          style: const TextStyle(
            fontSize: 10.5,
            fontFamily: TxColors.monoFamily,
            color: TxColors.textMuted,
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
