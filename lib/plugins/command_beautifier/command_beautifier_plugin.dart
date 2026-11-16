import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../../core/plugin_system/plugin_interface.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../../core/theme/ui_tokens.dart';
import 'beauty_card_widgets.dart';
import 'command_catalog.dart';
import 'command_output_models.dart';
import 'command_output_parser.dart';

class _LogicalBufferLine {
  final int startRow;
  final int endRow;
  final String text;

  const _LogicalBufferLine({
    required this.startRow,
    required this.endRow,
    required this.text,
  });
}

class _ActiveCommandCapture {
  final int captureId;
  String command;
  final int anchorRow;
  final CellAnchor? anchor;
  final DateTime startedAt;

  _ActiveCommandCapture({
    required this.captureId,
    required this.command,
    required this.anchorRow,
    required this.anchor,
    required this.startedAt,
  });

  int resolveRow(Buffer buffer) {
    final a = anchor;
    if (a != null) {
      return a.attached ? a.y : 0;
    }
    return anchorRow.clamp(0, max<int>(0, buffer.height - 1));
  }

  void dispose() {
    anchor?.dispose();
  }
}

class _SessionBeautyTracker {
  final SshSessionController session;
  late final void Function(String data) inputListener;
  late final void Function(String chunk) outputListener;
  late final VoidCallback clearListener;
  late final VoidCallback sessionStateListener;

  Timer? debounceTimer;
  final StringBuffer typedBuffer = StringBuffer();
  _ActiveCommandCapture? activeCapture;
  int? lastCardCaptureId;
  bool wasUsingAltBuffer = false;

  final List<BeautifiedOutputCard> cards = [];
  int currentIndex = -1;
  CardDisplayMode displayMode = CardDisplayMode.beautified;
  bool pinned = false;
  bool overlayVisible = false;
  Offset? cardOffset;
  String? lastParsedSignature;
  String? dismissedSignature;
  String? lastRecoveredDockerLogSignature;
  void Function(String message)? onShowToast;

  _SessionBeautyTracker(this.session);

  BeautifiedOutputCard? get currentCard =>
      (currentIndex >= 0 && currentIndex < cards.length)
      ? cards[currentIndex]
      : null;

  bool get hasActiveOverlay => overlayVisible && currentCard != null;

  void clearActiveCapture() {
    activeCapture?.dispose();
    activeCapture = null;
  }

  void dispose() {
    debounceTimer?.cancel();
    debounceTimer = null;
    clearActiveCapture();
    session.removeTerminalInputListener(inputListener);
    session.removeTerminalOutputListener(outputListener);
    session.removeTerminalClearListener(clearListener);
    session.removeListener(sessionStateListener);
  }
}

/// 终端常见命令输出美化卡片插件 (Command Beautifier Overlay Plugin)
///
/// 自动嗅探终端中如 `docker ps`、`top`、`kubectl get`、`df -h`、`nvidia-smi`、
/// `ss -tulnp`、`ip addr`/`ipconfig`、`systemctl`、`ls -la`、`git status` 等命令输出，
/// 在对应终端窗格上方贴合渲染结构化可视化卡片，并支持随时一键切换「美化卡片」与「显示原文」。
class CommandBeautifierPlugin extends TermXPlugin {
  static const String pluginId = 'plugin.command_beautifier';
  static const int _maxHistoryPerSession = 24;

  static final RegExp _barePowershellPrompt = RegExp(
    r'^PS (?:[A-Za-z]:[^>]*|[^>]{0,80})>\s*$',
  );
  static final RegExp _bareCmdPrompt = RegExp(r'^[A-Za-z]:\\[^>]*>\s*$');
  static final RegExp _barePosixPrompt = RegExp(
    r'^(?:\([^)]+\)\s*)?\[?[\w.-]+@[\w.-]+[:\s][^\$#%❯\r\n]{0,120}\]?[\$#%❯]\s*$',
  );
  static final RegExp _bareModernPrompt = RegExp(
    r'^(?:➜\s+|\([^)]+\)\s*)?(?:~|\/[\w./-]+|[\w.-]+)\s+(?:git:\([^)]+\)\s*)?[❯\$#%]\s*$',
  );
  static final RegExp _bareSimpleShellPrompt = RegExp(
    r'^(?:(?:ba|z|da|k|fi|a)?sh(?:-[0-9.]+)?\s*)?[\$#%❯]\s*$',
  );

  static final List<RegExp> _promptCommandExtractors = [
    RegExp(r'^PS (?:[A-Za-z]:[^>]*|[^>]{0,80})>\s*(.+)$'),
    RegExp(r'^[A-Za-z]:\\[^>]*>\s*(.+)$'),
    RegExp(
      r'^(?:\([^)]+\)\s*)?\[?[\w.-]+@[\w.-]+[:\s][^\$#%❯\r\n]{0,120}\]?[\$#%❯]\s+(.+)$',
    ),
    RegExp(
      r'^(?:➜\s+|\([^)]+\)\s*)?(?:~|\/[\w./-]+|[\w.-]+)\s+(?:git:\([^)]+\)\s*)?[❯\$#%]\s+(.+)$',
    ),
    RegExp(r'^(?:ba|z|da|k|fi|a)?sh(?:-[0-9.]+)?[\$#%]\s+(.+)$'),
    RegExp(r'^\s*[\$❯]\s+(.+)$'),
  ];

  static const Set<String> _clearScreenCommands = {'clear', 'cls', 'reset'};

  static const Set<String> _passthroughInteractiveCommands = {
    'vim',
    'nvim',
    'vi',
    'nano',
    'less',
    'more',
    'man',
    'ssh',
    'sftp',
    'tmux',
    'screen',
  };

  final Map<String, _SessionBeautyTracker> _trackers = {};
  final Set<BeautyCategoryId> _enabledCategories = Set<BeautyCategoryId>.of(
    BeautyCategoryId.values,
  );
  SshSessionController? _activeSession;
  bool _autoPopupCard = true;
  int _captureSeq = 0;

  bool get autoPopupCard => _autoPopupCard;

  Set<BeautyCategoryId> get enabledCategories =>
      Set<BeautyCategoryId>.unmodifiable(_enabledCategories);

  @override
  PluginManifest get manifest => const PluginManifest(
    id: pluginId,
    name: '命令输出美化贴片 (Command Beautifier)',
    version: '1.0.0',
    author: 'TermX Core Team',
    description:
        '自动识别 docker ps、top、kubectl、df、nvidia-smi、ss、ipconfig、git 等 12 大类命令输出，在终端贴合渲染可视化卡片，随时一键切换原文与美化视图。',
    icon: Icons.auto_awesome_outlined,
    accentColor: Color(0xFF38BDF8),
    permissions: [
      PluginPermission.terminalIo,
      PluginPermission.uiTerminalOverlay,
      PluginPermission.uiStatusBar,
      PluginPermission.uiPanel,
    ],
    isCorePlugin: true,
  );

  @override
  void onSessionAttached(SshSessionController session) {
    _ensureSessionTracked(session);
  }

  @override
  void onActiveSessionChanged(SshSessionController? session) {
    _activeSession = session;
    if (session != null && !session.isDisposed) {
      _ensureSessionTracked(session);
    }
    _pruneDisposedSessions();
    notifyListeners();
  }

  @override
  void onUnload() {
    for (final tracker in _trackers.values) {
      tracker.dispose();
    }
    _trackers.clear();
  }

  @override
  void dispose() {
    onUnload();
    super.dispose();
  }

  bool isCategoryEnabled(BeautyCategoryId category) =>
      _enabledCategories.contains(category);

  void setCategoryEnabled(BeautyCategoryId category, bool enabled) {
    final changed = enabled
        ? _enabledCategories.add(category)
        : _enabledCategories.remove(category);
    if (changed) notifyListeners();
  }

  void setAutoPopupCard(bool value) {
    if (_autoPopupCard == value) return;
    _autoPopupCard = value;
    notifyListeners();
  }

  List<BeautifiedOutputCard> cardsForSession(String sessionId) {
    final tracker = _trackers[sessionId];
    if (tracker == null) return const [];
    return List<BeautifiedOutputCard>.unmodifiable(tracker.cards);
  }

  CardDisplayMode? displayModeForSession(String sessionId) =>
      _trackers[sessionId]?.displayMode;

  bool hasOverlayForSession(String sessionId) =>
      _trackers[sessionId]?.hasActiveOverlay ?? false;

  /// 切换指定终端会话的「美化卡片 / 终端原文」模式（供快捷键 Alt+B、右键菜单与标题栏按钮调用）
  bool toggleSessionDisplayMode(String sessionId) {
    final tracker = _trackers[sessionId];
    if (tracker == null || tracker.cards.isEmpty) return false;
    if (!tracker.overlayVisible) {
      tracker.overlayVisible = true;
      tracker.currentIndex = tracker.cards.length - 1;
      tracker.displayMode = CardDisplayMode.beautified;
    } else {
      tracker.displayMode = tracker.displayMode == CardDisplayMode.beautified
          ? CardDisplayMode.raw
          : CardDisplayMode.beautified;
    }
    notifyListeners();
    return true;
  }

  void setSessionDisplayMode(String sessionId, CardDisplayMode mode) {
    final tracker = _trackers[sessionId];
    if (tracker == null || tracker.cards.isEmpty) return;
    tracker.overlayVisible = true;
    tracker.displayMode = mode;
    notifyListeners();
  }

  void toggleSessionPin(String sessionId) {
    final tracker = _trackers[sessionId];
    if (tracker == null) return;
    tracker.pinned = !tracker.pinned;
    notifyListeners();
  }

  void dismissSessionOverlay(String sessionId) {
    final tracker = _trackers[sessionId];
    if (tracker == null) return;
    tracker.overlayVisible = false;
    tracker.pinned = false;
    tracker.dismissedSignature = tracker.lastParsedSignature;
    notifyListeners();
  }

  void stepSessionHistory(String sessionId, int delta) {
    final tracker = _trackers[sessionId];
    if (tracker == null || tracker.cards.isEmpty) return;
    final next = (tracker.currentIndex + delta).clamp(
      0,
      tracker.cards.length - 1,
    );
    if (next == tracker.currentIndex && tracker.overlayVisible) return;
    tracker.currentIndex = next;
    tracker.overlayVisible = true;
    notifyListeners();
  }

  void activateHistoryCard(
    String sessionId,
    int index, {
    CardDisplayMode mode = CardDisplayMode.beautified,
  }) {
    final tracker = _trackers[sessionId];
    if (tracker == null || index < 0 || index >= tracker.cards.length) return;
    tracker.currentIndex = index;
    tracker.overlayVisible = true;
    tracker.displayMode = mode;
    notifyListeners();
  }

  void clearSessionHistory(String sessionId) {
    final tracker = _trackers[sessionId];
    if (tracker == null) return;
    tracker.cards.clear();
    tracker.currentIndex = -1;
    tracker.overlayVisible = false;
    tracker.pinned = false;
    tracker.lastCardCaptureId = null;
    notifyListeners();
  }

  /// 一键在目标终端窗格上预览任意分类的美化卡片样式（无需真实安装对应 CLI）
  BeautifiedOutputCard? previewCatalogSample(
    BeautyCategoryId category,
    SshSessionController? targetSession,
  ) {
    final session = targetSession ?? _activeSession;
    if (session == null || session.isDisposed) return null;
    final spec = BeautyCommandCatalog.specFor(category);
    final card = CommandOutputParser.parse(
      command: spec.sampleCommand,
      rawOutput: spec.sampleRawOutput,
      isAltScreen: category == BeautyCategoryId.systemTop,
    );
    if (card == null) return null;
    final tracker = _ensureSessionTracked(session);
    _pushCard(
      tracker,
      card,
      captureId: ++_captureSeq,
      forceBeautified: true,
    );
    notifyListeners();
    return card;
  }

  _SessionBeautyTracker _ensureSessionTracked(SshSessionController session) {
    final existing = _trackers[session.sessionId];
    if (existing != null) return existing;

    final tracker = _SessionBeautyTracker(session);
    tracker.inputListener = (data) => _onTerminalInput(tracker, data);
    tracker.outputListener = (_) => _scheduleOutputScan(tracker);
    tracker.clearListener = () {
      tracker.clearActiveCapture();
      tracker.typedBuffer.clear();
      if (!tracker.pinned) {
        tracker.overlayVisible = false;
        notifyListeners();
      }
    };
    tracker.sessionStateListener = () {
      if (session.isDisposed) {
        _trackers.remove(session.sessionId)?.dispose();
      }
    };

    session.addTerminalInputListener(tracker.inputListener);
    session.addTerminalOutputListener(tracker.outputListener);
    session.addTerminalClearListener(tracker.clearListener);
    session.addListener(tracker.sessionStateListener);
    _trackers[session.sessionId] = tracker;
    return tracker;
  }

  void _pruneDisposedSessions() {
    final deadIds = _trackers.entries
        .where((e) => e.value.session.isDisposed)
        .map((e) => e.key)
        .toList();
    for (final id in deadIds) {
      _trackers.remove(id)?.dispose();
    }
  }

  void _onTerminalInput(_SessionBeautyTracker tracker, String data) {
    if (data.isEmpty || tracker.session.isDisposed) return;

    // Ctrl+C / Ctrl+U 重置输入缓冲
    if (data.contains('\x03') || data.contains('\x15')) {
      tracker.typedBuffer.clear();
      return;
    }

    final newlineMatch = RegExp(r'[\r\n]').firstMatch(data);
    if (newlineMatch == null) {
      _appendPrintableKeystrokes(tracker.typedBuffer, data);
      return;
    }

    // 回车提交命令：合并本次数据包回车前内容（如粘贴或一键注入 `docker ps\r`）与终端光标行回显
    final beforeEnter = data.substring(0, newlineMatch.start);
    _appendPrintableKeystrokes(tracker.typedBuffer, beforeEnter);

    final mainBuf = tracker.session.terminal.mainBuffer;
    final int anchorRow = mainBuf.absoluteCursorY
        .clamp(0, max<int>(0, mainBuf.height - 1))
        .toInt();
    final promptLineText = _readSingleLogicalLineAround(mainBuf, anchorRow);
    final echoedCmd = _extractCommandFromPromptLine(promptLineText);
    final bufferedCmd = tracker.typedBuffer.toString().trim();
    tracker.typedBuffer.clear();

    String submittedCmd = '';
    if (echoedCmd != null && echoedCmd.trim().isNotEmpty) {
      submittedCmd = echoedCmd.trim();
      final preClean = _cleanPrintable(beforeEnter).trim();
      if (preClean.isNotEmpty && !submittedCmd.endsWith(preClean)) {
        submittedCmd = '$submittedCmd$preClean'.trim();
      }
    } else if (bufferedCmd.isNotEmpty) {
      submittedCmd = bufferedCmd;
    }

    // 回车后若有剩余字符（例如多行粘贴），保留最后一段到输入缓冲
    final afterLastNewline = data.split(RegExp(r'[\r\n]+')).last;
    if (afterLastNewline.isNotEmpty) {
      _appendPrintableKeystrokes(tracker.typedBuffer, afterLastNewline);
    }

    if (submittedCmd.isEmpty) {
      // 用户在空行敲回车，不覆盖当前状态
      return;
    }

    final firstExecutable = _primaryExecutable(submittedCmd);
    if (_clearScreenCommands.contains(firstExecutable)) {
      tracker.clearActiveCapture();
      if (!tracker.pinned) {
        tracker.overlayVisible = false;
        notifyListeners();
      }
      return;
    }

    if (_passthroughInteractiveCommands.contains(firstExecutable)) {
      tracker.clearActiveCapture();
      if (!tracker.pinned && tracker.overlayVisible) {
        tracker.displayMode = CardDisplayMode.raw;
        notifyListeners();
      }
      return;
    }

    tracker.clearActiveCapture();
    final anchor = mainBuf.height > 0
        ? mainBuf.createAnchor(0, anchorRow)
        : null;
    tracker.activeCapture = _ActiveCommandCapture(
      captureId: ++_captureSeq,
      command: submittedCmd,
      anchorRow: anchorRow,
      anchor: anchor,
      startedAt: DateTime.now(),
    );
    tracker.dismissedSignature = null;

    // 若上一张卡片未固定且处于大卡片展开态，提交新命令时先优雅切回原文态，
    // 若新命令输出命中美化规则会在 60ms 内自动弹出新卡片，未命中则不遮挡普通命令结果。
    if (!tracker.pinned &&
        tracker.overlayVisible &&
        tracker.displayMode == CardDisplayMode.beautified) {
      tracker.displayMode = CardDisplayMode.raw;
      notifyListeners();
    }
  }

  void _appendPrintableKeystrokes(StringBuffer buf, String input) {
    if (input.isEmpty) return;
    // 跳过方向键等 CSI/SS3 控制序列
    final stripped = input.replaceAll(
      RegExp(r'\x1B(?:\[[0-?]*[ -/]*[@-~]|O[A-Za-z]|.)'),
      '',
    );
    for (final codeUnit in stripped.runes) {
      if (codeUnit == 0x7F || codeUnit == 0x08) {
        final s = buf.toString();
        buf.clear();
        if (s.isNotEmpty) {
          buf.write(s.substring(0, s.length - 1));
        }
      } else if (codeUnit >= 0x20 && codeUnit != 0x7F) {
        buf.writeCharCode(codeUnit);
      }
    }
  }

  String _cleanPrintable(String input) {
    final out = StringBuffer();
    _appendPrintableKeystrokes(out, input);
    return out.toString();
  }

  String _primaryExecutable(String cmd) {
    final trimmed = cmd.trim();
    if (trimmed.isEmpty) return '';
    final tokens = trimmed.split(RegExp(r'\s+'));
    var idx = 0;
    while (idx < tokens.length &&
        (tokens[idx] == 'sudo' ||
            tokens[idx] == 'env' ||
            tokens[idx].contains('='))) {
      idx++;
    }
    if (idx >= tokens.length) return '';
    final exe = tokens[idx].split('/').last.split(r'\').last.toLowerCase();
    return exe;
  }

  void _scheduleOutputScan(_SessionBeautyTracker tracker) {
    if (tracker.session.isDisposed) return;
    tracker.debounceTimer?.cancel();
    tracker.debounceTimer = Timer(const Duration(milliseconds: 60), () {
      tracker.debounceTimer = null;
      if (tracker.session.isDisposed) return;
      _evaluateSessionOutput(tracker);
    });
  }

  void _evaluateSessionOutput(_SessionBeautyTracker tracker) {
    final terminal = tracker.session.terminal;
    final isAlt = terminal.isUsingAltBuffer;

    // 从交互式备用缓冲区（如 top/htop 按 q 退出）回到主缓冲区时，若未固定则自动收起实时卡片到胶囊态
    if (tracker.wasUsingAltBuffer && !isAlt) {
      tracker.wasUsingAltBuffer = false;
      final cur = tracker.currentCard;
      if (cur != null && cur.isLiveInteractive && !tracker.pinned) {
        tracker.displayMode = CardDisplayMode.raw;
        notifyListeners();
      }
      return;
    }
    tracker.wasUsingAltBuffer = isAlt;

    if (isAlt) {
      final altLines = _extractLogicalLines(
        terminal.altBuffer,
        startPhysicalRow: 0,
      );
      final rawText = altLines
          .map((l) => l.text)
          .skipWhile((t) => t.trim().isEmpty)
          .toList()
          .join('\n')
          .trimRight();
      if (rawText.isEmpty) return;

      final cmdHint = tracker.activeCapture?.command ?? 'top';
      final sig = 'alt|$cmdHint|$rawText';
      if (sig == tracker.dismissedSignature || sig == tracker.lastParsedSignature) {
        return;
      }

      final card = CommandOutputParser.parse(
        command: cmdHint,
        rawOutput: rawText,
        isAltScreen: true,
        enabledCategories: _enabledCategories,
      );
      if (card != null) {
        tracker.lastParsedSignature = sig;
        final capId = tracker.activeCapture?.captureId ??
            tracker.lastCardCaptureId ??
            (++_captureSeq);
        _pushCard(tracker, card, captureId: capId);
        notifyListeners();
      }
      return;
    }

    // 主缓冲区提取：优先基于已记录的命令锚点，否则向后嗅探最近一次提示符块
    final mainBuf = terminal.mainBuffer;
    final capture = tracker.activeCapture;

    String commandHint = '';
    List<String> candidateLines = const [];
    int captureKey = 0;

    if (capture != null && mainBuf.height > 0) {
      final resolvedAnchorRow = capture.resolveRow(mainBuf);
      final logicalLines = _extractLogicalLines(
        mainBuf,
        startPhysicalRow: max(0, resolvedAnchorRow),
      );
      if (logicalLines.isNotEmpty) {
        final firstLine = logicalLines.first.text;
        final reExtracted = _extractCommandFromPromptLine(firstLine);
        if (reExtracted != null && reExtracted.trim().isNotEmpty) {
          capture.command = reExtracted.trim();
        }
        commandHint = capture.command;
        captureKey = capture.captureId;

        // 如果首行是命令提示符行，则跳过首行；若终端直接覆盖了首行则保留
        final startIdx =
            (_extractCommandFromPromptLine(firstLine) != null ||
                _isBareShellPrompt(firstLine) ||
                (commandHint.isNotEmpty && firstLine.contains(commandHint)))
            ? 1
            : 0;
        candidateLines = logicalLines
            .skip(startIdx)
            .map((e) => e.text)
            .toList();
      }
    } else {
      // 无显式输入锚点时（例如沙盒自动回显、外部写入或脚本输出），扫描最近 120 行
      final startRow = max(0, mainBuf.height - 140);
      final logicalLines = _extractLogicalLines(
        mainBuf,
        startPhysicalRow: startRow,
      );
      // 去掉末尾空行与末尾裸提示符后，逆向寻找最近一条带命令的提示符行
      var endExclusive = logicalLines.length;
      while (endExclusive > 0 &&
          (logicalLines[endExclusive - 1].text.trim().isEmpty ||
              _isBareShellPrompt(logicalLines[endExclusive - 1].text))) {
        endExclusive--;
      }
      int promptIdx = -1;
      for (var i = endExclusive - 1; i >= 0; i--) {
        final cmd = _extractCommandFromPromptLine(logicalLines[i].text);
        if (cmd != null && cmd.trim().isNotEmpty) {
          promptIdx = i;
          commandHint = cmd.trim();
          break;
        }
      }
      if (promptIdx >= 0) {
        captureKey = 1000000 + logicalLines[promptIdx].startRow;
        candidateLines = logicalLines
            .sublist(promptIdx + 1, endExclusive)
            .map((e) => e.text)
            .toList();
      } else if (endExclusive > 0) {
        captureKey = 2000000;
        candidateLines = logicalLines
            .sublist(0, endExclusive)
            .map((e) => e.text)
            .toList();
      }
    }

    // 剥离首尾空行与末尾新打印出来的空 Shell 提示符
    while (candidateLines.isNotEmpty && candidateLines.last.trim().isEmpty) {
      candidateLines.removeLast();
    }
    while (candidateLines.isNotEmpty && _isBareShellPrompt(candidateLines.last)) {
      candidateLines.removeLast();
      while (candidateLines.isNotEmpty && candidateLines.last.trim().isEmpty) {
        candidateLines.removeLast();
      }
    }
    while (candidateLines.isNotEmpty && candidateLines.first.trim().isEmpty) {
      candidateLines.removeAt(0);
    }

    if (candidateLines.isEmpty) return;

    final rawOutput = candidateLines.join('\n');

    // 当 Docker 容器 json-file 日志因宿主机断电/强行清空混入 \x00 空字节时，
    // `docker logs` 会报 `Error grabbing logs: invalid character '\x00' looking for beginning of value`。
    // 自动在 POSIX 终端内绕过损坏空字节提取并解码最新日志，避免用户卡死在报错提示。
    if (isDockerNullByteLogError(rawOutput)) {
      final parsedLogs = parseDockerLogsCommand(commandHint);
      final recoverySig = '$captureKey|$commandHint|docker_null_log_recovery';
      final isPosixShell =
          !tracker.session.isDemoMode &&
          (!tracker.session.isLocalSession || !Platform.isWindows);
      if (parsedLogs != null &&
          isPosixShell &&
          tracker.lastRecoveredDockerLogSignature != recoverySig) {
        tracker.lastRecoveredDockerLogSignature = recoverySig;
        final fallbackCmd = buildDockerNullByteFallbackCommand(
          parsedLogs.container,
          tail: parsedLogs.tail,
        );
        tracker.session.sendRawInput('$fallbackCmd\r');
        tracker.onShowToast?.call(
          '检测到 ${parsedLogs.container} 日志含损坏空字节 (\\x00)，已自动绕过并读取最新日志',
        );
        return;
      }
    }

    final signature = '$captureKey|$commandHint|$rawOutput';
    if (signature == tracker.dismissedSignature ||
        signature == tracker.lastParsedSignature) {
      return;
    }

    final parsed = CommandOutputParser.parse(
      command: commandHint,
      rawOutput: rawOutput,
      isAltScreen: false,
      enabledCategories: _enabledCategories,
    );
    if (parsed == null) return;

    tracker.lastParsedSignature = signature;
    _pushCard(
      tracker,
      parsed,
      captureId: captureKey == 0 ? (++_captureSeq) : captureKey,
    );
    notifyListeners();
  }

  /// 检测 Docker Engine 读取损坏 `*-json.log` 空字节时的标准报错特征
  static bool isDockerNullByteLogError(String rawOutput) {
    final lower = rawOutput.toLowerCase();
    return lower.contains('error grabbing logs:') &&
        lower.contains('invalid character') &&
        (rawOutput.contains(r'\x00') || lower.contains('0x00'));
  }

  /// 解析 `docker logs` / `sudo docker container logs` 命令中的目标容器名与 `--tail` 行数
  static ({String container, int tail})? parseDockerLogsCommand(
    String command,
  ) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return null;
    // 排除复合管道/脚本语句，仅针对纯 docker logs 命令触发容错
    if (trimmed.contains(';') ||
        trimmed.contains('|') ||
        trimmed.contains('&&') ||
        trimmed.contains('||')) {
      return null;
    }

    final tokens = _tokenizeSimpleShellArgs(trimmed);
    if (tokens.isEmpty) return null;

    var idx = 0;
    while (idx < tokens.length &&
        (tokens[idx] == 'sudo' ||
            tokens[idx] == 'env' ||
            tokens[idx].contains('='))) {
      if (tokens[idx] == 'sudo') {
        idx++;
        while (idx < tokens.length && tokens[idx].startsWith('-')) {
          if ((tokens[idx] == '-u' || tokens[idx] == '-g') &&
              idx + 1 < tokens.length) {
            idx += 2;
          } else {
            idx++;
          }
        }
      } else {
        idx++;
      }
    }
    if (idx >= tokens.length) return null;

    final exe = tokens[idx].split('/').last.split(r'\').last.toLowerCase();
    if (exe != 'docker') return null;
    idx++;

    // 跳过全局 docker 参数（如 -H / --context / --config）
    while (idx < tokens.length && tokens[idx].startsWith('-')) {
      final flag = tokens[idx];
      if ((flag == '-H' ||
              flag == '--host' ||
              flag == '-c' ||
              flag == '--context' ||
              flag == '--config' ||
              flag == '-l' ||
              flag == '--log-level') &&
          idx + 1 < tokens.length) {
        idx += 2;
      } else {
        idx++;
      }
    }
    if (idx >= tokens.length) return null;

    if (tokens[idx] == 'container') {
      idx++;
    }
    if (idx >= tokens.length || tokens[idx] != 'logs') return null;
    idx++;

    var tail = 50;
    String? container;

    while (idx < tokens.length) {
      final tok = tokens[idx];
      if (tok == '--') {
        idx++;
        if (idx < tokens.length) {
          container ??= tokens[idx];
        }
        break;
      }
      if (tok == '--tail' || tok == '-n') {
        if (idx + 1 < tokens.length) {
          final parsedTail = int.tryParse(tokens[idx + 1]);
          if (parsedTail != null && parsedTail > 0) {
            tail = parsedTail.clamp(1, 5000);
          }
          idx += 2;
          continue;
        }
      } else if (tok.startsWith('--tail=')) {
        final parsedTail = int.tryParse(tok.substring('--tail='.length));
        if (parsedTail != null && parsedTail > 0) {
          tail = parsedTail.clamp(1, 5000);
        }
      } else if (tok.startsWith('-n') && tok.length > 2) {
        final rawNum = tok.startsWith('-n=')
            ? tok.substring(3)
            : tok.substring(2);
        final parsedTail = int.tryParse(rawNum);
        if (parsedTail != null && parsedTail > 0) {
          tail = parsedTail.clamp(1, 5000);
        }
      } else if (tok == '--since' || tok == '--until') {
        idx += 2;
        continue;
      } else if (!tok.startsWith('-')) {
        container ??= tok;
      }
      idx++;
    }

    if (container == null || container.trim().isEmpty) return null;
    final cleanContainer = container.trim();
    if (RegExp(r'[\r\n\x00]').hasMatch(cleanContainer)) return null;
    return (container: cleanContainer, tail: tail);
  }

  static List<String> _tokenizeSimpleShellArgs(String input) {
    final result = <String>[];
    final buf = StringBuffer();
    String? quote;
    for (var i = 0; i < input.length; i++) {
      final ch = input[i];
      if (quote != null) {
        if (ch == quote) {
          quote = null;
        } else if (ch == r'\' && quote == '"' && i + 1 < input.length) {
          buf.write(input[++i]);
        } else {
          buf.write(ch);
        }
      } else {
        if (ch == "'" || ch == '"') {
          quote = ch;
        } else if (ch == ' ' || ch == '\t') {
          if (buf.isNotEmpty) {
            result.add(buf.toString());
            buf.clear();
          }
        } else {
          buf.write(ch);
        }
      }
    }
    if (buf.isNotEmpty) {
      result.add(buf.toString());
    }
    return result;
  }

  /// 生成兼容 Linux / OpenWrt (BusyBox ash) / macOS 的 `\x00` 容错容器日志读取命令
  ///
  /// 前置空格在开启 `HISTCONTROL=ignorespace/ignoreboth` 的 Shell 中不会污染历史记录。
  static String buildDockerNullByteFallbackCommand(
    String containerRef, {
    int tail = 50,
  }) {
    final safeTail = tail.clamp(1, 5000);
    final escapedRef = containerRef.replaceAll("'", r"'\''");
    return " _c='$escapedRef'; "
        r'_lp=$(docker inspect -f "{{.LogPath}}" "$_c" 2>/dev/null || sudo -n docker inspect -f "{{.LogPath}}" "$_c" 2>/dev/null); '
        'if [ -n "\$_lp" ]; then '
        "printf '\\033[33m[TermX] 容器日志含损坏空字节(0x00)，已自动绕过并提取最新 $safeTail 行：\\033[0m\\n'; "
        r'(if [ -r "$_lp" ]; then cat "$_lp"; '
        r'elif sudo -n test -r "$_lp" 2>/dev/null; then sudo -n cat "$_lp"; '
        r'else _im=$(docker inspect -f "{{.Config.Image}}" "$_c" 2>/dev/null); '
        r'([ -n "$_im" ] && docker run --rm --entrypoint /bin/cat -v "$_lp":/l:ro "$_im" /l 2>/dev/null) || sudo cat "$_lp"; '
        'fi) '
        "| tr -d '\\000' | tail -n $safeTail "
        r'''| sed 's/^{"log":"//; s/","stream":"[^"]*".*}$//; s/\\n$//; s/\\r$//; s/\\u001b\[[0-9;]*[a-zA-Z]//g; s/\\u003c/</g; s/\\u003e/>/g; s/\\u0026/\&/g; s/\\"/"/g; s/\\\\/\\/g'; '''
        r'''printf '\033[36m[TermX] 永久清理空字节修复命令：sudo sed -i "s/\\x00//g" "%s"\033[0m\n' "$_lp"; '''
        'fi';
  }

  void _pushCard(
    _SessionBeautyTracker tracker,
    BeautifiedOutputCard card, {
    required int captureId,
    bool forceBeautified = false,
  }) {
    // 同一条流式命令（如 ping 连续回包、top 连续刷新）原地更新最新卡片，避免产生重复历史记录
    final isSameStreamingCapture =
        tracker.cards.isNotEmpty &&
        (tracker.lastCardCaptureId == captureId ||
            (card.isLiveInteractive &&
                tracker.cards.last.isLiveInteractive &&
                tracker.cards.last.category == card.category));

    if (isSameStreamingCapture) {
      final replaceIdx = tracker.cards.length - 1;
      final preservedId = tracker.cards[replaceIdx].id;
      tracker.cards[replaceIdx] = BeautifiedOutputCard(
        id: preservedId,
        category: card.category,
        title: card.title,
        command: card.command,
        summaryBadge: card.summaryBadge,
        rawOutput: card.rawOutput,
        capturedAt: card.capturedAt,
        isLiveInteractive: card.isLiveInteractive,
        payload: card.payload,
      );
      if (forceBeautified) {
        tracker.currentIndex = replaceIdx;
        tracker.overlayVisible = true;
        tracker.displayMode = CardDisplayMode.beautified;
      }
      return;
    }

    tracker.cards.add(card);
    if (tracker.cards.length > _maxHistoryPerSession) {
      tracker.cards.removeAt(0);
    }
    tracker.lastCardCaptureId = captureId;

    if (!tracker.pinned || forceBeautified || !tracker.overlayVisible) {
      tracker.currentIndex = tracker.cards.length - 1;
      tracker.overlayVisible = true;
      tracker.displayMode = (forceBeautified || _autoPopupCard)
          ? CardDisplayMode.beautified
          : CardDisplayMode.raw;
    }
  }

  static bool _isBareShellPrompt(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.length > 160) return false;
    return _barePowershellPrompt.hasMatch(trimmed) ||
        _bareCmdPrompt.hasMatch(trimmed) ||
        _barePosixPrompt.hasMatch(trimmed) ||
        _bareModernPrompt.hasMatch(trimmed) ||
        _bareSimpleShellPrompt.hasMatch(trimmed);
  }

  static String? _extractCommandFromPromptLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return null;
    for (final reg in _promptCommandExtractors) {
      final m = reg.firstMatch(trimmed);
      if (m != null) {
        final cmd = m.group(1)?.trim();
        if (cmd != null && cmd.isNotEmpty) return cmd;
      }
    }
    return null;
  }

  static String _readSingleLogicalLineAround(Buffer buffer, int physicalRow) {
    if (buffer.height <= 0) return '';
    var start = physicalRow.clamp(0, buffer.height - 1);
    while (start > 0 && buffer.lines[start].isWrapped) {
      start--;
    }
    var end = physicalRow.clamp(0, buffer.height - 1);
    while (end + 1 < buffer.height && buffer.lines[end + 1].isWrapped) {
      end++;
    }
    final extracted = _extractLogicalLines(
      buffer,
      startPhysicalRow: start,
      endPhysicalRow: end,
    );
    return extracted.isEmpty ? '' : extracted.first.text;
  }

  static List<_LogicalBufferLine> _extractLogicalLines(
    Buffer buffer, {
    required int startPhysicalRow,
    int? endPhysicalRow,
  }) {
    if (buffer.height <= 0 || buffer.viewWidth <= 0) return const [];
    final firstRow = startPhysicalRow.clamp(0, buffer.height - 1);
    final lastRow = (endPhysicalRow ?? (buffer.height - 1)).clamp(
      firstRow,
      buffer.height - 1,
    );

    final result = <_LogicalBufferLine>[];
    final currentText = StringBuffer();
    var logicalStart = firstRow;

    for (var y = firstRow; y <= lastRow; y++) {
      final line = buffer.lines[y];
      if (y > firstRow && !line.isWrapped) {
        result.add(
          _LogicalBufferLine(
            startRow: logicalStart,
            endRow: y - 1,
            text: currentText.toString(),
          ),
        );
        currentText.clear();
        logicalStart = y;
      }

      var lastCol = buffer.viewWidth;
      final nextWraps = y + 1 <= lastRow && buffer.lines[y + 1].isWrapped;
      if (!nextWraps) {
        while (lastCol > 0 && line.getCodePoint(lastCol - 1) == 0) {
          lastCol--;
        }
      }

      for (var x = 0; x < lastCol; x++) {
        final code = line.getCodePoint(x);
        final width = line.getWidth(x);
        if (code == 0 && width == 0 && x > 0 && line.getWidth(x - 1) == 2) {
          continue;
        }
        currentText.write(code == 0 ? ' ' : String.fromCharCode(code));
      }
    }

    result.add(
      _LogicalBufferLine(
        startRow: logicalStart,
        endRow: lastRow,
        text: currentText.toString(),
      ),
    );
    return result;
  }

  // ---------------------------------------------------------------------------
  // [插槽 3] 终端窗格画布浮层贴片
  // ---------------------------------------------------------------------------
  @override
  Widget? buildTerminalOverlayWidget(
    BuildContext context,
    PluginContext pluginContext,
    SshSessionController session,
  ) {
    final tracked = _ensureSessionTracked(session);
    tracked.onShowToast = pluginContext.showToast;
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        final tracker = _trackers[session.sessionId];
        final card = tracker?.currentCard;
        if (tracker == null || !tracker.hasActiveOverlay || card == null) {
          return const IgnorePointer(child: SizedBox.expand());
        }
        return TerminalBeautyOverlay(
          card: card,
          displayMode: tracker.displayMode,
          pinned: tracker.pinned,
          historyIndex: tracker.currentIndex,
          historyTotal: tracker.cards.length,
          savedOffset: tracker.cardOffset,
          onOffsetChanged: (next) {
            tracker.cardOffset = next;
          },
          onToggleDisplayMode: (mode) =>
              setSessionDisplayMode(session.sessionId, mode),
          onTogglePin: () => toggleSessionPin(session.sessionId),
          onDismiss: () => dismissSessionOverlay(session.sessionId),
          onStepHistory: (delta) => stepSessionHistory(session.sessionId, delta),
          onSendCommand: (cmd, {bool appendNewline = true}) {
            if (appendNewline &&
                cmd != 'q' &&
                tracker.overlayVisible &&
                tracker.displayMode == CardDisplayMode.beautified) {
              tracker.displayMode = CardDisplayMode.raw;
              notifyListeners();
            }
            session.sendRawInput(appendNewline ? '$cmd\r' : cmd);
          },
          onCopyToast: pluginContext.showToast,
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // [插槽 1] 底部状态栏快捷胶囊
  // ---------------------------------------------------------------------------
  @override
  Widget? buildStatusBarWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) {
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        final session = pluginContext.activeSession ?? _activeSession;
        final tracker = session != null ? _trackers[session.sessionId] : null;
        final cardCount = tracker?.cards.length ?? 0;
        final hasOverlay = tracker?.hasActiveOverlay ?? false;
        final isBeauty = tracker?.displayMode == CardDisplayMode.beautified;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(5),
              onTap: () => pluginContext.requestOpenPanel(pluginId),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.auto_awesome_outlined,
                      size: 13.5,
                      color: hasOverlay && isBeauty
                          ? TxColors.accent
                          : TxColors.textMuted,
                    ),
                    const SizedBox(width: 5),
                    Text(
                      cardCount > 0 ? '命令美化 ($cardCount)' : '命令美化',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: hasOverlay && isBeauty
                            ? TxColors.textPrimary
                            : TxColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (session != null && cardCount > 0) ...[
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => toggleSessionDisplayMode(session.sessionId),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: hasOverlay && isBeauty
                        ? TxColors.accent.withValues(alpha: 0.16)
                        : TxColors.bgElevated,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: hasOverlay && isBeauty
                          ? TxColors.accent.withValues(alpha: 0.45)
                          : TxColors.borderSubtle,
                    ),
                  ),
                  child: Text(
                    hasOverlay && isBeauty ? '切原文' : '显卡片',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: hasOverlay && isBeauty
                          ? TxColors.accent
                          : TxColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // [插槽 2] 侧边栏 / 底部抽屉管理与命令清单面板
  // ---------------------------------------------------------------------------
  @override
  Widget? buildPanelWidget(BuildContext context, PluginContext pluginContext) {
    return _CommandBeautifierSidePanel(
      plugin: this,
      pluginContext: pluginContext,
    );
  }
}

class _CommandBeautifierSidePanel extends StatefulWidget {
  const _CommandBeautifierSidePanel({
    required this.plugin,
    required this.pluginContext,
  });

  final CommandBeautifierPlugin plugin;
  final PluginContext pluginContext;

  @override
  State<_CommandBeautifierSidePanel> createState() =>
      _CommandBeautifierSidePanelState();
}

class _CommandBeautifierSidePanelState
    extends State<_CommandBeautifierSidePanel> {
  int _tabIndex = 0; // 0: 支持命令清单与预览, 1: 当前会话已捕获卡片
  final TextEditingController _catalogSearchCtrl = TextEditingController();

  @override
  void dispose() {
    _catalogSearchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.plugin,
      builder: (context, _) {
        final session = widget.pluginContext.activeSession;
        final cards = session != null
            ? widget.plugin.cardsForSession(session.sessionId)
            : const <BeautifiedOutputCard>[];
        final currentMode = session != null
            ? widget.plugin.displayModeForSession(session.sessionId)
            : null;
        final hasOverlay = session != null &&
            widget.plugin.hasOverlayForSession(session.sessionId);

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildTopControlStrip(session, cards, currentMode, hasOverlay),
            _buildSubTabBar(cards.length),
            Expanded(
              child: _tabIndex == 0
                  ? _buildCatalogList(session)
                  : _buildCapturedCardsList(session, cards),
            ),
          ],
        );
      },
    );
  }

  void _dismissSheetIfModal(BuildContext context) {
    final route = ModalRoute.of(context);
    if (route is PopupRoute && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Widget _buildTopControlStrip(
    SshSessionController? session,
    List<BeautifiedOutputCard> cards,
    CardDisplayMode? currentMode,
    bool hasOverlay,
  ) {
    final isMobileSheet = MediaQuery.sizeOf(context).width < 600;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: const BoxDecoration(
        color: TxColors.bgSidebar,
        border: Border(bottom: BorderSide(color: TxColors.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(
                Icons.auto_awesome_rounded,
                size: 16,
                color: TxColors.accent,
              ),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  '检测到支持命令时自动展开卡片',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: TxColors.textPrimary,
                  ),
                ),
              ),
              SizedBox(
                height: 24,
                child: Transform.scale(
                  scale: 0.78,
                  child: Switch(
                    value: widget.plugin.autoPopupCard,
                    onChanged: widget.plugin.setAutoPopupCard,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            widget.plugin.autoPopupCard
                ? (isMobileSheet
                      ? '已开启自动贴片 · 卡片顶栏可拖动移位或全屏展开，随时一键切回原文'
                      : '已开启自动贴片 · 卡片顶部可任意拖拽移位，Alt+B 随时切换美化与原文')
                : '静默胶囊模式 · 命令输出保持原文，悬浮小胶囊供按需展开卡片',
            style: const TextStyle(fontSize: 11.5, color: TxColors.textMuted),
          ),
          if (session != null && cards.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: TxColors.bgChrome,
                borderRadius: BorderRadius.circular(7),
                border: Border.all(color: TxColors.borderSubtle),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _modeSwitchButton(
                      label: '美化卡片视图',
                      icon: Icons.auto_awesome_rounded,
                      selected:
                          hasOverlay && currentMode == CardDisplayMode.beautified,
                      onTap: () {
                        widget.plugin.setSessionDisplayMode(
                          session.sessionId,
                          CardDisplayMode.beautified,
                        );
                        _dismissSheetIfModal(context);
                      },
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: _modeSwitchButton(
                      label: '显示终端原文',
                      icon: Icons.notes_rounded,
                      selected: !hasOverlay || currentMode == CardDisplayMode.raw,
                      onTap: () {
                        widget.plugin.setSessionDisplayMode(
                          session.sessionId,
                          CardDisplayMode.raw,
                        );
                        _dismissSheetIfModal(context);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _modeSwitchButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(5),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 7),
        decoration: BoxDecoration(
          color: selected ? TxColors.bgElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
            color: selected
                ? TxColors.accent.withValues(alpha: 0.55)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 14,
              color: selected ? TxColors.accent : TxColors.textMuted,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? TxColors.textPrimary : TxColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSubTabBar(int capturedCount) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: const BoxDecoration(
        color: TxColors.bgChrome,
        border: Border(bottom: BorderSide(color: TxColors.borderSubtle)),
      ),
      child: Row(
        children: [
          _subTabChip(
            index: 0,
            title: '支持命令清单 (${BeautyCommandCatalog.specs.length}类)',
          ),
          const SizedBox(width: 6),
          _subTabChip(index: 1, title: '当前会话卡片 ($capturedCount)'),
        ],
      ),
    );
  }

  Widget _subTabChip({required int index, required String title}) {
    final active = _tabIndex == index;
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(5),
        onTap: () => setState(() => _tabIndex = index),
        child: Container(
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? TxColors.bgElevated : Colors.transparent,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: active ? TxColors.borderDefault : Colors.transparent,
            ),
          ),
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              color: active ? TxColors.textPrimary : TxColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCatalogList(SshSessionController? session) {
    final q = _catalogSearchCtrl.text.trim().toLowerCase();
    final filtered = BeautyCommandCatalog.specs.where((spec) {
      if (q.isEmpty) return true;
      if (spec.category.title.toLowerCase().contains(q)) return true;
      if (spec.subtitle.toLowerCase().contains(q)) return true;
      return spec.coveredCommands.any((c) => c.toLowerCase().contains(q));
    }).toList();

    final useWindowsCmd = session != null &&
        session.isLocalSession &&
        Platform.isWindows;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: SizedBox(
            height: 32,
            child: TextField(
              controller: _catalogSearchCtrl,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 12.5),
              decoration: InputDecoration(
                hintText: '搜索命令清单 (如 docker / top / ipconfig / git)…',
                prefixIcon: const Icon(Icons.search_rounded, size: 15),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                suffixIcon: q.isNotEmpty
                    ? IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.clear_rounded, size: 15),
                        onPressed: () {
                          _catalogSearchCtrl.clear();
                          setState(() {});
                        },
                      )
                    : null,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 6,
                ),
                isDense: true,
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 12),
            itemCount: filtered.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, idx) {
              final spec = filtered[idx];
              final enabled = widget.plugin.isCategoryEnabled(spec.category);
              final quickCmd = useWindowsCmd
                  ? spec.windowsQuickCommand
                  : spec.posixQuickCommand;

              return Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TxColors.bgElevated,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: enabled
                        ? TxColors.borderDefault
                        : TxColors.borderSubtle,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          spec.category.icon,
                          size: 16,
                          color: enabled ? TxColors.accent : TxColors.textMuted,
                        ),
                        const SizedBox(width: 7),
                        Expanded(
                          child: Text(
                            spec.category.title,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: enabled
                                  ? TxColors.textPrimary
                                  : TxColors.textMuted,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: 22,
                          child: Transform.scale(
                            scale: 0.74,
                            child: Switch(
                              value: enabled,
                              onChanged: (v) => widget.plugin
                                  .setCategoryEnabled(spec.category, v),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      spec.subtitle,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: TxColors.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 7),
                    Wrap(
                      spacing: 5,
                      runSpacing: 5,
                      children: [
                        for (final cmd in spec.coveredCommands)
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: TxColors.bgChrome,
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: TxColors.borderSubtle),
                            ),
                            child: Text(
                              cmd,
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textSecondary,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: SizedBox(
                            height: 34,
                            child: OutlinedButton.icon(
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              onPressed: session == null
                                  ? null
                                  : () {
                                      widget.plugin.previewCatalogSample(
                                        spec.category,
                                        session,
                                      );
                                      _dismissSheetIfModal(context);
                                      widget.pluginContext.showToast(
                                        '已在终端贴合预览「${spec.category.shortLabel}」美化卡片',
                                      );
                                    },
                              icon: const Icon(
                                Icons.visibility_outlined,
                                size: 15,
                              ),
                              label: const Text('预览卡片'),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 34,
                            child: FilledButton.tonalIcon(
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                ),
                                textStyle: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              onPressed: session == null
                                  ? null
                                  : () {
                                      _dismissSheetIfModal(context);
                                      widget.pluginContext.writeToTerminal(
                                        quickCmd,
                                      );
                                    },
                              icon: const Icon(
                                Icons.play_arrow_rounded,
                                size: 16,
                              ),
                              label: const Text('终端执行'),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildCapturedCardsList(
    SshSessionController? session,
    List<BeautifiedOutputCard> cards,
  ) {
    if (session == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            '请先打开一个本地或远程终端会话。',
            style: TextStyle(fontSize: 12, color: TxColors.textMuted),
          ),
        ),
      );
    }

    if (cards.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.auto_awesome_mosaic_outlined,
                size: 30,
                color: TxColors.textMuted,
              ),
              const SizedBox(height: 10),
              const Text(
                '当前终端暂未捕获到结构化命令输出',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: TxColors.textSecondary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                '在终端输入 docker ps、top、df -h、ipconfig、git status 等命令即可自动在终端贴合生成美化卡片。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: TxColors.textMuted),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () {
                  widget.plugin.previewCatalogSample(
                    BeautyCategoryId.containers,
                    session,
                  );
                  _dismissSheetIfModal(context);
                },
                icon: const Icon(Icons.auto_awesome_outlined, size: 14),
                label: const Text(
                  '在当前终端一键预览 docker ps 卡片',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
          child: Row(
            children: [
              Text(
                '共捕获 ${cards.length} 张命令卡片',
                style: const TextStyle(fontSize: 11, color: TxColors.textMuted),
              ),
              const Spacer(),
              TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                onPressed: () =>
                    widget.plugin.clearSessionHistory(session.sessionId),
                icon: const Icon(Icons.delete_sweep_outlined, size: 13.5),
                label: const Text('清空记录', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 12),
            itemCount: cards.length,
            separatorBuilder: (_, _) => const SizedBox(height: 6),
            itemBuilder: (context, revIdx) {
              final realIdx = cards.length - 1 - revIdx;
              final card = cards[realIdx];
              final hh = card.capturedAt.hour.toString().padLeft(2, '0');
              final mm = card.capturedAt.minute.toString().padLeft(2, '0');
              final ss = card.capturedAt.second.toString().padLeft(2, '0');

              return InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () {
                  widget.plugin.activateHistoryCard(
                    session.sessionId,
                    realIdx,
                    mode: CardDisplayMode.beautified,
                  );
                  _dismissSheetIfModal(context);
                },
                child: Container(
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: TxColors.bgElevated,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TxColors.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            card.category.icon,
                            size: 13.5,
                            color: TxColors.accent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              card.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                          Text(
                            '$hh:$mm:$ss',
                            style: const TextStyle(
                              fontSize: 10,
                              fontFamily: TxColors.monoFamily,
                              color: TxColors.textMuted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              card.command.isEmpty
                                  ? '(自动特征识别)'
                                  : '\$ ${card.command}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 10.5,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textSecondary,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: TxColors.bgChrome,
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: TxColors.borderSubtle),
                            ),
                            child: Text(
                              card.summaryBadge,
                              style: const TextStyle(
                                fontSize: 10,
                                color: TxColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
