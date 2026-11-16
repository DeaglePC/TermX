import 'dart:math';

import 'command_output_models.dart';

/// 双引擎终端命令输出解析器：
/// 1. 命令语义引擎（识别用户输入的命令、管道或别名）
/// 2. 输出特征指纹嗅探引擎（即使通过脚本、别名或无命令上下文，也能自动识别结构化输出）
class CommandOutputParser {
  CommandOutputParser._();

  static final RegExp _ansiCsiRegex = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~]|\][^\x07\x1B]*(?:\x07|\x1B\\))',
  );

  /// 清理 ANSI 转义序列、回车符与多余空字节
  static String stripAnsi(String input) {
    return input
        .replaceAll('\x00', '')
        .replaceAll(_ansiCsiRegex, '')
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n');
  }

  /// 核心解析入口：若未命中任何需要美化的结构，返回 `null`（绝不误伤普通命令或报错输出）
  static BeautifiedOutputCard? parse({
    required String command,
    required String rawOutput,
    bool isAltScreen = false,
    Set<BeautyCategoryId>? enabledCategories,
    DateTime? now,
  }) {
    final cleanOutput = stripAnsi(rawOutput).trimRight();
    if (cleanOutput.trim().isEmpty) return null;

    final nonEmptyLines = cleanOutput
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.trim().isNotEmpty)
        .toList();
    if (nonEmptyLines.isEmpty) return null;

    // 过滤典型启动欢迎横幅与单行报错，避免误触发
    if (_looksLikeBannerOrError(command, nonEmptyLines)) {
      return null;
    }

    final normalizedCmd = _normalizeCommand(command);
    final ts = now ?? DateTime.now();
    final idSeed = 'card_${ts.microsecondsSinceEpoch}';

    bool allowed(BeautyCategoryId cat) =>
        enabledCategories == null || enabledCategories.contains(cat);

    // 1. top / htop / uptime 实时负载快照
    if (allowed(BeautyCategoryId.systemTop)) {
      final topCard = _tryParseSystemTop(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
        isAltScreen: isAltScreen,
      );
      if (topCard != null) return topCard;
    }

    // 2. Docker / Podman / Compose 容器、监控与镜像
    if (allowed(BeautyCategoryId.containers)) {
      final dockerCard = _tryParseDocker(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (dockerCard != null) return dockerCard;
    }

    // 3. Kubernetes (kubectl get pods/svc/nodes/deploy)
    if (allowed(BeautyCategoryId.kubernetes)) {
      final k8sCard = _tryParseKubernetes(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (k8sCard != null) return k8sCard;
    }

    // 4. NVIDIA GPU & 物理内存 (nvidia-smi / free / vm_stat)
    if (allowed(BeautyCategoryId.memoryGpu)) {
      final gpuCard = _tryParseNvidiaSmi(
        idSeed,
        command,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (gpuCard != null) return gpuCard;

      final memCard = _tryParseMemory(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (memCard != null) return memCard;
    }

    // 5. 磁盘挂载与目录体积 (df / Get-PSDrive / du)
    if (allowed(BeautyCategoryId.diskStorage)) {
      final diskCard = _tryParseDiskAndDu(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (diskCard != null) return diskCard;
    }

    // 6. 网络端口监听 (ss / netstat / lsof -i)
    if (allowed(BeautyCategoryId.networkPorts)) {
      final sockCard = _tryParseNetworkSockets(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (sockCard != null) return sockCard;
    }

    // 7. 网卡地址与 Ping 诊断 (ip a / ifconfig / ipconfig / ping)
    if (allowed(BeautyCategoryId.networkInterfaces)) {
      final pingCard = _tryParsePing(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (pingCard != null) return pingCard;

      final ifaceCard = _tryParseNetworkInterfaces(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (ifaceCard != null) return ifaceCard;
    }

    // 8. 系统服务与防火墙 (systemctl / Get-Service / ufw)
    if (allowed(BeautyCategoryId.servicesFirewall)) {
      final svcCard = _tryParseServicesAndFirewall(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (svcCard != null) return svcCard;
    }

    // 9. 进程列表 (ps aux / ps -ef / Get-Process / tasklist / pm2)
    if (allowed(BeautyCategoryId.processes)) {
      final procCard = _tryParseProcesses(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (procCard != null) return procCard;
    }

    // 10. Git 状态与提交历史 (git status / git log)
    if (allowed(BeautyCategoryId.gitVcs)) {
      final gitCard = _tryParseGit(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (gitCard != null) return gitCard;
    }

    // 11. 目录文件列表 (ls -la / ll / Get-ChildItem / dir)
    if (allowed(BeautyCategoryId.fileListing)) {
      final lsCard = _tryParseDirectoryListing(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (lsCard != null) return lsCard;
    }

    // 12. 系统架构信息、WSL、登录用户及通用对齐 CLI 表格兜底
    if (allowed(BeautyCategoryId.systemEnv)) {
      final sysCard = _tryParseSystemEnvAndTables(
        idSeed,
        command,
        normalizedCmd,
        cleanOutput,
        nonEmptyLines,
        ts,
      );
      if (sysCard != null) return sysCard;
    }

    return null;
  }

  static String _normalizeCommand(String cmd) {
    var trimmed = cmd.trim();
    // 去掉常见 sudo / time 前缀
    trimmed = trimmed.replaceFirst(RegExp(r'^(?:sudo\s+(?:-\S+\s+)*|time\s+)'), '');
    return trimmed;
  }

  static bool _looksLikeBannerOrError(String cmd, List<String> lines) {
    final joined = lines.take(6).join('\n');
    if (joined.contains('TermX Ultra-Modern Cross-Platform SSH Terminal') ||
        joined.contains('Welcome to Ubuntu') ||
        (lines.first.startsWith('Windows PowerShell') &&
            joined.contains('Copyright'))) {
      return true;
    }
    if (lines.length <= 2) {
      final first = lines.first.trim();
      if (first.contains(': command not found') ||
          first.contains(': No such file or directory') ||
          first.contains('is not recognized as the name of a cmdlet') ||
          first.startsWith('[Executed] ') ||
          first.startsWith('[TermX') ||
          first.startsWith('[SSH 连接失败]')) {
        return true;
      }
    }
    return false;
  }

  // ==================== 通用表头列偏移切片工具 ====================

  static List<({String name, int start, int end})> _computeColumnSpans(
    String headerLine,
    List<String> knownHeaders,
  ) {
    final upper = headerLine.toUpperCase();
    final positions = <({String name, int start})>[];
    var searchFrom = 0;
    for (final h in knownHeaders) {
      final idx = upper.indexOf(h.toUpperCase(), searchFrom);
      if (idx >= 0) {
        positions.add((name: h, start: idx));
        searchFrom = idx + h.length;
      }
    }
    if (positions.length < 2) return const [];
    final spans = <({String name, int start, int end})>[];
    for (var i = 0; i < positions.length; i++) {
      final start = i == 0 ? 0 : positions[i].start;
      final end = i + 1 < positions.length ? positions[i + 1].start : -1;
      spans.add((name: positions[i].name, start: start, end: end));
    }
    return spans;
  }

  static Map<String, String> _sliceByColumnSpans(
    String line,
    List<({String name, int start, int end})> spans,
  ) {
    final map = <String, String>{};
    for (final s in spans) {
      if (s.start >= line.length) {
        map[s.name] = '';
        continue;
      }
      final end = s.end < 0 ? line.length : min(s.end, line.length);
      map[s.name] = line.substring(s.start, end).trim();
    }
    return map;
  }

  // ==================== 1. top / htop / uptime 解析 ====================

  static BeautifiedOutputCard? _tryParseSystemTop(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts, {
    required bool isAltScreen,
  }) {
    final head = lines.take(8).join('\n');
    final isLinuxTop = RegExp(
      r'top\s+-\s+\d{1,2}:\d{2}:\d{2}\s+up\s+',
    ).hasMatch(head);
    final isMacTop = head.contains('Processes:') &&
        head.contains('Load Avg:') &&
        head.contains('CPU usage:');
    final isHtop = (normCmd.startsWith('htop') || head.contains('Mem[')) &&
        lines.any((l) => RegExp(r'\bPID\s+USER\b').hasMatch(l));

    if (isLinuxTop || isMacTop || isHtop) {
      var uptime = '运行中';
      var users = 1;
      var loads = <double>[0.0, 0.0, 0.0];
      var tasksTotal = 0, tasksRunning = 0, tasksSleeping = 0, tasksZombie = 0;
      var cpuUs = 0.0, cpuSy = 0.0, cpuId = 100.0, cpuWa = 0.0;
      var memTotalMb = 0.0, memUsedMb = 0.0, memCacheMb = 0.0;
      var swapTotalMb = 0.0, swapUsedMb = 0.0;
      final procs = <ProcessRowItem>[];

      bool inProcTable = false;
      for (final rawLine in lines) {
        final line = rawLine.trim();
        if (!inProcTable) {
          final upMatch = RegExp(
            r'up\s+(.+?),\s*(\d+)\s+users?,\s*load averages?:\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)',
            caseSensitive: false,
          ).firstMatch(line);
          if (upMatch != null) {
            uptime = upMatch.group(1)!.trim();
            users = int.tryParse(upMatch.group(2)!) ?? 1;
            loads = [
              double.tryParse(upMatch.group(3)!) ?? 0,
              double.tryParse(upMatch.group(4)!) ?? 0,
              double.tryParse(upMatch.group(5)!) ?? 0,
            ];
            continue;
          }

          final macLoad = RegExp(
            r'Load Avg:\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)',
          ).firstMatch(line);
          if (macLoad != null) {
            loads = [
              double.tryParse(macLoad.group(1)!) ?? 0,
              double.tryParse(macLoad.group(2)!) ?? 0,
              double.tryParse(macLoad.group(3)!) ?? 0,
            ];
          }

          final taskMatch = RegExp(
            r'(?:Tasks|Processes):\s*(\d+)\s+total,\s*(\d+)\s+running,\s*(\d+)\s+(?:sleeping|stuck)',
            caseSensitive: false,
          ).firstMatch(line);
          if (taskMatch != null) {
            tasksTotal = int.tryParse(taskMatch.group(1)!) ?? 0;
            tasksRunning = int.tryParse(taskMatch.group(2)!) ?? 0;
            tasksSleeping = int.tryParse(taskMatch.group(3)!) ?? 0;
            final zMatch = RegExp(r'(\d+)\s+zombie').firstMatch(line);
            if (zMatch != null) {
              tasksZombie = int.tryParse(zMatch.group(1)!) ?? 0;
            }
            continue;
          }

          if (line.contains('Cpu(s):') || line.startsWith('CPU usage:')) {
            final usM = RegExp(r'([\d.]+)%?\s*(?:us|user)').firstMatch(line);
            final syM = RegExp(r'([\d.]+)%?\s*(?:sy|sys)').firstMatch(line);
            final idM = RegExp(r'([\d.]+)%?\s*(?:id|idle)').firstMatch(line);
            final waM = RegExp(r'([\d.]+)%?\s*wa').firstMatch(line);
            if (usM != null) cpuUs = double.tryParse(usM.group(1)!) ?? 0;
            if (syM != null) cpuSy = double.tryParse(syM.group(1)!) ?? 0;
            if (idM != null) {
              cpuId = double.tryParse(idM.group(1)!) ??
                  (100.0 - cpuUs - cpuSy).clamp(0.0, 100.0);
            } else {
              cpuId = (100.0 - cpuUs - cpuSy).clamp(0.0, 100.0);
            }
            if (waM != null) cpuWa = double.tryParse(waM.group(1)!) ?? 0;
            continue;
          }

          final memMatch = RegExp(
            r'(KiB|MiB|GiB)?\s*Mem\s*:\s*([\d.]+)\s*total,\s*([\d.]+)\s*free,\s*([\d.]+)\s*used(?:,\s*([\d.]+)\s*buff/cache)?',
            caseSensitive: false,
          ).firstMatch(line);
          if (memMatch != null) {
            final unit = (memMatch.group(1) ?? 'MiB').toLowerCase();
            final factor = unit.startsWith('k')
                ? 1 / 1024.0
                : unit.startsWith('g')
                ? 1024.0
                : 1.0;
            memTotalMb = (double.tryParse(memMatch.group(2)!) ?? 0) * factor;
            memUsedMb = (double.tryParse(memMatch.group(4)!) ?? 0) * factor;
            memCacheMb =
                (double.tryParse(memMatch.group(5) ?? '0') ?? 0) * factor;
            continue;
          }

          final macPhys = RegExp(
            r'PhysMem:\s*([\d.]+)([MG])\s+used',
            caseSensitive: false,
          ).firstMatch(line);
          if (macPhys != null) {
            final val = double.tryParse(macPhys.group(1)!) ?? 0;
            final unit = macPhys.group(2)!.toUpperCase();
            memUsedMb = unit == 'G' ? val * 1024 : val;
            final unusedM = RegExp(
              r'([\d.]+)([MG])\s+unused',
              caseSensitive: false,
            ).firstMatch(line);
            final unusedMb = unusedM != null
                ? (double.tryParse(unusedM.group(1)!) ?? 0) *
                      (unusedM.group(2)!.toUpperCase() == 'G' ? 1024 : 1)
                : 0.0;
            memTotalMb = memUsedMb + unusedMb;
          }

          final swapMatch = RegExp(
            r'(KiB|MiB|GiB)?\s*Swap\s*:\s*([\d.]+)\s*total,\s*([\d.]+)\s*free,\s*([\d.]+)\s*used',
            caseSensitive: false,
          ).firstMatch(line);
          if (swapMatch != null) {
            final unit = (swapMatch.group(1) ?? 'MiB').toLowerCase();
            final factor = unit.startsWith('k')
                ? 1 / 1024.0
                : unit.startsWith('g')
                ? 1024.0
                : 1.0;
            swapTotalMb = (double.tryParse(swapMatch.group(2)!) ?? 0) * factor;
            swapUsedMb = (double.tryParse(swapMatch.group(4)!) ?? 0) * factor;
            continue;
          }

          // htop 内存条: Mem[|||||| 2.45G/15.6G]
          final htopMem = RegExp(
            r'Mem\[.*?([\d.]+)([KMGTP])/([\d.]+)([KMGTP])\]',
          ).firstMatch(line);
          if (htopMem != null) {
            memUsedMb = _toMegabytes(
              double.tryParse(htopMem.group(1)!) ?? 0,
              htopMem.group(2)!,
            );
            memTotalMb = _toMegabytes(
              double.tryParse(htopMem.group(3)!) ?? 0,
              htopMem.group(4)!,
            );
          }

          if (RegExp(r'^PID\s+USER\b').hasMatch(line) ||
              RegExp(r'^PID\s+COMMAND\s+%CPU').hasMatch(line)) {
            inProcTable = true;
            continue;
          }
        } else {
          // 解析 top / htop 进程行
          final cols = line.split(RegExp(r'\s+'));
          if (cols.length >= 12 && int.tryParse(cols[0]) != null) {
            // 标准 Linux top/htop: PID USER PR NI VIRT RES SHR S %CPU %MEM TIME+ COMMAND
            procs.add(
              ProcessRowItem(
                pid: cols[0],
                user: cols[1],
                state: cols[7],
                cpuPercent: double.tryParse(cols[8]) ?? 0,
                memPercent: double.tryParse(cols[9]) ?? 0,
                memoryText: cols[5],
                timeText: cols[10],
                command: cols.sublist(11).join(' '),
              ),
            );
          } else if (cols.length >= 4 && int.tryParse(cols[0]) != null) {
            procs.add(
              ProcessRowItem(
                pid: cols[0],
                user: cols.length > 2 ? cols[1] : '-',
                cpuPercent: double.tryParse(cols[2]) ?? 0,
                memPercent: 0,
                command: cols.sublist(3).join(' '),
              ),
            );
          }
        }
      }

      final payload = SystemTopPayload(
        uptimeText: uptime,
        usersCount: users,
        loadAverages: loads,
        tasksTotal: tasksTotal,
        tasksRunning: tasksRunning,
        tasksSleeping: tasksSleeping,
        tasksZombie: tasksZombie,
        cpuUser: cpuUs,
        cpuSys: cpuSy,
        cpuIdle: cpuId,
        cpuWait: cpuWa,
        memTotalMb: memTotalMb,
        memUsedMb: memUsedMb,
        memCacheMb: memCacheMb,
        swapTotalMb: swapTotalMb,
        swapUsedMb: swapUsedMb,
        processes: procs,
      );

      final cpuBusy = payload.cpuBusyPercent.toStringAsFixed(1);
      return BeautifiedOutputCard(
        id: id,
        category: BeautyCategoryId.systemTop,
        title: isHtop ? 'htop 系统实时负载' : 'top 系统负载快照',
        command: rawCmd.trim().isEmpty ? 'top' : rawCmd.trim(),
        summaryBadge: 'CPU $cpuBusy% · Load ${loads.first.toStringAsFixed(2)}',
        rawOutput: cleanOutput,
        capturedAt: ts,
        isLiveInteractive: isAltScreen,
        payload: payload,
      );
    }

    // 单行 uptime 命令
    if (lines.length <= 2) {
      final upOnly = RegExp(
        r'^\s*\d{1,2}:\d{2}(?::\d{2})?\s+up\s+(.+?),\s*(\d+)\s+users?,\s*load averages?:\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)',
        caseSensitive: false,
      ).firstMatch(lines.first);
      if (upOnly != null) {
        final l1 = double.tryParse(upOnly.group(3)!) ?? 0;
        final l5 = double.tryParse(upOnly.group(4)!) ?? 0;
        final l15 = double.tryParse(upOnly.group(5)!) ?? 0;
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.systemTop,
          title: '系统运行时间与平均负载',
          command: rawCmd.trim().isEmpty ? 'uptime' : rawCmd.trim(),
          summaryBadge: '已运行 ${upOnly.group(1)!.trim()} · Load $l1',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: SystemInfoPayload([
            KeyValueFact(key: '持续运行 (Uptime)', value: upOnly.group(1)!.trim()),
            KeyValueFact(key: '在线用户数', value: '${upOnly.group(2)} 人'),
            KeyValueFact(
              key: '1 分钟负载',
              value: '$l1',
              highlight: l1 > 4 ? SemanticHealth.warning : SemanticHealth.healthy,
            ),
            KeyValueFact(key: '5 分钟负载', value: '$l5'),
            KeyValueFact(key: '15 分钟负载', value: '$l15'),
          ]),
        );
      }
    }

    return null;
  }

  static double _toMegabytes(double val, String unitChar) {
    return switch (unitChar.toUpperCase()) {
      'K' => val / 1024.0,
      'G' => val * 1024.0,
      'T' => val * 1048576.0,
      _ => val,
    };
  }

  // ==================== 2. Docker / Podman / Compose 解析 ====================

  static BeautifiedOutputCard? _tryParseDocker(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    final headerIdx = lines.indexWhere(
      (l) =>
          (l.contains('CONTAINER ID') &&
              (l.contains('IMAGE') || l.contains('CPU %'))) ||
          (l.contains('REPOSITORY') &&
              l.contains('TAG') &&
              l.contains('IMAGE ID')) ||
          (l.startsWith('NAME') &&
              l.contains('STATUS') &&
              l.contains('PORTS') &&
              (normCmd.contains('docker') || normCmd.contains('podman'))),
    );
    if (headerIdx < 0) return null;

    final header = lines[headerIdx];

    // 2A. docker stats
    if (header.contains('CONTAINER ID') && header.contains('CPU %')) {
      final spans = _computeColumnSpans(header, const [
        'CONTAINER ID',
        'NAME',
        'CPU %',
        'MEM USAGE / LIMIT',
        'MEM %',
        'NET I/O',
        'BLOCK I/O',
        'PIDS',
      ]);
      final stats = <ContainerStatItem>[];
      for (final row in lines.skip(headerIdx + 1)) {
        if (spans.length >= 5) {
          final m = _sliceByColumnSpans(row, spans);
          final cid = m['CONTAINER ID'] ?? '';
          if (cid.isEmpty) continue;
          stats.add(
            ContainerStatItem(
              id: cid,
              name: m['NAME'] ?? cid,
              cpuPercent:
                  double.tryParse((m['CPU %'] ?? '').replaceAll('%', '')) ?? 0,
              memUsage: m['MEM USAGE / LIMIT'] ?? '',
              memPercent:
                  double.tryParse((m['MEM %'] ?? '').replaceAll('%', '')) ?? 0,
              netIo: m['NET I/O'] ?? '',
              blockIo: m['BLOCK I/O'] ?? '',
              pids: m['PIDS'] ?? '',
            ),
          );
        }
      }
      if (stats.isEmpty) return null;
      return BeautifiedOutputCard(
        id: id,
        category: BeautyCategoryId.containers,
        title: 'Docker 容器资源实时监控',
        command: rawCmd.trim().isEmpty ? 'docker stats' : rawCmd.trim(),
        summaryBadge: '${stats.length} 个活跃容器',
        rawOutput: cleanOutput,
        capturedAt: ts,
        payload: DockerStatsPayload(stats),
      );
    }

    // 2B. docker images
    if (header.contains('REPOSITORY') && header.contains('IMAGE ID')) {
      final spans = _computeColumnSpans(header, const [
        'REPOSITORY',
        'TAG',
        'IMAGE ID',
        'CREATED',
        'SIZE',
      ]);
      final images = <DockerImageItem>[];
      for (final row in lines.skip(headerIdx + 1)) {
        if (spans.length >= 4) {
          final m = _sliceByColumnSpans(row, spans);
          if ((m['REPOSITORY'] ?? '').isEmpty) continue;
          images.add(
            DockerImageItem(
              repository: m['REPOSITORY'] ?? '',
              tag: m['TAG'] ?? 'latest',
              imageId: m['IMAGE ID'] ?? '',
              created: m['CREATED'] ?? '',
              size: m['SIZE'] ?? '',
            ),
          );
        }
      }
      if (images.isEmpty) return null;
      return BeautifiedOutputCard(
        id: id,
        category: BeautyCategoryId.containers,
        title: 'Docker 本地镜像仓库',
        command: rawCmd.trim().isEmpty ? 'docker images' : rawCmd.trim(),
        summaryBadge: '${images.length} 个镜像',
        rawOutput: cleanOutput,
        capturedAt: ts,
        payload: DockerImagesPayload(images),
      );
    }

    // 2C. docker ps / podman ps / docker compose ps
    final knownCols = [
      if (header.contains('CONTAINER ID')) 'CONTAINER ID',
      if (header.startsWith('NAME') && !header.contains('CONTAINER ID')) 'NAME',
      if (header.contains('IMAGE')) 'IMAGE',
      if (header.contains('COMMAND')) 'COMMAND',
      if (header.contains('SERVICE')) 'SERVICE',
      if (header.contains('CREATED')) 'CREATED',
      if (header.contains('STATUS')) 'STATUS',
      if (header.contains('PORTS')) 'PORTS',
      if (header.contains('NAMES')) 'NAMES',
    ];
    final spans = _computeColumnSpans(header, knownCols);
    final containers = <ContainerItem>[];
    for (final row in lines.skip(headerIdx + 1)) {
      if (row.trim().isEmpty) continue;
      if (spans.length >= 3) {
        final m = _sliceByColumnSpans(row, spans);
        final cid = m['CONTAINER ID'] ?? '';
        final name = m['NAMES'] ?? m['NAME'] ?? cid;
        final status = m['STATUS'] ?? '';
        if (cid.isEmpty && name.isEmpty) continue;
        final lowerStatus = status.toLowerCase();
        final health = lowerStatus.contains('unhealthy') ||
                lowerStatus.contains('exited (') &&
                    !lowerStatus.contains('exited (0)') ||
                lowerStatus.contains('dead')
            ? SemanticHealth.danger
            : lowerStatus.contains('restarting') || lowerStatus.contains('paused')
            ? SemanticHealth.warning
            : lowerStatus.startsWith('up') || lowerStatus.contains('running')
            ? SemanticHealth.healthy
            : SemanticHealth.neutral;
        containers.add(
          ContainerItem(
            id: cid,
            name: name,
            image: m['IMAGE'] ?? m['SERVICE'] ?? '',
            status: status,
            ports: m['PORTS'] ?? '',
            command: m['COMMAND'] ?? '',
            health: health,
          ),
        );
      }
    }
    // 即使 `docker ps` 当前没有任何运行容器（仅表头），如果是显式输入的 docker ps 也展示空状态卡片
    if (containers.isEmpty && !normCmd.contains('ps')) {
      return null;
    }
    final runningCount = containers
        .where((c) => c.health == SemanticHealth.healthy)
        .length;
    return BeautifiedOutputCard(
      id: id,
      category: BeautyCategoryId.containers,
      title: 'Docker 容器实例列表',
      command: rawCmd.trim().isEmpty ? 'docker ps' : rawCmd.trim(),
      summaryBadge: containers.isEmpty
          ? '0 个运行容器'
          : '${containers.length} 个容器 · $runningCount 运行中',
      rawOutput: cleanOutput,
      capturedAt: ts,
      payload: DockerContainersPayload(containers),
    );
  }

  // ==================== 3. Kubernetes (kubectl get) 解析 ====================

  static BeautifiedOutputCard? _tryParseKubernetes(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    final headerIdx = lines.indexWhere(
      (l) =>
          (l.contains('NAME') &&
              l.contains('READY') &&
              l.contains('STATUS') &&
              l.contains('AGE')) ||
          (l.contains('NAME') &&
              l.contains('TYPE') &&
              l.contains('CLUSTER-IP') &&
              l.contains('PORT(S)')) ||
          (l.contains('NAME') &&
              l.contains('STATUS') &&
              l.contains('ROLES') &&
              l.contains('VERSION')),
    );
    if (headerIdx < 0) return null;
    final header = lines[headerIdx];

    if (header.contains('READY') && header.contains('STATUS')) {
      final hasNs = header.trimLeft().startsWith('NAMESPACE');
      final cols = [
        if (hasNs) 'NAMESPACE',
        'NAME',
        'READY',
        'STATUS',
        if (header.contains('RESTARTS')) 'RESTARTS',
        'AGE',
        if (header.contains('IP')) 'IP',
        if (header.contains('NODE')) 'NODE',
      ];
      final spans = _computeColumnSpans(header, cols);
      final items = <K8sResourceItem>[];
      for (final row in lines.skip(headerIdx + 1)) {
        final m = _sliceByColumnSpans(row, spans);
        final name = m['NAME'] ?? '';
        if (name.isEmpty) continue;
        final status = m['STATUS'] ?? '';
        final sl = status.toLowerCase();
        final health = sl.contains('crash') ||
                sl.contains('err') ||
                sl.contains('backoff') ||
                sl.contains('oom') ||
                sl.contains('evicted')
            ? SemanticHealth.danger
            : sl.contains('pending') ||
                  sl.contains('creating') ||
                  sl.contains('init') ||
                  sl.contains('terminating')
            ? SemanticHealth.warning
            : sl == 'running' || sl == 'completed' || sl == 'succeeded'
            ? SemanticHealth.healthy
            : SemanticHealth.neutral;
        items.add(
          K8sResourceItem(
            namespace: m['NAMESPACE'] ?? 'default',
            name: name,
            ready: m['READY'] ?? '',
            status: status,
            restarts: m['RESTARTS'] ?? '0',
            age: m['AGE'] ?? '',
            extra: [
              if ((m['IP'] ?? '').isNotEmpty) m['IP']!,
              if ((m['NODE'] ?? '').isNotEmpty) m['NODE']!,
            ].join(' · '),
            health: health,
          ),
        );
      }
      if (items.isEmpty) return null;
      final healthyCount = items
          .where((i) => i.health == SemanticHealth.healthy)
          .length;
      return BeautifiedOutputCard(
        id: id,
        category: BeautyCategoryId.kubernetes,
        title: 'Kubernetes Pods 状态',
        command: rawCmd.trim().isEmpty ? 'kubectl get pods' : rawCmd.trim(),
        summaryBadge: '${items.length} Pods · $healthyCount 就绪',
        rawOutput: cleanOutput,
        capturedAt: ts,
        payload: K8sResourcesPayload(resourceKind: 'Pod', items: items),
      );
    }

    // Service / Node 走结构化 K8s 列表
    final partsHeader = header.trim().split(RegExp(r'\s{2,}'));
    final rows = <List<String>>[];
    for (final r in lines.skip(headerIdx + 1)) {
      final cells = r.trim().split(RegExp(r'\s{2,}'));
      if (cells.length >= 3) rows.add(cells);
    }
    if (rows.isEmpty) return null;
    return BeautifiedOutputCard(
      id: id,
      category: BeautyCategoryId.kubernetes,
      title: header.contains('CLUSTER-IP')
          ? 'Kubernetes Services'
          : 'Kubernetes Nodes',
      command: rawCmd.trim().isEmpty ? 'kubectl get' : rawCmd.trim(),
      summaryBadge: '${rows.length} 项资源',
      rawOutput: cleanOutput,
      capturedAt: ts,
      payload: GenericTablePayload(columns: partsHeader, rows: rows),
    );
  }

  // ==================== 4. NVIDIA GPU & 内存 (nvidia-smi / free) ====================

  static BeautifiedOutputCard? _tryParseNvidiaSmi(
    String id,
    String rawCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    if (!cleanOutput.contains('NVIDIA-SMI') ||
        !cleanOutput.contains('Driver Version:')) {
      return null;
    }
    final verMatch = RegExp(
      r'Driver Version:\s*([\w.]+)\s+CUDA Version:\s*([\w.]+)',
    ).firstMatch(cleanOutput);
    final driver = verMatch?.group(1) ?? '-';
    final cuda = verMatch?.group(2) ?? '-';

    final gpus = <GpuCardItem>[];
    final gpuProcs = <GpuProcessItem>[];

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      // 匹配显卡名称行: |   0  NVIDIA A100-SXM4-80GB   On  | ...
      final nameRow = RegExp(
        r'^\|\s*(\d+)\s+(.+?)\s+(?:On|Off|N/A)\s*\|',
      ).firstMatch(line);
      if (nameRow != null && i + 1 < lines.length) {
        final nextLine = lines[i + 1];
        final metricRow = RegExp(
          r'\|\s*(?:\d+%|N/A)\s+(\d+)C\s+\S+\s+(.+?)\s*\|\s*(\d+)MiB\s*/\s*(\d+)MiB\s*\|\s*(\d+)%',
        ).firstMatch(nextLine);
        if (metricRow != null) {
          gpus.add(
            GpuCardItem(
              index: int.tryParse(nameRow.group(1)!) ?? 0,
              name: nameRow.group(2)!.trim(),
              tempC: int.tryParse(metricRow.group(1)!) ?? 0,
              powerUsage: metricRow.group(2)!.trim(),
              memUsedMiB: int.tryParse(metricRow.group(3)!) ?? 0,
              memTotalMiB: int.tryParse(metricRow.group(4)!) ?? 1,
              utilPercent: int.tryParse(metricRow.group(5)!) ?? 0,
            ),
          );
        }
      }
      // 匹配显存进程行: |    0   N/A  N/A    12849      C   python     14200MiB |
      final procRow = RegExp(
        r'^\|\s*(\d+)\s+\S+\s+\S+\s+(\d+)\s+[CG]+\s+(.+?)\s+(\d+MiB)\s*\|$',
      ).firstMatch(line);
      if (procRow != null) {
        gpuProcs.add(
          GpuProcessItem(
            gpuIndex: int.tryParse(procRow.group(1)!) ?? 0,
            pid: procRow.group(2)!,
            processName: procRow.group(3)!.trim(),
            usedMemory: procRow.group(4)!,
          ),
        );
      }
    }

    if (gpus.isEmpty) return null;
    final avgUtil =
        (gpus.fold<int>(0, (a, b) => a + b.utilPercent) / gpus.length).round();
    return BeautifiedOutputCard(
      id: id,
      category: BeautyCategoryId.memoryGpu,
      title: 'NVIDIA GPU 算力与显存监控',
      command: rawCmd.trim().isEmpty ? 'nvidia-smi' : rawCmd.trim(),
      summaryBadge: '${gpus.length} GPU · 平均算力 $avgUtil% · CUDA $cuda',
      rawOutput: cleanOutput,
      capturedAt: ts,
      payload: GpuStatusPayload(
        driverVersion: driver,
        cudaVersion: cuda,
        gpus: gpus,
        processes: gpuProcs,
      ),
    );
  }

  static BeautifiedOutputCard? _tryParseMemory(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    final memLine = lines
        .where((l) => RegExp(r'^\s*(?:Mem|内存)[:：]\s*\S+').hasMatch(l))
        .firstOrNull;
    final hasFreeHeader = lines.any(
      (l) =>
          l.contains('total') &&
          l.contains('used') &&
          l.contains('free'),
    );
    if (memLine != null && hasFreeHeader) {
      final mParts = memLine
          .replaceFirst(RegExp(r'^\s*(?:Mem|内存)[:：]\s*'), '')
          .trim()
          .split(RegExp(r'\s+'));
      if (mParts.length >= 3) {
        final totalVal = _parseHumanBytes(mParts[0]);
        final usedVal = _parseHumanBytes(mParts[1]);
        final freeStr = mParts[2];
        final buffStr = mParts.length >= 5 ? mParts[4] : '0B';
        final availStr = mParts.length >= 6 ? mParts[5] : freeStr;
        final cacheVal = _parseHumanBytes(buffStr);

        final swapLine = lines
            .where((l) => RegExp(r'^\s*(?:Swap|交换)[:：]\s*\S+').hasMatch(l))
            .firstOrNull;
        String? swTotal, swUsed, swFree;
        var swRatio = 0.0;
        if (swapLine != null) {
          final sParts = swapLine
              .replaceFirst(RegExp(r'^\s*(?:Swap|交换)[:：]\s*'), '')
              .trim()
              .split(RegExp(r'\s+'));
          if (sParts.length >= 3) {
            swTotal = sParts[0];
            swUsed = sParts[1];
            swFree = sParts[2];
            final st = _parseHumanBytes(swTotal);
            final su = _parseHumanBytes(swUsed);
            if (st > 0) swRatio = (su / st).clamp(0.0, 1.0);
          }
        }

        final usedRatio = totalVal > 0
            ? (usedVal / totalVal).clamp(0.0, 1.0)
            : 0.0;
        final cacheRatio = totalVal > 0
            ? (cacheVal / totalVal).clamp(0.0, 1.0 - usedRatio)
            : 0.0;

        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.memoryGpu,
          title: '系统物理内存与 Swap 占用',
          command: rawCmd.trim().isEmpty ? 'free -h' : rawCmd.trim(),
          summaryBadge:
              '已用 ${mParts[1]} / ${mParts[0]} (${(usedRatio * 100).toStringAsFixed(0)}%)',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: MemoryUsagePayload(
            ramTotal: mParts[0],
            ramUsed: mParts[1],
            ramFree: freeStr,
            ramBuffCache: buffStr,
            ramAvailable: availStr,
            ramUsedRatio: usedRatio,
            ramCacheRatio: cacheRatio,
            swapTotal: swTotal,
            swapUsed: swUsed,
            swapFree: swFree,
            swapUsedRatio: swRatio,
          ),
        );
      }
    }
    return null;
  }

  // ==================== 5. 磁盘挂载 (df / Get-PSDrive) & 目录体积 (du) ====================

  static BeautifiedOutputCard? _tryParseDiskAndDu(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    // 5A. POSIX df -h / df -Th / df -k / macOS df
    final dfHeaderIdx = lines.indexWhere(
      (l) =>
          l.contains('Filesystem') &&
          (l.contains('Mounted on') || l.contains('Use%') || l.contains('Capacity')),
    );
    if (dfHeaderIdx >= 0) {
      final hasType = lines[dfHeaderIdx].contains('Type');
      final mounts = <DiskMountItem>[];
      for (final row in lines.skip(dfHeaderIdx + 1)) {
        final pctMatch = RegExp(
          hasType
              ? r'^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)%\s+(.+)$'
              : r'^(.+?)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)%(?:\s+\d+\s+\d+\s+\d+%)?\s+(.+)$',
        ).firstMatch(row.trim());
        if (pctMatch == null) continue;
        if (hasType) {
          mounts.add(
            DiskMountItem(
              filesystem: pctMatch.group(1)!,
              fsType: pctMatch.group(2)!,
              sizeText: pctMatch.group(3)!,
              usedText: pctMatch.group(4)!,
              availText: pctMatch.group(5)!,
              useRatio: ((int.tryParse(pctMatch.group(6)!) ?? 0) / 100.0)
                  .clamp(0.0, 1.0),
              mountPoint: pctMatch.group(7)!.trim(),
            ),
          );
        } else {
          mounts.add(
            DiskMountItem(
              filesystem: pctMatch.group(1)!.trim(),
              sizeText: pctMatch.group(2)!,
              usedText: pctMatch.group(3)!,
              availText: pctMatch.group(4)!,
              useRatio: ((int.tryParse(pctMatch.group(5)!) ?? 0) / 100.0)
                  .clamp(0.0, 1.0),
              mountPoint: pctMatch.group(6)!.trim(),
            ),
          );
        }
      }
      if (mounts.isNotEmpty) {
        final highCount = mounts.where((m) => m.useRatio >= 0.85).length;
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.diskStorage,
          title: '磁盘分区挂载容量',
          command: rawCmd.trim().isEmpty ? 'df -h' : rawCmd.trim(),
          summaryBadge: highCount > 0
              ? '${mounts.length} 个挂载点 · $highCount 个高水位告警'
              : '${mounts.length} 个挂载点',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: DiskUsagePayload(mounts),
        );
      }
    }

    // 5B. Windows PowerShell Get-PSDrive (Name Used (GB) Free (GB) Provider Root)
    final psDriveIdx = lines.indexWhere(
      (l) =>
          l.contains('Used (GB)') &&
          l.contains('Free (GB)') &&
          l.contains('Provider'),
    );
    if (psDriveIdx >= 0) {
      final mounts = <DiskMountItem>[];
      for (final row in lines.skip(psDriveIdx + 1)) {
        final t = row.trim();
        if (t.startsWith('----')) continue;
        final m = RegExp(
          r'^(\S+)\s+([\d.]+)\s+([\d.]+)\s+FileSystem\s+(.+)$',
        ).firstMatch(t);
        if (m != null) {
          final usedGb = double.tryParse(m.group(2)!.replaceAll(',', '')) ?? 0;
          final freeGb = double.tryParse(m.group(3)!.replaceAll(',', '')) ?? 0;
          final totalGb = usedGb + freeGb;
          if (totalGb <= 0) continue;
          final rootParts = m.group(4)!.trim().split(RegExp(r'\s{2,}'));
          final rootClean = rootParts.first.trim();
          final curLoc = rootParts.length > 1 ? rootParts.last.trim() : '';
          mounts.add(
            DiskMountItem(
              filesystem: '${m.group(1)}: 盘',
              fsType: 'NTFS',
              sizeText: '${totalGb.toStringAsFixed(1)}G',
              usedText: '${usedGb.toStringAsFixed(1)}G',
              availText: '${freeGb.toStringAsFixed(1)}G',
              useRatio: (usedGb / totalGb).clamp(0.0, 1.0),
              mountPoint: curLoc.isNotEmpty
                  ? '$rootClean ($curLoc)'
                  : rootClean,
            ),
          );
        }
      }
      if (mounts.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.diskStorage,
          title: '本机磁盘驱动器容量',
          command: rawCmd.trim().isEmpty ? 'Get-PSDrive' : rawCmd.trim(),
          summaryBadge: '${mounts.length} 个逻辑盘',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: DiskUsagePayload(mounts),
        );
      }
    }

    // 5C. du -sh / du -h 目录大小排行
    final isDuCmd = RegExp(r'^du(?:\s|$)').hasMatch(normCmd);
    if (isDuCmd || lines.length >= 3) {
      final parsedDu = <({String size, double bytes, String path})>[];
      var allMatch = lines.isNotEmpty;
      for (final line in lines) {
        final m = RegExp(
          r'^\s*(\d+(?:[.,]\d+)?[KMGTPBkmgtpb]i?B?)\s+(.+)$',
        ).firstMatch(line);
        if (m == null) {
          allMatch = false;
          break;
        }
        final path = m.group(2)!.trim();
        // 非显式 du 命令时要求路径看起来像文件/目录路径
        if (!isDuCmd && !path.contains('/') && !path.contains(r'\') && !path.startsWith('.')) {
          allMatch = false;
          break;
        }
        parsedDu.add((
          size: m.group(1)!,
          bytes: _parseHumanBytes(m.group(1)!),
          path: path,
        ));
      }
      if (allMatch && parsedDu.length >= 2) {
        parsedDu.sort((a, b) => b.bytes.compareTo(a.bytes));
        final maxBytes = max(1.0, parsedDu.first.bytes);
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.diskStorage,
          title: '目录与文件空间占用排行',
          command: rawCmd.trim().isEmpty ? 'du -sh *' : rawCmd.trim(),
          summaryBadge: '${parsedDu.length} 项 · 最大 ${parsedDu.first.size}',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: DirSizeRankPayload(
            parsedDu
                .map(
                  (e) => DirSizeItem(
                    path: e.path,
                    sizeText: e.size,
                    bytesEstimate: e.bytes,
                    ratioOfMax: (e.bytes / maxBytes).clamp(0.02, 1.0),
                  ),
                )
                .toList(),
          ),
        );
      }
    }

    return null;
  }

  static double _parseHumanBytes(String text) {
    final cleaned = text.trim().replaceAll(',', '.');
    final m = RegExp(r'^([\d.]+)\s*([KMGTPkmgtp])?').firstMatch(cleaned);
    if (m == null) return 0;
    final numVal = double.tryParse(m.group(1)!) ?? 0;
    final unit = (m.group(2) ?? '').toUpperCase();
    return switch (unit) {
      'K' => numVal * 1024,
      'M' => numVal * 1024 * 1024,
      'G' => numVal * 1024 * 1024 * 1024,
      'T' => numVal * 1024 * 1024 * 1024 * 1024,
      'P' => numVal * 1024 * 1024 * 1024 * 1024 * 1024,
      _ => numVal,
    };
  }

  // ==================== 6. 网络端口与套接字 (ss / netstat / lsof -i) ====================

  static BeautifiedOutputCard? _tryParseNetworkSockets(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    // 6A. Linux ss -tulnp / ss -antp
    final ssHeaderIdx = lines.indexWhere(
      (l) =>
          (l.contains('Local Address:Port') && l.contains('Peer Address:Port')) ||
          (l.startsWith('Netid') && l.contains('State') && l.contains('Recv-Q')),
    );
    if (ssHeaderIdx >= 0) {
      final hasNetid = lines[ssHeaderIdx].trimLeft().startsWith('Netid');
      final sockets = <SocketPortItem>[];
      for (final row in lines.skip(ssHeaderIdx + 1)) {
        final cols = row.trim().split(RegExp(r'\s+'));
        final minCols = hasNetid ? 5 : 4;
        if (cols.length < minCols) continue;
        final proto = hasNetid ? cols[0].toUpperCase() : 'TCP';
        final state = hasNetid ? cols[1] : cols[0];
        final localFull = hasNetid ? cols[4] : cols[3];
        final peerFull = cols.length > (hasNetid ? 5 : 4)
            ? cols[hasNetid ? 5 : 4]
            : '*:*';
        final procRaw = cols.length > (hasNetid ? 6 : 5)
            ? cols.sublist(hasNetid ? 6 : 5).join(' ')
            : '';
        final procClean = _cleanSsProcess(procRaw);
        final splitAddr = _splitHostPort(localFull);
        sockets.add(
          SocketPortItem(
            proto: proto,
            state: state,
            localAddress: splitAddr.$1,
            localPort: splitAddr.$2,
            peerAddress: peerFull,
            process: procClean,
            health: _socketHealth(state),
          ),
        );
      }
      if (sockets.isNotEmpty) {
        final listenCnt = sockets
            .where((s) => s.state.toUpperCase().contains('LISTEN'))
            .length;
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.networkPorts,
          title: '网络套接字与监听端口',
          command: rawCmd.trim().isEmpty ? 'ss -tulnp' : rawCmd.trim(),
          summaryBadge: '${sockets.length} 条连接 · $listenCnt 监听中',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: NetworkSocketsPayload(sockets),
        );
      }
    }

    // 6B. Linux / Windows netstat (-tulnp / -ano，含中文“协议 本地地址 外部地址 状态 PID”)
    final netstatIdx = lines.indexWhere(
      (l) =>
          (l.contains('Proto') &&
              l.contains('Local Address') &&
              l.contains('Foreign Address')) ||
          (l.contains('协议') && l.contains('本地地址') && l.contains('外部地址')),
    );
    if (netstatIdx >= 0) {
      final sockets = <SocketPortItem>[];
      for (final row in lines.skip(netstatIdx + 1)) {
        final cols = row.trim().split(RegExp(r'\s+'));
        if (cols.length < 4) continue;
        final proto = cols[0].toUpperCase();
        if (!proto.startsWith('TCP') && !proto.startsWith('UDP')) continue;

        // Linux netstat 有 Recv-Q Send-Q (数字列)，Windows netstat 直接是 Local Foreign
        final isLinuxFormat =
            int.tryParse(cols[1]) != null && int.tryParse(cols[2]) != null;
        if (isLinuxFormat && cols.length >= 5) {
          final local = _splitHostPort(cols[3]);
          final peer = cols[4];
          var state = cols.length >= 6 ? cols[5] : 'OPEN';
          var proc = cols.length >= 7 ? cols.sublist(6).join(' ') : '';
          if (proto.startsWith('UDP') && state.contains('/')) {
            proc = state;
            state = 'UNCONN';
          }
          sockets.add(
            SocketPortItem(
              proto: proto,
              state: state,
              localAddress: local.$1,
              localPort: local.$2,
              peerAddress: peer,
              process: proc,
              health: _socketHealth(state),
            ),
          );
        } else {
          // Windows netstat -ano: TCP 0.0.0.0:135 0.0.0.0:0 LISTENING 1140
          // UDP 0.0.0.0:5353 *:* 2412
          final local = _splitHostPort(cols[1]);
          final peer = cols[2];
          final hasState = !proto.startsWith('UDP') && cols.length >= 4 && int.tryParse(cols[3]) == null;
          final state = hasState ? cols[3] : (proto.startsWith('UDP') ? 'UDP' : '');
          final pidCol = hasState
              ? (cols.length >= 5 ? cols[4] : '')
              : (cols.length >= 4 ? cols[3] : '');
          sockets.add(
            SocketPortItem(
              proto: proto,
              state: state,
              localAddress: local.$1,
              localPort: local.$2,
              peerAddress: peer,
              process: pidCol.isNotEmpty ? 'PID $pidCol' : '',
              health: _socketHealth(state),
            ),
          );
        }
      }
      if (sockets.isNotEmpty) {
        final listenCnt = sockets
            .where((s) => s.state.toUpperCase().contains('LISTEN'))
            .length;
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.networkPorts,
          title: '网络端口连接状态 (netstat)',
          command: rawCmd.trim().isEmpty ? 'netstat' : rawCmd.trim(),
          summaryBadge: '${sockets.length} 条记录 · $listenCnt 监听端口',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: NetworkSocketsPayload(sockets),
        );
      }
    }

    // 6C. lsof -i
    final lsofIdx = lines.indexWhere(
      (l) =>
          l.startsWith('COMMAND') &&
          l.contains('PID') &&
          l.contains('USER') &&
          l.contains('NODE') &&
          l.contains('NAME'),
    );
    if (lsofIdx >= 0) {
      final sockets = <SocketPortItem>[];
      for (final row in lines.skip(lsofIdx + 1)) {
        final cols = row.trim().split(RegExp(r'\s+'));
        if (cols.length < 9) continue;
        final cmdName = cols[0];
        final pid = cols[1];
        final user = cols[2];
        final proto = cols[7].toUpperCase();
        final nameRest = cols.sublist(8).join(' ');
        final stateM = RegExp(r'\(([^)]+)\)$').firstMatch(nameRest);
        final state = stateM?.group(1) ?? 'OPEN';
        final endpoint = nameRest.replaceFirst(RegExp(r'\s*\([^)]+\)$'), '');
        final parts = endpoint.split('->');
        final local = _splitHostPort(parts.first);
        sockets.add(
          SocketPortItem(
            proto: proto,
            state: state,
            localAddress: local.$1,
            localPort: local.$2,
            peerAddress: parts.length > 1 ? parts[1] : '*:*',
            process: '$cmdName (PID $pid · $user)',
            health: _socketHealth(state),
          ),
        );
      }
      if (sockets.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.networkPorts,
          title: '进程打开网络端口 (lsof)',
          command: rawCmd.trim().isEmpty ? 'lsof -i' : rawCmd.trim(),
          summaryBadge: '${sockets.length} 个网络句柄',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: NetworkSocketsPayload(sockets),
        );
      }
    }

    return null;
  }

  static String _cleanSsProcess(String raw) {
    final m = RegExp(r'"([^"]+)",pid=(\d+)').firstMatch(raw);
    if (m != null) return '${m.group(1)} (PID ${m.group(2)})';
    return raw;
  }

  static (String, String) _splitHostPort(String addr) {
    final lastColon = addr.lastIndexOf(':');
    if (lastColon <= 0 || lastColon == addr.length - 1) {
      return (addr, '-');
    }
    return (addr.substring(0, lastColon), addr.substring(lastColon + 1));
  }

  static SemanticHealth _socketHealth(String state) {
    final u = state.toUpperCase();
    if (u.contains('LISTEN')) return SemanticHealth.healthy;
    if (u.contains('ESTABLISHED')) return SemanticHealth.info;
    if (u.contains('CLOSE_WAIT') || u.contains('SYN_')) {
      return SemanticHealth.warning;
    }
    return SemanticHealth.neutral;
  }

  // ==================== 7. Ping 与网卡接口 (ping / ip a / ifconfig / ipconfig) ====================

  static BeautifiedOutputCard? _tryParsePing(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    final first = lines.first;
    final isPing = first.startsWith('PING ') ||
        first.startsWith('Pinging ') ||
        first.startsWith('正在 Ping ');
    if (!isPing) return null;

    var target = '目标主机';
    final tMatch = RegExp(
      r'^(?:PING|Pinging|正在 Ping)\s+(\S+)',
    ).firstMatch(first);
    if (tMatch != null) target = tMatch.group(1)!;

    final replies = <PingReplySample>[];
    var seqCounter = 1;
    var tx = 0, rx = 0;
    var lossPct = 0.0;
    double? minMs, avgMs, maxMs;

    for (final line in lines.skip(1)) {
      // Linux/macOS: 64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=11.4 ms
      final posixReply = RegExp(
        r'(?:icmp_seq|seq)=(\d+).*?ttl=(\d+).*?time[=<]\s*([\d.]+)\s*ms',
        caseSensitive: false,
      ).firstMatch(line);
      if (posixReply != null) {
        replies.add(
          PingReplySample(
            seq: int.tryParse(posixReply.group(1)!) ?? seqCounter++,
            ttl: posixReply.group(2)!,
            timeMs: double.tryParse(posixReply.group(3)!) ?? 0,
          ),
        );
        continue;
      }

      // Windows 英文/中文: Reply from ...: bytes=32 time=12ms TTL=56 / 来自 ... 的回复: 字节=32 时间<1ms TTL=64
      final winReply = RegExp(
        r'(?:time|时间)\s*([=<])\s*([\d.]+)\s*ms(?:\s+TTL=(\d+))?',
        caseSensitive: false,
      ).firstMatch(line);
      if (winReply != null) {
        final rawMs = double.tryParse(winReply.group(2)!) ?? 1.0;
        replies.add(
          PingReplySample(
            seq: seqCounter++,
            timeMs: winReply.group(1) == '<' ? 0.5 : rawMs,
            ttl: winReply.group(3) ?? '',
          ),
        );
        continue;
      }

      // Linux/macOS 汇总: 4 packets transmitted, 4 packets received, 0.0% packet loss
      final posixStat = RegExp(
        r'(\d+)\s+packets\s+transmitted,\s*(\d+)\s+(?:packets\s+)?received,\s*([\d.]+)%\s+packet\s+loss',
      ).firstMatch(line);
      if (posixStat != null) {
        tx = int.tryParse(posixStat.group(1)!) ?? 0;
        rx = int.tryParse(posixStat.group(2)!) ?? 0;
        lossPct = double.tryParse(posixStat.group(3)!) ?? 0;
        continue;
      }

      // Windows 汇总: Sent = 4, Received = 4, Lost = 0 (0% loss) / 已发送 = 4，已接收 = 4，丢失 = 0 (0% 丢失)
      final winStat = RegExp(
        r'(?:Sent|已发送)\s*=\s*(\d+).*?(?:Received|已接收)\s*=\s*(\d+).*?\(([\d.]+)%\s*(?:loss|丢失)\)',
      ).firstMatch(line);
      if (winStat != null) {
        tx = int.tryParse(winStat.group(1)!) ?? 0;
        rx = int.tryParse(winStat.group(2)!) ?? 0;
        lossPct = double.tryParse(winStat.group(3)!) ?? 0;
        continue;
      }

      // Linux/macOS rtt: min/avg/max/... = 10.800/11.550/12.100/... ms
      final rttM = RegExp(
        r'=\s*([\d.]+)/([\d.]+)/([\d.]+)',
      ).firstMatch(line);
      if (rttM != null && line.contains('ms')) {
        minMs = double.tryParse(rttM.group(1)!);
        avgMs = double.tryParse(rttM.group(2)!);
        maxMs = double.tryParse(rttM.group(3)!);
        continue;
      }

      // Windows rtt: Minimum = 10ms, Maximum = 14ms, Average = 12ms / 最短 = 10ms，最长 = 14ms，平均 = 12ms
      final winRtt = RegExp(
        r'(?:Minimum|最短)\s*=\s*([\d.]+)ms.*?(?:Maximum|最长)\s*=\s*([\d.]+)ms.*?(?:Average|平均)\s*=\s*([\d.]+)ms',
      ).firstMatch(line);
      if (winRtt != null) {
        minMs = double.tryParse(winRtt.group(1)!);
        maxMs = double.tryParse(winRtt.group(2)!);
        avgMs = double.tryParse(winRtt.group(3)!);
      }
    }

    if (replies.isEmpty && tx == 0) return null;
    if (tx == 0) {
      tx = replies.length;
      rx = replies.length;
    }
    if (avgMs == null && replies.isNotEmpty) {
      final times = replies.map((r) => r.timeMs).toList()..sort();
      minMs = times.first;
      maxMs = times.last;
      avgMs = times.fold<double>(0, (a, b) => a + b) / times.length;
    }

    return BeautifiedOutputCard(
      id: id,
      category: BeautyCategoryId.networkInterfaces,
      title: 'Ping 网络连通性诊断 ($target)',
      command: rawCmd.trim().isEmpty ? 'ping $target' : rawCmd.trim(),
      summaryBadge: avgMs != null
          ? '平均 ${avgMs.toStringAsFixed(1)}ms · 丢包 ${lossPct.toStringAsFixed(0)}%'
          : '已发 $tx · 丢包 ${lossPct.toStringAsFixed(0)}%',
      rawOutput: cleanOutput,
      capturedAt: ts,
      payload: PingStatsPayload(
        target: target,
        replies: replies,
        transmitted: tx,
        received: rx,
        lossPercent: lossPct,
        minMs: minMs,
        avgMs: avgMs,
        maxMs: maxMs,
      ),
    );
  }

  static BeautifiedOutputCard? _tryParseNetworkInterfaces(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    // 7A. Linux `ip addr` / `ip a`
    if (lines.any((l) => RegExp(r'^\d+:\s+[\w.@:-]+:\s+<').hasMatch(l))) {
      final list = <NetInterfaceItem>[];
      String? curName;
      var curUp = false;
      var v4 = <String>[];
      var v6 = <String>[];
      var mac = '';

      void flush() {
        if (curName != null) {
          list.add(
            NetInterfaceItem(
              name: curName,
              isUp: curUp,
              ipv4List: List.of(v4),
              ipv6List: List.of(v6),
              macAddress: mac,
            ),
          );
        }
      }

      for (final line in lines) {
        final headM = RegExp(
          r'^\d+:\s+([^:@\s]+)(?:@\S+)?:\s+<([^>]*)>',
        ).firstMatch(line);
        if (headM != null) {
          flush();
          curName = headM.group(1)!;
          final flags = headM.group(2)!;
          curUp =
              (flags.contains('LOWER_UP') || flags.split(',').contains('UP')) &&
              !line.contains('state DOWN');
          v4 = [];
          v6 = [];
          mac = '';
          continue;
        }
        final t = line.trim();
        if (t.startsWith('inet ')) {
          final parts = t.split(RegExp(r'\s+'));
          if (parts.length >= 2) v4.add(parts[1]);
        } else if (t.startsWith('inet6 ')) {
          final parts = t.split(RegExp(r'\s+'));
          if (parts.length >= 2) v6.add(parts[1]);
        } else if (t.startsWith('link/ether ')) {
          final parts = t.split(RegExp(r'\s+'));
          if (parts.length >= 2) mac = parts[1];
        }
      }
      flush();
      if (list.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.networkInterfaces,
          title: '网络接口地址配置 (ip addr)',
          command: rawCmd.trim().isEmpty ? 'ip addr' : rawCmd.trim(),
          summaryBadge: '${list.length} 个网卡接口',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: NetworkInterfacesPayload(list),
        );
      }
    }

    // 7B. macOS / Linux `ifconfig`
    if (lines.any((l) => RegExp(r'^[\w.]+:\s+flags=\d+<').hasMatch(l))) {
      final list = <NetInterfaceItem>[];
      String? curName;
      var curUp = false;
      var v4 = <String>[];
      var v6 = <String>[];
      var mac = '';

      void flush() {
        if (curName != null && (v4.isNotEmpty || v6.isNotEmpty || mac.isNotEmpty)) {
          list.add(
            NetInterfaceItem(
              name: curName,
              isUp: curUp,
              ipv4List: List.of(v4),
              ipv6List: List.of(v6),
              macAddress: mac,
            ),
          );
        }
      }

      for (final line in lines) {
        final headM = RegExp(r'^([\w.]+):\s+flags=\d+<([^>]*)>').firstMatch(line);
        if (headM != null) {
          flush();
          curName = headM.group(1)!;
          curUp = headM.group(2)!.split(',').contains('UP');
          v4 = [];
          v6 = [];
          mac = '';
          continue;
        }
        final t = line.trim();
        if (t.startsWith('inet ')) {
          final parts = t.split(RegExp(r'\s+'));
          if (parts.length >= 2) v4.add(parts[1]);
        } else if (t.startsWith('inet6 ')) {
          final parts = t.split(RegExp(r'\s+'));
          if (parts.length >= 2) v6.add(parts[1]);
        } else if (t.startsWith('ether ')) {
          final parts = t.split(RegExp(r'\s+'));
          if (parts.length >= 2) mac = parts[1];
        } else if (t.startsWith('status: inactive')) {
          curUp = false;
        }
      }
      flush();
      if (list.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.networkInterfaces,
          title: '网络接口地址配置 (ifconfig)',
          command: rawCmd.trim().isEmpty ? 'ifconfig' : rawCmd.trim(),
          summaryBadge: '${list.length} 个活跃接口',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: NetworkInterfacesPayload(list),
        );
      }
    }

    // 7C. Windows `ipconfig` / `ipconfig /all` (中英文双语适配)
    if (cleanOutput.contains('Windows IP Configuration') ||
        cleanOutput.contains('Windows IP 配置')) {
      final list = <NetInterfaceItem>[];
      String? curName;
      var curUp = true;
      var v4 = <String>[];
      var v6 = <String>[];
      var mac = '';
      var gw = '';

      void flush() {
        if (curName != null && (v4.isNotEmpty || v6.isNotEmpty || !curUp)) {
          list.add(
            NetInterfaceItem(
              name: curName,
              isUp: curUp && v4.isNotEmpty,
              ipv4List: List.of(v4),
              ipv6List: List.of(v6),
              macAddress: mac,
              gatewayOrMask: gw,
            ),
          );
        }
      }

      for (final rawLine in lines) {
        if (!rawLine.startsWith(' ') &&
            rawLine.trimRight().endsWith(':') &&
            !rawLine.contains('Windows IP')) {
          flush();
          curName = rawLine.trim().replaceFirst(RegExp(r':$'), '');
          curUp = true;
          v4 = [];
          v6 = [];
          mac = '';
          gw = '';
          continue;
        }
        final t = rawLine.trim();
        if (t.contains('Media disconnected') || t.contains('媒体已断开连接')) {
          curUp = false;
        } else if (t.contains('IPv4')) {
          final val = t.split(':').last.trim().replaceAll(RegExp(r'\(.*\)'), '');
          if (val.isNotEmpty) v4.add(val);
        } else if (t.contains('IPv6')) {
          final idx = t.indexOf(':');
          if (idx > 0) {
            final val = t
                .substring(idx + 1)
                .trim()
                .replaceAll(RegExp(r'\(.*\)'), '');
            if (val.isNotEmpty) v6.add(val);
          }
        } else if (t.contains('Physical Address') || t.contains('物理地址')) {
          mac = t.split(':').last.trim();
        } else if (t.contains('Default Gateway') || t.contains('默认网关')) {
          final gVal = t.split(':').last.trim();
          if (gVal.isNotEmpty) gw = '网关 $gVal';
        }
      }
      flush();
      if (list.isNotEmpty) {
        final activeCnt = list.where((i) => i.ipv4List.isNotEmpty).length;
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.networkInterfaces,
          title: 'Windows 网卡 IP 配置 (ipconfig)',
          command: rawCmd.trim().isEmpty ? 'ipconfig' : rawCmd.trim(),
          summaryBadge: '${list.length} 个适配器 · $activeCnt 已联网',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: NetworkInterfacesPayload(list),
        );
      }
    }

    return null;
  }

  // ==================== 8. 系统服务与防火墙 (systemctl / Get-Service / ufw) ====================

  static BeautifiedOutputCard? _tryParseServicesAndFirewall(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    // 8A. systemctl status <unit>
    if (lines.any((l) => l.trimLeft().startsWith('Loaded:')) &&
        lines.any((l) => l.trimLeft().startsWith('Active:'))) {
      final first = lines.first.replaceFirst(RegExp(r'^[●○×*]\s*'), '').trim();
      final parts = first.split(' - ');
      final unitName = parts.first.trim();
      final desc = parts.length > 1 ? parts.sublist(1).join(' - ').trim() : '';
      var activeState = 'unknown';
      var subState = '';
      final details = <String, String>{};
      final logs = <String>[];

      for (final line in lines.skip(1)) {
        final t = line.trim();
        final kv = RegExp(
          r'^(Loaded|Active|Main PID|Tasks|Memory|CPU|CGroup|Docs):\s*(.+)$',
        ).firstMatch(t);
        if (kv != null) {
          final k = kv.group(1)!;
          final v = kv.group(2)!.trim();
          details[k] = v;
          if (k == 'Active') {
            final am = RegExp(r'^(\S+)\s*\(([^)]+)\)').firstMatch(v);
            activeState = am?.group(1) ?? v.split(' ').first;
            subState = am?.group(2) ?? '';
          }
        } else if (RegExp(r'^[A-Z][a-z]{2}\s+\d+\s+\d{2}:\d{2}:\d{2}').hasMatch(t) ||
            RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(t)) {
          logs.add(t);
        }
      }

      final health = activeState == 'active'
          ? SemanticHealth.healthy
          : activeState == 'failed'
          ? SemanticHealth.danger
          : SemanticHealth.neutral;

      return BeautifiedOutputCard(
        id: id,
        category: BeautyCategoryId.servicesFirewall,
        title: 'systemd 服务详情 ($unitName)',
        command: rawCmd.trim().isEmpty
            ? 'systemctl status $unitName'
            : rawCmd.trim(),
        summaryBadge: subState.isNotEmpty
            ? '$activeState ($subState)'
            : activeState,
        rawOutput: cleanOutput,
        capturedAt: ts,
        payload: ServiceStatusPayload(
          services: [
            ServiceUnitItem(
              name: unitName,
              state: activeState,
              subState: subState,
              description: desc,
              health: health,
            ),
          ],
          singleUnitDetails: details,
          recentLogs: logs,
        ),
      );
    }

    // 8B. systemctl list-units
    final sysIdx = lines.indexWhere(
      (l) =>
          l.contains('UNIT') &&
          l.contains('LOAD') &&
          l.contains('ACTIVE') &&
          l.contains('SUB'),
    );
    if (sysIdx >= 0) {
      final units = <ServiceUnitItem>[];
      for (final row in lines.skip(sysIdx + 1)) {
        final cleaned = row.replaceFirst(RegExp(r'^\s*[●○×*]\s*'), '').trim();
        if (cleaned.isEmpty ||
            cleaned.startsWith('LOAD ') ||
            cleaned.contains('loaded units listed')) {
          break;
        }
        final cols = cleaned.split(RegExp(r'\s+'));
        if (cols.length < 4) continue;
        final active = cols[2];
        final sub = cols[3];
        units.add(
          ServiceUnitItem(
            name: cols[0],
            state: active,
            subState: sub,
            description: cols.length > 4 ? cols.sublist(4).join(' ') : '',
            health: active == 'active'
                ? SemanticHealth.healthy
                : active == 'failed'
                ? SemanticHealth.danger
                : SemanticHealth.neutral,
          ),
        );
      }
      if (units.isNotEmpty) {
        final runningCnt = units
            .where((u) => u.health == SemanticHealth.healthy)
            .length;
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.servicesFirewall,
          title: 'systemd 系统服务列表',
          command: rawCmd.trim().isEmpty ? 'systemctl list-units' : rawCmd.trim(),
          summaryBadge: '${units.length} 个服务 · $runningCnt 运行中',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: ServiceStatusPayload(services: units),
        );
      }
    }

    // 8C. Windows PowerShell Get-Service (Status   Name   DisplayName)
    final gsvIdx = lines.indexWhere(
      (l) =>
          l.trimLeft().startsWith('Status') &&
          l.contains('Name') &&
          l.contains('DisplayName'),
    );
    if (gsvIdx >= 0) {
      final spans = _computeColumnSpans(lines[gsvIdx], const [
        'Status',
        'Name',
        'DisplayName',
      ]);
      final units = <ServiceUnitItem>[];
      for (final row in lines.skip(gsvIdx + 1)) {
        if (row.trim().startsWith('----')) continue;
        final m = _sliceByColumnSpans(row, spans);
        final status = m['Status'] ?? '';
        final name = m['Name'] ?? '';
        if (status.isEmpty || name.isEmpty) continue;
        units.add(
          ServiceUnitItem(
            name: name,
            state: status,
            description: m['DisplayName'] ?? '',
            health: status.toLowerCase() == 'running'
                ? SemanticHealth.healthy
                : SemanticHealth.neutral,
          ),
        );
      }
      if (units.isNotEmpty) {
        final runningCnt = units
            .where((u) => u.health == SemanticHealth.healthy)
            .length;
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.servicesFirewall,
          title: 'Windows 系统服务状态 (Get-Service)',
          command: rawCmd.trim().isEmpty ? 'Get-Service' : rawCmd.trim(),
          summaryBadge: '${units.length} 项 · $runningCnt 运行中',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: ServiceStatusPayload(services: units),
        );
      }
    }

    // 8D. UFW 防火墙状态
    if (lines.first.startsWith('Status: ') &&
        lines.any((l) => l.contains('Action') && l.contains('From'))) {
      final actIdx = lines.indexWhere(
        (l) => l.contains('Action') && l.contains('From'),
      );
      final rows = <List<String>>[];
      for (final r in lines.skip(actIdx + 1)) {
        if (r.trim().startsWith('--')) continue;
        final c = r.trim().split(RegExp(r'\s{2,}'));
        if (c.length >= 2) rows.add(c);
      }
      if (rows.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.servicesFirewall,
          title: 'UFW 防火墙规则 (${lines.first.trim()})',
          command: rawCmd.trim().isEmpty ? 'ufw status' : rawCmd.trim(),
          summaryBadge: '${rows.length} 条放行/拦截规则',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: GenericTablePayload(
            columns: const ['目标端口 (To)', '策略 (Action)', '来源 (From)'],
            rows: rows,
          ),
        );
      }
    }

    return null;
  }

  // ==================== 9. 进程列表 (ps / Get-Process / tasklist / pm2) ====================

  static BeautifiedOutputCard? _tryParseProcesses(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    // 9A. POSIX ps aux / ps -ef
    final psIdx = lines.indexWhere(
      (l) =>
          (l.contains('USER') &&
              l.contains('PID') &&
              l.contains('%CPU') &&
              l.contains('%MEM')) ||
          (l.contains('UID') &&
              l.contains('PID') &&
              l.contains('PPID') &&
              (l.contains('CMD') || l.contains('COMMAND'))),
    );
    if (psIdx >= 0) {
      final header = lines[psIdx];
      final isAux = header.contains('%CPU');
      final procs = <ProcessRowItem>[];
      for (final row in lines.skip(psIdx + 1)) {
        final cols = row.trim().split(RegExp(r'\s+'));
        if (isAux && cols.length >= 11 && int.tryParse(cols[1]) != null) {
          final rssKb = double.tryParse(cols[5]) ?? 0;
          procs.add(
            ProcessRowItem(
              user: cols[0],
              pid: cols[1],
              cpuPercent: double.tryParse(cols[2]) ?? 0,
              memPercent: double.tryParse(cols[3]) ?? 0,
              memoryText: rssKb >= 1024
                  ? '${(rssKb / 1024).toStringAsFixed(1)} MB'
                  : '${rssKb.toInt()} KB',
              state: cols[7],
              timeText: cols[9],
              command: cols.sublist(10).join(' '),
            ),
          );
        } else if (!isAux && cols.length >= 8 && int.tryParse(cols[1]) != null) {
          procs.add(
            ProcessRowItem(
              user: cols[0],
              pid: cols[1],
              cpuPercent: double.tryParse(cols[3]) ?? 0,
              memPercent: 0,
              timeText: cols[6],
              command: cols.sublist(7).join(' '),
            ),
          );
        }
      }
      if (procs.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.processes,
          title: '系统进程快照 (ps)',
          command: rawCmd.trim().isEmpty ? 'ps aux' : rawCmd.trim(),
          summaryBadge: '${procs.length} 个进程',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: ProcessListPayload(sourceKind: 'ps', processes: procs),
        );
      }
    }

    // 9B. Windows PowerShell Get-Process / gps / ps
    final gpsIdx = lines.indexWhere(
      (l) =>
          l.contains('NPM(') &&
          l.contains('WS(') &&
          l.contains('Id') &&
          l.contains('ProcessName'),
    );
    if (gpsIdx >= 0) {
      final isWsMb = lines[gpsIdx].contains('WS(M)');
      final hasHandles = lines[gpsIdx].trimLeft().startsWith('Handles');
      final rowPattern = hasHandles
          ? RegExp(
              r'^\s*\d+\s+[\d,]+\s+[\d,.]+\s+([\d,.]+)\s+(?:([\d,.]+)\s+)?(\d+)\s+(\d+)\s+(.+?)\s*$',
            )
          : RegExp(
              r'^\s*[\d,]+\s+[\d,.]+\s+([\d,.]+)\s+(?:([\d,.]+)\s+)?(\d+)\s+(\d+)\s+(.+?)\s*$',
            );
      final procs = <ProcessRowItem>[];
      for (final row in lines.skip(gpsIdx + 1)) {
        final t = row.trim();
        if (t.isEmpty || t.startsWith('--')) continue;
        final m = rowPattern.firstMatch(row);
        if (m != null) {
          final wsVal = double.tryParse(m.group(1)!.replaceAll(',', '')) ?? 0.0;
          final mb = isWsMb ? wsVal : wsVal / 1024.0;
          final cpuRaw = m.group(2);
          final cpuSec = cpuRaw != null
              ? (double.tryParse(cpuRaw.replaceAll(',', '')) ?? 0.0)
              : 0.0;
          final pidStr = m.group(3)!;
          final si = m.group(4)!;
          final procName = m.group(5)!.trim();
          procs.add(
            ProcessRowItem(
              pid: pidStr,
              user: 'SI:$si',
              cpuPercent: cpuSec,
              memPercent: (mb / 163.84).clamp(0.0, 100.0),
              memoryText: '${mb.toStringAsFixed(1)} MB',
              timeText: cpuSec > 0 ? '${cpuSec.toStringAsFixed(1)}s' : '-',
              command: procName,
            ),
          );
        }
      }
      if (procs.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.processes,
          title: 'Windows 进程列表 (Get-Process)',
          command: rawCmd.trim().isEmpty ? 'Get-Process' : rawCmd.trim(),
          summaryBadge: '${procs.length} 个进程',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: ProcessListPayload(
            sourceKind: 'Get-Process',
            processes: procs,
          ),
        );
      }
    }

    // 9C. Windows tasklist (中英文分隔线 ==== ====)
    final eqIdx = lines.indexWhere(
      (l) => RegExp(r'^={4,}\s+={3,}\s+={4,}').hasMatch(l.trim()),
    );
    if (eqIdx >= 1) {
      final procs = <ProcessRowItem>[];
      for (final row in lines.skip(eqIdx + 1)) {
        final m = RegExp(
          r'^(.+?)\s+(\d+)\s+(\S+)\s+\d+\s+([\d,.\s]+K)\s*$',
          caseSensitive: false,
        ).firstMatch(row.trim());
        if (m != null) {
          final memStr = m.group(4)!.trim();
          final kb =
              double.tryParse(memStr.replaceAll(RegExp(r'[^\d.]'), '')) ?? 0;
          procs.add(
            ProcessRowItem(
              pid: m.group(2)!,
              user: m.group(3)!,
              cpuPercent: 0,
              memPercent: (kb / 1024 / 163.84).clamp(0.0, 100.0),
              memoryText: '${(kb / 1024).toStringAsFixed(1)} MB',
              command: m.group(1)!.trim(),
            ),
          );
        }
      }
      if (procs.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.processes,
          title: 'Windows 任务列表 (tasklist)',
          command: rawCmd.trim().isEmpty ? 'tasklist' : rawCmd.trim(),
          summaryBadge: '${procs.length} 个进程',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: ProcessListPayload(sourceKind: 'tasklist', processes: procs),
        );
      }
    }

    // 9D. PM2 表格 (│ id │ name │ ... │ status │ cpu │ mem │)
    if (lines.any((l) => l.contains('│') && l.contains('status') && l.contains('cpu'))) {
      final dataRows = lines
          .where(
            (l) =>
                l.contains('│') &&
                !l.contains('─') &&
                !l.contains('status'),
          )
          .toList();
      final procs = <ProcessRowItem>[];
      for (final r in dataRows) {
        final cells = r
            .split('│')
            .map((c) => c.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        if (cells.length >= 8) {
          procs.add(
            ProcessRowItem(
              pid: cells.length > 5 ? cells[5] : cells[0],
              user: cells.last,
              state: cells.firstWhere(
                (c) => c == 'online' || c == 'stopped' || c == 'errored',
                orElse: () => '',
              ),
              cpuPercent: double.tryParse(
                    cells
                        .firstWhere((c) => c.endsWith('%'), orElse: () => '0%')
                        .replaceAll('%', ''),
                  ) ??
                  0,
              memPercent: 0,
              memoryText: cells.firstWhere(
                (c) => c.endsWith('b') || c.endsWith('B'),
                orElse: () => '',
              ),
              command: cells[1],
            ),
          );
        }
      }
      if (procs.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.processes,
          title: 'PM2 守护进程矩阵',
          command: rawCmd.trim().isEmpty ? 'pm2 list' : rawCmd.trim(),
          summaryBadge: '${procs.length} 个实例',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: ProcessListPayload(sourceKind: 'pm2', processes: procs),
        );
      }
    }

    return null;
  }

  // ==================== 10. Git 工作区状态与提交历史 ====================

  static BeautifiedOutputCard? _tryParseGit(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    // 10A. 标准 git status (英文 / 中文)
    final first = lines.first.trim();
    if (first.startsWith('On branch ') ||
        first.startsWith('HEAD detached ') ||
        first.startsWith('位于分支 ')) {
      final branch = first
          .replaceFirst('On branch ', '')
          .replaceFirst('位于分支 ', '')
          .trim();
      var syncSummary = '';
      var isClean = false;
      var section = 'unstaged';
      final changes = <GitFileChangeItem>[];

      for (final rawLine in lines.skip(1)) {
        final t = rawLine.trim();
        if (t.startsWith('Your branch is ') || t.startsWith('您的分支')) {
          syncSummary = t;
        } else if (t.contains('nothing to commit, working tree clean') ||
            t.contains('无文件要提交，干净的工作区')) {
          isClean = true;
        } else if (t.startsWith('Changes to be committed') ||
            t.startsWith('要提交的变更')) {
          section = 'staged';
        } else if (t.startsWith('Changes not staged for commit') ||
            t.startsWith('尚未暂存以备提交的变更')) {
          section = 'modified';
        } else if (t.startsWith('Untracked files') || t.startsWith('未跟踪的文件')) {
          section = 'untracked';
        } else if (t.startsWith('(') || t.startsWith('（')) {
          continue;
        } else if (rawLine.startsWith('\t') || rawLine.startsWith('  ')) {
          final kv = RegExp(
            r'^(modified|new file|deleted|renamed|修改|新文件|删除|重命名)\s*[:：]\s*(.+)$',
          ).firstMatch(t);
          if (kv != null) {
            final verb = kv.group(1)!;
            final file = kv.group(2)!.trim();
            final staged = section == 'staged';
            changes.add(
              GitFileChangeItem(
                path: file,
                changeKind: section,
                badgeLabel: staged ? '已暂存 · $verb' : verb,
                health: staged
                    ? SemanticHealth.healthy
                    : verb.contains('del') || verb.contains('删除')
                    ? SemanticHealth.danger
                    : SemanticHealth.warning,
              ),
            );
          } else if (section == 'untracked' && t.isNotEmpty) {
            changes.add(
              GitFileChangeItem(
                path: t,
                changeKind: 'untracked',
                badgeLabel: '未跟踪',
                health: SemanticHealth.neutral,
              ),
            );
          }
        }
      }

      return BeautifiedOutputCard(
        id: id,
        category: BeautyCategoryId.gitVcs,
        title: 'Git 工作区状态 ($branch)',
        command: rawCmd.trim().isEmpty ? 'git status' : rawCmd.trim(),
        summaryBadge: isClean && changes.isEmpty
            ? '工作区干净'
            : '${changes.length} 个变更文件',
        rawOutput: cleanOutput,
        capturedAt: ts,
        payload: GitStatusPayload(
          branch: branch,
          syncSummary: syncSummary,
          isClean: isClean && changes.isEmpty,
          changes: changes,
        ),
      );
    }

    // 10B. git status -s / --short
    if (RegExp(r'^git\s+status\b').hasMatch(normCmd) && lines.isNotEmpty) {
      final changes = <GitFileChangeItem>[];
      var branch = 'HEAD';
      for (final line in lines) {
        if (line.startsWith('## ')) {
          branch = line.substring(3).trim();
          continue;
        }
        if (line.length >= 4 &&
            RegExp(r'^[ MADRCU?!]{2}\s+').hasMatch(line)) {
          final code = line.substring(0, 2).trim();
          final path = line.substring(3).trim();
          changes.add(
            GitFileChangeItem(
              path: path,
              changeKind: code,
              badgeLabel: code,
              health: code == '??'
                  ? SemanticHealth.neutral
                  : code.contains('D')
                  ? SemanticHealth.danger
                  : line[0] != ' '
                  ? SemanticHealth.healthy
                  : SemanticHealth.warning,
            ),
          );
        }
      }
      if (changes.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.gitVcs,
          title: 'Git 简短状态 ($branch)',
          command: rawCmd.trim(),
          summaryBadge: '${changes.length} 个变更',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: GitStatusPayload(
            branch: branch,
            syncSummary: '',
            isClean: false,
            changes: changes,
          ),
        );
      }
    }

    // 10C. git log (多行完整格式 commit <40hex>)
    if (lines.any((l) => RegExp(r'^commit\s+[0-9a-f]{7,40}').hasMatch(l))) {
      final commits = <GitCommitItem>[];
      String? hash;
      var refs = '';
      var author = '';
      var date = '';
      final msgBuf = <String>[];

      void flush() {
        if (hash != null) {
          commits.add(
            GitCommitItem(
              hash: hash.substring(0, min(7, hash.length)),
              refs: refs,
              author: author,
              date: date,
              message: msgBuf.join(' ').trim(),
            ),
          );
        }
      }

      for (final line in lines) {
        final cm = RegExp(
          r'^commit\s+([0-9a-f]{7,40})(?:\s*\(([^)]+)\))?',
        ).firstMatch(line.trim());
        if (cm != null) {
          flush();
          hash = cm.group(1)!;
          refs = cm.group(2) ?? '';
          author = '';
          date = '';
          msgBuf.clear();
          continue;
        }
        if (line.startsWith('Author:')) {
          author = line.substring(7).trim();
        } else if (line.startsWith('Date:')) {
          date = line.substring(5).trim();
        } else if (line.startsWith('    ')) {
          msgBuf.add(line.trim());
        }
      }
      flush();
      if (commits.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.gitVcs,
          title: 'Git 提交时间线',
          command: rawCmd.trim().isEmpty ? 'git log' : rawCmd.trim(),
          summaryBadge: '${commits.length} 次提交',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: GitLogPayload(commits),
        );
      }
    }

    // 10D. git log --oneline
    if ((RegExp(r'^git\s+log\b').hasMatch(normCmd) || lines.length >= 2) &&
        lines.every(
          (l) => RegExp(
            r'^(?:[*|\\/\s]+)?[0-9a-f]{7,12}\s+(?:\([^)]+\)\s+)?\S+',
          ).hasMatch(l.trim()),
        )) {
      final commits = <GitCommitItem>[];
      for (final line in lines) {
        final m = RegExp(
          r'^(?:[*|\\/\s]+)?([0-9a-f]{7,12})\s+(?:\(([^)]+)\)\s+)?(.+)$',
        ).firstMatch(line.trim());
        if (m != null) {
          commits.add(
            GitCommitItem(
              hash: m.group(1)!,
              refs: m.group(2) ?? '',
              message: m.group(3)!.trim(),
            ),
          );
        }
      }
      if (commits.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.gitVcs,
          title: 'Git 提交记录 (--oneline)',
          command: rawCmd.trim().isEmpty ? 'git log --oneline' : rawCmd.trim(),
          summaryBadge: '${commits.length} 条记录',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: GitLogPayload(commits),
        );
      }
    }

    return null;
  }

  // ==================== 11. 目录文件列表 (ls -la / ll / Get-ChildItem) ====================

  static BeautifiedOutputCard? _tryParseDirectoryListing(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    // 11A. POSIX ls -l / ll
    final permLineRe = RegExp(
      r'^([dlcbps-][rwxstST-]{9}[+@.]?)\s+\d+\s+(\S+)\s+(\S+)\s+(\d+(?:[.,]\d+)?[KMGTPB]?)\s+(.+)$',
    );
    final lsEntries = <FileEntryCardItem>[];
    var nonMatchCount = 0;
    for (final line in lines) {
      final t = line.trim();
      if (t.startsWith('total ') || t.startsWith('总用量 ')) continue;
      final m = permLineRe.firstMatch(t);
      if (m == null) {
        nonMatchCount++;
        continue;
      }
      final perm = m.group(1)!;
      final owner = '${m.group(2)}:${m.group(3)}';
      final sizeRaw = m.group(4)!;
      final rest = m.group(5)!;

      // 提取日期时间（例如 "Nov 15 14:20 file" 或 "2026-11-15 14:20 file"）与文件名
      String modDate = '';
      String fileName = rest;
      final dateM = RegExp(
        r'^((?:[A-Z][a-z]{2}\s+\d+\s+[\d:]{4,5})|(?:\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2})|(?:\d+月\s+\d+\s+[\d:]{4,5}))\s+(.+)$',
      ).firstMatch(rest);
      if (dateM != null) {
        modDate = dateM.group(1)!;
        fileName = dateM.group(2)!;
      }

      var linkTarget = '';
      if (perm.startsWith('l') && fileName.contains(' -> ')) {
        final sp = fileName.split(' -> ');
        fileName = sp.first;
        linkTarget = sp.sublist(1).join(' -> ');
      }
      if (fileName == '.' || fileName == '..') continue;

      final sizeNum = int.tryParse(sizeRaw);
      final prettySize = sizeNum != null ? _formatByteInt(sizeNum) : sizeRaw;

      lsEntries.add(
        FileEntryCardItem(
          name: fileName,
          isDirectory: perm.startsWith('d'),
          isSymlink: perm.startsWith('l'),
          isExecutable: !perm.startsWith('d') && perm.contains('x'),
          permissions: perm.substring(0, 10),
          octalPerm: _symbolicToOctal(perm),
          owner: owner,
          sizeText: prettySize,
          modifiedText: modDate,
          linkTarget: linkTarget,
        ),
      );
    }

    if (lsEntries.isNotEmpty && nonMatchCount <= 1) {
      final dirCnt = lsEntries.where((e) => e.isDirectory).length;
      final fileCnt = lsEntries.length - dirCnt;
      return BeautifiedOutputCard(
        id: id,
        category: BeautyCategoryId.fileListing,
        title: '目录文件列表',
        command: rawCmd.trim().isEmpty ? 'ls -la' : rawCmd.trim(),
        summaryBadge: '$dirCnt 个目录 · $fileCnt 个文件',
        rawOutput: cleanOutput,
        capturedAt: ts,
        payload: DirectoryListingPayload(entries: lsEntries),
      );
    }

    // 11B. Windows PowerShell Get-ChildItem / ls / dir
    final pwshHeaderIdx = lines.indexWhere(
      (l) =>
          l.contains('Mode') &&
          l.contains('LastWriteTime') &&
          l.contains('Length') &&
          l.contains('Name'),
    );
    if (pwshHeaderIdx >= 0) {
      String? dirHeader;
      for (final pre in lines.take(pwshHeaderIdx)) {
        if (pre.trim().startsWith('Directory:') ||
            pre.trim().startsWith('目录:')) {
          dirHeader = pre.trim().split(RegExp(r'[:：]\s*')).sublist(1).join(':');
        }
      }
      final entries = <FileEntryCardItem>[];
      for (final row in lines.skip(pwshHeaderIdx + 1)) {
        final t = row.trim();
        if (t.isEmpty || t.startsWith('----')) continue;
        final m = RegExp(
          r'^([darhsl-]{5,6})\s+(\d{1,4}[/-]\d{1,2}[/-]\d{1,4}(?:\s+(?:周.|星期.|上午|下午))?\s+\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APap][Mm])?)\s+(?:([\d,]+)\s+)?(.+)$',
        ).firstMatch(t);
        if (m != null) {
          final mode = m.group(1)!;
          final isDir = mode.startsWith('d');
          final lenStr = m.group(3)?.replaceAll(',', '');
          final name = m.group(4)!.trim();
          entries.add(
            FileEntryCardItem(
              name: name,
              isDirectory: isDir,
              isExecutable: name.endsWith('.exe') ||
                  name.endsWith('.bat') ||
                  name.endsWith('.ps1') ||
                  name.endsWith('.cmd'),
              permissions: mode,
              sizeText: isDir
                  ? '目录'
                  : (lenStr != null
                        ? _formatByteInt(int.tryParse(lenStr) ?? 0)
                        : '-'),
              modifiedText: m.group(2)!,
            ),
          );
        }
      }
      if (entries.isNotEmpty) {
        final dirCnt = entries.where((e) => e.isDirectory).length;
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.fileListing,
          title: dirHeader != null ? '目录列表 ($dirHeader)' : 'PowerShell 目录文件列表',
          command: rawCmd.trim().isEmpty ? 'Get-ChildItem' : rawCmd.trim(),
          summaryBadge: '$dirCnt 个文件夹 · ${entries.length - dirCnt} 个文件',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: DirectoryListingPayload(
            directoryHeader: dirHeader,
            entries: entries,
          ),
        );
      }
    }

    return null;
  }

  static String _symbolicToOctal(String perm) {
    if (perm.length < 10) return '';
    int triad(String s) {
      var v = 0;
      if (s[0] == 'r') v += 4;
      if (s[1] == 'w') v += 2;
      if (s[2] == 'x' || s[2] == 's' || s[2] == 't') v += 1;
      return v;
    }

    final u = triad(perm.substring(1, 4));
    final g = triad(perm.substring(4, 7));
    final o = triad(perm.substring(7, 10));
    return '0$u$g$o';
  }

  static String _formatByteInt(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1048576) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1073741824) return '${(bytes / 1048576).toStringAsFixed(1)} MB';
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }

  // ==================== 12. 系统架构信息、WSL、who 与通用表格 ====================

  static BeautifiedOutputCard? _tryParseSystemEnvAndTables(
    String id,
    String rawCmd,
    String normCmd,
    String cleanOutput,
    List<String> lines,
    DateTime ts,
  ) {
    // 12A. uname -a
    if (lines.length == 1 &&
        RegExp(r'^(Linux|Darwin|FreeBSD)\s+\S+\s+\d+\.\d+').hasMatch(lines.first)) {
      final parts = lines.first.trim().split(RegExp(r'\s+'));
      final archMatch = RegExp(
        r'\b(x86_64|aarch64|arm64|armv7l|riscv64|i686|amd64)\b',
      ).firstMatch(lines.first);
      return BeautifiedOutputCard(
        id: id,
        category: BeautyCategoryId.systemEnv,
        title: '操作系统内核架构 (uname)',
        command: rawCmd.trim().isEmpty ? 'uname -a' : rawCmd.trim(),
        summaryBadge: '${parts[0]} · ${archMatch?.group(1) ?? parts.last}',
        rawOutput: cleanOutput,
        capturedAt: ts,
        payload: SystemInfoPayload([
          KeyValueFact(key: '内核系统', value: parts[0]),
          if (parts.length > 1) KeyValueFact(key: '主机节点名', value: parts[1]),
          if (parts.length > 2) KeyValueFact(key: '内核版本', value: parts[2]),
          if (archMatch != null)
            KeyValueFact(
              key: 'CPU 架构',
              value: archMatch.group(1)!,
              highlight: SemanticHealth.info,
            ),
          KeyValueFact(key: '完整标识', value: lines.first.trim()),
        ]),
      );
    }

    // 12B. hostnamectl / lscpu 键值对
    if (lines.length >= 4 &&
        (lines.any((l) => l.contains('Static hostname:') || l.contains('Operating System:')) ||
            lines.any((l) => l.startsWith('Architecture:') && lines.any((x) => x.contains('CPU(s):'))))) {
      final facts = <KeyValueFact>[];
      for (final line in lines) {
        final idx = line.indexOf(':');
        if (idx <= 0) continue;
        final k = line.substring(0, idx).trim();
        final v = line.substring(idx + 1).trim();
        if (k.isNotEmpty && v.isNotEmpty) {
          facts.add(KeyValueFact(key: k, value: v));
        }
      }
      if (facts.length >= 4) {
        final isCpu = facts.any((f) => f.key == 'CPU(s)');
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.systemEnv,
          title: isCpu ? 'CPU 硬件拓扑详情 (lscpu)' : '主机系统元数据 (hostnamectl)',
          command: rawCmd.trim().isEmpty
              ? (isCpu ? 'lscpu' : 'hostnamectl')
              : rawCmd.trim(),
          summaryBadge: '${facts.length} 项指标',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: SystemInfoPayload(facts),
        );
      }
    }

    // 12C. Windows WSL 实例列表 (`wsl -l -v`，兼容 UTF-16LE 宽字符空格输出)
    final normalizedWslLines = lines.any(
          (l) => RegExp(
            r'N\s?A\s?M\s?E\s{2,}S\s?T\s?A\s?T\s?E\s{2,}V\s?E\s?R\s?S\s?I\s?O\s?N',
            caseSensitive: false,
          ).hasMatch(l),
        )
        ? lines
              .map(
                (l) => l
                    .trim()
                    .split(RegExp(r'\s{3,}'))
                    .map((seg) => seg.replaceAll(' ', ''))
                    .where((seg) => seg.isNotEmpty)
                    .join('   '),
              )
              .where((l) => l.isNotEmpty)
              .toList()
        : lines;

    final wslIdx = normalizedWslLines.indexWhere(
      (l) =>
          l.toUpperCase().contains('NAME') &&
          l.toUpperCase().contains('STATE') &&
          l.toUpperCase().contains('VERSION'),
    );
    if (wslIdx >= 0) {
      final rows = <List<String>>[];
      for (final r in normalizedWslLines.skip(wslIdx + 1)) {
        final isDefault = r.trimLeft().startsWith('*');
        final cleaned = r.replaceFirst(RegExp(r'^\s*\*\s*'), '').trim();
        final cols = cleaned.split(RegExp(r'\s{2,}|\s+'));
        if (cols.length >= 3) {
          rows.add([
            isDefault ? '★ ${cols[0]} (默认)' : cols[0],
            cols[1],
            'WSL ${cols[2]}',
          ]);
        }
      }
      if (rows.isNotEmpty) {
        return BeautifiedOutputCard(
          id: id,
          category: BeautyCategoryId.systemEnv,
          title: 'WSL Linux 子系统实例',
          command: rawCmd.trim().isEmpty ? 'wsl -l -v' : rawCmd.trim(),
          summaryBadge: '${rows.length} 个发行版',
          rawOutput: cleanOutput,
          capturedAt: ts,
          payload: GenericTablePayload(
            columns: const ['发行版 (NAME)', '运行状态 (STATE)', '内核版本'],
            rows: rows,
          ),
        );
      }
    }

    // 12D. 通用对齐 CLI 表格兜底（例如 pip list, helm list, docker volume ls, docker network ls, lsblk）
    if (lines.length >= 3) {
      // 情形 1: 第 2 行是 `----  ----` 分隔线（如 pip list / winget / PowerShell Format-Table）
      if (RegExp(r'^-{3,}(?:\s+-{3,})+$').hasMatch(lines[1].trim())) {
        final headers = lines[0].trim().split(RegExp(r'\s{2,}|\s+'));
        if (headers.length >= 2 && headers.length <= 8) {
          final rows = <List<String>>[];
          for (final r in lines.skip(2)) {
            final cells = r.trim().split(RegExp(r'\s{2,}|\s+'));
            if (cells.length >= 2) {
              if (cells.length > headers.length) {
                rows.add([
                  ...cells.take(headers.length - 1),
                  cells.skip(headers.length - 1).join(' '),
                ]);
              } else {
                rows.add(cells);
              }
            }
          }
          if (rows.isNotEmpty) {
            return BeautifiedOutputCard(
              id: id,
              category: BeautyCategoryId.systemEnv,
              title: rawCmd.trim().isNotEmpty
                  ? '命令结构化表格 (${rawCmd.trim()})'
                  : '结构化数据表格',
              command: rawCmd.trim(),
              summaryBadge: '${rows.length} 行记录',
              rawOutput: cleanOutput,
              capturedAt: ts,
              payload: GenericTablePayload(columns: headers, rows: rows),
            );
          }
        }
      }

      // 情形 2: 首行全大写双空格多列表头（如 lsblk / docker network ls / helm list）
      final firstTrim = lines.first.trim();
      final headerCols = firstTrim.split(RegExp(r'\s{2,}'));
      if (headerCols.length >= 3 &&
          headerCols.length <= 9 &&
          RegExp(r'^[A-Z0-9_:/%(). -]+$').hasMatch(firstTrim)) {
        final spans = _computeColumnSpans(lines.first, headerCols);
        final rows = <List<String>>[];
        for (final r in lines.skip(1)) {
          if (spans.length == headerCols.length) {
            final map = _sliceByColumnSpans(r, spans);
            final rowVals = headerCols.map((h) => map[h] ?? '').toList();
            if (rowVals.any((v) => v.isNotEmpty)) {
              rows.add(rowVals);
            }
          }
        }
        if (rows.length >= 2) {
          return BeautifiedOutputCard(
            id: id,
            category: BeautyCategoryId.systemEnv,
            title: rawCmd.trim().isNotEmpty
                ? '结构化输出 (${rawCmd.trim()})'
                : 'CLI 表格视图',
            command: rawCmd.trim(),
            summaryBadge: '${rows.length} 项',
            rawOutput: cleanOutput,
            capturedAt: ts,
            payload: GenericTablePayload(columns: headerCols, rows: rows),
          );
        }
      }
    }

    return null;
  }
}
