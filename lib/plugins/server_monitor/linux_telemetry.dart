class LinuxDiskUsage {
  LinuxDiskUsage(
    this.device,
    this.mountPoint,
    this.totalGb,
    this.usedGb,
    this.ratio,
  );
  final String device, mountPoint;
  final double totalGb, usedGb, ratio;
}

class LinuxProcessUsage {
  LinuxProcessUsage(
    this.pid,
    this.command,
    this.cpuPercent,
    this.memPercent, {
    this.memMb,
    this.diskKbps = 0.0,
    this.netKbps = 0.0,
    this.netConns = 0,
  });
  final int pid;
  final String command;
  final double cpuPercent, memPercent;
  final double? memMb;
  final double diskKbps;
  final double netKbps;
  final int netConns;
}

class LinuxTelemetry {
  LinuxTelemetry({
    required this.cpu,
    required this.cores,
    required this.loads,
    required this.usedGb,
    required this.cachedGb,
    required this.totalGb,
    required this.upKbps,
    required this.downKbps,
    required this.disks,
    required this.processes,
  });
  final double cpu, usedGb, cachedGb, totalGb, upKbps, downKbps;
  final List<double> cores, loads;
  final List<LinuxDiskUsage> disks;
  final List<LinuxProcessUsage> processes;
}

/// /proc counters are cumulative. Rates require two samples, never load average.
class LinuxTelemetrySampler {
  Map<String, List<int>> _cpus = {};
  Map<String, List<int>> _network = {};
  Map<int, List<int>> _processes = {};
  Map<int, List<int>> _processIo = {};
  Map<int, int> _processNetBytes = {};
  Duration? _time;

  static List<LinuxProcessUsage> selectMultiDimensionTopProcesses(
    List<LinuxProcessUsage> all, {
    int perDimensionLimit = 15,
  }) {
    if (all.length <= perDimensionLimit) {
      final copy = List<LinuxProcessUsage>.of(all);
      copy.sort(_compareByCpuDesc);
      return copy;
    }

    final selectedPids = <int>{};
    final merged = <LinuxProcessUsage>[];

    void pickTop(Comparator<LinuxProcessUsage> cmp) {
      final sorted = List<LinuxProcessUsage>.of(all)..sort(cmp);
      var count = 0;
      for (final p in sorted) {
        if (count >= perDimensionLimit) break;
        count++;
        if (selectedPids.add(p.pid)) {
          merged.add(p);
        }
      }
    }

    pickTop(_compareByCpuDesc);
    pickTop((a, b) {
      final m = (b.memMb ?? b.memPercent).compareTo(a.memMb ?? a.memPercent);
      return m != 0 ? m : _compareByCpuDesc(a, b);
    });
    pickTop((a, b) {
      final d = b.diskKbps.compareTo(a.diskKbps);
      return d != 0 ? d : _compareByCpuDesc(a, b);
    });
    pickTop((a, b) {
      final n = b.netKbps.compareTo(a.netKbps);
      if (n != 0) return n;
      final c = b.netConns.compareTo(a.netConns);
      return c != 0 ? c : _compareByCpuDesc(a, b);
    });

    merged.sort(_compareByCpuDesc);
    return merged;
  }

  static int _compareByCpuDesc(LinuxProcessUsage a, LinuxProcessUsage b) {
    final cpu = b.cpuPercent.compareTo(a.cpuPercent);
    if (cpu != 0) return cpu;
    final memory = b.memPercent.compareTo(a.memPercent);
    return memory != 0 ? memory : a.pid.compareTo(b.pid);
  }

  static const command = r'''
PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"
OS_KERNEL=$(uname -s 2>/dev/null)
printf '\n[OS]\n%s\n' "$OS_KERNEL"
if [ "$OS_KERNEL" = "Darwin" ]; then
  printf '\n[MAC_SYS]\n'
  printf 'NCPU:%s\n' "$(sysctl -n hw.ncpu 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 1)"
  printf 'MEMSIZE:%s\n' "$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  printf 'LOAD:%s\n' "$(sysctl -n vm.loadavg 2>/dev/null)"
  printf '\n[MAC_VM]\n'; vm_stat 2>/dev/null
  printf '\n[MAC_ROUTE]\n'; route -n get default 2>/dev/null | awk '/interface:/{print $2}'
  printf '\n[MAC_NET]\n'; netstat -ibn 2>/dev/null | awk '$3 ~ /^<Link#/ && NF >= 7 { print $1, $(NF-4), $(NF-1) }'
  printf '\n[DISK]\n'; LC_ALL=C df -Pk -l 2>/dev/null
  printf '\n[MAC_PROC]\n'; LC_ALL=C ps -Aceo pid=,pcpu=,pmem=,comm= -r 2>/dev/null
  printf '\n[MAC_NETTOP]\n'; nettop -P -L 1 -x -J bytes_in,bytes_out 2>/dev/null
else
  printf '\n[STAT]\n'; cat /proc/stat
  printf '\n[MEM]\n'; cat /proc/meminfo
  printf '\n[NET]\n'; cat /proc/net/dev
  printf '\n[ROUTE]\n'; cat /proc/net/route
  printf '\n[LOAD]\n'; cat /proc/loadavg
  printf '\n[DISK]\n'; LC_ALL=C df -Pkl -x tmpfs -x devtmpfs
  printf '\n[PAGE]\n'; getconf PAGESIZE 2>/dev/null || getconf PAGE_SIZE 2>/dev/null
  printf '\n[PROCESS]\n'
  awk 'BEGIN {
    for (i = 1; i < ARGC; i++) {
      if ((getline line < ARGV[i]) > 0) {
        rest = line; sub(/^.*\) /, "", rest)
        count = split(rest, fields, " ")
        pid = line; sub(/ .*/, "", pid)
        name = line; sub(/^[^(]*\(/, "", name); sub(/\) [^)]*$/, "", name)
        gsub(/[\t\r\n]/, " ", name)
        if (count >= 22) printf "%s\t%s\t%.0f\t%s\t%s\n", pid, fields[20], fields[12]+fields[13], fields[22], name
      }
      close(ARGV[i])
    }
    exit
  }' /proc/[0-9]*/stat 2>/dev/null
  printf '\n[PROC_IO]\n'
  awk 'BEGIN {
    for (i = 1; i < ARGC; i++) {
      pid = ARGV[i]; sub(/^\/proc\//, "", pid); sub(/\/io$/, "", pid)
      rb = 0; wb = 0; ok = 0
      while ((getline line < ARGV[i]) > 0) {
        if (line ~ /^read_bytes:/) { sub(/^read_bytes:[ \t]*/, "", line); rb = line + 0; ok = 1 }
        else if (line ~ /^write_bytes:/) { sub(/^write_bytes:[ \t]*/, "", line); wb = line + 0; ok = 1 }
      }
      close(ARGV[i])
      if (ok && (rb > 0 || wb > 0)) printf "%s\t%.0f\n", pid, rb + wb
    }
    exit
  }' /proc/[0-9]*/io 2>/dev/null
  printf '\n[PROC_NET]\n'
  ss -tinp 2>/dev/null | awk '
    /pid=[0-9]+/ {
      curPid = $0; sub(/^.*pid=/, "", curPid); sub(/[^0-9].*$/, "", curPid)
      if (curPid + 0 > 0) conns[curPid]++
      next
    }
    curPid + 0 > 0 && (/bytes_acked:/ || /bytes_received:/ || /bytes_sent:/) {
      s = $0; ba = 0; br = 0
      if (match(s, /bytes_acked:[0-9]+/)) { t = substr(s, RSTART + 12, RLENGTH - 12); ba = t + 0 }
      else if (match(s, /bytes_sent:[0-9]+/)) { t = substr(s, RSTART + 11, RLENGTH - 11); ba = t + 0 }
      if (match(s, /bytes_received:[0-9]+/)) { t = substr(s, RSTART + 15, RLENGTH - 15); br = t + 0 }
      bytes[curPid] += (ba + br)
      curPid = 0
    }
    END {
      for (p in conns) printf "%s\t%.0f\t%d\n", p, bytes[p] + 0, conns[p]
    }
  '
fi
''';

  LinuxTelemetry sample(String raw, Duration time) {
    final sections = <String, List<String>>{};
    String? section;
    for (final line in raw.split('\n')) {
      final text = line.trim();
      if (RegExp(
        r'^\[(OS|STAT|MEM|NET|ROUTE|LOAD|DISK|PAGE|PROCESS|PROC_IO|PROC_NET|MAC_SYS|MAC_VM|MAC_ROUTE|MAC_NET|MAC_PROC|MAC_NETTOP)\]$',
      ).hasMatch(text)) {
        section = text;
        sections[section] = [];
      } else if (section != null && text.isNotEmpty) {
        sections[section]!.add(text);
      }
    }

    final osKernel = (sections['[OS]'] ?? const <String>[]).join(' ').trim();
    if (osKernel == 'Darwin' || sections.containsKey('[MAC_SYS]')) {
      return _sampleDarwin(sections, time);
    }
    final cpus = <String, List<int>>{};
    for (final line in sections['[STAT]'] ?? <String>[]) {
      final fields = line.split(RegExp(r'\s+'));
      if (!RegExp(r'^cpu\d*$').hasMatch(fields.first) || fields.length < 5) {
        continue;
      }
      // guest and guest_nice are already counted in user and nice.
      cpus[fields.first] = fields.skip(1).take(8).map(int.parse).toList();
    }
    final memory = <String, int>{};
    for (final line in sections['[MEM]'] ?? <String>[]) {
      final fields = line.split(RegExp(r'[:\s]+'));
      if (fields.length >= 2) memory[fields.first] = int.parse(fields[1]);
    }
    final loads = (sections['[LOAD]'] ?? []).join(' ').split(RegExp(r'\s+'));
    if (!cpus.containsKey('cpu') ||
        (memory['MemTotal'] ?? 0) <= 0 ||
        loads.length < 3 ||
        !sections.containsKey('[NET]')) {
      throw const FormatException('服务器未提供有效的 Linux /proc 监控数据');
    }
    final defaultInterfaces = <String>{};
    for (final line in sections['[ROUTE]'] ?? <String>[]) {
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length >= 4 &&
          fields[1] == '00000000' &&
          ((int.tryParse(fields[3], radix: 16) ?? 0) & 1) != 0) {
        defaultInterfaces.add(fields.first);
      }
    }
    final network = <String, List<int>>{};
    for (final line in sections['[NET]']!) {
      final colon = line.indexOf(':');
      if (colon < 0) continue;
      final name = line.substring(0, colon).trim();
      if (name == 'lo' ||
          (defaultInterfaces.isNotEmpty && !defaultInterfaces.contains(name))) {
        continue;
      }
      final fields = line.substring(colon + 1).trim().split(RegExp(r'\s+'));
      if (fields.length >= 9) {
        network[name] = [int.parse(fields[0]), int.parse(fields[8])];
      }
    }
    double cpuUsage(String name) {
      final previous = _cpus[name];
      final now = cpus[name]!;
      if (previous == null) return 0;
      final total =
          now.fold(0, (a, b) => a + b) - previous.fold(0, (a, b) => a + b);
      final idle =
          now[3] +
          (now.length > 4 ? now[4] : 0) -
          previous[3] -
          (previous.length > 4 ? previous[4] : 0);
      if (total <= 0 || idle < 0) return 0;
      return ((total - idle) / total * 100).clamp(0, 100);
    }

    final seconds = _time == null ? 0.0 : (time - _time!).inMicroseconds / 1e6;
    var downBytes = 0, upBytes = 0;
    for (final entry in network.entries) {
      final previous = _network[entry.key];
      if (previous == null) continue;
      downBytes += (entry.value[0] - previous[0]).clamp(0, 1 << 62);
      upBytes += (entry.value[1] - previous[1]).clamp(0, 1 << 62);
    }
    final total = memory['MemTotal']!.toDouble();
    final cached =
        ((memory['Cached'] ?? 0) +
                (memory['SReclaimable'] ?? 0) -
                (memory['Shmem'] ?? 0))
            .clamp(0, total);
    final available =
        (memory['MemAvailable'] ??
                ((memory['MemFree'] ?? 0) + (memory['Buffers'] ?? 0) + cached))
            .clamp(0, total);
    final used = total - available;
    final coreNames = cpus.keys.where((name) => name != 'cpu').toList()
      ..sort(
        (a, b) =>
            int.parse(a.substring(3)).compareTo(int.parse(b.substring(3))),
      );
    final disks = <LinuxDiskUsage>[];
    for (final line in sections['[DISK]'] ?? <String>[]) {
      final match = RegExp(
        r'^(.+?)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(.+)$',
      ).firstMatch(line);
      if (match == null) continue;
      final totalKb = int.parse(match[2]!);
      if (totalKb <= 0) continue;
      disks.add(
        LinuxDiskUsage(
          match[1]!,
          match[6]!,
          totalKb / 1048576,
          int.parse(match[3]!) / 1048576,
          (int.parse(match[5]!) / 100).clamp(0, 1),
        ),
      );
    }
    final pageSize =
        int.tryParse((sections['[PAGE]'] ?? []).join('').trim()) ?? 0;
    if (disks.isEmpty || pageSize <= 0 || !sections.containsKey('[PROCESS]')) {
      throw const FormatException('无法读取真实磁盘或进程数据');
    }
    final rawProcIo = <int, int>{};
    for (final line in sections['[PROC_IO]'] ?? const <String>[]) {
      final parts = line.split('\t');
      if (parts.length < 2) continue;
      final pid = int.tryParse(parts[0]);
      final bytes = int.tryParse(parts[1]);
      if (pid != null && bytes != null) {
        rawProcIo[pid] = bytes;
      }
    }

    final rawProcNetBytes = <int, int>{};
    final rawProcNetConns = <int, int>{};
    for (final line in sections['[PROC_NET]'] ?? const <String>[]) {
      final parts = line.split('\t');
      if (parts.length < 3) continue;
      final pid = int.tryParse(parts[0]);
      final bytes = int.tryParse(parts[1]);
      final conns = int.tryParse(parts[2]);
      if (pid != null) {
        if (bytes != null) rawProcNetBytes[pid] = bytes;
        if (conns != null) rawProcNetConns[pid] = conns;
      }
    }

    final currentProcesses = <int, List<int>>{};
    final currentProcessIo = <int, List<int>>{};
    final currentProcessNet = <int, int>{};
    final processes = <LinuxProcessUsage>[];
    final totalTicks = cpus['cpu']!.fold(0, (a, b) => a + b);
    final previousTicks = _cpus['cpu']?.fold(0, (a, b) => a + b);
    final deltaTicks = previousTicks == null ? 0 : totalTicks - previousTicks;
    for (final line in sections['[PROCESS]']!) {
      final fields = line.split('\t');
      if (fields.length < 5) continue;
      final pid = int.tryParse(fields[0]);
      final start = int.tryParse(fields[1]);
      final ticks = int.tryParse(fields[2]);
      final rssPages = int.tryParse(fields[3]);
      if (pid == null ||
          pid <= 0 ||
          start == null ||
          ticks == null ||
          rssPages == null) {
        continue;
      }
      final previous = _processes[pid];
      var usage = 0.0;
      // Start time distinguishes a reused PID from the previous process.
      if (previous != null &&
          previous[0] == start &&
          deltaTicks > 0 &&
          ticks >= previous[1]) {
        usage = (ticks - previous[1]) / deltaTicks * coreNames.length * 100;
      }
      currentProcesses[pid] = [start, ticks];

      var diskKbps = 0.0;
      final ioBytes = rawProcIo[pid];
      if (ioBytes != null) {
        final prevIo = _processIo[pid];
        if (prevIo != null &&
            prevIo[0] == start &&
            seconds > 0 &&
            ioBytes >= prevIo[1]) {
          diskKbps = (ioBytes - prevIo[1]) / seconds / 1024.0;
        }
        currentProcessIo[pid] = [start, ioBytes];
      }

      var netKbps = 0.0;
      final netBytes = rawProcNetBytes[pid];
      if (netBytes != null) {
        final prevNet = _processNetBytes[pid];
        if (prevNet != null &&
            previous != null &&
            previous[0] == start &&
            seconds > 0 &&
            netBytes >= prevNet) {
          netKbps = (netBytes - prevNet) / seconds / 1024.0;
        }
        currentProcessNet[pid] = netBytes;
      }

      final memBytes = rssPages * pageSize;
      processes.add(
        LinuxProcessUsage(
          pid,
          fields.sublist(4).join('\t'),
          usage,
          (memBytes / (total * 1024) * 100).clamp(0, 100),
          memMb: memBytes / 1048576.0,
          diskKbps: diskKbps,
          netKbps: netKbps,
          netConns: rawProcNetConns[pid] ?? 0,
        ),
      );
    }
    if (processes.isEmpty) {
      throw const FormatException('无法读取真实进程列表');
    }
    final result = LinuxTelemetry(
      cpu: cpuUsage('cpu'),
      cores: coreNames.map(cpuUsage).toList(),
      loads: loads.take(3).map(double.parse).toList(),
      totalGb: total / 1048576,
      usedGb: used / 1048576,
      cachedGb: cached.clamp(0, total - used) / 1048576,
      upKbps: seconds > 0 ? upBytes / seconds / 1024 : 0,
      downKbps: seconds > 0 ? downBytes / seconds / 1024 : 0,
      disks: disks,
      processes: selectMultiDimensionTopProcesses(processes),
    );
    _cpus = cpus;
    _network = network;
    _time = time;
    _processes = currentProcesses;
    _processIo = currentProcessIo;
    _processNetBytes = currentProcessNet;
    return result;
  }

  LinuxTelemetry _sampleDarwin(
    Map<String, List<String>> sections,
    Duration time,
  ) {
    int ncpu = 1;
    int memSizeBytes = 0;
    List<double> loads = const [0.0, 0.0, 0.0];

    for (final line in sections['[MAC_SYS]'] ?? const <String>[]) {
      if (line.startsWith('NCPU:')) {
        ncpu = (int.tryParse(line.substring(5).trim()) ?? 1).clamp(1, 512);
      } else if (line.startsWith('MEMSIZE:')) {
        memSizeBytes = int.tryParse(line.substring(8).trim()) ?? 0;
      } else if (line.startsWith('LOAD:')) {
        final loadText = line.substring(5).replaceAll(',', '.');
        final parsed = RegExp(r'\d+(?:\.\d+)?')
            .allMatches(loadText)
            .map((m) => double.parse(m.group(0)!))
            .take(3)
            .toList();
        if (parsed.length == 3) {
          loads = parsed;
        }
      }
    }

    int pageSize = 4096;
    final vmPages = <String, int>{};
    for (final line in sections['[MAC_VM]'] ?? const <String>[]) {
      final pageMatch = RegExp(r'page size of\s+(\d+)\s+bytes').firstMatch(line);
      if (pageMatch != null) {
        pageSize = int.tryParse(pageMatch.group(1)!) ?? 4096;
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      final key = line.substring(0, colon).replaceAll('"', '').trim();
      final valStr = line
          .substring(colon + 1)
          .replaceAll('.', '')
          .trim();
      final val = int.tryParse(valStr);
      if (val != null) {
        vmPages[key] = val;
      }
    }

    if (memSizeBytes <= 0 || vmPages.isEmpty) {
      throw const FormatException('无法读取 macOS 内存监控数据');
    }

    final totalBytes = memSizeBytes.toDouble();
    final purgeable = vmPages['Pages purgeable'] ?? 0;
    final wired = vmPages['Pages wired down'] ?? 0;
    final compressed = vmPages['Pages occupied by compressor'] ?? 0;
    final fileBacked = vmPages['File-backed pages'] ?? 0;

    double usedBytes;
    double cachedBytes;
    if (vmPages.containsKey('Anonymous pages')) {
      final appPages = (vmPages['Anonymous pages']! - purgeable).clamp(
        0,
        1 << 60,
      );
      usedBytes = ((appPages + wired + compressed) * pageSize)
          .toDouble()
          .clamp(0.0, totalBytes);
      cachedBytes = ((fileBacked + purgeable) * pageSize)
          .toDouble()
          .clamp(0.0, totalBytes - usedBytes);
    } else {
      final freePages =
          (vmPages['Pages free'] ?? 0) +
          (vmPages['Pages speculative'] ?? 0) +
          (vmPages['Pages inactive'] ?? 0);
      usedBytes = (totalBytes - freePages * pageSize).clamp(0.0, totalBytes);
      cachedBytes = (((vmPages['Pages inactive'] ?? 0) + purgeable) * pageSize)
          .toDouble()
          .clamp(0.0, totalBytes - usedBytes);
    }

    // 网络速率计算（基于 netstat -ibn <Link#> 累计字节差值）
    final defaultIfaces = (sections['[MAC_ROUTE]'] ?? const <String>[])
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    final allNet = <String, List<int>>{};
    for (final line in sections['[MAC_NET]'] ?? const <String>[]) {
      final parts = line.split(RegExp(r'\s+'));
      if (parts.length < 3) continue;
      final iface = parts[0];
      if (iface.startsWith('lo')) continue;
      final rx = int.tryParse(parts[1]);
      final tx = int.tryParse(parts[2]);
      if (rx != null && tx != null) {
        final prev = allNet[iface];
        if (prev == null || (rx + tx) > (prev[0] + prev[1])) {
          allNet[iface] = [rx, tx];
        }
      }
    }
    final filteredNet = <String, List<int>>{
      for (final e in allNet.entries)
        if (defaultIfaces.contains(e.key)) e.key: e.value,
    };
    final activeNet = filteredNet.isNotEmpty ? filteredNet : allNet;

    final seconds = _time == null ? 0.0 : (time - _time!).inMicroseconds / 1e6;
    var downBytes = 0, upBytes = 0;
    for (final entry in activeNet.entries) {
      final previous = _network[entry.key];
      if (previous == null) continue;
      downBytes += (entry.value[0] - previous[0]).clamp(0, 1 << 62);
      upBytes += (entry.value[1] - previous[1]).clamp(0, 1 << 62);
    }

    // 磁盘空间解析（自动合并 macOS APFS 根快照与 /System/Volumes/Data，隐藏内部辅助卷）
    final rawDisks = <({
      String device,
      String mount,
      int totalKb,
      int usedKb,
      int availKb,
      int capPct,
    })>[];
    for (final line in sections['[DISK]'] ?? const <String>[]) {
      final match = RegExp(
        r'^(.+?)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)%\s+(.+)$',
      ).firstMatch(line);
      if (match == null) continue;
      final device = match[1]!.trim();
      final totalKb = int.parse(match[2]!);
      final usedKb = int.parse(match[3]!);
      final availKb = int.parse(match[4]!);
      final capPct = int.parse(match[5]!);
      final mount = match[6]!.trim();
      if (totalKb <= 0) continue;
      if (device == 'devfs' ||
          device == 'autofs' ||
          device.startsWith('map ') ||
          mount == '/dev' ||
          mount == '/private/var/vm') {
        continue;
      }
      if (mount.startsWith('/System/Volumes/') &&
          mount != '/System/Volumes/Data') {
        continue;
      }
      rawDisks.add((
        device: device,
        mount: mount,
        totalKb: totalKb,
        usedKb: usedKb,
        availKb: availKb,
        capPct: capPct,
      ));
    }

    final rootEntry = rawDisks.where((d) => d.mount == '/').firstOrNull;
    final dataEntry = rawDisks
        .where((d) => d.mount == '/System/Volumes/Data')
        .firstOrNull;
    final mergeApfsContainer =
        rootEntry != null &&
        dataEntry != null &&
        (rootEntry.totalKb - dataEntry.totalKb).abs() <= 1024;

    final disks = <LinuxDiskUsage>[];
    for (final d in rawDisks) {
      if (mergeApfsContainer && d.mount == '/System/Volumes/Data') {
        continue;
      }
      if (mergeApfsContainer && d.mount == '/') {
        final realUsedKb = (d.totalKb - dataEntry.availKb).clamp(
          d.usedKb,
          d.totalKb,
        );
        disks.add(
          LinuxDiskUsage(
            d.device,
            '/',
            d.totalKb / 1048576.0,
            realUsedKb / 1048576.0,
            (realUsedKb / d.totalKb).clamp(0.0, 1.0),
          ),
        );
        continue;
      }
      disks.add(
        LinuxDiskUsage(
          d.device,
          d.mount,
          d.totalKb / 1048576.0,
          d.usedKb / 1048576.0,
          (d.capPct / 100.0).clamp(0.0, 1.0),
        ),
      );
    }

    // 解析 macOS nettop 进程级网络吞吐（格式：process_name.pid,bytes_in,bytes_out）
    final macNetBytes = <int, int>{};
    for (final line in sections['[MAC_NETTOP]'] ?? const <String>[]) {
      final m = RegExp(r'\.(\d+),(\d+),(\d+)').firstMatch(line);
      if (m == null) continue;
      final pid = int.tryParse(m.group(1)!);
      final rx = int.tryParse(m.group(2)!);
      final tx = int.tryParse(m.group(3)!);
      if (pid != null && rx != null && tx != null) {
        macNetBytes[pid] = (macNetBytes[pid] ?? 0) + rx + tx;
      }
    }

    // 进程与多核 CPU 负载计算
    final processes = <LinuxProcessUsage>[];
    final currentProcessNet = <int, int>{};
    double sumPcpu = 0.0;
    final coreLoads = List<double>.filled(ncpu, 0.0);

    for (final line in sections['[MAC_PROC]'] ?? const <String>[]) {
      final match = RegExp(
        r'^(\d+)\s+([\d.,]+)\s+([\d.,]+)\s+(.+)$',
      ).firstMatch(line);
      if (match == null) continue;
      final pid = int.tryParse(match.group(1)!);
      final pcpu =
          double.tryParse(match.group(2)!.replaceAll(',', '.')) ?? 0.0;
      final pmem =
          double.tryParse(match.group(3)!.replaceAll(',', '.')) ?? 0.0;
      final comm = match.group(4)!.trim();
      if (pid == null) continue;

      sumPcpu += pcpu;
      var remaining = pcpu;
      while (remaining > 0.01) {
        var minIdx = 0;
        for (var i = 1; i < ncpu; i++) {
          if (coreLoads[i] < coreLoads[minIdx]) {
            minIdx = i;
          }
        }
        final headroom = 100.0 - coreLoads[minIdx];
        if (headroom <= 0.01) break;
        final chunk = remaining < headroom ? remaining : headroom;
        coreLoads[minIdx] += chunk;
        remaining -= chunk;
      }

      var netKbps = 0.0;
      final netTotal = macNetBytes[pid];
      if (netTotal != null) {
        final prevNet = _processNetBytes[pid];
        if (prevNet != null && seconds > 0 && netTotal >= prevNet) {
          netKbps = (netTotal - prevNet) / seconds / 1024.0;
        }
        currentProcessNet[pid] = netTotal;
      }

      final clampedMem = pmem.clamp(0.0, 100.0);
      processes.add(
        LinuxProcessUsage(
          pid,
          comm,
          pcpu.clamp(0.0, ncpu * 100.0),
          clampedMem,
          memMb: (totalBytes * (clampedMem / 100.0)) / 1048576.0,
          netKbps: netKbps,
          netConns: netTotal != null && netTotal > 0 ? 1 : 0,
        ),
      );
    }

    if (disks.isEmpty || processes.isEmpty) {
      throw const FormatException('无法读取 macOS 磁盘或进程监控数据');
    }

    final totalCpu = (sumPcpu / ncpu).clamp(0.0, 100.0);
    _network = activeNet;
    _processNetBytes = currentProcessNet;
    _time = time;

    return LinuxTelemetry(
      cpu: totalCpu,
      cores: coreLoads.map((c) => c.clamp(0.0, 100.0)).toList(),
      loads: loads,
      totalGb: totalBytes / 1073741824.0,
      usedGb: usedBytes / 1073741824.0,
      cachedGb: cachedBytes / 1073741824.0,
      upKbps: seconds > 0 ? upBytes / seconds / 1024.0 : 0.0,
      downKbps: seconds > 0 ? downBytes / seconds / 1024.0 : 0.0,
      disks: disks,
      processes: selectMultiDimensionTopProcesses(processes),
    );
  }
}
