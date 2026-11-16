import 'package:flutter/material.dart';

/// 终端命令输出美化 12 大核心场景分类
enum BeautyCategoryId {
  containers(
    id: 'containers',
    title: 'Docker 与容器引擎',
    shortLabel: '容器',
    icon: Icons.view_in_ar_rounded,
  ),
  kubernetes(
    id: 'kubernetes',
    title: 'Kubernetes 集群编排',
    shortLabel: 'K8s',
    icon: Icons.hub_outlined,
  ),
  systemTop(
    id: 'system_top',
    title: '系统实时负载 (top/htop)',
    shortLabel: '负载',
    icon: Icons.monitor_heart_outlined,
  ),
  processes(
    id: 'processes',
    title: '进程与任务排行',
    shortLabel: '进程',
    icon: Icons.account_tree_outlined,
  ),
  diskStorage(
    id: 'disk_storage',
    title: '磁盘挂载与目录体积',
    shortLabel: '存储',
    icon: Icons.storage_rounded,
  ),
  memoryGpu(
    id: 'memory_gpu',
    title: '物理内存与 GPU 算力',
    shortLabel: '内存/GPU',
    icon: Icons.memory_rounded,
  ),
  networkPorts(
    id: 'network_ports',
    title: '端口监听与网络连接',
    shortLabel: '端口',
    icon: Icons.settings_ethernet_rounded,
  ),
  networkInterfaces(
    id: 'network_interfaces',
    title: '网卡地址与 Ping 诊断',
    shortLabel: '网络',
    icon: Icons.lan_outlined,
  ),
  servicesFirewall(
    id: 'services_firewall',
    title: '系统服务与防火墙规则',
    shortLabel: '服务',
    icon: Icons.miscellaneous_services_rounded,
  ),
  fileListing(
    id: 'file_listing',
    title: '目录文件与权限视图',
    shortLabel: '文件',
    icon: Icons.folder_open_rounded,
  ),
  gitVcs(
    id: 'git_vcs',
    title: 'Git 状态与提交历史',
    shortLabel: 'Git',
    icon: Icons.commit_rounded,
  ),
  systemEnv(
    id: 'system_env',
    title: '系统架构、WSL 与通用表格',
    shortLabel: '系统/表格',
    icon: Icons.dns_outlined,
  );

  final String id;
  final String title;
  final String shortLabel;
  final IconData icon;

  const BeautyCategoryId({
    required this.id,
    required this.title,
    required this.shortLabel,
    required this.icon,
  });
}

/// 终端贴片显示模式：美化卡片 vs 终端原文
enum CardDisplayMode {
  /// 展示结构化可视化卡片贴片
  beautified,

  /// 展示底层真实终端原文（右上角保留轻量切换胶囊，一键切回美化卡片）
  raw,
}

/// 语义状态级别（驱动圆点、胶囊颜色与告警条）
enum SemanticHealth {
  healthy,
  warning,
  danger,
  neutral,
  info,
}

/// 单次命令输出美化后的完整卡片实体
class BeautifiedOutputCard {
  final String id;
  final BeautyCategoryId category;
  final String title;
  final String command;
  final String summaryBadge;
  final String rawOutput;
  final DateTime capturedAt;
  final bool isLiveInteractive;
  final BeautyPayload payload;

  const BeautifiedOutputCard({
    required this.id,
    required this.category,
    required this.title,
    required this.command,
    required this.summaryBadge,
    required this.rawOutput,
    required this.capturedAt,
    required this.payload,
    this.isLiveInteractive = false,
  });

  BeautifiedOutputCard copyWith({
    String? id,
    String? title,
    String? command,
    String? summaryBadge,
    String? rawOutput,
    DateTime? capturedAt,
    bool? isLiveInteractive,
    BeautyPayload? payload,
  }) {
    return BeautifiedOutputCard(
      id: id ?? this.id,
      category: category,
      title: title ?? this.title,
      command: command ?? this.command,
      summaryBadge: summaryBadge ?? this.summaryBadge,
      rawOutput: rawOutput ?? this.rawOutput,
      capturedAt: capturedAt ?? this.capturedAt,
      isLiveInteractive: isLiveInteractive ?? this.isLiveInteractive,
      payload: payload ?? this.payload,
    );
  }
}

sealed class BeautyPayload {
  const BeautyPayload();
}

// ==================== 1. 容器与镜像卡片数据 ====================

class ContainerItem {
  final String id;
  final String name;
  final String image;
  final String status;
  final String ports;
  final String command;
  final SemanticHealth health;

  const ContainerItem({
    required this.id,
    required this.name,
    required this.image,
    required this.status,
    required this.ports,
    this.command = '',
    required this.health,
  });
}

class DockerContainersPayload extends BeautyPayload {
  final List<ContainerItem> containers;
  const DockerContainersPayload(this.containers);
}

class ContainerStatItem {
  final String id;
  final String name;
  final double cpuPercent;
  final String memUsage;
  final double memPercent;
  final String netIo;
  final String blockIo;
  final String pids;

  const ContainerStatItem({
    required this.id,
    required this.name,
    required this.cpuPercent,
    required this.memUsage,
    required this.memPercent,
    required this.netIo,
    required this.blockIo,
    required this.pids,
  });
}

class DockerStatsPayload extends BeautyPayload {
  final List<ContainerStatItem> stats;
  const DockerStatsPayload(this.stats);
}

class DockerImageItem {
  final String repository;
  final String tag;
  final String imageId;
  final String created;
  final String size;

  const DockerImageItem({
    required this.repository,
    required this.tag,
    required this.imageId,
    required this.created,
    required this.size,
  });
}

class DockerImagesPayload extends BeautyPayload {
  final List<DockerImageItem> images;
  const DockerImagesPayload(this.images);
}

// ==================== 2. Kubernetes 资源卡片数据 ====================

class K8sResourceItem {
  final String namespace;
  final String name;
  final String ready;
  final String status;
  final String restarts;
  final String age;
  final String extra;
  final SemanticHealth health;

  const K8sResourceItem({
    required this.namespace,
    required this.name,
    required this.ready,
    required this.status,
    required this.restarts,
    required this.age,
    this.extra = '',
    required this.health,
  });
}

class K8sResourcesPayload extends BeautyPayload {
  final String resourceKind;
  final List<K8sResourceItem> items;
  const K8sResourcesPayload({required this.resourceKind, required this.items});
}

// ==================== 3. top / htop 实时负载与进程排行 ====================

class ProcessRowItem {
  final String pid;
  final String user;
  final double cpuPercent;
  final double memPercent;
  final String memoryText;
  final String state;
  final String timeText;
  final String command;

  const ProcessRowItem({
    required this.pid,
    required this.user,
    required this.cpuPercent,
    required this.memPercent,
    this.memoryText = '',
    this.state = '',
    this.timeText = '',
    required this.command,
  });
}

class SystemTopPayload extends BeautyPayload {
  final String uptimeText;
  final int usersCount;
  final List<double> loadAverages; // [1m, 5m, 15m]
  final int tasksTotal;
  final int tasksRunning;
  final int tasksSleeping;
  final int tasksZombie;
  final double cpuUser;
  final double cpuSys;
  final double cpuIdle;
  final double cpuWait;
  final double memTotalMb;
  final double memUsedMb;
  final double memCacheMb;
  final double swapTotalMb;
  final double swapUsedMb;
  final List<ProcessRowItem> processes;

  const SystemTopPayload({
    required this.uptimeText,
    required this.usersCount,
    required this.loadAverages,
    required this.tasksTotal,
    required this.tasksRunning,
    required this.tasksSleeping,
    required this.tasksZombie,
    required this.cpuUser,
    required this.cpuSys,
    required this.cpuIdle,
    required this.cpuWait,
    required this.memTotalMb,
    required this.memUsedMb,
    required this.memCacheMb,
    required this.swapTotalMb,
    required this.swapUsedMb,
    required this.processes,
  });

  double get cpuBusyPercent => (100.0 - cpuIdle).clamp(0.0, 100.0);
  double get memRatio =>
      memTotalMb <= 0 ? 0.0 : (memUsedMb / memTotalMb).clamp(0.0, 1.0);
}

class ProcessListPayload extends BeautyPayload {
  final String sourceKind; // ps / Get-Process / tasklist / pm2
  final List<ProcessRowItem> processes;
  const ProcessListPayload({
    required this.sourceKind,
    required this.processes,
  });
}

// ==================== 4. 磁盘挂载、目录体积与块设备 ====================

class DiskMountItem {
  final String filesystem;
  final String fsType;
  final String sizeText;
  final String usedText;
  final String availText;
  final double useRatio; // 0.0 - 1.0
  final String mountPoint;

  const DiskMountItem({
    required this.filesystem,
    this.fsType = '',
    required this.sizeText,
    required this.usedText,
    required this.availText,
    required this.useRatio,
    required this.mountPoint,
  });
}

class DiskUsagePayload extends BeautyPayload {
  final List<DiskMountItem> mounts;
  const DiskUsagePayload(this.mounts);
}

class DirSizeItem {
  final String path;
  final String sizeText;
  final double bytesEstimate;
  final double ratioOfMax;

  const DirSizeItem({
    required this.path,
    required this.sizeText,
    required this.bytesEstimate,
    required this.ratioOfMax,
  });
}

class DirSizeRankPayload extends BeautyPayload {
  final List<DirSizeItem> items;
  const DirSizeRankPayload(this.items);
}

// ==================== 5. 物理内存与 GPU 算力 ====================

class MemoryUsagePayload extends BeautyPayload {
  final String ramTotal;
  final String ramUsed;
  final String ramFree;
  final String ramBuffCache;
  final String ramAvailable;
  final double ramUsedRatio;
  final double ramCacheRatio;
  final String? swapTotal;
  final String? swapUsed;
  final String? swapFree;
  final double swapUsedRatio;

  const MemoryUsagePayload({
    required this.ramTotal,
    required this.ramUsed,
    required this.ramFree,
    required this.ramBuffCache,
    required this.ramAvailable,
    required this.ramUsedRatio,
    required this.ramCacheRatio,
    this.swapTotal,
    this.swapUsed,
    this.swapFree,
    this.swapUsedRatio = 0.0,
  });
}

class GpuCardItem {
  final int index;
  final String name;
  final int tempC;
  final String powerUsage;
  final int memUsedMiB;
  final int memTotalMiB;
  final int utilPercent;

  const GpuCardItem({
    required this.index,
    required this.name,
    required this.tempC,
    required this.powerUsage,
    required this.memUsedMiB,
    required this.memTotalMiB,
    required this.utilPercent,
  });

  double get memRatio =>
      memTotalMiB <= 0 ? 0.0 : (memUsedMiB / memTotalMiB).clamp(0.0, 1.0);
}

class GpuProcessItem {
  final int gpuIndex;
  final String pid;
  final String processName;
  final String usedMemory;

  const GpuProcessItem({
    required this.gpuIndex,
    required this.pid,
    required this.processName,
    required this.usedMemory,
  });
}

class GpuStatusPayload extends BeautyPayload {
  final String driverVersion;
  final String cudaVersion;
  final List<GpuCardItem> gpus;
  final List<GpuProcessItem> processes;

  const GpuStatusPayload({
    required this.driverVersion,
    required this.cudaVersion,
    required this.gpus,
    this.processes = const [],
  });
}

// ==================== 6. 网络端口监听、网卡接口与 Ping ====================

class SocketPortItem {
  final String proto;
  final String state;
  final String localAddress;
  final String localPort;
  final String peerAddress;
  final String process;
  final SemanticHealth health;

  const SocketPortItem({
    required this.proto,
    required this.state,
    required this.localAddress,
    required this.localPort,
    required this.peerAddress,
    required this.process,
    required this.health,
  });
}

class NetworkSocketsPayload extends BeautyPayload {
  final List<SocketPortItem> sockets;
  const NetworkSocketsPayload(this.sockets);
}

class NetInterfaceItem {
  final String name;
  final bool isUp;
  final List<String> ipv4List;
  final List<String> ipv6List;
  final String macAddress;
  final String gatewayOrMask;

  const NetInterfaceItem({
    required this.name,
    required this.isUp,
    required this.ipv4List,
    this.ipv6List = const [],
    this.macAddress = '',
    this.gatewayOrMask = '',
  });
}

class NetworkInterfacesPayload extends BeautyPayload {
  final List<NetInterfaceItem> interfaces;
  const NetworkInterfacesPayload(this.interfaces);
}

class PingReplySample {
  final int seq;
  final double timeMs;
  final String ttl;

  const PingReplySample({
    required this.seq,
    required this.timeMs,
    this.ttl = '',
  });
}

class PingStatsPayload extends BeautyPayload {
  final String target;
  final List<PingReplySample> replies;
  final int transmitted;
  final int received;
  final double lossPercent;
  final double? minMs;
  final double? avgMs;
  final double? maxMs;

  const PingStatsPayload({
    required this.target,
    required this.replies,
    required this.transmitted,
    required this.received,
    required this.lossPercent,
    this.minMs,
    this.avgMs,
    this.maxMs,
  });
}

// ==================== 7. 系统服务与防火墙 ====================

class ServiceUnitItem {
  final String name;
  final String state;
  final String subState;
  final String description;
  final SemanticHealth health;

  const ServiceUnitItem({
    required this.name,
    required this.state,
    this.subState = '',
    required this.description,
    required this.health,
  });
}

class ServiceStatusPayload extends BeautyPayload {
  final List<ServiceUnitItem> services;
  final Map<String, String> singleUnitDetails;
  final List<String> recentLogs;

  const ServiceStatusPayload({
    required this.services,
    this.singleUnitDetails = const {},
    this.recentLogs = const [],
  });
}

// ==================== 8. 目录文件列表 ====================

class FileEntryCardItem {
  final String name;
  final bool isDirectory;
  final bool isSymlink;
  final bool isExecutable;
  final String permissions;
  final String octalPerm;
  final String owner;
  final String sizeText;
  final String modifiedText;
  final String linkTarget;

  const FileEntryCardItem({
    required this.name,
    required this.isDirectory,
    this.isSymlink = false,
    this.isExecutable = false,
    this.permissions = '',
    this.octalPerm = '',
    this.owner = '',
    required this.sizeText,
    this.modifiedText = '',
    this.linkTarget = '',
  });
}

class DirectoryListingPayload extends BeautyPayload {
  final String? directoryHeader;
  final List<FileEntryCardItem> entries;

  const DirectoryListingPayload({
    this.directoryHeader,
    required this.entries,
  });
}

// ==================== 9. Git 工作区与提交历史 ====================

class GitFileChangeItem {
  final String path;
  final String changeKind; // staged / modified / untracked / deleted / renamed
  final String badgeLabel;
  final SemanticHealth health;

  const GitFileChangeItem({
    required this.path,
    required this.changeKind,
    required this.badgeLabel,
    required this.health,
  });
}

class GitStatusPayload extends BeautyPayload {
  final String branch;
  final String syncSummary;
  final bool isClean;
  final List<GitFileChangeItem> changes;

  const GitStatusPayload({
    required this.branch,
    required this.syncSummary,
    required this.isClean,
    required this.changes,
  });
}

class GitCommitItem {
  final String hash;
  final String refs;
  final String message;
  final String author;
  final String date;

  const GitCommitItem({
    required this.hash,
    this.refs = '',
    required this.message,
    this.author = '',
    this.date = '',
  });
}

class GitLogPayload extends BeautyPayload {
  final List<GitCommitItem> commits;
  const GitLogPayload(this.commits);
}

// ==================== 10. 系统信息键值对与通用对齐表格 ====================

class KeyValueFact {
  final String key;
  final String value;
  final SemanticHealth? highlight;

  const KeyValueFact({
    required this.key,
    required this.value,
    this.highlight,
  });
}

class SystemInfoPayload extends BeautyPayload {
  final List<KeyValueFact> facts;
  const SystemInfoPayload(this.facts);
}

class GenericTablePayload extends BeautyPayload {
  final List<String> columns;
  final List<List<String>> rows;

  const GenericTablePayload({
    required this.columns,
    required this.rows,
  });
}
