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

  // 终端输入/输出观察者（供命令美化卡片等插件无侵入监听）
  final List<void Function(String data)> _terminalInputListeners = [];
  final List<void Function(String chunk)> _terminalOutputListeners = [];
  final List<VoidCallback> _terminalClearListeners = [];

  /// 可选的软键盘/终端输入修饰转换器（将底部虚拟 CTRL/ALT 组合键同步作用于系统软键盘输入）
  String Function(String rawData)? inputModifierTransform;

  void _handleTerminalOutput(String data) {
    final transformed = inputModifierTransform != null
        ? inputModifierTransform!(data)
        : data;
    if (transformed.isEmpty) return;
    sendRawInput(transformed);
  }

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

  void addTerminalInputListener(void Function(String data) listener) {
    if (!_disposed && !_terminalInputListeners.contains(listener)) {
      _terminalInputListeners.add(listener);
    }
  }

  void removeTerminalInputListener(void Function(String data) listener) {
    _terminalInputListeners.remove(listener);
  }

  void addTerminalOutputListener(void Function(String chunk) listener) {
    if (!_disposed && !_terminalOutputListeners.contains(listener)) {
      _terminalOutputListeners.add(listener);
    }
  }

  void removeTerminalOutputListener(void Function(String chunk) listener) {
    _terminalOutputListeners.remove(listener);
  }

  void addTerminalClearListener(VoidCallback listener) {
    if (!_disposed && !_terminalClearListeners.contains(listener)) {
      _terminalClearListeners.add(listener);
    }
  }

  void removeTerminalClearListener(VoidCallback listener) {
    _terminalClearListeners.remove(listener);
  }

  void _notifyTerminalInput(String data) {
    if (_disposed || _terminalInputListeners.isEmpty) return;
    for (final listener in List.of(_terminalInputListeners)) {
      listener(data);
    }
  }

  void _notifyTerminalOutput(String chunk) {
    if (_disposed || _terminalOutputListeners.isEmpty) return;
    for (final listener in List.of(_terminalOutputListeners)) {
      listener(chunk);
    }
  }

  void _notifyTerminalCleared() {
    if (_disposed || _terminalClearListeners.isEmpty) return;
    for (final listener in List.of(_terminalClearListeners)) {
      listener();
    }
  }

  /// 向终端画布写入输出并通知已注册的输出监听插件
  void writeTerminalOutput(String data) {
    if (_disposed) return;
    terminal.write(data);
    if (data.contains('\x1b[2J') || data.contains('\x1b[3J')) {
      _notifyTerminalCleared();
    }
    _notifyTerminalOutput(data);
  }

  /// 清空当前终端屏幕与回滚缓冲区并通知插件收起旧浮层
  void clearTerminalScreen() {
    if (_disposed) return;
    terminal.write('\x1b[3J\x1b[2J\x1b[H');
    _notifyTerminalCleared();
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
        writeTerminalOutput(utf8.decode(data, allowMalformed: true));
      });
      _shellSession!.stderr.listen((Uint8List data) {
        writeTerminalOutput(utf8.decode(data, allowMalformed: true));
      });
      _shellSession!.done.then((_) {
        if (_disposed) return;
        _state = SessionConnectionState.disconnected;
        _sftpClient = null;
        _sftpFuture = null;
        writeTerminalOutput('\r\n\x1b[33m[TermX] 远端 SSH 会话已断开。\x1b[0m\r\n');
        notifyListeners();
      });

      // 绑定终端键盘输入与带防抖的 PTY 尺寸缩放 (适配 iPadOS 分屏与台前调度)
      terminal.onOutput = _handleTerminalOutput;
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
        sendRawInput('${host.initCommand}\n');
      }
    } catch (e) {
      if (_disposed) return;
      _errorMessage = e.toString();
      _state = SessionConnectionState.error;
      terminal.write(
        '\r\n\x1b[31m[SSH 连接失败] $e\x1b[0m\r\n点击顶部/下方“重新连接”按钮，或右键标签选择“重新连接 / 重启终端”重试。\r\n',
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
          .listen(writeTerminalOutput);
      terminal.onOutput = _handleTerminalOutput;
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

    terminal.onOutput = _handleTerminalOutput;
    terminal.onResize = (int w, int h, int pw, int ph) {
      _resizeDebounceTimer?.cancel();
      _resizeDebounceTimer = Timer(const Duration(milliseconds: 80), () {
        // 触发防抖 SIGWINCH 适配
      });
    };
  }

  void _writeDemoPrompt() {
    final shortCwd = _demoCwd == '/root' ? '~' : _demoCwd;
    writeTerminalOutput(
      '\x1b[1;32m${host.username}@${host.name}\x1b[0m:\x1b[1;34m$shortCwd\x1b[0m# ',
    );
  }

  void _handleDemoTerminalInput(String data) {
    final cleaned = data.replaceAll(
      RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|O[A-Za-z]|.)'),
      '',
    );
    for (var i = 0; i < cleaned.length; i++) {
      final code = cleaned.codeUnitAt(i);
      if (code == 13) {
        // Enter
        writeTerminalOutput('\r\n');
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
        writeTerminalOutput('^C\r\n');
        _writeDemoPrompt();
      } else if (code == 4) {
        // Ctrl+D
        if (_demoLineBuffer.isEmpty) {
          writeTerminalOutput('logout\r\n');
          _writeDemoPrompt();
        }
      } else if (code == 26) {
        // Ctrl+Z
        _demoLineBuffer.clear();
        writeTerminalOutput('^Z\r\n');
        _writeDemoPrompt();
      } else if (code == 21 || code == 11) {
        // Ctrl+U / Ctrl+K 清空当前行
        final current = _demoLineBuffer.toString();
        if (current.isNotEmpty) {
          _demoLineBuffer.clear();
          writeTerminalOutput('\b \b' * current.length);
        }
      } else if (code == 23) {
        // Ctrl+W 删除前一个单词
        final current = _demoLineBuffer.toString();
        if (current.isNotEmpty) {
          final next = current.replaceFirst(RegExp(r'\S+\s*$'), '');
          final removed = current.length - next.length;
          if (removed > 0) {
            _demoLineBuffer
              ..clear()
              ..write(next);
            writeTerminalOutput('\b \b' * removed);
          }
        }
      } else if (code == 12) {
        // Ctrl+L
        clearTerminalScreen();
        _writeDemoPrompt();
      } else if (code == 127 || code == 8) {
        // Backspace
        final current = _demoLineBuffer.toString();
        if (current.isNotEmpty) {
          _demoLineBuffer.clear();
          _demoLineBuffer.write(current.substring(0, current.length - 1));
          writeTerminalOutput('\b \b');
        }
      } else if (code == 9) {
        // Tab 自动补全示例
        final partial = _demoLineBuffer.toString();
        if (partial == 'doc') {
          _demoLineBuffer.write('ker ps');
          writeTerminalOutput('ker ps');
        } else if (partial == ' Sys' || partial == 'sys') {
          _demoLineBuffer.write('temctl status nginx');
          writeTerminalOutput('temctl status nginx');
        }
      } else if (code >= 32) {
        _demoLineBuffer.write(cleaned[i]);
        writeTerminalOutput(cleaned[i]);
      }
    }
  }

  void _executeDemoShellCommand(String cmd) {
    final parts = cmd.split(RegExp(r'\s+'));
    final binary = parts.first;

    switch (binary) {
      case 'help':
        writeTerminalOutput(
          '\x1b[36m可用沙盒交互命令：\x1b[0m\r\n'
          '  \x1b[33mls / ll\x1b[0m             列出当前目录文件（支持美化卡片与 SFTP 同步）\r\n'
          '  \x1b[33mcd <dir>\x1b[0m            切换工作目录\r\n'
          '  \x1b[33mcat <file>\x1b[0m          查看文件内容\r\n'
          '  \x1b[33mtouch <file>\x1b[0m        创建新文件（可立即在 SFTP 面板看到）\r\n'
          '  \x1b[33mdocker ps / stats\x1b[0m   查看运行容器状态 / 资源监控\r\n'
          '  \x1b[33mkubectl get pods\x1b[0m    查看 Kubernetes Pod 状态\r\n'
          '  \x1b[33mtop / htop / ps\x1b[0m     打印系统负载与进程快照\r\n'
          '  \x1b[33mdf -h / free -h\x1b[0m     查看磁盘挂载与内存使用率\r\n'
          '  \x1b[33mss -tulnp / ip a\x1b[0m    查看监听端口与网络接口\r\n'
          '  \x1b[33msystemctl / git\x1b[0m     查看系统服务或 Git 状态\r\n'
          '  \x1b[33mnvidia-smi / ping\x1b[0m   查看 GPU 状态或连通性测试\r\n'
          '  \x1b[33muname -a\x1b[0m            查看内核版本信息\r\n'
          '  \x1b[33mclear\x1b[0m               清屏\r\n',
        );
        break;
      case 'ls':
      case 'll':
        final entries = _virtualFs[_demoCwd] ?? const [];
        writeTerminalOutput('total ${entries.length * 4}\r\n');
        for (final item in entries) {
          final color = item.isDirectory ? '\x1b[1;34m' : '\x1b[0m';
          writeTerminalOutput(
            '${item.permissions}  1 root root ${item.sizeBytes.toString().padLeft(8)} Nov 15 14:20 $color${item.name}\x1b[0m\r\n',
          );
        }
        break;
      case 'pwd':
        writeTerminalOutput('$_demoCwd\r\n');
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
            writeTerminalOutput(
              'bash: cd: $target: No such file or directory\r\n',
            );
          }
        }
        notifyListeners();
        break;
      case 'cat':
        if (parts.length < 2) {
          writeTerminalOutput('Usage: cat <filename>\r\n');
        } else {
          final fileName = parts[1];
          final entries = _virtualFs[_demoCwd] ?? const [];
          final match = entries.where((e) => e.name == fileName).toList();
          if (match.isEmpty) {
            writeTerminalOutput(
              'cat: $fileName: No such file or directory\r\n',
            );
          } else if (match.first.isDirectory) {
            writeTerminalOutput('cat: $fileName: Is a directory\r\n');
          } else {
            writeTerminalOutput(
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
        writeTerminalOutput(
          'Linux ${host.name} 6.8.0-48-generic #48-Ubuntu SMP PREEMPT_DYNAMIC x86_64 GNU/Linux\r\n',
        );
        break;
      case 'df':
        writeTerminalOutput(
          'Filesystem      Size  Used Avail Use% Mounted on\r\n'
          '/dev/vda1       120G   46G   74G  39% /\r\n'
          '/dev/vdb1       500G  435G   65G  87% /data/storage\r\n'
          'tmpfs           7.9G  1.2M  7.9G   1% /run\r\n',
        );
        break;
      case 'du':
        writeTerminalOutput(
          '18.4G\t/data/storage/backups\r\n'
          '6.2G\t/data/storage/postgres\r\n'
          '1.8G\t/var/lib/docker\r\n'
          '420M\t/root/logs\r\n',
        );
        break;
      case 'free':
        writeTerminalOutput(
          '               total        used        free      shared  buff/cache   available\r\n'
          'Mem:           15.6Gi       6.2Gi       4.7Gi       128Mi       4.7Gi       9.1Gi\r\n'
          'Swap:          4.0Gi       256Mi       3.8Gi\r\n',
        );
        break;
      case 'docker':
        final sub = parts.length > 1 ? parts[1] : 'ps';
        if (sub == 'images') {
          writeTerminalOutput(
            'REPOSITORY      TAG          IMAGE ID       CREATED        SIZE\r\n'
            'nginx           alpine       cc44224bfe20   2 weeks ago    43.2MB\r\n'
            'redis           7-alpine     8c9f08f89a11   3 weeks ago    34.8MB\r\n'
            'postgres        16           2f418f10d8e4   4 weeks ago    432MB\r\n',
          );
        } else if (sub == 'stats') {
          writeTerminalOutput(
            'CONTAINER ID   NAME          CPU %     MEM USAGE / LIMIT     MEM %     NET I/O           BLOCK I/O        PIDS\r\n'
            'a81f940b2c19   api-gateway   4.28%     68.4MiB / 15.62GiB    0.43%     1.42GB / 980MB    12.4MB / 0B      12\r\n'
            '79c20e1b55d1   redis-cache   2.15%     142.8MiB / 2GiB       6.97%     845MB / 612MB     4.1MB / 88MB     6\r\n'
            '3e19a8410f02   pg-primary    11.60%    1.24GiB / 8GiB        15.50%    412MB / 520MB     1.8GB / 4.2GB    28\r\n',
          );
        } else if (sub == 'logs') {
          final target = parts.length > 2 ? parts.last : 'api-gateway';
          writeTerminalOutput(
            '2026-11-15T19:40:01.104Z [INFO] [$target] worker process ready (pid=1)\r\n'
            '2026-11-15T19:40:12.482Z [INFO] [$target] healthcheck /readyz -> 200 OK (1.2ms)\r\n'
            '2026-11-15T19:40:28.915Z [INFO] [$target] upstream keepalive pool active=4 idle=12\r\n',
          );
        } else {
          writeTerminalOutput(
            'CONTAINER ID   IMAGE            COMMAND                  STATUS          PORTS                    NAMES\r\n'
            'a81f940b2c19   nginx:alpine     "/docker-entrypoint.…"   Up 14 days      0.0.0.0:443->443/tcp     api-gateway\r\n'
            '79c20e1b55d1   redis:7-alpine   "docker-entrypoint.s…"   Up 14 days      0.0.0.0:6379->6379/tcp   redis-cache\r\n'
            '3e19a8410f02   postgres:16      "docker-entrypoint.s…"   Up 9 days       5432/tcp                 pg-primary\r\n',
          );
        }
        break;
      case 'kubectl':
        writeTerminalOutput(
          'NAMESPACE     NAME                               READY   STATUS    RESTARTS   AGE\r\n'
          'prod          api-gateway-7c8d94f6b-9xk2p        1/1     Running   0          14d\r\n'
          'prod          worker-billing-5f9b8c7d4-m4v8q     2/2     Running   1          9d\r\n'
          'monitoring    prometheus-server-0                2/2     Running   0          31d\r\n',
        );
        break;
      case 'top':
      case 'htop':
        writeTerminalOutput(
          'top - 15:42:10 up 42 days,  6:18,  1 user,  load average: 0.48, 0.39, 0.31\r\n'
          'Tasks: 148 total,   1 running, 147 sleeping,   0 stopped,   0 zombie\r\n'
          '%Cpu(s): 18.4 us,  4.2 sy,  0.0 ni, 76.8 id,  0.4 wa,  0.0 hi,  0.2 si\r\n'
          'MiB Mem :  16384.0 total,   4820.5 free,   6412.2 used,   5151.3 buff/cache\r\n'
          'MiB Swap:   4096.0 total,   3840.0 free,    256.0 used.   9420.8 avail Mem\r\n'
          '\r\n'
          '  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND\r\n'
          ' 2190 postgres  20   0 1420800 312400  98200 S  11.6   1.9  84:12.40 postgres\r\n'
          ' 1042 www-data  20   0  284120  68400  24100 S   8.4   0.4  41:08.15 nginx\r\n'
          ' 1884 redis     20   0  198400 142800  12400 S   3.8   0.9  19:54.02 redis-server\r\n'
          ' 3412 root      20   0 1894000 112600  56000 S   2.2   0.7  15:20.88 dockerd\r\n',
        );
        break;
      case 'ps':
        writeTerminalOutput(
          'USER         PID %CPU %MEM    VSZ   RSS TTY      STAT START   TIME COMMAND\r\n'
          'postgres    2190 11.6  1.9 1420800 312400 ?      Ss   Nov01  84:12 postgres: walwriter\r\n'
          'www-data    1042  8.4  0.4 284120  68400 ?       S    Nov01  41:08 nginx: worker process\r\n'
          'redis       1884  3.8  0.9 198400 142800 ?       Ssl  Nov01  19:54 /usr/bin/redis-server *:6379\r\n'
          'root        3412  2.2  0.7 1894000 112600 ?      Ssl  Nov01  15:20 /usr/bin/dockerd -H fd://\r\n',
        );
        break;
      case 'ss':
      case 'netstat':
        writeTerminalOutput(
          'Netid  State   Recv-Q  Send-Q   Local Address:Port    Peer Address:Port  Process\r\n'
          'tcp    LISTEN  0       4096     0.0.0.0:443           0.0.0.0:*          users:(("nginx",pid=1042,fd=6))\r\n'
          'tcp    LISTEN  0       128      0.0.0.0:22            0.0.0.0:*          users:(("sshd",pid=812,fd=3))\r\n'
          'tcp    LISTEN  0       511      127.0.0.1:6379        0.0.0.0:*          users:(("redis-server",pid=1884,fd=7))\r\n'
          'tcp    LISTEN  0       244      127.0.0.1:5432        0.0.0.0:*          users:(("postgres",pid=2190,fd=5))\r\n',
        );
        break;
      case 'ip':
      case 'ifconfig':
        writeTerminalOutput(
          '1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 state UNKNOWN\r\n'
          '    inet 127.0.0.1/8 scope host lo\r\n'
          '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP\r\n'
          '    link/ether 52:54:00:4a:9c:12 brd ff:ff:ff:ff:ff:ff\r\n'
          '    inet ${host.host}/24 brd 192.168.1.255 scope global eth0\r\n',
        );
        break;
      case 'systemctl':
        if (parts.length >= 3 && parts[1] == 'status') {
          final svc = parts[2];
          writeTerminalOutput(
            '● $svc.service - High Performance Service ($svc)\r\n'
            '     Loaded: loaded (/lib/systemd/system/$svc.service; enabled; preset: enabled)\r\n'
            '     Active: active (running) since Sat 2026-11-01 09:24:10 CST; 14 days ago\r\n'
            '   Main PID: 1042 ($svc)\r\n'
            '      Tasks: 9 (limit: 19122)\r\n'
            '     Memory: 68.4M\r\n',
          );
        } else {
          writeTerminalOutput(
            'UNIT                     LOAD   ACTIVE SUB     DESCRIPTION\r\n'
            'nginx.service            loaded active running A high performance web server\r\n'
            'docker.service           loaded active running Docker Application Container Engine\r\n'
            'postgresql.service       loaded active running PostgreSQL RDBMS\r\n'
            'ssh.service              loaded active running OpenBSD Secure Shell server\r\n',
          );
        }
        break;
      case 'git':
        final sub = parts.length > 1 ? parts[1] : 'status';
        if (sub == 'log') {
          writeTerminalOutput(
            'a94e8c1 (HEAD -> main, origin/main) feat: add smart command output beautifier cards\r\n'
            '6d12f4b fix(sftp): preserve detected OS icon across host edits\r\n'
            '3b89a0c refactor(ui): adopt neutral carbon dark tokens\r\n',
          );
        } else {
          writeTerminalOutput(
            'On branch main\r\n'
            'Your branch is up to date with \'origin/main\'.\r\n'
            'Changes to be committed:\r\n'
            '  modified:   docker-compose.yml\r\n'
            'Changes not staged for commit:\r\n'
            '  modified:   deploy.sh\r\n'
            'Untracked files:\r\n'
            '  logs/audit.log\r\n',
          );
        }
        break;
      case 'nvidia-smi':
        writeTerminalOutput(
          '+-----------------------------------------------------------------------------------------+\r\n'
          '| NVIDIA-SMI 550.90.07              Driver Version: 550.90.07      CUDA Version: 12.4     |\r\n'
          '|-----------------------------------------+------------------------+----------------------+\r\n'
          '| GPU  Name                 Persistence-M | Bus-Id          Disp.A | Volatile Uncorr. ECC |\r\n'
          '| Fan  Temp   Perf          Pwr:Usage/Cap |           Memory-Usage | GPU-Util  Compute M. |\r\n'
          '|=========================================+========================+======================|\r\n'
          '|   0  NVIDIA A100-SXM4-80GB          On  |   00000000:00:04.0 Off |                    0 |\r\n'
          '| N/A   46C    P0             182W / 400W |   48620MiB / 81920MiB |     74%      Default |\r\n'
          '+-----------------------------------------+------------------------+----------------------+\r\n',
        );
        break;
      case 'ping':
        final target = parts.length > 1 ? parts.last : '1.1.1.1';
        writeTerminalOutput(
          'PING $target ($target) 56(84) bytes of data.\r\n'
          '64 bytes from $target: icmp_seq=1 ttl=57 time=11.4 ms\r\n'
          '64 bytes from $target: icmp_seq=2 ttl=57 time=12.1 ms\r\n'
          '64 bytes from $target: icmp_seq=3 ttl=57 time=10.8 ms\r\n'
          '64 bytes from $target: icmp_seq=4 ttl=57 time=11.9 ms\r\n'
          '--- $target ping statistics ---\r\n'
          '4 packets transmitted, 4 received, 0% packet loss, time 3005ms\r\n'
          'rtt min/avg/max/mdev = 10.800/11.550/12.100/0.502 ms\r\n',
        );
        break;
      case 'clear':
        clearTerminalScreen();
        break;
      default:
        writeTerminalOutput('\x1b[32m[Executed]\x1b[0m $cmd\r\n');
    }
    _writeDemoPrompt();
  }

  /// 向当前终端注入按键或命令（供手机虚拟键盘栏、iPad 悬浮键盘球、Snippets 插件调用）
  void sendRawInput(String data) {
    if (_disposed || _state != SessionConnectionState.connected) return;
    _notifyTerminalInput(data);
    if (isLocalSession) {
      final pty = _localPty;
      if (pty != null) {
        unawaited(
          pty.input.writeUtf8(data).catchError((Object error) {
            if (!_disposed && _localPty != null) {
              writeTerminalOutput('\r\n[TermX] 本地终端写入失败：$error\r\n');
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
    _terminalInputListeners.clear();
    _terminalOutputListeners.clear();
    _terminalClearListeners.clear();
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
