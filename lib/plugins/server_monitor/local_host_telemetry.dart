import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'linux_telemetry.dart';

// ==================== Win32 / NT Native FFI Typedefs ====================

typedef _GetProcessHeapNative = Pointer<Void> Function();
typedef _GetProcessHeapDart = Pointer<Void> Function();

typedef _HeapAllocNative = Pointer<Uint8> Function(
  Pointer<Void> hHeap,
  Uint32 dwFlags,
  IntPtr dwBytes,
);
typedef _HeapAllocDart = Pointer<Uint8> Function(
  Pointer<Void> hHeap,
  int dwFlags,
  int dwBytes,
);

typedef _HeapFreeNative = Int32 Function(
  Pointer<Void> hHeap,
  Uint32 dwFlags,
  Pointer<Void> lpMem,
);
typedef _HeapFreeDart = int Function(
  Pointer<Void> hHeap,
  int dwFlags,
  Pointer<Void> lpMem,
);

typedef _GlobalMemoryStatusExNative = Int32 Function(Pointer<Uint8> lpBuffer);
typedef _GlobalMemoryStatusExDart = int Function(Pointer<Uint8> lpBuffer);

typedef _K32GetPerformanceInfoNative = Int32 Function(
  Pointer<Uint8> pPerformanceInformation,
  Uint32 cb,
);
typedef _K32GetPerformanceInfoDart = int Function(
  Pointer<Uint8> pPerformanceInformation,
  int cb,
);

typedef _GetLogicalDrivesNative = Uint32 Function();
typedef _GetLogicalDrivesDart = int Function();

typedef _GetDriveTypeWNative = Uint32 Function(Pointer<Uint16> lpRootPathName);
typedef _GetDriveTypeWDart = int Function(Pointer<Uint16> lpRootPathName);

typedef _GetDiskFreeSpaceExWNative = Int32 Function(
  Pointer<Uint16> lpDirectoryName,
  Pointer<Uint64> lpFreeBytesAvailableToCaller,
  Pointer<Uint64> lpTotalNumberOfBytes,
  Pointer<Uint64> lpTotalNumberOfFreeBytes,
);
typedef _GetDiskFreeSpaceExWDart = int Function(
  Pointer<Uint16> lpDirectoryName,
  Pointer<Uint64> lpFreeBytesAvailableToCaller,
  Pointer<Uint64> lpTotalNumberOfBytes,
  Pointer<Uint64> lpTotalNumberOfFreeBytes,
);

typedef _GetVolumeInformationWNative = Int32 Function(
  Pointer<Uint16> lpRootPathName,
  Pointer<Uint16> lpVolumeNameBuffer,
  Uint32 nVolumeNameSize,
  Pointer<Uint32> lpVolumeSerialNumber,
  Pointer<Uint32> lpMaximumComponentLength,
  Pointer<Uint32> lpFileSystemFlags,
  Pointer<Uint16> lpFileSystemNameBuffer,
  Uint32 nFileSystemNameSize,
);
typedef _GetVolumeInformationWDart = int Function(
  Pointer<Uint16> lpRootPathName,
  Pointer<Uint16> lpVolumeNameBuffer,
  int nVolumeNameSize,
  Pointer<Uint32> lpVolumeSerialNumber,
  Pointer<Uint32> lpMaximumComponentLength,
  Pointer<Uint32> lpFileSystemFlags,
  Pointer<Uint16> lpFileSystemNameBuffer,
  int nFileSystemNameSize,
);

typedef _NtQuerySystemInformationNative = Int32 Function(
  Int32 systemInformationClass,
  Pointer<Uint8> systemInformation,
  Uint32 systemInformationLength,
  Pointer<Uint32> returnLength,
);
typedef _NtQuerySystemInformationDart = int Function(
  int systemInformationClass,
  Pointer<Uint8> systemInformation,
  int systemInformationLength,
  Pointer<Uint32> returnLength,
);

typedef _GetIfTable2Native = Uint32 Function(Pointer<Pointer<Uint8>> table);
typedef _GetIfTable2Dart = int Function(Pointer<Pointer<Uint8>> table);

typedef _FreeMibTableNative = Void Function(Pointer<Uint8> memory);
typedef _FreeMibTableDart = void Function(Pointer<Uint8> memory);

typedef _GetExtendedTcpTableNative = Uint32 Function(
  Pointer<Uint8> pTcpTable,
  Pointer<Uint32> pdwSize,
  Int32 bOrder,
  Uint32 ulAf,
  Int32 tableClass,
  Uint32 reserved,
);
typedef _GetExtendedTcpTableDart = int Function(
  Pointer<Uint8> pTcpTable,
  Pointer<Uint32> pdwSize,
  int bOrder,
  int ulAf,
  int tableClass,
  int reserved,
);

typedef _GetExtendedUdpTableNative = Uint32 Function(
  Pointer<Uint8> pUdpTable,
  Pointer<Uint32> pdwSize,
  Int32 bOrder,
  Uint32 ulAf,
  Int32 tableClass,
  Uint32 reserved,
);
typedef _GetExtendedUdpTableDart = int Function(
  Pointer<Uint8> pUdpTable,
  Pointer<Uint32> pdwSize,
  int bOrder,
  int ulAf,
  int tableClass,
  int reserved,
);

class _Win32Bindings {
  static _Win32Bindings? _instance;
  static _Win32Bindings get instance => _instance ??= _Win32Bindings._();

  late final Pointer<Void> processHeap;
  late final _HeapAllocDart heapAlloc;
  late final _HeapFreeDart heapFree;
  late final _GlobalMemoryStatusExDart globalMemoryStatusEx;
  late final _K32GetPerformanceInfoDart getPerformanceInfo;
  late final _GetLogicalDrivesDart getLogicalDrives;
  late final _GetDriveTypeWDart getDriveTypeW;
  late final _GetDiskFreeSpaceExWDart getDiskFreeSpaceExW;
  late final _GetVolumeInformationWDart getVolumeInformationW;
  late final _NtQuerySystemInformationDart ntQuerySystemInformation;
  late final _GetIfTable2Dart getIfTable2;
  late final _FreeMibTableDart freeMibTable;
  late final _GetExtendedTcpTableDart getExtendedTcpTable;
  late final _GetExtendedUdpTableDart getExtendedUdpTable;

  _Win32Bindings._() {
    final kernel32 = DynamicLibrary.open('kernel32.dll');
    final ntdll = DynamicLibrary.open('ntdll.dll');
    final iphlpapi = DynamicLibrary.open('iphlpapi.dll');

    final getProcessHeap = kernel32
        .lookupFunction<_GetProcessHeapNative, _GetProcessHeapDart>(
          'GetProcessHeap',
        );
    processHeap = getProcessHeap();
    heapAlloc = kernel32.lookupFunction<_HeapAllocNative, _HeapAllocDart>(
      'HeapAlloc',
    );
    heapFree = kernel32.lookupFunction<_HeapFreeNative, _HeapFreeDart>(
      'HeapFree',
    );
    globalMemoryStatusEx = kernel32
        .lookupFunction<_GlobalMemoryStatusExNative, _GlobalMemoryStatusExDart>(
          'GlobalMemoryStatusEx',
        );
    getPerformanceInfo = kernel32
        .lookupFunction<
          _K32GetPerformanceInfoNative,
          _K32GetPerformanceInfoDart
        >('K32GetPerformanceInfo');
    getLogicalDrives = kernel32
        .lookupFunction<_GetLogicalDrivesNative, _GetLogicalDrivesDart>(
          'GetLogicalDrives',
        );
    getDriveTypeW = kernel32
        .lookupFunction<_GetDriveTypeWNative, _GetDriveTypeWDart>(
          'GetDriveTypeW',
        );
    getDiskFreeSpaceExW = kernel32
        .lookupFunction<_GetDiskFreeSpaceExWNative, _GetDiskFreeSpaceExWDart>(
          'GetDiskFreeSpaceExW',
        );
    getVolumeInformationW = kernel32
        .lookupFunction<
          _GetVolumeInformationWNative,
          _GetVolumeInformationWDart
        >('GetVolumeInformationW');

    ntQuerySystemInformation = ntdll
        .lookupFunction<
          _NtQuerySystemInformationNative,
          _NtQuerySystemInformationDart
        >('NtQuerySystemInformation');

    getIfTable2 = iphlpapi.lookupFunction<_GetIfTable2Native, _GetIfTable2Dart>(
      'GetIfTable2',
    );
    freeMibTable = iphlpapi
        .lookupFunction<_FreeMibTableNative, _FreeMibTableDart>('FreeMibTable');
    getExtendedTcpTable = iphlpapi
        .lookupFunction<_GetExtendedTcpTableNative, _GetExtendedTcpTableDart>(
          'GetExtendedTcpTable',
        );
    getExtendedUdpTable = iphlpapi
        .lookupFunction<_GetExtendedUdpTableNative, _GetExtendedUdpTableDart>(
          'GetExtendedUdpTable',
        );
  }

  Pointer<Uint8> zalloc(int bytes) {
    final ptr = heapAlloc(processHeap, 0x08 /* HEAP_ZERO_MEMORY */, bytes);
    if (ptr.address == 0) {
      throw StateError('Win32 HeapAlloc failed for $bytes bytes');
    }
    return ptr;
  }

  void free(Pointer<NativeType> ptr) {
    if (ptr.address != 0) {
      heapFree(processHeap, 0, ptr.cast<Void>());
    }
  }
}

class _WinProcPrev {
  final int createTime;
  final int cpuTicks;
  final int diskBytes;
  final int otherBytes;

  const _WinProcPrev({
    required this.createTime,
    required this.cpuTicks,
    required this.diskBytes,
    required this.otherBytes,
  });
}

class _WinRawProcEntry {
  final int pid;
  final String name;
  final int createTime;
  final int cpuTicks;
  final int memBytes;
  final int diskBytes;
  final int otherBytes;

  const _WinRawProcEntry({
    required this.pid,
    required this.name,
    required this.createTime,
    required this.cpuTicks,
    required this.memBytes,
    required this.diskBytes,
    required this.otherBytes,
  });
}

/// 本机资源实时采样器（支持 Windows 原生 Win32/NT 内核零进程开销采样，以及 macOS/Linux 本地 Shell 采样）
class LocalHostTelemetrySampler {
  // Windows 累计计数器基线
  List<(int idle, int total)>? _prevCores;
  Map<int, (int rx, int tx)> _prevNicOctets = {};
  Map<int, _WinProcPrev> _prevProcs = {};
  Duration? _prevTime;
  double? _ewma1m;
  double? _ewma5m;
  double? _ewma15m;

  // Unix 本地回退采样器
  final LinuxTelemetrySampler _unixSampler = LinuxTelemetrySampler();

  Future<LinuxTelemetry> sample(Duration elapsed) async {
    if (Platform.isWindows && sizeOf<IntPtr>() == 8) {
      return _sampleWindowsNative(elapsed);
    }
    final res = await Process.run('/bin/sh', [
      '-c',
      LinuxTelemetrySampler.command,
    ]);
    return _unixSampler.sample(res.stdout.toString(), elapsed);
  }

  LinuxTelemetry _sampleWindowsNative(Duration now) {
    final w = _Win32Bindings.instance;
    final dtSec = _prevTime == null
        ? 0.0
        : (now - _prevTime!).inMicroseconds / 1e6;

    // 1. CPU 总使用率与逐核使用率 (NtQuerySystemInformation class 8)
    final coreTicks = _readCorePerformanceTicks(w);
    final corePercents = <double>[];
    var sumDeltaBusy = 0;
    var sumDeltaTotal = 0;

    if (_prevCores != null && _prevCores!.length == coreTicks.length) {
      for (var i = 0; i < coreTicks.length; i++) {
        final dIdle = coreTicks[i].$1 - _prevCores![i].$1;
        final dTotal = coreTicks[i].$2 - _prevCores![i].$2;
        if (dTotal > 0 && dIdle >= 0) {
          final dBusy = max(0, dTotal - dIdle);
          sumDeltaBusy += dBusy;
          sumDeltaTotal += dTotal;
          corePercents.add((dBusy / dTotal * 100.0).clamp(0.0, 100.0));
        } else {
          corePercents.add(0.0);
        }
      }
    } else {
      corePercents.addAll(List<double>.filled(coreTicks.length, 0.0));
    }
    final totalCpu = sumDeltaTotal > 0
        ? (sumDeltaBusy / sumDeltaTotal * 100.0).clamp(0.0, 100.0)
        : 0.0;

    // 计算等效 1m / 5m / 15m 活跃核心指数滑动均值负载
    final activeCoresNow = (totalCpu / 100.0) * max(1, coreTicks.length);
    if (_prevCores == null || _ewma1m == null) {
      if (_prevCores != null) {
        _ewma1m = activeCoresNow;
        _ewma5m = activeCoresNow;
        _ewma15m = activeCoresNow;
      }
    } else if (dtSec > 0) {
      final a1 = 1.0 - exp(-dtSec / 60.0);
      final a5 = 1.0 - exp(-dtSec / 300.0);
      final a15 = 1.0 - exp(-dtSec / 900.0);
      _ewma1m = _ewma1m! + a1 * (activeCoresNow - _ewma1m!);
      _ewma5m = _ewma5m! + a5 * (activeCoresNow - _ewma5m!);
      _ewma15m = _ewma15m! + a15 * (activeCoresNow - _ewma15m!);
    }

    // 2. 物理内存与系统缓存 (GlobalMemoryStatusEx + K32GetPerformanceInfo)
    final (totalPhysBytes, usedPhysBytes, cachedPhysBytes) = _readMemoryStatus(
      w,
    );

    // 3. 网卡吞吐速率 (GetIfTable2 64 位硬件网卡字节计数)
    final nicMap = _readHardwareNicOctets(w);
    var downBytes = 0;
    var upBytes = 0;
    for (final entry in nicMap.entries) {
      final prev = _prevNicOctets[entry.key];
      if (prev != null) {
        if (entry.value.$1 >= prev.$1) {
          downBytes += entry.value.$1 - prev.$1;
        }
        if (entry.value.$2 >= prev.$2) {
          upBytes += entry.value.$2 - prev.$2;
        }
      }
    }
    final downKbps = dtSec > 0 ? downBytes / dtSec / 1024.0 : 0.0;
    final upKbps = dtSec > 0 ? upBytes / dtSec / 1024.0 : 0.0;
    final totalNicKbps = downKbps + upKbps;

    // 4. 本机磁盘分区容量 (GetLogicalDrives + GetDiskFreeSpaceExW)
    final disks = _readLogicalDisks(w);

    // 5. 活跃 TCP/UDP 套接字归属映射 + 全量进程快照 (NtQuerySystemInformation class 5)
    final (activeTcpConnsByPid, udpPids) = _readProcessSocketActivity(w);
    final rawProcs = _readProcessTable(w);

    final nextProcState = <int, _WinProcPrev>{};
    final rawSocketKbpsByPid = <int, double>{};
    var sumRawSocketKbps = 0.0;

    final prelim = <({
      int pid,
      String name,
      double cpuPct,
      double memPct,
      double memMb,
      double diskKbps,
      int tcpConns,
      bool hasSocket,
    })>[];

    for (final p in rawProcs) {
      final prev = _prevProcs[p.pid];
      var cpuPct = 0.0;
      var diskKbps = 0.0;
      var rawOtherKbps = 0.0;

      if (prev != null && prev.createTime == p.createTime) {
        if (sumDeltaTotal > 0 && p.cpuTicks >= prev.cpuTicks) {
          // 与 Windows 任务管理器一致：单进程 CPU% 归一化到整机总逻辑算力 (0..100%)
          cpuPct = ((p.cpuTicks - prev.cpuTicks) / sumDeltaTotal * 100.0).clamp(
            0.0,
            100.0,
          );
        }
        if (dtSec > 0 && p.diskBytes >= prev.diskBytes) {
          diskKbps = (p.diskBytes - prev.diskBytes) / dtSec / 1024.0;
        }
        if (dtSec > 0 && p.otherBytes >= prev.otherBytes) {
          rawOtherKbps = (p.otherBytes - prev.otherBytes) / dtSec / 1024.0;
        }
      }

      nextProcState[p.pid] = _WinProcPrev(
        createTime: p.createTime,
        cpuTicks: p.cpuTicks,
        diskBytes: p.diskBytes,
        otherBytes: p.otherBytes,
      );

      final tcpConns = activeTcpConnsByPid[p.pid] ?? 0;
      final hasSocket = tcpConns > 0 || udpPids.contains(p.pid);
      if (hasSocket && rawOtherKbps > 0) {
        rawSocketKbpsByPid[p.pid] = rawOtherKbps;
        sumRawSocketKbps += rawOtherKbps;
      }

      final memPct = totalPhysBytes > 0
          ? (p.memBytes / totalPhysBytes * 100.0).clamp(0.0, 100.0)
          : 0.0;
      prelim.add((
        pid: p.pid,
        name: p.name,
        cpuPct: cpuPct,
        memPct: memPct,
        memMb: p.memBytes / 1048576.0,
        diskKbps: diskKbps,
        tcpConns: tcpConns,
        hasSocket: hasSocket,
      ));
    }

    // 按整机网卡真实总吞吐比例校准 Winsock AFD OtherTransferCount，彻底过滤本地命名管道/IPC 噪声
    final netScale = (sumRawSocketKbps > 0 && sumRawSocketKbps > totalNicKbps)
        ? (totalNicKbps / sumRawSocketKbps)
        : 1.0;

    final allProcUsages = <LinuxProcessUsage>[
      for (final item in prelim)
        LinuxProcessUsage(
          item.pid,
          item.name,
          item.cpuPct,
          item.memPct,
          memMb: item.memMb,
          diskKbps: item.diskKbps,
          netKbps: (rawSocketKbpsByPid[item.pid] ?? 0.0) * netScale,
          netConns: item.tcpConns,
        ),
    ];

    _prevCores = coreTicks;
    _prevNicOctets = nicMap;
    _prevProcs = nextProcState;
    _prevTime = now;

    double roundLoad(double? v) =>
        double.parse((v ?? activeCoresNow).toStringAsFixed(2));

    return LinuxTelemetry(
      cpu: totalCpu,
      cores: corePercents,
      loads: [roundLoad(_ewma1m), roundLoad(_ewma5m), roundLoad(_ewma15m)],
      totalGb: totalPhysBytes / 1073741824.0,
      usedGb: usedPhysBytes / 1073741824.0,
      cachedGb: cachedPhysBytes / 1073741824.0,
      upKbps: upKbps,
      downKbps: downKbps,
      disks: disks,
      processes: LinuxTelemetrySampler.selectMultiDimensionTopProcesses(
        allProcUsages,
        perDimensionLimit: 18,
      ),
    );
  }

  List<(int idle, int total)> _readCorePerformanceTicks(_Win32Bindings w) {
    const maxCores = 256;
    const entrySize = 48;
    const bufLen = maxCores * entrySize;
    final buf = w.zalloc(bufLen);
    final retLen = w.zalloc(4).cast<Uint32>();
    try {
      final status = w.ntQuerySystemInformation(
        8 /* SystemProcessorPerformanceInformation */,
        buf,
        bufLen,
        retLen,
      );
      if (status != 0) {
        return const [(0, 0)];
      }
      final count = (retLen.value ~/ entrySize).clamp(1, maxCores);
      final result = <(int, int)>[];
      for (var i = 0; i < count; i++) {
        final base = buf.address + i * entrySize;
        final idle = Pointer<Int64>.fromAddress(base).value;
        // Windows KernelTime 已包含 IdleTime，因此总时间片 = KernelTime + UserTime
        final kernel = Pointer<Int64>.fromAddress(base + 8).value;
        final user = Pointer<Int64>.fromAddress(base + 16).value;
        result.add((idle, kernel + user));
      }
      return result;
    } finally {
      w.free(retLen);
      w.free(buf);
    }
  }

  (int total, int used, int cached) _readMemoryStatus(_Win32Bindings w) {
    final memBuf = w.zalloc(64);
    final perfBuf = w.zalloc(104);
    try {
      Pointer<Uint32>.fromAddress(memBuf.address).value = 64;
      var totalPhys = 0;
      var availPhys = 0;
      if (w.globalMemoryStatusEx(memBuf) != 0) {
        totalPhys =
            Pointer<Uint64>.fromAddress(memBuf.address + 8).value &
            0x7FFFFFFFFFFFFFFF;
        availPhys =
            Pointer<Uint64>.fromAddress(memBuf.address + 16).value &
            0x7FFFFFFFFFFFFFFF;
      }
      final usedPhys = max(0, totalPhys - availPhys);

      var cachedPhys = 0;
      Pointer<Uint32>.fromAddress(perfBuf.address).value = 104;
      if (w.getPerformanceInfo(perfBuf, 104) != 0) {
        final cachePages =
            Pointer<Uint64>.fromAddress(perfBuf.address + 48).value &
            0x7FFFFFFFFFFFFFFF;
        final pageSize =
            Pointer<Uint64>.fromAddress(perfBuf.address + 80).value &
            0x7FFFFFFFFFFFFFFF;
        if (pageSize > 0) {
          cachedPhys = min(availPhys, cachePages * pageSize);
        }
      }
      return (totalPhys, usedPhys, cachedPhys);
    } finally {
      w.free(perfBuf);
      w.free(memBuf);
    }
  }

  Map<int, (int rx, int tx)> _readHardwareNicOctets(_Win32Bindings w) {
    final tablePtrHolder = w.zalloc(8).cast<Pointer<Uint8>>();
    Pointer<Uint8> tablePtr = nullptr;
    try {
      final rc = w.getIfTable2(tablePtrHolder);
      if (rc != 0) return const {};
      tablePtr = tablePtrHolder.value;
      if (tablePtr.address == 0) return const {};

      final numEntries = Pointer<Uint32>.fromAddress(tablePtr.address).value;
      const rowSize = 1352;
      final hardwareMap = <int, (int, int)>{};
      final fallbackMap = <int, (int, int)>{};

      for (var i = 0; i < numEntries; i++) {
        final rowAddr = tablePtr.address + 8 + i * rowSize;
        final luid = Pointer<Int64>.fromAddress(rowAddr).value;
        final ifType = Pointer<Uint32>.fromAddress(rowAddr + 1128).value;
        final flags = Pointer<Uint8>.fromAddress(rowAddr + 1152).value;
        final operStatus = Pointer<Int32>.fromAddress(rowAddr + 1156).value;

        // 仅统计已连接 (IfOperStatusUp == 1)、非回环 (Type != 24)、非 NDIS 过滤层 (FilterInterface == 0)
        final isFilter = (flags & 0x02) != 0;
        if (operStatus != 1 || ifType == 24 || isFilter) continue;

        final inOctets =
            Pointer<Uint64>.fromAddress(rowAddr + 1208).value &
            0x7FFFFFFFFFFFFFFF;
        final outOctets =
            Pointer<Uint64>.fromAddress(rowAddr + 1280).value &
            0x7FFFFFFFFFFFFFFF;
        if (inOctets == 0 && outOctets == 0) continue;

        final isHardware = (flags & 0x01) != 0;
        if (isHardware) {
          hardwareMap[luid] = (inOctets, outOctets);
        } else {
          fallbackMap[luid] = (inOctets, outOctets);
        }
      }
      return hardwareMap.isNotEmpty ? hardwareMap : fallbackMap;
    } finally {
      if (tablePtr.address != 0) {
        w.freeMibTable(tablePtr);
      }
      w.free(tablePtrHolder);
    }
  }

  List<LinuxDiskUsage> _readLogicalDisks(_Win32Bindings w) {
    final mask = w.getLogicalDrives();
    if (mask == 0) return const [];

    final rootBuf = w.zalloc(16).cast<Uint16>();
    final freeAvail = w.zalloc(8).cast<Uint64>();
    final totalBytesPtr = w.zalloc(8).cast<Uint64>();
    final totalFreePtr = w.zalloc(8).cast<Uint64>();
    final volNameBuf = w.zalloc(520).cast<Uint16>();
    final fsNameBuf = w.zalloc(128).cast<Uint16>();

    try {
      final disks = <LinuxDiskUsage>[];
      for (var i = 0; i < 26; i++) {
        if ((mask & (1 << i)) == 0) continue;
        final driveLetter = String.fromCharCode(65 + i);
        // 写入 "C:\\\0"
        rootBuf[0] = 65 + i;
        rootBuf[1] = 58; // ':'
        rootBuf[2] = 92; // '\\'
        rootBuf[3] = 0;

        final driveType = w.getDriveTypeW(rootBuf);
        // DRIVE_REMOVABLE (2) / DRIVE_FIXED (3)
        if (driveType != 3 && driveType != 2) continue;

        if (w.getDiskFreeSpaceExW(
              rootBuf,
              freeAvail,
              totalBytesPtr,
              totalFreePtr,
            ) ==
            0) {
          continue;
        }
        final totalBytes = totalBytesPtr.value & 0x7FFFFFFFFFFFFFFF;
        final freeBytes = totalFreePtr.value & 0x7FFFFFFFFFFFFFFF;
        if (totalBytes <= 0) continue;

        volNameBuf[0] = 0;
        fsNameBuf[0] = 0;
        w.getVolumeInformationW(
          rootBuf,
          volNameBuf,
          260,
          nullptr,
          nullptr,
          nullptr,
          fsNameBuf,
          64,
        );
        final volLabel = _readUtf16ZeroTerminated(volNameBuf, 260).trim();
        final fsName = _readUtf16ZeroTerminated(fsNameBuf, 64).trim();
        final deviceDesc = [
          if (volLabel.isNotEmpty) volLabel,
          if (fsName.isNotEmpty) fsName else 'Local Disk',
        ].join(' · ');

        final usedBytes = max(0, totalBytes - freeBytes);
        final totalGb = totalBytes / 1073741824.0;
        final usedGb = usedBytes / 1073741824.0;
        disks.add(
          LinuxDiskUsage(
            deviceDesc,
            '$driveLetter:\\',
            totalGb,
            usedGb,
            (usedBytes / totalBytes).clamp(0.0, 1.0),
          ),
        );
      }
      return disks;
    } finally {
      w.free(fsNameBuf);
      w.free(volNameBuf);
      w.free(totalFreePtr);
      w.free(totalBytesPtr);
      w.free(freeAvail);
      w.free(rootBuf);
    }
  }

  (Map<int, int> tcpConns, Set<int> udpPids) _readProcessSocketActivity(
    _Win32Bindings w,
  ) {
    final tcpConns = <int, int>{};
    final udpPids = <int>{};
    final sizePtr = w.zalloc(4).cast<Uint32>();

    void scanTcp(int af, int rowSize, int stateOffset, int pidOffset) {
      sizePtr.value = 0;
      w.getExtendedTcpTable(nullptr, sizePtr, 0, af, 4, 0);
      final needed = sizePtr.value;
      if (needed <= 4 || needed > 16 * 1024 * 1024) return;
      final allocLen = needed + 2048;
      sizePtr.value = allocLen;
      final buf = w.zalloc(allocLen);
      try {
        if (w.getExtendedTcpTable(buf, sizePtr, 0, af, 4, 0) != 0) return;
        final count = Pointer<Uint32>.fromAddress(buf.address).value;
        for (var i = 0; i < count; i++) {
          final off = 4 + i * rowSize;
          if (off + rowSize > allocLen) break;
          final state = Pointer<Uint32>.fromAddress(
            buf.address + off + stateOffset,
          ).value;
          final pid = Pointer<Uint32>.fromAddress(
            buf.address + off + pidOffset,
          ).value;
          // SYN_SENT(3) .. LAST_ACK(10)，以 ESTABLISHED(5) 为主
          if (pid > 0 && state >= 3 && state <= 10) {
            tcpConns[pid] = (tcpConns[pid] ?? 0) + 1;
          }
        }
      } finally {
        w.free(buf);
      }
    }

    void scanUdp(int af, int rowSize, int pidOffset) {
      sizePtr.value = 0;
      w.getExtendedUdpTable(nullptr, sizePtr, 0, af, 1, 0);
      final needed = sizePtr.value;
      if (needed <= 4 || needed > 16 * 1024 * 1024) return;
      final allocLen = needed + 2048;
      sizePtr.value = allocLen;
      final buf = w.zalloc(allocLen);
      try {
        if (w.getExtendedUdpTable(buf, sizePtr, 0, af, 1, 0) != 0) return;
        final count = Pointer<Uint32>.fromAddress(buf.address).value;
        for (var i = 0; i < count; i++) {
          final off = 4 + i * rowSize;
          if (off + rowSize > allocLen) break;
          final pid = Pointer<Uint32>.fromAddress(
            buf.address + off + pidOffset,
          ).value;
          if (pid > 0) {
            udpPids.add(pid);
          }
        }
      } finally {
        w.free(buf);
      }
    }

    try {
      scanTcp(2 /* AF_INET */, 24, 0, 20);
      scanTcp(23 /* AF_INET6 */, 56, 48, 52);
      scanUdp(2 /* AF_INET */, 12, 8);
      scanUdp(23 /* AF_INET6 */, 28, 24);
      return (tcpConns, udpPids);
    } finally {
      w.free(sizePtr);
    }
  }

  List<_WinRawProcEntry> _readProcessTable(_Win32Bindings w) {
    final retLen = w.zalloc(4).cast<Uint32>();
    var bufLen = 1024 * 1024;
    var buf = w.zalloc(bufLen);

    try {
      var status = w.ntQuerySystemInformation(
        5 /* SystemProcessInformation */,
        buf,
        bufLen,
        retLen,
      );
      // STATUS_INFO_LENGTH_MISMATCH == 0xC0000004 (-1073741820)
      var retries = 0;
      while (status == -1073741820 && retries < 4) {
        retries++;
        w.free(buf);
        bufLen = max(bufLen * 2, retLen.value + 131072);
        buf = w.zalloc(bufLen);
        status = w.ntQuerySystemInformation(5, buf, bufLen, retLen);
      }
      if (status != 0) return const [];

      final result = <_WinRawProcEntry>[];
      var offset = 0;
      while (offset + 256 <= bufLen) {
        final entryAddr = buf.address + offset;
        final nextOff = Pointer<Uint32>.fromAddress(entryAddr).value;
        final pid = Pointer<Int64>.fromAddress(entryAddr + 80).value;

        if (pid > 0) {
          final wsPrivate = Pointer<Int64>.fromAddress(entryAddr + 8).value;
          final createTime = Pointer<Int64>.fromAddress(entryAddr + 32).value;
          final userTime = Pointer<Int64>.fromAddress(entryAddr + 40).value;
          final kernelTime = Pointer<Int64>.fromAddress(entryAddr + 48).value;
          final nameBytesLen = Pointer<Uint16>.fromAddress(
            entryAddr + 56,
          ).value;
          final namePtrAddr = Pointer<IntPtr>.fromAddress(entryAddr + 64).value;
          final wsTotal =
              Pointer<Uint64>.fromAddress(entryAddr + 144).value &
              0x7FFFFFFFFFFFFFFF;
          final readBytes = max(
            0,
            Pointer<Int64>.fromAddress(entryAddr + 232).value,
          );
          final writeBytes = max(
            0,
            Pointer<Int64>.fromAddress(entryAddr + 240).value,
          );
          final otherBytes = max(
            0,
            Pointer<Int64>.fromAddress(entryAddr + 248).value,
          );

          String name;
          if (pid == 4) {
            name = 'System';
          } else if (nameBytesLen > 0 && namePtrAddr != 0) {
            final charCount = nameBytesLen ~/ 2;
            name = String.fromCharCodes(
              Pointer<Uint16>.fromAddress(namePtrAddr).asTypedList(charCount),
            );
          } else {
            name = 'PID $pid';
          }

          final memBytes = wsPrivate > 0 ? wsPrivate : wsTotal;
          result.add(
            _WinRawProcEntry(
              pid: pid,
              name: name,
              createTime: createTime,
              cpuTicks: max(0, userTime + kernelTime),
              memBytes: memBytes,
              diskBytes: readBytes + writeBytes,
              otherBytes: otherBytes,
            ),
          );
        }

        if (nextOff <= 0) break;
        offset += nextOff;
      }
      return result;
    } finally {
      w.free(buf);
      w.free(retLen);
    }
  }

  static String _readUtf16ZeroTerminated(Pointer<Uint16> ptr, int maxChars) {
    var len = 0;
    while (len < maxChars && (ptr + len).value != 0) {
      len++;
    }
    if (len == 0) return '';
    return String.fromCharCodes(ptr.asTypedList(len));
  }
}
