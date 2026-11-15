import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pty2/flutter_pty2.dart';
import 'package:xterm/xterm.dart';

import '../models/host_config.dart';
import '../models/remote_os.dart';

enum SessionConnectionState {
  connecting,
  connected,
  reconnecting,
  disconnected,
  error,
}

/// 远端或沙盒虚拟文件节点（供 SFTP 插件统一消费）
class RemoteFileEntry {
  final String name;
  final String fullPath;
  final bool isDirectory;
  final int sizeBytes;
  final String permissions;
  final DateTime modifiedAt;
  String? textContent;

  RemoteFileEntry({
    required this.name,
    required this.fullPath,
    required this.isDirectory,
    required this.sizeBytes,
    required this.permissions,
    required this.modifiedAt,
    this.textContent,
  });
}

/// 单个 SSH 终端会话控制器（同时驱动 xterm.dart Terminal、后台插件 Exec Channel 与 SFTP 通道）
class SshSessionController extends ChangeNotifier {
  final String sessionId;
  HostConfig _host;
  HostConfig get host => _host;
  final Terminal terminal;

  SessionConnectionState _state = SessionConnectionState.connecting;
  String? _errorMessage;
  SSHClient? _sshClient;
  SSHSession? _shellSession;
  SftpClient? _sftpClient;
  Future<SftpClient>? _sftpFuture;
  String? _sftpHomeDir;
  PtySession? _localPty;
  StreamSubscription<String>? _localOutput;
  bool _disposed = false;
  bool _demoStarted = false;

  // iPadOS Stage Manager / Split View 分屏拖拽缩放防抖计时器
  Timer? _resizeDebounceTimer;

  // Demo 沙盒交互式 Shell 状态
  String _demoCwd = '/root';
  final StringBuffer _demoLineBuffer = StringBuffer();
  final List<String> _demoHistory = [];
  final Map<String, List<RemoteFileEntry>> _virtualFs = {};

  SessionConnectionState get state => _state;
  String? get errorMessage => _errorMessage;
  bool get isDisposed => _disposed;
  bool get isLocalSession => _host.authMethod == AuthMethod.localShell;
  bool get isDemoMode =>
      _host.authMethod == AuthMethod.demoSandbox || _demoStarted;
  String get _defaultHomeDirectoryGuess {
    if (_detectedOs == RemoteOsType.macos) {
      return _host.username == 'root'
          ? '/var/root'
          : '/Users/${_host.username}';
    }
    return _host.username == 'root' ? '/root' : '/home/${_host.username}';
  }

  String get currentDirectory =>
      isDemoMode ? _demoCwd : (_sftpHomeDir ?? _defaultHomeDirectoryGuess);
  RemoteOsType _detectedOs;
  String? _detectedOsPrettyName;
  RemoteOsType get detectedOs => _detectedOs;
  String? get detectedOsPrettyName => _detectedOsPrettyName;

  SshSessionController({required this.sessionId, required HostConfig host})
    : _host = host,
      _detectedOs = host.authMethod == AuthMethod.localShell
          ? RemoteOsType.windows
          : host.authMethod == AuthMethod.demoSandbox
          ? RemoteOsType.ubuntu
          : (host.detectedOs ?? RemoteOsType.unknown),
      _detectedOsPrettyName = host.authMethod == AuthMethod.localShell
          ? 'Windows PowerShell'
          : host.authMethod == AuthMethod.demoSandbox
          ? 'Ubuntu 24.04.1 LTS'
          : host.detectedOsPrettyName,
      terminal = Terminal(maxLines: 10000) {
    _initVirtualFilesystem();
  }

  void updateHostMetadata(HostConfig updated) {
    if (_disposed) return;
    _host = updated;
    if (updated.detectedOs != null &&
        updated.detectedOs != RemoteOsType.unknown) {
      _detectedOs = updated.detectedOs!;
      _detectedOsPrettyName = updated.detectedOsPrettyName;
    }
    notifyListeners();
  }

  void applyDetectedOs(RemoteOsType os, [String? prettyName]) {
    if (_disposed || os == RemoteOsType.unknown) return;
    if (_detectedOs == os && _detectedOsPrettyName == prettyName) return;
    _detectedOs = os;
    if (prettyName != null && prettyName.isNotEmpty) {
      _detectedOsPrettyName = prettyName;
    }
    notifyListeners();
  }

  void _initVirtualFilesystem() {
    final now = DateTime.now();
    _virtualFs['/root'] = [
      RemoteFileEntry(
        name: '.bashrc',
        fullPath: '/root/.bashrc',
        isDirectory: false,
        sizeBytes: 3420,
        permissions: '-rw-r--r--',
        modifiedAt: now.subtract(const Duration(days: 12)),
        textContent:
            '# ~/.bashrc: executed by bash(1) for non-login shells.\nexport PS1="\\[\\033[01;32m\\]\\u@\\h\\[\\033[00m\\]:\\[\\033[01;34m\\]\\w\\[\\033[00m\\]\\\$ "\nalias ll="ls -alF"\nalias k="kubectl"\n',
      ),
      RemoteFileEntry(
        name: 'docker-compose.yml',
        fullPath: '/root/docker-compose.yml',
        isDirectory: false,
        sizeBytes: 1840,
        permissions: '-rw-r--r--',
        modifiedAt: now.subtract(const Duration(hours: 5)),
        textContent:
            'version: "3.9"\nservices:\n  api-gateway:\n    image: nginx:alpine\n    ports:\n      - "443:443"\n    restart: always\n  redis-cache:\n    image: redis:7-alpine\n    ports:\n      - "6379:6379"\n',
      ),
      RemoteFileEntry(
        name: 'deploy.sh',
        fullPath: '/root/deploy.sh',
        isDirectory: false,
        sizeBytes: 960,
        permissions: '-rwxr-xr-x',
        modifiedAt: now.subtract(const Duration(hours: 2)),
        textContent:
            '#!/usr/bin/env bash\nset -euo pipefail\necho "[TermX] Deploying production cluster..."\ndocker compose pull && docker compose up -d\necho "[TermX] Done!"\n',
      ),
      RemoteFileEntry(
        name: 'logs',
        fullPath: '/root/logs',
        isDirectory: true,
        sizeBytes: 4096,
        permissions: 'drwxr-xr-x',
        modifiedAt: now.subtract(const Duration(minutes: 25)),
      ),
      RemoteFileEntry(
        name: 'nginx',
        fullPath: '/root/nginx',
        isDirectory: true,
        sizeBytes: 4096,
        permissions: 'drwxr-xr-x',
        modifiedAt: now.subtract(const Duration(days: 3)),
      ),
    ];
    _virtualFs['/root/logs'] = [
      RemoteFileEntry(
        name: 'access.log',
        fullPath: '/root/logs/access.log',
        isDirectory: false,
        sizeBytes: 148290,
        permissions: '-rw-r-----',
        modifiedAt: now.subtract(const Duration(minutes: 2)),
        textContent:
            '192.168.1.10 - - [14/Nov/2026:15:30:01 +0800] "GET /api/v1/health HTTP/2.0" 200 48\n10.0.14.88 - - [14/Nov/2026:15:30:04 +0800] "POST /api/v1/session HTTP/2.0" 201 512\n',
      ),
      RemoteFileEntry(
        name: 'error.log',
        fullPath: '/root/logs/error.log',
        isDirectory: false,
        sizeBytes: 4120,
        permissions: '-rw-r-----',
        modifiedAt: now.subtract(const Duration(minutes: 18)),
        textContent:
            '2026/11/14 15:12:09 [warn] 1042#1042: *891 upstream server temporarilybuffered\n',
      ),
    ];
    _virtualFs['/root/nginx'] = [
      RemoteFileEntry(
        name: 'nginx.conf',
        fullPath: '/root/nginx/nginx.conf',
        isDirectory: false,
        sizeBytes: 2490,
        permissions: '-rw-r--r--',
        modifiedAt: now.subtract(const Duration(days: 3)),
        textContent:
            'user nginx;\nworker_processes auto;\nevents {\n    worker_connections 4096;\n}\nhttp {\n    include /etc/nginx/mime.types;\n    sendfile on;\n    keepalive_timeout 65;\n}\n',
      ),
    ];
  }

  /// 建立连接（支持真实 SSH2 协议与内置高仿真沙盒节点）
  Future<void> connect(HostSecretCredential? credential) async {
    if (_disposed) return;
    _state = SessionConnectionState.connecting;
    _errorMessage = null;
    notifyListeners();

    if (isLocalSession) {
      await _startLocalSession();
      return;
    }

    if (host.authMethod == AuthMethod.demoSandbox) {
      await _startDemoSandboxSession();
      return;
    }

    try {
      terminal.write(
        '\x1b[36m[TermX Core]\x1b[0m 正在从系统钥匙串读取加密凭据 (${host.keychainAccountKey})...\r\n',
      );
      terminal.write(
        '\x1b[36m[TermX Core]\x1b[0m 正在连接 ${host.username}@${host.host}:${host.port} ...\r\n',
      );

      final socket = await SSHSocket.connect(
        host.host,
        host.port,
        timeout: const Duration(seconds: 10),
      );
      if (_disposed) {
        socket.close();
        return;
      }

      List<SSHKeyPair>? identities;
      if (host.authMethod == AuthMethod.privateKey &&
          credential?.privateKeyPem != null &&
          credential!.privateKeyPem!.trim().isNotEmpty) {
        identities = SSHKeyPair.fromPem(
          credential.privateKeyPem!,
          credential.passphrase,
        );
      }

      _sshClient = SSHClient(
        socket,
        username: host.username,
        identities: identities,
        onPasswordRequest: () => credential?.password ?? '',
        keepAliveInterval: const Duration(seconds: 20),
      );

      _shellSession = await _sshClient!.shell(
        pty: SSHPtyConfig(
          width: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
          height: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
        ),
      );
      if (_disposed) {
        _shellSession?.close();
        _sshClient?.close();
        return;
      }

      // 绑定远端 stdout / stderr 到 xterm.dart
      _shellSession!.stdout.listen((Uint8List data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
      });
      _shellSession!.stderr.listen((Uint8List data) {
        terminal.write(utf8.decode(data, allowMalformed: true));
      });
      _shellSession!.done.then((_) {
        if (_disposed) return;
        _state = SessionConnectionState.disconnected;
        _sftpClient = null;
        _sftpFuture = null;
        terminal.write('\r\n\x1b[33m[TermX] 远端 SSH 会话已断开。\x1b[0m\r\n');
        notifyListeners();
      });

      // 绑定终端键盘输入与带防抖的 PTY 尺寸缩放 (适配 iPadOS 分屏与台前调度)
      terminal.onOutput = (String data) {
        _shellSession?.write(utf8.encode(data));
      };
      terminal.onResize = (int w, int h, int pw, int ph) {
        _resizeDebounceTimer?.cancel();
        _resizeDebounceTimer = Timer(const Duration(milliseconds: 80), () {
          _shellSession?.resizeTerminal(w, h, pw, ph);
        });
      };

      _state = SessionConnectionState.connected;
      notifyListeners();
      unawaited(_detectRemoteOs());

      if (host.initCommand != null && host.initCommand!.trim().isNotEmpty) {
        _shellSession!.write(utf8.encode('${host.initCommand}\n'));
      }
    } catch (e) {
      if (_disposed) return;
      _errorMessage = e.toString();
      _state = SessionConnectionState.error;
      terminal.write(
        '\r\n\x1b[31m[SSH 连接失败] $e\x1b[0m\r\n右键标签或终端，选择“重新连接 / 重启终端”重试。\r\n',
      );
      _sftpClient?.close();
      _sftpClient = null;
      _sftpFuture = null;
      _sshClient?.close();
      _sshClient = null;
      notifyListeners();
    }
  }

  Future<void> _detectRemoteOs() async {
    final client = _sshClient;
    if (_disposed || client == null) return;
    try {
      final posixBytes = await client
          .run(RemoteOsDetector.posixProbeCommand)
          .timeout(const Duration(seconds: 6));
      if (_disposed || !identical(_sshClient, client)) return;
      var info = RemoteOsDetector.parseProbeOutput(
        utf8.decode(posixBytes, allowMalformed: true),
      );
      if (info.type == RemoteOsType.unknown) {
        final winBytes = await client
            .run(RemoteOsDetector.windowsProbeCommand)
            .timeout(const Duration(seconds: 4));
        if (_disposed || !identical(_sshClient, client)) return;
        info = RemoteOsDetector.parseProbeOutput(
          utf8.decode(winBytes, allowMalformed: true),
        );
      }
      if (info.type != RemoteOsType.unknown) {
        applyDetectedOs(info.type, info.prettyName);
      }
    } catch (_) {
      // 远端受限 Shell 无法执行探针时静默忽略，不影响交互式终端正常使用
    }
  }

  Future<void> _startLocalSession() async {
    try {
      if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) {
        throw UnsupportedError('本地终端会话仅支持桌面端系统');
      }
      final String executable;
      final List<String> arguments;
      PtyEnvironment environment = const PtyEnvironment.inherit();
      if (Platform.isWindows) {
        final systemRoot =
            Platform.environment['SystemRoot'] ?? r'C:\Windows';
        executable =
            '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
        arguments = const ['-NoLogo'];
      } else {
        executable =
            Platform.environment['SHELL'] ??
            (Platform.isMacOS ? '/bin/zsh' : '/bin/bash');
        arguments = const ['-l'];
        environment = const PtyEnvironment.inherit(
          overrides: {
            'TERM': 'xterm-256color',
            'COLORTERM': 'truecolor',
          },
        );
      }
      final pty = await Pty.spawn(
        PtySpawnOptions(
          executable: executable,
          arguments: arguments,
          environment: environment,
          workingDirectory: Directory.current.path,
          size: PtySize(
            rows: terminal.viewHeight > 0 ? terminal.viewHeight : 24,
            columns: terminal.viewWidth > 0 ? terminal.viewWidth : 80,
          ),
        ),
      );
      if (_disposed) {
        await pty.close();
        return;
      }
      _localPty = pty;
      _localOutput = pty.output
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(terminal.write);
      terminal.onOutput = sendRawInput;
      terminal.onResize = (w, h, pw, ph) {
        if (w > 0 && h > 0) {
          _localPty?.resize(PtySize(rows: h, columns: w));
        }
      };
      _state = SessionConnectionState.connected;
      notifyListeners();
      pty.done.then((exit) async {
        await pty.close();
        if (_disposed) return;
        _localPty = null;
        _state = SessionConnectionState.disconnected;
        final code = exit is PtyExitCode ? exit.code : exit.toString();
        terminal.write('\r\n[TermX] 本地 PowerShell 已退出（退出码 $code）。\r\n');
        notifyListeners();
      });
    } catch (e) {
      if (_disposed) return;
      _errorMessage = e.toString();
      _state = SessionConnectionState.error;
      terminal.write('\r\n[TermX] 无法启动本地 PowerShell：$e\r\n');
      notifyListeners();
    }
  }

  Future<void> _startDemoSandboxSession({bool isFallback = false}) async {
    _demoStarted = true;
    await Future<void>.delayed(const Duration(milliseconds: 280));
    if (_disposed) return;
    _state = SessionConnectionState.connected;
    notifyListeners();

    if (!isFallback) {
      terminal.write(
        '\x1b[38;5;75m╭──────────────────────────────────────────────────────────────╮\x1b[0m\r\n'
        '\x1b[38;5;75m│\x1b[0m  \x1b[1;32mTermX Ultra-Modern Cross-Platform SSH Terminal\x1b[0m              \x1b[38;5;75m│\x1b[0m\r\n'
        '\x1b[38;5;75m│\x1b[0m  Keychain Vault : \x1b[36mVerified (Apple Keychain / DPAPI Ready)\x1b[0m    \x1b[38;5;75m│\x1b[0m\r\n'
        '\x1b[38;5;75m│\x1b[0m  Active Plugins : \x1b[33mServerMonitor, SFTP, Snippets, PortFwd\x1b[0m     \x1b[38;5;75m│\x1b[0m\r\n'
        '\x1b[38;5;75m╰──────────────────────────────────────────────────────────────╯\x1b[0m\r\n',
      );
    }
    terminal.write(
      'Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-48-generic x86_64)\r\n'
      ' * System load:  0.42               Processes:           148\r\n'
      ' * Usage of /:   38.4% of 120.0GB   Users logged in:     1\r\n'
      ' * Memory usage: 42%                IPv4 address for eth0: ${host.host}\r\n'
      '\r\n'
      '\x1b[90m输入 \x1b[36mhelp\x1b[90m 查看内置命令，或使用底部/悬浮快捷键及右侧 SFTP/监控插件面板。\x1b[0m\r\n',
    );
    _writeDemoPrompt();

    terminal.onOutput = _handleDemoTerminalInput;
    terminal.onResize = (int w, int h, int pw, int ph) {
      _resizeDebounceTimer?.cancel();
      _resizeDebounceTimer = Timer(const Duration(milliseconds: 80), () {
        // 触发防抖 SIGWINCH 适配
      });
    };
  }

  void _writeDemoPrompt() {
    final shortCwd = _demoCwd == '/root' ? '~' : _demoCwd;
    terminal.write(
      '\x1b[1;32m${host.username}@${host.name}\x1b[0m:\x1b[1;34m$shortCwd\x1b[0m# ',
    );
  }

  void _handleDemoTerminalInput(String data) {
    for (var i = 0; i < data.length; i++) {
      final code = data.codeUnitAt(i);
      if (code == 13) {
        // Enter
        terminal.write('\r\n');
        final cmd = _demoLineBuffer.toString().trim();
        _demoLineBuffer.clear();
        if (cmd.isNotEmpty) {
          _demoHistory.add(cmd);
          _executeDemoShellCommand(cmd);
        } else {
          _writeDemoPrompt();
        }
      } else if (code == 3) {
        // Ctrl+C
        _demoLineBuffer.clear();
        terminal.write('^C\r\n');
        _writeDemoPrompt();
      } else if (code == 12) {
        // Ctrl+L
        terminal.write('\x1b[2J\x1b[H');
        _writeDemoPrompt();
      } else if (code == 127 || code == 8) {
        // Backspace
        final current = _demoLineBuffer.toString();
        if (current.isNotEmpty) {
          _demoLineBuffer.clear();
          _demoLineBuffer.write(current.substring(0, current.length - 1));
          terminal.write('\b \b');
        }
      } else if (code == 9) {
        // Tab 自动补全示例
        final partial = _demoLineBuffer.toString();
        if (partial == 'doc') {
          _demoLineBuffer.write('ker ps');
          terminal.write('ker ps');
        } else if (partial == ' Sys' || partial == 'sys') {
          _demoLineBuffer.write('temctl status nginx');
          terminal.write('temctl status nginx');
        }
      } else if (code >= 32) {
        _demoLineBuffer.write(data[i]);
        terminal.write(data[i]);
      }
    }
  }

  void _executeDemoShellCommand(String cmd) {
    final parts = cmd.split(RegExp(r'\s+'));
    final binary = parts.first;

    switch (binary) {
      case 'help':
        terminal.write(
          '\x1b[36m可用沙盒交互命令：\x1b[0m\r\n'
          '  \x1b[33mls / ll\x1b[0m             列出当前目录文件（与右侧 SFTP 插件实时同步！）\r\n'
          '  \x1b[33mcd <dir>\x1b[0m            切换工作目录\r\n'
          '  \x1b[33mcat <file>\x1b[0m          查看文件内容\r\n'
          '  \x1b[33mtouch <file>\x1b[0m        创建新文件（可立即在 SFTP 面板看到）\r\n'
          '  \x1b[33mdocker ps\x1b[0m           查看运行中的容器状态\r\n'
          '  \x1b[33mtop / htop\x1b[0m          打印系统实时负载快照\r\n'
          '  \x1b[33mdf -h\x1b[0m               查看磁盘挂载使用率\r\n'
          '  \x1b[33muname -a\x1b[0m            查看内核版本信息\r\n'
          '  \x1b[33mclear\x1b[0m               清屏\r\n',
        );
        break;
      case 'ls':
      case 'll':
        final entries = _virtualFs[_demoCwd] ?? const [];
        for (final item in entries) {
          final color = item.isDirectory ? '\x1b[1;34m' : '\x1b[0m';
          terminal.write(
            '${item.permissions}  1 root root ${item.sizeBytes.toString().padLeft(8)}  $color${item.name}\x1b[0m\r\n',
          );
        }
        break;
      case 'pwd':
        terminal.write('$_demoCwd\r\n');
        break;
      case 'cd':
        final target = parts.length > 1 ? parts[1] : '/root';
        if (target == '~' || target == '/root') {
          _demoCwd = '/root';
        } else if (target == '..') {
          _demoCwd = '/root';
        } else {
          final candidate = target.startsWith('/')
              ? target
              : '$_demoCwd/$target';
          if (_virtualFs.containsKey(candidate)) {
            _demoCwd = candidate;
          } else {
            terminal.write('bash: cd: $target: No such file or directory\r\n');
          }
        }
        notifyListeners();
        break;
      case 'cat':
        if (parts.length < 2) {
          terminal.write('Usage: cat <filename>\r\n');
        } else {
          final fileName = parts[1];
          final entries = _virtualFs[_demoCwd] ?? const [];
          final match = entries.where((e) => e.name == fileName).toList();
          if (match.isEmpty) {
            terminal.write('cat: $fileName: No such file or directory\r\n');
          } else if (match.first.isDirectory) {
            terminal.write('cat: $fileName: Is a directory\r\n');
          } else {
            terminal.write(
              '${(match.first.textContent ?? '').replaceAll('\n', '\r\n')}\r\n',
            );
          }
        }
        break;
      case 'touch':
        if (parts.length >= 2) {
          final fileName = parts[1];
          final list = _virtualFs.putIfAbsent(_demoCwd, () => []);
          if (!list.any((e) => e.name == fileName)) {
            list.add(
              RemoteFileEntry(
                name: fileName,
                fullPath: '$_demoCwd/$fileName',
                isDirectory: false,
                sizeBytes: 128,
                permissions: '-rw-r--r--',
                modifiedAt: DateTime.now(),
                textContent: '# Created via TermX terminal\n',
              ),
            );
            notifyListeners();
          }
        }
        break;
      case 'uname':
        terminal.write(
          'Linux ${host.name} 6.8.0-48-generic #48-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux\r\n',
        );
        break;
      case 'df':
        terminal.write(
          'Filesystem      Size  Used Avail Use% Mounted on\r\n'
          '/dev/vda1       120G   46G   74G  39% /\r\n'
          '/dev/vdb1       500G  435G   65G  87% /data/storage\r\n'
          'tmpfs           7.9G  1.2M  7.9G   1% /run\r\n',
        );
        break;
      case 'docker':
        terminal.write(
          'CONTAINER ID   IMAGE            COMMAND                  STATUS          PORTS                    NAMES\r\n'
          'a81f940b2c19   nginx:alpine     "/docker-entrypoint.…"   Up 14 days      0.0.0.0:443->443/tcp     api-gateway\r\n'
          '79c20e1b55d1   redis:7-alpine   "docker-entrypoint.s…"   Up 14 days      0.0.0.0:6379->6379/tcp   redis-cache\r\n'
          '3e19a8410f02   postgres:16      "docker-entrypoint.s…"   Up 9 days       5432/tcp                 pg-primary\r\n',
        );
        break;
      case 'top':
      case 'htop':
        terminal.write(
          'top - 15:42:10 up 42 days,  6:18,  1 user,  load average: 0.48, 0.39, 0.31\r\n'
          'Tasks: 148 total,   1 running, 147 sleeping,   0 stopped,   0 zombie\r\n'
          '%Cpu(s): 18.4 us,  4.2 sy,  0.0 ni, 76.8 id,  0.4 wa,  0.0 hi,  0.2 si\r\n'
          'MiB Mem :  16384.0 total,   4820.5 free,   6412.2 used,   5151.3 buff/cache\r\n',
        );
        break;
      case 'clear':
        terminal.write('\x1b[2J\x1b[H');
        break;
      default:
        terminal.write('\x1b[32m[Executed]\x1b[0m $cmd\r\n');
    }
    _writeDemoPrompt();
  }

  /// 向当前终端注入按键或命令（供手机虚拟键盘栏、iPad 悬浮键盘球、Snippets 插件调用）
  void sendRawInput(String data) {
    if (_disposed || _state != SessionConnectionState.connected) return;
    if (isLocalSession) {
      final pty = _localPty;
      if (pty != null) {
        unawaited(
          pty.input.writeUtf8(data).catchError((Object error) {
            if (!_disposed && _localPty != null) {
              terminal.write('\r\n[TermX] 本地终端写入失败：$error\r\n');
            }
          }),
        );
      }
      return;
    }
    if (_shellSession != null) {
      _shellSession!.write(utf8.encode(data));
    } else {
      _handleDemoTerminalInput(data);
    }
  }

  /// 在独立 SSH Exec Channel 上静默执行命令（供服务器负载监控插件、Docker 插件等调用，不干扰主终端显示）
  Future<String> execBackgroundCommand(String command) async {
    _requireRemoteSession();
    if (_sshClient != null) {
      final result = await _sshClient!.run(command);
      return utf8.decode(result, allowMalformed: true);
    }
    // Demo 模式返回仿真输出
    return 'DEMO_EXEC_OK';
  }

  // ==================== SFTP 操作接口（真实 SFTP + 沙盒无缝切换） ====================

  Future<SftpClient> _ensureSftpClient() {
    final client = _sshClient;
    if (_disposed || client == null || _state != SessionConnectionState.connected) {
      throw StateError('SSH 会话尚未连接完成');
    }
    if (_sftpClient != null) {
      return Future<SftpClient>.value(_sftpClient!);
    }
    return _sftpFuture ??= client.sftp().then(
      (sftp) {
        if (_disposed || !identical(_sshClient, client)) {
          sftp.close();
          throw StateError('SSH 会话已关闭');
        }
        _sftpClient = sftp;
        return sftp;
      },
      onError: (Object e) {
        _sftpFuture = null;
        throw e;
      },
    );
  }

  /// 解析当前登录账号在远端 SFTP 的真实默认主目录（例如 macOS /Users/patrickdu、Linux /home/dpc 或 /root）
  Future<String> resolveSftpHomeDirectory() async {
    _requireRemoteSession();
    if (isDemoMode) return _demoCwd;
    if (_sftpHomeDir != null && _sftpHomeDir!.isNotEmpty) {
      return _sftpHomeDir!;
    }
    try {
      final sftp = await _ensureSftpClient();
      final resolved = (await sftp.absolute('.')).trim();
      if (resolved.isNotEmpty) {
        _sftpHomeDir = resolved;
        return resolved;
      }
    } catch (_) {}
    if (_sshClient != null) {
      try {
        final shellHome =
            (await execBackgroundCommand(r'printf "%s" "$HOME"')).trim();
        if (shellHome.startsWith('/')) {
          _sftpHomeDir = shellHome;
          return shellHome;
        }
      } catch (_) {}
    }
    final fallback = _defaultHomeDirectoryGuess;
    _sftpHomeDir = fallback;
    return fallback;
  }

  static String _formatSftpPermissions(SftpName item, bool isDir) {
    final longTrimmed = item.longname.trimLeft();
    if (longTrimmed.length >= 10) {
      final permToken = longTrimmed.substring(0, 10);
      if (RegExp(r'^[dlcbps-][rwxstST-]{9}$').hasMatch(permToken)) {
        return permToken;
      }
    }
    final mode = item.attr.mode;
    if (mode != null) {
      final prefix = item.attr.isSymbolicLink
          ? 'l'
          : (isDir ? 'd' : '-');
      final chars = [
        mode.userRead ? 'r' : '-',
        mode.userWrite ? 'w' : '-',
        mode.userExecute ? 'x' : '-',
        mode.groupRead ? 'r' : '-',
        mode.groupWrite ? 'w' : '-',
        mode.groupExecute ? 'x' : '-',
        mode.otherRead ? 'r' : '-',
        mode.otherWrite ? 'w' : '-',
        mode.otherExecute ? 'x' : '-',
      ].join();
      return '$prefix$chars';
    }
    return isDir ? 'drwxr-xr-x' : '-rw-r--r--';
  }

  static int _parseSymbolicPermissionBits(String symbolic) {
    final s = symbolic.trim();
    final perm = s.length >= 10 ? s.substring(s.length - 9) : s.padRight(9, '-');
    var bits = 0;
    if (perm[0] == 'r') bits |= 0x100;
    if (perm[1] == 'w') bits |= 0x080;
    if (perm[2] == 'x' || perm[2] == 's') bits |= 0x040;
    if (perm[3] == 'r') bits |= 0x020;
    if (perm[4] == 'w') bits |= 0x010;
    if (perm[5] == 'x' || perm[5] == 's') bits |= 0x008;
    if (perm[6] == 'r') bits |= 0x004;
    if (perm[7] == 'w') bits |= 0x002;
    if (perm[8] == 'x' || perm[8] == 't') bits |= 0x001;
    return bits;
  }

  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    _requireRemoteSession();
    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      final normalizedPath = path.trim().isEmpty ? '.' : path.trim();
      final items = await sftp.listdir(normalizedPath);
      final entries = <RemoteFileEntry>[];
      for (final item in items) {
        if (item.filename == '.' || item.filename == '..') continue;
        final full = normalizedPath == '/'
            ? '/${item.filename}'
            : normalizedPath.endsWith('/')
            ? '$normalizedPath${item.filename}'
            : '$normalizedPath/${item.filename}';
        var isDir = item.attr.isDirectory;
        var sizeBytes = item.attr.size ?? 0;
        if (!isDir && item.attr.isSymbolicLink) {
          try {
            final targetAttr = await sftp.stat(full);
            isDir = targetAttr.isDirectory;
            sizeBytes = targetAttr.size ?? sizeBytes;
          } catch (_) {}
        }
        entries.add(
          RemoteFileEntry(
            name: item.filename,
            fullPath: full,
            isDirectory: isDir,
            sizeBytes: sizeBytes,
            permissions: _formatSftpPermissions(item, isDir),
            modifiedAt: item.attr.modifyTime != null
                ? DateTime.fromMillisecondsSinceEpoch(
                    item.attr.modifyTime! * 1000,
                  )
                : DateTime.now(),
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      return entries;
    }

    // 虚拟沙盒文件系统（仅限 Demo 沙盒节点）
    final entries = List<RemoteFileEntry>.from(_virtualFs[path] ?? const []);
    entries.sort((a, b) {
      if (a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      return a.name.compareTo(b.name);
    });
    return entries;
  }

  Future<String> readRemoteTextFile(RemoteFileEntry entry) async {
    _requireRemoteSession();
    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      final file = await sftp.open(entry.fullPath);
      try {
        final bytes = await file.readBytes();
        return utf8.decode(bytes, allowMalformed: true);
      } finally {
        await file.close();
      }
    }
    return entry.textContent ?? '# File content of ${entry.name}\n';
  }

  Future<void> downloadRemoteFileToLocal({
    required RemoteFileEntry entry,
    required File destinationFile,
    required void Function(double progress) onProgress,
  }) async {
    _requireRemoteSession();
    await destinationFile.parent.create(recursive: true);
    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      final total = entry.sizeBytes;
      final sink = destinationFile.openWrite();
      try {
        await sftp.download(
          entry.fullPath,
          sink,
          onProgress: (bytesRead) {
            if (total > 0) {
              onProgress((bytesRead / total).clamp(0.0, 1.0));
            } else {
              onProgress(0.5);
            }
          },
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      onProgress(1.0);
      return;
    }

    final content = entry.textContent ?? '# File content of ${entry.name}\n';
    for (var i = 1; i <= 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      onProgress(i / 5);
    }
    await destinationFile.writeAsString(content, flush: true);
  }

  Future<void> writeRemoteTextFile(
    String dirPath,
    String fileName,
    String content,
  ) async {
    _requireRemoteSession();
    final fullPath = dirPath.endsWith('/')
        ? '$dirPath$fileName'
        : '$dirPath/$fileName';
    final bytes = utf8.encode(content);

    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      final file = await sftp.open(
        fullPath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        await file.writeBytes(Uint8List.fromList(bytes));
      } finally {
        await file.close();
      }
      return;
    }

    final list = _virtualFs.putIfAbsent(dirPath, () => []);
    final existingIdx = list.indexWhere((e) => e.name == fileName);
    final updated = RemoteFileEntry(
      name: fileName,
      fullPath: fullPath,
      isDirectory: false,
      sizeBytes: bytes.length,
      permissions: existingIdx >= 0
          ? list[existingIdx].permissions
          : '-rw-r--r--',
      modifiedAt: DateTime.now(),
      textContent: content,
    );
    if (existingIdx >= 0) {
      list[existingIdx] = updated;
    } else {
      list.add(updated);
    }
  }

  /// 流式上传本地文件（支持超大文件拖拽上传，无需一次性读入内存）
  Future<void> uploadLocalFile({
    required File localFile,
    required String remoteDirPath,
    String? remoteFileName,
    required void Function(double progress) onProgress,
  }) async {
    _requireRemoteSession();
    final fileName =
        remoteFileName ?? localFile.path.split(RegExp(r'[/\\]')).last;
    final totalBytes = await localFile.length();
    final fullPath = remoteDirPath.endsWith('/')
        ? '$remoteDirPath$fileName'
        : '$remoteDirPath/$fileName';

    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      final remoteFile = await sftp.open(
        fullPath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        if (totalBytes == 0) {
          await remoteFile.writeBytes(Uint8List(0));
          onProgress(1.0);
        } else {
          final writer = remoteFile.write(
            localFile.openRead().map(
              (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
            ),
            onProgress: (written) {
              onProgress((written / totalBytes).clamp(0.0, 1.0));
            },
          );
          await writer.done;
          onProgress(1.0);
        }
      } finally {
        await remoteFile.close();
      }
      return;
    }

    final previewBytes = totalBytes <= 64 * 1024
        ? await localFile.readAsBytes()
        : Uint8List(0);
    for (var i = 1; i <= 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      onProgress(i / 5);
    }
    final list = _virtualFs.putIfAbsent(remoteDirPath, () => []);
    list.removeWhere((e) => e.name == fileName);
    list.add(
      RemoteFileEntry(
        name: fileName,
        fullPath: fullPath,
        isDirectory: false,
        sizeBytes: totalBytes,
        permissions: '-rw-r--r--',
        modifiedAt: DateTime.now(),
        textContent: utf8.decode(previewBytes, allowMalformed: true),
      ),
    );
  }

  Future<void> uploadBytes({
    required String remoteDirPath,
    required String fileName,
    required Uint8List bytes,
    required void Function(double progress) onProgress,
  }) async {
    _requireRemoteSession();
    final fullPath = remoteDirPath.endsWith('/')
        ? '$remoteDirPath$fileName'
        : '$remoteDirPath/$fileName';

    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      final file = await sftp.open(
        fullPath,
        mode:
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      try {
        const chunkSize = 64 * 1024;
        if (bytes.isEmpty) {
          await file.writeBytes(bytes);
          onProgress(1.0);
        } else {
          for (var offset = 0; offset < bytes.length; offset += chunkSize) {
            final end = min(offset + chunkSize, bytes.length);
            await file.writeBytes(
              Uint8List.sublistView(bytes, offset, end),
              offset: offset,
            );
            onProgress(end / bytes.length);
          }
        }
      } finally {
        await file.close();
      }
      return;
    }

    // 模拟分块流式进度以展示 SFTP 传输队列
    const chunks = 8;
    for (var i = 1; i <= chunks; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 70));
      onProgress(i / chunks);
    }
    final list = _virtualFs.putIfAbsent(remoteDirPath, () => []);
    list.removeWhere((e) => e.name == fileName);
    list.add(
      RemoteFileEntry(
        name: fileName,
        fullPath: fullPath,
        isDirectory: false,
        sizeBytes: max(bytes.length, 512),
        permissions: '-rw-r--r--',
        modifiedAt: DateTime.now(),
        textContent: utf8.decode(bytes, allowMalformed: true),
      ),
    );
  }

  Future<void> createRemoteDirectory(
    String parentPath,
    String folderName,
  ) async {
    _requireRemoteSession();
    final fullPath = parentPath.endsWith('/')
        ? '$parentPath$folderName'
        : '$parentPath/$folderName';
    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      await sftp.mkdir(fullPath);
      return;
    }
    final list = _virtualFs.putIfAbsent(parentPath, () => []);
    list.add(
      RemoteFileEntry(
        name: folderName,
        fullPath: fullPath,
        isDirectory: true,
        sizeBytes: 4096,
        permissions: 'drwxr-xr-x',
        modifiedAt: DateTime.now(),
      ),
    );
    _virtualFs.putIfAbsent(fullPath, () => []);
  }

  Future<void> renameRemoteEntry(
    String parentPath,
    RemoteFileEntry entry,
    String newName,
  ) async {
    _requireRemoteSession();
    final trimmed = newName.trim();
    if (trimmed.isEmpty || trimmed == entry.name) return;
    final newFull = parentPath.endsWith('/')
        ? '$parentPath$trimmed'
        : '$parentPath/$trimmed';
    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      await sftp.rename(entry.fullPath, newFull);
      return;
    }
    final list = _virtualFs[parentPath];
    if (list != null) {
      final idx = list.indexWhere((e) => e.name == entry.name);
      if (idx >= 0) {
        list[idx] = RemoteFileEntry(
          name: trimmed,
          fullPath: newFull,
          isDirectory: entry.isDirectory,
          sizeBytes: entry.sizeBytes,
          permissions: entry.permissions,
          modifiedAt: DateTime.now(),
          textContent: entry.textContent,
        );
      }
    }
  }

  Future<void> deleteRemoteEntry(
    String parentPath,
    RemoteFileEntry entry,
  ) async {
    _requireRemoteSession();
    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      if (entry.isDirectory) {
        await sftp.rmdir(entry.fullPath);
      } else {
        await sftp.remove(entry.fullPath);
      }
      return;
    }
    _virtualFs[parentPath]?.removeWhere((e) => e.name == entry.name);
  }

  Future<void> chmodRemoteEntry(
    String parentPath,
    RemoteFileEntry entry,
    String newSymbolicPermissions,
  ) async {
    _requireRemoteSession();
    if (!isDemoMode) {
      final sftp = await _ensureSftpClient();
      final bits = _parseSymbolicPermissionBits(newSymbolicPermissions);
      await sftp.setStat(
        entry.fullPath,
        SftpFileAttrs(mode: SftpFileMode.value(bits)),
      );
      return;
    }
    final list = _virtualFs[parentPath];
    if (list != null) {
      final idx = list.indexWhere((e) => e.name == entry.name);
      if (idx >= 0) {
        list[idx] = RemoteFileEntry(
          name: entry.name,
          fullPath: entry.fullPath,
          isDirectory: entry.isDirectory,
          sizeBytes: entry.sizeBytes,
          permissions: newSymbolicPermissions,
          modifiedAt: DateTime.now(),
          textContent: entry.textContent,
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    terminal.onOutput = null;
    terminal.onResize = null;
    _localOutput?.cancel();
    unawaited(_localPty?.close());
    _localPty = null;
    _resizeDebounceTimer?.cancel();
    _shellSession?.close();
    _sftpClient?.close();
    _sshClient?.close();
    super.dispose();
  }

  void _requireRemoteSession() {
    if (isLocalSession) {
      throw UnsupportedError('此功能需要 SSH 会话，本地 PowerShell 不提供远程通道');
    }
  }
}
