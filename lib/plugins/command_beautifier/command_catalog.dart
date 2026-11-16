import 'command_output_models.dart';

/// 单个命令分类的完整元数据、覆盖命令清单与一键预览样例
class BeautyCommandSpec {
  final BeautyCategoryId category;
  final String subtitle;
  final List<String> coveredCommands;
  final String posixQuickCommand;
  final String windowsQuickCommand;
  final String sampleCommand;
  final String sampleRawOutput;

  const BeautyCommandSpec({
    required this.category,
    required this.subtitle,
    required this.coveredCommands,
    required this.posixQuickCommand,
    required this.windowsQuickCommand,
    required this.sampleCommand,
    required this.sampleRawOutput,
  });
}

/// 日常运维与开发命令美化全量清单（12 大类 · 48+ 常见命令变体）
class BeautyCommandCatalog {
  BeautyCommandCatalog._();

  static const List<BeautyCommandSpec> specs = [
    BeautyCommandSpec(
      category: BeautyCategoryId.containers,
      subtitle: '容器运行状态徽章、端口转发胶囊、CPU/内存实时进度条与镜像体积表',
      coveredCommands: [
        'docker ps',
        'docker ps -a',
        'docker container ls',
        'docker stats',
        'docker images',
        'docker compose ps',
        'podman ps',
      ],
      posixQuickCommand: 'docker ps -a',
      windowsQuickCommand: 'docker ps -a',
      sampleCommand: 'docker ps -a',
      sampleRawOutput:
          'CONTAINER ID   IMAGE                  COMMAND                  CREATED        STATUS                    PORTS                                       NAMES\n'
          'a81f940b2c19   nginx:1.27-alpine      "/docker-entrypoint.…"   2 weeks ago    Up 14 days (healthy)      0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp    api-gateway\n'
          '79c20e1b55d1   redis:7.2-alpine       "docker-entrypoint.s…"   2 weeks ago    Up 14 days                127.0.0.1:6379->6379/tcp                    redis-cache\n'
          '3e19a8410f02   postgres:16-bookworm   "docker-entrypoint.s…"   9 days ago     Up 9 days                 0.0.0.0:5432->5432/tcp                      pg-primary\n'
          'f42c0198ad77   migrate/migrate:v4     "migrate -path=/sql…"    3 hours ago    Exited (0) 3 hours ago                                                db-migration',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.kubernetes,
      subtitle: 'Pod / Service / Node 就绪比例、CrashLoop 告警高亮与重启次数提示',
      coveredCommands: [
        'kubectl get pods',
        'kubectl get po -A',
        'kubectl get svc',
        'kubectl get nodes',
        'kubectl get deploy',
        'k get pods',
      ],
      posixQuickCommand: 'kubectl get pods -A',
      windowsQuickCommand: 'kubectl get pods -A',
      sampleCommand: 'kubectl get pods -A',
      sampleRawOutput:
          'NAMESPACE     NAME                                  READY   STATUS             RESTARTS      AGE\n'
          'prod          api-gateway-7c8d94f6b-9xk2p           1/1     Running            0             14d\n'
          'prod          worker-billing-5f9b8c7d4-m4v8q        2/2     Running            1 (2d ago)    9d\n'
          'prod          payment-webhook-6d4f8a9c-k2l9z        0/1     CrashLoopBackOff   6 (42s ago)   35m\n'
          'monitoring    prometheus-k8s-0                      2/2     Running            0             31d',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.systemTop,
      subtitle: '解析 top / htop / uptime 负载均值、CPU 分项占用条、内存仪表与高负载进程榜',
      coveredCommands: [
        'top',
        'htop',
        'btop',
        'top -bn1',
        'uptime',
      ],
      posixQuickCommand: 'top -bn1 | head -n 20',
      windowsQuickCommand: 'Get-Process | Sort-Object CPU -Descending | Select-Object -First 12',
      sampleCommand: 'top',
      sampleRawOutput:
          'top - 16:10:24 up 42 days,  6:46,  2 users,  load average: 0.64, 0.48, 0.35\n'
          'Tasks: 186 total,   2 running, 184 sleeping,   0 stopped,   0 zombie\n'
          '%Cpu(s): 24.6 us,  5.8 sy,  0.0 ni, 68.4 id,  0.8 wa,  0.0 hi,  0.4 si,  0.0 st\n'
          'MiB Mem :  16384.0 total,   3920.4 free,   7240.6 used,   5223.0 buff/cache\n'
          'MiB Swap:   4096.0 total,   3840.0 free,    256.0 used.   8612.5 avail Mem\n'
          '\n'
          '  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND\n'
          ' 2190 postgres  20   0 1420800 512400  98200 R  18.5   3.1  84:12.40 postgres\n'
          ' 1042 www-data  20   0  284120  98400  24100 S   9.2   0.6  41:08.15 nginx\n'
          ' 4910 ubuntu    20   0 2841000 842000  64200 S   6.4   5.1  12:30.44 node\n'
          ' 1884 redis     20   0  198400 142800  12400 S   3.1   0.9  19:54.02 redis-server',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.processes,
      subtitle: '支持 Linux ps aux / pm2 list 与 Windows PowerShell Get-Process / tasklist 搜索过滤',
      coveredCommands: [
        'ps aux',
        'ps -ef',
        'pm2 list',
        'Get-Process (ps/gps)',
        'tasklist',
      ],
      posixQuickCommand: 'ps aux --sort=-%cpu | head -n 20',
      windowsQuickCommand: 'Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 15',
      sampleCommand: 'ps aux --sort=-%cpu',
      sampleRawOutput:
          'USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND\n'
          'postgres    2190 14.2  3.1 1420800 512400 ?      Ss   Nov01  84:12 postgres: walwriter\n'
          'ubuntu      4910  8.6  5.1 2841000 842000 ?      Sl   10:15  12:30 /usr/bin/node dist/main.js\n'
          'www-data    1042  4.8  0.6 284120  98400 ?       S    Nov01  41:08 nginx: worker process\n'
          'redis       1884  2.4  0.9 198400 142800 ?       Ssl  Nov01  19:54 /usr/bin/redis-server *:6379',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.diskStorage,
      subtitle: '挂载分区容量告警进度条 (df -h / Get-PSDrive) 与目录体积横向排行 (du -sh)',
      coveredCommands: [
        'df -h',
        'df -Th',
        'df -i',
        'du -sh *',
        'lsblk',
        'Get-PSDrive (gdr)',
      ],
      posixQuickCommand: 'df -h',
      windowsQuickCommand: 'Get-PSDrive -PSProvider FileSystem',
      sampleCommand: 'df -h',
      sampleRawOutput:
          'Filesystem      Size  Used Avail Use% Mounted on\n'
          '/dev/nvme0n1p2  120G   46G   68G  41% /\n'
          '/dev/nvme1n1p1  500G  438G   62G  88% /data/storage\n'
          '/dev/sda1       2.0T  1.86T 140G  93% /mnt/archive\n'
          'tmpfs           7.8G  2.4M  7.8G   1% /run',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.memoryGpu,
      subtitle: '物理内存分段色带 (free -h / vm_stat) 与 NVIDIA GPU 显存/功耗/算力监控卡 (nvidia-smi)',
      coveredCommands: [
        'free -h',
        'free -m',
        'vm_stat',
        'nvidia-smi',
      ],
      posixQuickCommand: 'free -h',
      windowsQuickCommand: 'nvidia-smi',
      sampleCommand: 'nvidia-smi',
      sampleRawOutput:
          '+-----------------------------------------------------------------------------------------+\n'
          '| NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |\n'
          '|-----------------------------------------+------------------------+----------------------+\n'
          '| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |\n'
          '| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |\n'
          '|=========================================+========================+======================|\n'
          '|   0  NVIDIA A100-SXM4-80GB          On  |   00000000:00:04.0 Off |                    0 |\n'
          '| N/A   52C    P0             245W / 400W |   61440MiB / 81920MiB |     86%      Default |\n'
          '+-----------------------------------------+------------------------+----------------------+\n'
          '|   1  NVIDIA A100-SXM4-80GB          On  |   00000000:00:05.0 Off |                    0 |\n'
          '| N/A   39C    P0              92W / 400W |   18420MiB / 81920MiB |     22%      Default |\n'
          '+-----------------------------------------+------------------------+----------------------+',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.networkPorts,
      subtitle: 'TCP/UDP 协议标签、LISTEN/ESTABLISHED 状态徽章、监听端口号高亮与进程映射',
      coveredCommands: [
        'ss -tulnp',
        'ss -antp',
        'netstat -tulnp',
        'netstat -ano',
        'lsof -i -P -n',
      ],
      posixQuickCommand: 'ss -tulnp',
      windowsQuickCommand: 'netstat -ano',
      sampleCommand: 'ss -tulnp',
      sampleRawOutput:
          'Netid  State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process\n'
          'tcp    LISTEN  0       4096     0.0.0.0:443           0.0.0.0:*          users:(("nginx",pid=1042,fd=6))\n'
          'tcp    LISTEN  0       128      0.0.0.0:22            0.0.0.0:*          users:(("sshd",pid=812,fd=3))\n'
          'tcp    LISTEN  0       511      127.0.0.1:6379        0.0.0.0:*          users:(("redis-server",pid=1884,fd=7))\n'
          'udp    UNCONN  0       0        0.0.0.0:53            0.0.0.0:*          users:(("coredns",pid=960,fd=8))',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.networkInterfaces,
      subtitle: '网卡 IPv4/IPv6/MAC 一键复制卡片 (ip a / ifconfig / ipconfig) 与 Ping 延迟柱状统计',
      coveredCommands: [
        'ip addr (ip a)',
        'ifconfig',
        'ipconfig',
        'ping',
      ],
      posixQuickCommand: 'ip addr',
      windowsQuickCommand: 'ipconfig',
      sampleCommand: 'ping -c 4 1.1.1.1',
      sampleRawOutput:
          'PING 1.1.1.1 (1.1.1.1) 56(84) bytes of data.\n'
          '64 bytes from 1.1.1.1: icmp_seq=1 ttl=57 time=10.8 ms\n'
          '64 bytes from 1.1.1.1: icmp_seq=2 ttl=57 time=14.2 ms\n'
          '64 bytes from 1.1.1.1: icmp_seq=3 ttl=57 time=11.5 ms\n'
          '64 bytes from 1.1.1.1: icmp_seq=4 ttl=57 time=12.1 ms\n'
          '--- 1.1.1.1 ping statistics ---\n'
          '4 packets transmitted, 4 received, 0% packet loss, time 3004ms\n'
          'rtt min/avg/max/mdev = 10.800/12.150/14.200/1.265 ms',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.servicesFirewall,
      subtitle: 'systemd / Windows 服务运行健康度状态点、PID/内存详情与 UFW 防火墙规则表',
      coveredCommands: [
        'systemctl status <svc>',
        'systemctl list-units --type=service',
        'service --status-all',
        'Get-Service (gsv)',
        'ufw status',
      ],
      posixQuickCommand: 'systemctl list-units --type=service --state=running --no-pager',
      windowsQuickCommand: 'Get-Service | Sort-Object Status -Descending | Select-Object -First 15',
      sampleCommand: 'systemctl list-units --type=service',
      sampleRawOutput:
          'UNIT                        LOAD   ACTIVE SUB     DESCRIPTION\n'
          'nginx.service               loaded active running A high performance web server and a reverse proxy server\n'
          'docker.service              loaded active running Docker Application Container Engine\n'
          'postgresql.service          loaded active running PostgreSQL RDBMS\n'
          'certbot-renew.service       loaded failed failed  Renew Let\'s Encrypt certificates',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.fileListing,
      subtitle: 'Linux ls -la / ll 与 PowerShell Get-ChildItem / dir 文件夹图标、八进制权限徽章与大小对齐',
      coveredCommands: [
        'ls -la',
        'ls -lh',
        'll',
        'Get-ChildItem (dir / ls)',
      ],
      posixQuickCommand: 'ls -lhA',
      windowsQuickCommand: 'Get-ChildItem',
      sampleCommand: 'ls -la',
      sampleRawOutput:
          'total 64\n'
          'drwxr-xr-x  5 root root   4096 Nov 15 15:20 logs\n'
          'drwxr-xr-x  2 root root   4096 Nov 12 09:10 nginx\n'
          '-rwxr-xr-x  1 root root    960 Nov 15 13:40 deploy.sh\n'
          '-rw-r--r--  1 root root   1840 Nov 15 10:15 docker-compose.yml\n'
          '-rw-r--r--  1 root root   3420 Nov 02 08:00 .bashrc',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.gitVcs,
      subtitle: 'Git 当前分支同步状态、暂存/修改/未跟踪文件分组卡片与提交历史时间线',
      coveredCommands: [
        'git status',
        'git status -s',
        'git log --oneline',
        'git log',
        'git branch -vv',
      ],
      posixQuickCommand: 'git status',
      windowsQuickCommand: 'git status',
      sampleCommand: 'git status',
      sampleRawOutput:
          'On branch main\n'
          'Your branch is ahead of \'origin/main\' by 2 commits.\n'
          'Changes to be committed:\n'
          '  new file:   lib/plugins/command_beautifier/command_beautifier_plugin.dart\n'
          '  modified:   lib/ui/termx_workbench.dart\n'
          'Changes not staged for commit:\n'
          '  modified:   README.md\n'
          'Untracked files:\n'
          '  test/command_beautifier_test.dart',
    ),
    BeautyCommandSpec(
      category: BeautyCategoryId.systemEnv,
      subtitle: '主机架构 (uname / hostnamectl / lscpu)、WSL 实例、在线用户 (who/w) 及对齐 CLI 表格自动美化',
      coveredCommands: [
        'uname -a',
        'hostnamectl',
        'lscpu',
        'wsl -l -v',
        'who / w',
        'pip list / helm list / brew list',
      ],
      posixQuickCommand: 'uname -a',
      windowsQuickCommand: 'wsl -l -v',
      sampleCommand: 'hostnamectl',
      sampleRawOutput:
          ' Static hostname: prod-tokyo-node01\n'
          '       Icon name: computer-vm\n'
          '         Chassis: vm\n'
          '  Virtualization: kvm\n'
          'Operating System: Ubuntu 24.04.1 LTS\n'
          '          Kernel: Linux 6.8.0-48-generic\n'
          '    Architecture: x86-64',
    ),
  ];

  static BeautyCommandSpec specFor(BeautyCategoryId id) =>
      specs.firstWhere((s) => s.category == id);
}
