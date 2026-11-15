import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/platform/desktop_native_bridge.dart';
import '../../core/plugin_system/plugin_interface.dart';
import '../../core/ssh/ssh_session_controller.dart';
import '../../core/theme/ui_tokens.dart';

enum TransferDirection { upload, download }

enum SftpSortField {
  name('名称'),
  modifiedTime('修改时间'),
  size('大小'),
  type('文件类型'),
  permissions('权限');

  const SftpSortField(this.label);
  final String label;
}

class SftpTransferTask {
  final String id;
  final String fileName;
  final TransferDirection direction;
  final int totalBytes;
  double progress;
  bool completed;
  String? targetNote;

  SftpTransferTask({
    required this.id,
    required this.fileName,
    required this.direction,
    required this.totalBytes,
    this.progress = 0.0,
    this.completed = false,
    this.targetNote,
  });
}

/// [核心插件 2] SFTP 可视化文件互传与远程编辑插件 (`plugin.sftp_manager`)
class SftpManagerPlugin extends TermXPlugin implements DesktopFileDropListener {
  static const String pluginId = 'plugin.sftp_manager';

  SftpManagerPlugin() {
    DesktopNativeBridge.instance.addDropListener(this);
  }

  final GlobalKey _panelBoundsKey = GlobalKey();
  SshSessionController? _session;
  PluginContext? _latestPluginContext;
  SessionConnectionState? _lastSessionState;
  final Map<String, String> _sessionPaths = {};
  final TextEditingController _pathController = TextEditingController(
    text: '/',
  );

  String _currentPath = '/';
  String? _lastDownloadDir;
  String? _lastUploadDir;
  List<RemoteFileEntry> _entries = [];
  bool _loading = false;
  bool _showHiddenFiles = true;
  SftpSortField _sortField = SftpSortField.name;
  bool _sortAscending = true;
  bool _foldersFirst = true;
  bool _isDragHovering = false;
  String? _errorMessage;
  int _loadGeneration = 0;
  final List<SftpTransferTask> _transferTasks = [];

  String get currentPath => _currentPath;
  bool get isDragHovering => _isDragHovering;
  SftpSortField get sortField => _sortField;
  bool get sortAscending => _sortAscending;
  bool get foldersFirst => _foldersFirst;

  List<RemoteFileEntry> get entries {
    final filtered = _showHiddenFiles
        ? _entries
        : _entries.where((e) => !e.name.startsWith('.'));
    return List.unmodifiable(_sortEntries(filtered));
  }

  List<SftpTransferTask> get transferTasks => List.unmodifiable(_transferTasks);

  void setSortField(SftpSortField field, {bool? ascending}) {
    if (_sortField == field && ascending == null) {
      _sortAscending = !_sortAscending;
    } else {
      _sortField = field;
      if (ascending != null) {
        _sortAscending = ascending;
      } else {
        // 首次切到按大小或按时间时，默认降序（大文件/最新修改在前）更符合直觉；名称/类型默认升序
        _sortAscending =
            field != SftpSortField.size && field != SftpSortField.modifiedTime;
      }
    }
    notifyListeners();
  }

  void setSortAscending(bool ascending) {
    if (_sortAscending == ascending) return;
    _sortAscending = ascending;
    notifyListeners();
  }

  void setFoldersFirst(bool value) {
    if (_foldersFirst == value) return;
    _foldersFirst = value;
    notifyListeners();
  }

  static String _extensionOf(RemoteFileEntry entry) {
    if (entry.isDirectory) return '';
    final name = entry.name;
    final dot = name.lastIndexOf('.');
    if (dot <= 0 || dot == name.length - 1) return '';
    return name.substring(dot + 1).toLowerCase();
  }

  List<RemoteFileEntry> _sortEntries(Iterable<RemoteFileEntry> source) {
    final list = List<RemoteFileEntry>.of(source);
    list.sort((a, b) {
      if (_foldersFirst && a.isDirectory != b.isDirectory) {
        return a.isDirectory ? -1 : 1;
      }
      int cmp;
      switch (_sortField) {
        case SftpSortField.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case SftpSortField.size:
          cmp = a.sizeBytes.compareTo(b.sizeBytes);
        case SftpSortField.modifiedTime:
          cmp = a.modifiedAt.compareTo(b.modifiedAt);
        case SftpSortField.type:
          cmp = _extensionOf(a).compareTo(_extensionOf(b));
        case SftpSortField.permissions:
          cmp = a.permissions.compareTo(b.permissions);
      }
      if (cmp == 0) {
        cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
      }
      return _sortAscending ? cmp : -cmp;
    });
    return list;
  }

  @override
  PluginManifest get manifest => const PluginManifest(
    id: pluginId,
    name: 'SFTP 文件互传管理',
    version: '1.6.0',
    author: 'TermX Core Team',
    description:
        '基于 SFTP 协议的远程文件浏览器，支持 PC 文件资源管理器直接拖拽上传（含多文件/文件夹）、下载路径自由选择、重命名、chmod 与远程在线编辑。',
    icon: Icons.folder_shared_outlined,
    accentColor: Color(0xFF7DCFFF),
    permissions: [
      PluginPermission.sshSftp,
      PluginPermission.uiStatusBar,
      PluginPermission.uiPanel,
    ],
    isCorePlugin: true,
  );

  bool get _isSessionReady {
    final s = _session;
    if (s == null || s.isDisposed || s.isLocalSession) return false;
    return s.state == SessionConnectionState.connected || s.isDemoMode;
  }

  bool _isPointInsidePanel(Offset globalPos) {
    final ctx = _panelBoundsKey.currentContext;
    if (ctx == null) return false;
    final renderObj = ctx.findRenderObject();
    if (renderObj is! RenderBox || !renderObj.hasSize || !renderObj.attached) {
      return false;
    }
    final local = renderObj.globalToLocal(globalPos);
    return renderObj.paintBounds.contains(local);
  }

  @override
  void onNativeDragEntered(Offset globalPosition) {
    final hovering = _isSessionReady && _isPointInsidePanel(globalPosition);
    if (_isDragHovering != hovering) {
      _isDragHovering = hovering;
      notifyListeners();
    }
  }

  @override
  void onNativeDragUpdated(Offset globalPosition) {
    final hovering = _isSessionReady && _isPointInsidePanel(globalPosition);
    if (_isDragHovering != hovering) {
      _isDragHovering = hovering;
      notifyListeners();
    }
  }

  @override
  void onNativeDragExited() {
    if (_isDragHovering) {
      _isDragHovering = false;
      notifyListeners();
    }
  }

  @override
  void onNativeFilesDropped(Offset globalPosition, List<String> paths) {
    final shouldAccept = _isSessionReady && _isPointInsidePanel(globalPosition);
    if (_isDragHovering) {
      _isDragHovering = false;
      notifyListeners();
    }
    if (!shouldAccept || paths.isEmpty) return;
    unawaited(uploadLocalPaths(paths, pluginContext: _latestPluginContext));
  }

  void _setPathInternal(String path, {bool persistSessionPath = true}) {
    final normalized = _normalizeRemotePath(path);
    _currentPath = normalized;
    final sid = _session?.sessionId;
    if (persistSessionPath && sid != null) {
      _sessionPaths[sid] = normalized;
    }
    if (_pathController.text != normalized) {
      _pathController.text = normalized;
    }
  }

  static String _normalizeRemotePath(String raw) {
    var p = raw.trim();
    if (p.isEmpty) return '/';
    if (!p.startsWith('/')) p = '/$p';
    while (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    return p;
  }

  static String _joinRemotePath(String parent, String child) {
    if (parent == '/' || parent.isEmpty) return '/$child';
    return parent.endsWith('/') ? '$parent$child' : '$parent/$child';
  }

  @override
  void onActiveSessionChanged(SshSessionController? session) {
    if (identical(_session, session)) return;
    _session?.removeListener(_onSessionUpdated);
    _session = session;
    _lastSessionState = session?.state;
    _isDragHovering = false;
    _errorMessage = null;

    if (session == null || session.isLocalSession) {
      _entries = [];
      _loading = false;
      notifyListeners();
      return;
    }

    session.addListener(_onSessionUpdated);
    final savedPath = _sessionPaths[session.sessionId];
    if (savedPath != null) {
      _setPathInternal(savedPath);
    } else {
      // 会话尚未连接完成时不要写入 _sessionPaths，以便连接建立后自动通过 SFTP 解析真实主目录（如 macOS 的 /Users/xxx）
      _setPathInternal(
        session.currentDirectory,
        persistSessionPath: session.isDemoMode,
      );
    }

    if (session.state == SessionConnectionState.connected ||
        session.isDemoMode) {
      unawaited(
        _initializeOrRefreshSession(session, resolveHome: savedPath == null),
      );
    } else {
      _entries = [];
      _loading = false;
      notifyListeners();
    }
  }

  void _onSessionUpdated() {
    final session = _session;
    if (session == null || session.isDisposed) return;

    final prevState = _lastSessionState;
    final currentState = session.state;
    _lastSessionState = currentState;

    if (prevState != SessionConnectionState.connected &&
        currentState == SessionConnectionState.connected) {
      final hasExplicitPath = _sessionPaths.containsKey(session.sessionId);
      unawaited(
        _initializeOrRefreshSession(session, resolveHome: !hasExplicitPath),
      );
      return;
    }

    if (session.isDemoMode && session.currentDirectory != _currentPath) {
      _setPathInternal(session.currentDirectory);
      unawaited(refreshDirectory());
      return;
    }

    if (currentState != SessionConnectionState.connected &&
        !session.isDemoMode) {
      _isDragHovering = false;
      notifyListeners();
    }
  }

  Future<void> _initializeOrRefreshSession(
    SshSessionController session, {
    required bool resolveHome,
  }) async {
    final gen = ++_loadGeneration;
    _loading = true;
    _errorMessage = null;
    notifyListeners();

    if (resolveHome) {
      try {
        final home = await session.resolveSftpHomeDirectory();
        if (gen != _loadGeneration || !identical(_session, session)) return;
        _setPathInternal(home);
      } catch (_) {}
    }
    await _loadDirectoryWithGen(session, gen);

    // 若初始默认猜测为 /home/<user> 但远端为 macOS (/Users/<user>) 导致路径不存在，自动尝试 /Users/<user>
    if (resolveHome &&
        gen == _loadGeneration &&
        identical(_session, session) &&
        _errorMessage != null &&
        _currentPath == '/home/${session.host.username}') {
      final macCandidate = '/Users/${session.host.username}';
      try {
        final list = await session.listDirectory(macCandidate);
        if (gen != _loadGeneration || !identical(_session, session)) return;
        _setPathInternal(macCandidate);
        _entries = list;
        _errorMessage = null;
        _loading = false;
        notifyListeners();
      } catch (_) {}
    }
  }

  Future<void> refreshDirectory() async {
    final session = _session;
    if (session == null || session.isLocalSession) {
      _entries = [];
      _loading = false;
      _errorMessage = null;
      notifyListeners();
      return;
    }
    if (session.state != SessionConnectionState.connected &&
        !session.isDemoMode) {
      _entries = [];
      _loading = false;
      notifyListeners();
      return;
    }
    final gen = ++_loadGeneration;
    _loading = true;
    _errorMessage = null;
    notifyListeners();
    await _loadDirectoryWithGen(session, gen);
  }

  Future<void> _loadDirectoryWithGen(
    SshSessionController session,
    int gen,
  ) async {
    try {
      final list = await session.listDirectory(_currentPath);
      if (gen != _loadGeneration || !identical(_session, session)) return;
      _entries = list;
      _errorMessage = null;
    } catch (e) {
      if (gen != _loadGeneration || !identical(_session, session)) return;
      _entries = [];
      _errorMessage = _friendlySftpError(e);
    } finally {
      if (gen == _loadGeneration && identical(_session, session)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  String _friendlySftpError(Object error) {
    final raw = error.toString();
    final lower = raw.toLowerCase();
    if (lower.contains('permission denied') || lower.contains('code 3')) {
      return '权限不足 (Permission denied)：当前登录账号无权访问 $_currentPath';
    }
    if (lower.contains('no such file') || lower.contains('code 2')) {
      return '路径不存在 (No such file)：$_currentPath';
    }
    return 'SFTP 操作失败：$raw';
  }

  Future<void> navigateTo(String path) async {
    final trimmed = path.trim();
    final session = _session;
    if (session != null && (trimmed == '~' || trimmed.startsWith('~/'))) {
      try {
        final home = await session.resolveSftpHomeDirectory();
        final suffix = trimmed.length > 1 ? trimmed.substring(1) : '';
        _setPathInternal('$home$suffix');
        await refreshDirectory();
        return;
      } catch (_) {}
    }
    _setPathInternal(trimmed);
    await refreshDirectory();
  }

  Future<void> navigateHome() async {
    final session = _session;
    if (session == null) return;
    try {
      final home = await session.resolveSftpHomeDirectory();
      await navigateTo(home);
    } catch (_) {
      await navigateTo('/');
    }
  }

  Future<void> navigateUp() async {
    final normalized = _normalizeRemotePath(_currentPath);
    if (normalized == '/') return;
    final idx = normalized.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : normalized.substring(0, idx);
    await navigateTo(parent);
  }

  /// 支持单文件、多文件与本地文件夹递归流式上传（供 PC 拖拽上传与文件选择框共用）
  Future<void> uploadLocalPaths(
    List<String> localPaths, {
    PluginContext? pluginContext,
    String? targetRemoteDir,
  }) async {
    final session = _session;
    if (session == null || !_isSessionReady) return;
    final destDir = targetRemoteDir ?? _currentPath;
    int uploadedFiles = 0;

    Future<void> uploadEntity(String localPath, String remoteDir) async {
      final type = FileSystemEntity.typeSync(localPath);
      final baseName = localPath
          .replaceAll(RegExp(r'[/\\]+$'), '')
          .split(RegExp(r'[/\\]'))
          .last;
      if (baseName.isEmpty) return;

      if (type == FileSystemEntityType.directory) {
        try {
          await session.createRemoteDirectory(remoteDir, baseName);
        } catch (_) {
          // 远端同名文件夹已存在时继续向内上传子文件
        }
        final childRemoteDir = _joinRemotePath(remoteDir, baseName);
        final children = Directory(localPath).listSync(followLinks: false);
        for (final child in children) {
          await uploadEntity(child.path, childRemoteDir);
        }
        return;
      }

      if (type == FileSystemEntityType.file) {
        final file = File(localPath);
        final length = file.lengthSync();
        final task = SftpTransferTask(
          id: '${DateTime.now().microsecondsSinceEpoch}_$uploadedFiles',
          fileName: baseName,
          direction: TransferDirection.upload,
          totalBytes: length,
          targetNote: _joinRemotePath(remoteDir, baseName),
        );
        _transferTasks.insert(0, task);
        notifyListeners();

        try {
          await session.uploadLocalFile(
            localFile: file,
            remoteDirPath: remoteDir,
            remoteFileName: baseName,
            onProgress: (p) {
              task.progress = p;
              if (p >= 1.0) task.completed = true;
              notifyListeners();
            },
          );
          task.progress = 1.0;
          task.completed = true;
          uploadedFiles++;
          notifyListeners();
        } catch (e) {
          _transferTasks.remove(task);
          notifyListeners();
          pluginContext?.showToast(
            '上传 $baseName 失败: ${_friendlySftpError(e)}',
          );
        }
      }
    }

    for (final p in localPaths) {
      final trimmed = p.trim();
      if (trimmed.isEmpty) continue;
      _lastUploadDir = File(trimmed).parent.path;
      await uploadEntity(trimmed, destDir);
    }

    await refreshDirectory();
    if (uploadedFiles > 0) {
      pluginContext?.showToast(
        uploadedFiles == 1
            ? 'SFTP 上传完成 -> $destDir'
            : 'SFTP 批量上传完成（共 $uploadedFiles 个文件） -> $destDir',
      );
    }
  }

  Future<void> uploadBytesFile({
    required String fileName,
    required Uint8List bytes,
    required PluginContext pluginContext,
  }) async {
    final session = _session;
    if (session == null) return;

    final task = SftpTransferTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fileName: fileName,
      direction: TransferDirection.upload,
      totalBytes: bytes.length,
      targetNote: _joinRemotePath(_currentPath, fileName),
    );
    _transferTasks.insert(0, task);
    notifyListeners();

    try {
      await session.uploadBytes(
        remoteDirPath: _currentPath,
        fileName: fileName,
        bytes: bytes,
        onProgress: (p) {
          task.progress = p;
          if (p >= 1.0) task.completed = true;
          notifyListeners();
        },
      );
      task.progress = 1.0;
      task.completed = true;
      await refreshDirectory();
      pluginContext.showToast('SFTP 上传完成: $fileName -> $_currentPath');
    } catch (e) {
      _transferTasks.remove(task);
      notifyListeners();
      pluginContext.showToast('SFTP 上传失败: ${_friendlySftpError(e)}');
    }
  }

  Directory _resolveDefaultDownloadDirectory() {
    if (Platform.isWindows) {
      final profile = Platform.environment['USERPROFILE'];
      if (profile != null && profile.isNotEmpty) {
        final downloads = Directory('$profile\\Downloads');
        if (downloads.existsSync()) return downloads;
      }
    } else {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        final downloads = Directory('$home/Downloads');
        if (downloads.existsSync()) return downloads;
      }
    }
    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}TermX_Downloads',
    );
  }

  Future<String?> _chooseSaveFilePath(
    BuildContext context,
    String suggestedName,
  ) async {
    final defaultDir = _lastDownloadDir ?? _resolveDefaultDownloadDirectory().path;
    if (DesktopNativeBridge.instance.supportsNativeDialogs) {
      return DesktopNativeBridge.instance.saveFileDialog(
        suggestedName: suggestedName,
        initialDirectory: defaultDir,
      );
    }

    // 非 Windows 平台提供手动路径选择弹窗
    final defaultFullPath =
        '$defaultDir${Platform.pathSeparator}$suggestedName';
    final ctrl = TextEditingController(text: defaultFullPath);
    final chosen = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1F2335),
        title: const Text('选择下载保存路径', style: TextStyle(fontSize: 15)),
        content: SizedBox(
          width: 420,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '保存到本地完整路径',
              isDense: true,
            ),
            onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(ctrl.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    ctrl.dispose();
    if (chosen == null || chosen.isEmpty) return null;
    return chosen;
  }

  /// 下载远程单个文件（弹出本地保存路径选择框）
  Future<void> downloadRemoteFile(
    BuildContext context,
    RemoteFileEntry entry,
    PluginContext pluginContext,
  ) async {
    final session = _session;
    if (session == null) return;

    final chosenPath = await _chooseSaveFilePath(context, entry.name);
    if (chosenPath == null || chosenPath.trim().isEmpty) {
      // 用户取消了保存路径选择
      return;
    }

    final outFile = File(chosenPath);
    _lastDownloadDir = outFile.parent.path;

    final task = SftpTransferTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      fileName: entry.name,
      direction: TransferDirection.download,
      totalBytes: entry.sizeBytes,
      targetNote: outFile.path,
    );
    _transferTasks.insert(0, task);
    notifyListeners();

    try {
      await session.downloadRemoteFileToLocal(
        entry: entry,
        destinationFile: outFile,
        onProgress: (p) {
          task.progress = p;
          notifyListeners();
        },
      );
      task.progress = 1.0;
      task.completed = true;
      task.targetNote = outFile.path;
      pluginContext.showToast('已下载保存至: ${outFile.path}');
    } catch (e) {
      _transferTasks.remove(task);
      pluginContext.showToast('SFTP 下载失败: ${_friendlySftpError(e)}');
    }
    notifyListeners();
  }

  /// 下载远程整个文件夹到本地选择的目录
  Future<void> downloadRemoteDirectory(
    BuildContext context,
    RemoteFileEntry folderEntry,
    PluginContext pluginContext,
  ) async {
    final session = _session;
    if (session == null || !folderEntry.isDirectory) return;

    final defaultDir = _lastDownloadDir ?? _resolveDefaultDownloadDirectory().path;
    String? parentLocalDir;
    if (DesktopNativeBridge.instance.supportsNativeDialogs) {
      parentLocalDir = await DesktopNativeBridge.instance.pickDirectoryDialog(
        initialDirectory: defaultDir,
      );
    } else {
      parentLocalDir = await _chooseSaveFilePath(context, folderEntry.name);
    }
    if (parentLocalDir == null || parentLocalDir.trim().isEmpty) return;
    _lastDownloadDir = parentLocalDir;

    final rootLocalDir = Directory(
      '$parentLocalDir${Platform.pathSeparator}${folderEntry.name}',
    );
    int downloadedCount = 0;

    Future<void> walkAndDownload(String remoteDir, Directory localDir) async {
      await localDir.create(recursive: true);
      final items = await session.listDirectory(remoteDir);
      for (final item in items) {
        if (item.isDirectory) {
          await walkAndDownload(
            item.fullPath,
            Directory('${localDir.path}${Platform.pathSeparator}${item.name}'),
          );
        } else {
          final targetFile = File(
            '${localDir.path}${Platform.pathSeparator}${item.name}',
          );
          final task = SftpTransferTask(
            id: '${DateTime.now().microsecondsSinceEpoch}_$downloadedCount',
            fileName: item.name,
            direction: TransferDirection.download,
            totalBytes: item.sizeBytes,
            targetNote: targetFile.path,
          );
          _transferTasks.insert(0, task);
          notifyListeners();

          await session.downloadRemoteFileToLocal(
            entry: item,
            destinationFile: targetFile,
            onProgress: (p) {
              task.progress = p;
              notifyListeners();
            },
          );
          task.progress = 1.0;
          task.completed = true;
          downloadedCount++;
          notifyListeners();
        }
      }
    }

    try {
      await walkAndDownload(folderEntry.fullPath, rootLocalDir);
      pluginContext.showToast(
        '文件夹已下载至: ${rootLocalDir.path}（共 $downloadedCount 个文件）',
      );
    } catch (e) {
      pluginContext.showToast('文件夹下载失败: ${_friendlySftpError(e)}');
    }
  }

  Future<void> _revealInExplorer(String path) async {
    if (!Platform.isWindows || path.isEmpty) return;
    try {
      if (File(path).existsSync()) {
        await Process.run('explorer.exe', ['/select,$path']);
      } else if (Directory(path).existsSync()) {
        await Process.run('explorer.exe', [path]);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    DesktopNativeBridge.instance.removeDropListener(this);
    _session?.removeListener(_onSessionUpdated);
    _pathController.dispose();
    super.dispose();
  }

  @override
  Widget buildStatusBarWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) {
    if (pluginContext.activeSession?.isLocalSession == true) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        final activeCount = _transferTasks.where((t) => !t.completed).length;
        final visibleCount = entries.length;
        return InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: () => pluginContext.requestOpenPanel(pluginId),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.folder_open_outlined,
                  size: 12,
                  color: activeCount > 0 ? TxColors.accent : TxColors.textMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  activeCount > 0
                      ? 'SFTP 传输中 ($activeCount)'
                      : 'SFTP $_currentPath ($visibleCount)',
                  style: TextStyle(
                    fontSize: 10.5,
                    fontFamily: TxColors.monoFamily,
                    color: activeCount > 0
                        ? TxColors.accent
                        : TxColors.textMuted,
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
  Widget buildPanelWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) {
    _latestPluginContext = pluginContext;
    final activeSession = pluginContext.activeSession;
    if (activeSession == null) {
      return const Center(
        child: Text(
          '请先连接一个远程 SSH 会话',
          style: TextStyle(fontSize: 12, color: TxColors.textMuted),
        ),
      );
    }
    if (activeSession.isLocalSession) {
      return localSessionNotice();
    }
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        final session = _session ?? activeSession;
        final connected =
            session.state == SessionConnectionState.connected ||
            session.isDemoMode;
        final visibleEntries = entries;

        return Container(
          key: _panelBoundsKey,
          child: Stack(
            children: [
              Column(
                children: [
                  // 顶部路径导航与操作栏（统一灰阶单色工具栏图标）
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 5,
                    ),
                    decoration: const BoxDecoration(
                      color: TxColors.bgSidebar,
                      border: Border(
                        bottom: BorderSide(color: TxColors.borderSubtle),
                      ),
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '返回上级目录 (..)',
                          icon: const Icon(
                            Icons.arrow_upward_rounded,
                            size: 15,
                            color: TxColors.iconDefault,
                          ),
                          onPressed: connected && _currentPath != '/'
                              ? navigateUp
                              : null,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '回到用户主目录 (~)',
                          icon: const Icon(
                            Icons.home_outlined,
                            size: 15,
                            color: TxColors.iconDefault,
                          ),
                          onPressed: connected ? navigateHome : null,
                        ),
                        const SizedBox(width: 2),
                        Expanded(
                          child: SizedBox(
                            height: 26,
                            child: TextField(
                              controller: _pathController,
                              enabled: connected,
                              style: const TextStyle(
                                fontSize: 11.5,
                                fontFamily: TxColors.monoFamily,
                                color: TxColors.textPrimary,
                              ),
                              decoration: InputDecoration(
                                isDense: true,
                                hintText: '/home/user',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                filled: true,
                                fillColor: TxColors.bgChrome,
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(5),
                                  borderSide: const BorderSide(
                                    color: TxColors.borderSubtle,
                                  ),
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(5),
                                  borderSide: const BorderSide(
                                    color: TxColors.borderSubtle,
                                  ),
                                ),
                              ),
                              onSubmitted: (val) => navigateTo(val),
                            ),
                          ),
                        ),
                        const SizedBox(width: 2),
                        _buildSortPopupMenuButton(),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: _showHiddenFiles
                              ? '隐藏点文件 (.*)'
                              : '显示隐藏文件 (.*)',
                          icon: Icon(
                            _showHiddenFiles
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 15,
                            color: _showHiddenFiles
                                ? TxColors.textPrimary
                                : TxColors.iconDefault,
                          ),
                          onPressed: () {
                            _showHiddenFiles = !_showHiddenFiles;
                            notifyListeners();
                          },
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '选择本地文件上传 (支持多选)',
                          icon: const Icon(
                            Icons.file_upload_outlined,
                            size: 16,
                            color: TxColors.iconDefault,
                          ),
                          onPressed: connected
                              ? () => _handleToolbarUpload(
                                  context,
                                  pluginContext,
                                )
                              : null,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '新建文件夹 (mkdir)',
                          icon: const Icon(
                            Icons.create_new_folder_outlined,
                            size: 15.5,
                            color: TxColors.iconDefault,
                          ),
                          onPressed: connected
                              ? () => _showNewFolderDialog(
                                  context,
                                  pluginContext,
                                )
                              : null,
                        ),
                        IconButton(
                          visualDensity: VisualDensity.compact,
                          constraints: const BoxConstraints(
                            minWidth: 26,
                            minHeight: 26,
                          ),
                          padding: EdgeInsets.zero,
                          tooltip: '刷新远端目录',
                          icon: const Icon(
                            Icons.refresh_rounded,
                            size: 15.5,
                            color: TxColors.iconDefault,
                          ),
                          onPressed: connected ? refreshDirectory : null,
                        ),
                      ],
                    ),
                  ),

                  // 拖拽上传提示条（克制中性灰底，拖拽悬停时再激活蓝色边框）
                  if (connected)
                    InkWell(
                      onTap: () => _handleToolbarUpload(context, pluginContext),
                      child: Container(
                        margin: const EdgeInsets.fromLTRB(8, 6, 8, 4),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 9,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: _isDragHovering
                              ? TxColors.accentSoft
                              : TxColors.bgPanel,
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: _isDragHovering
                                ? TxColors.accent
                                : TxColors.borderSubtle,
                          ),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.upload_rounded,
                              size: 14,
                              color: _isDragHovering
                                  ? TxColors.accent
                                  : TxColors.textMuted,
                            ),
                            const SizedBox(width: 6),
                            const Expanded(
                              child: Text(
                                '拖入文件或文件夹上传，或点击选择',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: TxColors.textSecondary,
                                ),
                              ),
                            ),
                            InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: () => _showTextUploadDialog(
                                context,
                                pluginContext,
                              ),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1,
                                ),
                                child: Text(
                                  '新建文件',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: TxColors.accent,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  // 可点击排序表头栏
                  if (connected && !_loading && _errorMessage == null)
                    _buildSortHeaderBar(visibleEntries.length),

                  // 远端文件列表与状态视图
                  Expanded(
                    child: !connected
                        ? _buildDisconnectedState(session)
                        : _loading
                        ? const Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        : _errorMessage != null
                        ? _buildErrorState()
                        : visibleEntries.isEmpty
                        ? const Center(
                            child: Text(
                              '当前目录为空（可将本地文件直接拖入此处上传）',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: TxColors.textMuted,
                              ),
                            ),
                          )
                        : ListView.separated(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 4,
                            ),
                            itemCount: visibleEntries.length,
                            separatorBuilder: (_, __) => const Divider(
                              height: 1,
                              color: TxColors.borderSubtle,
                            ),
                            itemBuilder: (context, idx) {
                              final item = visibleEntries[idx];
                              return ListTile(
                                dense: true,
                                visualDensity: VisualDensity.compact,
                                contentPadding: const EdgeInsets.only(
                                  left: 8,
                                  right: 2,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(5),
                                ),
                                leading: Icon(
                                  item.isDirectory
                                      ? Icons.folder_rounded
                                      : Icons.insert_drive_file_outlined,
                                  color: item.isDirectory
                                      ? TxColors.folderAmber
                                      : TxColors.fileSlate,
                                  size: 18,
                                ),
                                title: Text(
                                  item.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                    color: TxColors.textPrimary,
                                  ),
                                ),
                                subtitle: Text(
                                  '${item.permissions}  ·  ${item.isDirectory ? '<DIR>' : _formatSize(item.sizeBytes)}  ·  ${_formatModifiedTime(item.modifiedAt)}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 10,
                                    fontFamily: TxColors.monoFamily,
                                    color: TxColors.textMuted,
                                  ),
                                ),
                                onTap: () {
                                  if (item.isDirectory) {
                                    navigateTo(item.fullPath);
                                  } else {
                                    _openRemoteEditorDialog(
                                      context,
                                      item,
                                      pluginContext,
                                    );
                                  }
                                },
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      constraints: const BoxConstraints(
                                        minWidth: 28,
                                        minHeight: 28,
                                      ),
                                      padding: EdgeInsets.zero,
                                      tooltip: item.isDirectory
                                          ? '下载此文件夹到本地（选择目录）…'
                                          : '下载到本地（选择保存路径）…',
                                      icon: const Icon(
                                        Icons.download_rounded,
                                        size: 15,
                                        color: TxColors.iconDefault,
                                      ),
                                      onPressed: () {
                                        if (item.isDirectory) {
                                          downloadRemoteDirectory(
                                            context,
                                            item,
                                            pluginContext,
                                          );
                                        } else {
                                          downloadRemoteFile(
                                            context,
                                            item,
                                            pluginContext,
                                          );
                                        }
                                      },
                                    ),
                                    PopupMenuButton<String>(
                                      tooltip: '更多文件操作',
                                      padding: EdgeInsets.zero,
                                      icon: const Icon(
                                        Icons.more_horiz_rounded,
                                        size: 15.5,
                                        color: TxColors.textMuted,
                                      ),
                                      onSelected: (action) {
                                        switch (action) {
                                          case 'open':
                                            if (item.isDirectory) {
                                              navigateTo(item.fullPath);
                                            } else {
                                              _openRemoteEditorDialog(
                                                context,
                                                item,
                                                pluginContext,
                                              );
                                            }
                                          case 'download':
                                            if (item.isDirectory) {
                                              downloadRemoteDirectory(
                                                context,
                                                item,
                                                pluginContext,
                                              );
                                            } else {
                                              downloadRemoteFile(
                                                context,
                                                item,
                                                pluginContext,
                                              );
                                            }
                                          case 'rename':
                                            _showRenameDialog(
                                              context,
                                              item,
                                              pluginContext,
                                            );
                                          case 'chmod':
                                            _showChmodDialog(
                                              context,
                                              item,
                                              pluginContext,
                                            );
                                          case 'delete':
                                            _confirmDeleteDialog(
                                              context,
                                              item,
                                              pluginContext,
                                            );
                                        }
                                      },
                                      itemBuilder: (ctx) => [
                                        PopupMenuItem(
                                          value: 'open',
                                          child: Text(
                                            item.isDirectory
                                                ? '打开文件夹'
                                                : '编辑文本文件',
                                            style: const TextStyle(
                                              fontSize: 12.5,
                                            ),
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: 'download',
                                          child: Text(
                                            item.isDirectory
                                                ? '下载文件夹到本地…'
                                                : '下载到本地（选择路径）…',
                                            style: const TextStyle(
                                              fontSize: 12.5,
                                            ),
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'rename',
                                          child: Text(
                                            '重命名',
                                            style: TextStyle(fontSize: 12.5),
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'chmod',
                                          child: Text(
                                            '修改权限 (chmod)',
                                            style: TextStyle(fontSize: 12.5),
                                          ),
                                        ),
                                        const PopupMenuDivider(),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Text(
                                            '删除',
                                            style: TextStyle(
                                              fontSize: 12.5,
                                              color: TxColors.danger,
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

                  // 底部传输队列状态栏
                  if (_transferTasks.isNotEmpty)
                    Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      padding: const EdgeInsets.all(8),
                      decoration: const BoxDecoration(
                        color: TxColors.bgChrome,
                        border: Border(
                          top: BorderSide(color: TxColors.borderSubtle),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                '传输队列 (${_transferTasks.length})',
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: TxColors.textSecondary,
                                ),
                              ),
                              InkWell(
                                onTap: () {
                                  _transferTasks.clear();
                                  notifyListeners();
                                },
                                child: const Text(
                                  '清空',
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    color: TxColors.textMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Expanded(
                            child: ListView.builder(
                              itemCount: _transferTasks.length,
                              itemBuilder: (context, i) {
                                final t = _transferTasks[i];
                                final canReveal =
                                    Platform.isWindows &&
                                    t.direction == TransferDirection.download &&
                                    t.completed &&
                                    t.targetNote != null;
                                return Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 2,
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(
                                        t.direction == TransferDirection.upload
                                            ? Icons.arrow_upward_rounded
                                            : Icons.arrow_downward_rounded,
                                        size: 12.5,
                                        color: t.completed
                                            ? TxColors.success
                                            : TxColors.accent,
                                      ),
                                      const SizedBox(width: 5),
                                      Expanded(
                                        child: Tooltip(
                                          message: t.targetNote ?? t.fileName,
                                          child: Text(
                                            t.fileName,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: TxColors.textPrimary,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      SizedBox(
                                        width: 56,
                                        child: LinearProgressIndicator(
                                          value: t.progress,
                                          minHeight: 3.5,
                                          backgroundColor:
                                              TxColors.borderSubtle,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                t.completed
                                                    ? TxColors.success
                                                    : TxColors.accent,
                                              ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${(t.progress * 100).toStringAsFixed(0)}%',
                                        style: const TextStyle(
                                          fontSize: 10,
                                          fontFamily: TxColors.monoFamily,
                                          color: TxColors.textMuted,
                                        ),
                                      ),
                                      if (canReveal) ...[
                                        const SizedBox(width: 4),
                                        InkWell(
                                          onTap: () =>
                                              _revealInExplorer(t.targetNote!),
                                          child: const Tooltip(
                                            message: '在资源管理器中定位文件',
                                            child: Icon(
                                              Icons.folder_open_rounded,
                                              size: 13,
                                              color: TxColors.iconDefault,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),

              // PC 文件拖拽悬停高亮感应蒙层
              if (_isDragHovering && connected)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      margin: const EdgeInsets.all(6),
                      decoration: BoxDecoration(
                        color: TxColors.bgChrome.withValues(alpha: 0.90),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: TxColors.accent,
                          width: 1.5,
                        ),
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.upload_file_rounded,
                                size: 38,
                                color: TxColors.accent,
                              ),
                              const SizedBox(height: 10),
                              Text(
                                '松开鼠标上传至 $_currentPath',
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: TxColors.textPrimary,
                                ),
                              ),
                              const SizedBox(height: 4),
                              const Text(
                                '支持单文件、多文件与整个文件夹递归上传',
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: TxColors.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDisconnectedState(SshSessionController session) {
    final connecting =
        session.state == SessionConnectionState.connecting ||
        session.state == SessionConnectionState.reconnecting;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (connecting)
              const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              const Icon(
                Icons.cloud_off_rounded,
                size: 28,
                color: TxColors.textMuted,
              ),
            const SizedBox(height: 10),
            Text(
              connecting
                  ? '正在建立 SSH / SFTP 通道，连接后将自动加载文件列表…'
                  : '当前 SSH 会话未连接，重新连接后即可浏览远程文件',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: TxColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.folder_off_outlined,
              size: 28,
              color: TxColors.danger,
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? '无法访问当前目录',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: TxColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                if (_currentPath != '/')
                  OutlinedButton.icon(
                    onPressed: navigateUp,
                    icon: const Icon(Icons.arrow_upward_rounded, size: 15),
                    label: const Text('返回上级', style: TextStyle(fontSize: 12)),
                  ),
                FilledButton.tonalIcon(
                  onPressed: navigateHome,
                  icon: const Icon(Icons.home_outlined, size: 15),
                  label: const Text('回到主目录 (~)', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  Future<void> _handleToolbarUpload(
    BuildContext context,
    PluginContext pluginContext,
  ) async {
    if (DesktopNativeBridge.instance.supportsNativeDialogs) {
      final picked = await DesktopNativeBridge.instance.pickFilesDialog(
        allowMultiple: true,
        initialDirectory: _lastUploadDir,
      );
      if (picked.isNotEmpty) {
        await uploadLocalPaths(picked, pluginContext: pluginContext);
      }
      return;
    }
    if (context.mounted) {
      await _showTextUploadDialog(context, pluginContext);
    }
  }

  Future<void> _showTextUploadDialog(
    BuildContext context,
    PluginContext pluginContext,
  ) async {
    final nameCtrl = TextEditingController();
    final contentCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '在 $_currentPath 新建文本文件',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 430,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: '远端文件名',
                  hintText: '例如 config.yaml',
                  isDense: true,
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: contentCtrl,
                maxLines: 6,
                style: const TextStyle(
                  fontFamily: TxColors.monoFamily,
                  fontSize: 12,
                ),
                decoration: const InputDecoration(
                  labelText: '文件内容',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            onPressed: () async {
              var fileName = nameCtrl.text.trim();
              if (fileName.isEmpty) fileName = 'new_file.txt';
              final bytes = Uint8List.fromList(utf8.encode(contentCtrl.text));
              Navigator.of(ctx).pop();
              await uploadBytesFile(
                fileName: fileName,
                bytes: bytes,
                pluginContext: pluginContext,
              );
            },
            icon: const Icon(Icons.upload_rounded, size: 15),
            label: const Text('保存并上传'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    nameCtrl.dispose();
    contentCtrl.dispose();
  }

  Future<void> _showNewFolderDialog(
    BuildContext context,
    PluginContext pluginContext,
  ) async {
    final ctrl = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '新建远程文件夹',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '文件夹名称',
            hintText: '例如 logs',
          ),
          onSubmitted: (val) => Navigator.of(ctx).pop(val),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final name = ctrl.text.trim();
              Navigator.of(ctx).pop();
              if (name.isEmpty) return;
              try {
                await _session?.createRemoteDirectory(_currentPath, name);
                await refreshDirectory();
                pluginContext.showToast('已创建远程目录: $name');
              } catch (e) {
                pluginContext.showToast('创建失败: ${_friendlySftpError(e)}');
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    ctrl.dispose();
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    RemoteFileEntry entry,
    PluginContext pluginContext,
  ) async {
    final ctrl = TextEditingController(text: entry.name);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          '重命名 — ${entry.name}',
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(labelText: '新名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final newName = ctrl.text.trim();
              Navigator.of(ctx).pop();
              if (newName.isEmpty || newName == entry.name) return;
              try {
                await _session?.renameRemoteEntry(_currentPath, entry, newName);
                await refreshDirectory();
                pluginContext.showToast('已重命名为: $newName');
              } catch (e) {
                pluginContext.showToast('重命名失败: ${_friendlySftpError(e)}');
              }
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    ctrl.dispose();
  }

  Future<void> _confirmDeleteDialog(
    BuildContext context,
    RemoteFileEntry entry,
    PluginContext pluginContext,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '删除远端项目',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Text(
          '确定要永久删除远端${entry.isDirectory ? "空文件夹" : "文件"} "${entry.fullPath}" 吗？',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TxColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _session?.deleteRemoteEntry(_currentPath, entry);
      await refreshDirectory();
      pluginContext.showToast('已删除: ${entry.name}');
    } catch (e) {
      pluginContext.showToast('删除失败: ${_friendlySftpError(e)}');
    }
  }

  Future<void> _openRemoteEditorDialog(
    BuildContext context,
    RemoteFileEntry entry,
    PluginContext pluginContext,
  ) async {
    final session = _session;
    if (session == null) return;
    if (entry.sizeBytes > 2 * 1024 * 1024) {
      pluginContext.showToast('文件超过 2 MB，请点击下载图标保存到本地查看');
      return;
    }
    String initialText;
    try {
      initialText = await session.readRemoteTextFile(entry);
    } catch (e) {
      pluginContext.showToast('无法读取文件: ${_friendlySftpError(e)}');
      return;
    }
    if (!context.mounted) return;
    final ctrl = TextEditingController(text: initialText);

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            const Icon(
              Icons.description_outlined,
              size: 17,
              color: TxColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                entry.fullPath,
                style: const TextStyle(
                  fontSize: 13.5,
                  fontFamily: TxColors.monoFamily,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 600,
          height: 380,
          child: TextField(
            controller: ctrl,
            maxLines: null,
            expands: true,
            style: const TextStyle(
              fontFamily: TxColors.monoFamily,
              fontSize: 12.5,
              color: TxColors.textPrimary,
            ),
            decoration: const InputDecoration(
              filled: true,
              fillColor: TxColors.bgChrome,
              border: OutlineInputBorder(),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('关闭'),
          ),
          FilledButton.icon(
            onPressed: () async {
              try {
                await session.writeRemoteTextFile(
                  _currentPath,
                  entry.name,
                  ctrl.text,
                );
                if (ctx.mounted) Navigator.of(ctx).pop();
                await refreshDirectory();
                pluginContext.showToast('已保存并回传服务器: ${entry.name}');
              } catch (e) {
                pluginContext.showToast('保存失败: ${_friendlySftpError(e)}');
              }
            },
            icon: const Icon(Icons.save_outlined, size: 15),
            label: const Text('保存到远端'),
          ),
        ],
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 220));
    ctrl.dispose();
  }

  Future<void> _showChmodDialog(
    BuildContext context,
    RemoteFileEntry entry,
    PluginContext pluginContext,
  ) async {
    String selectedPerm = entry.permissions;
    final prefix = entry.isDirectory ? 'd' : '-';
    final presets = [
      ('${prefix}rwxr-xr-x', '755 (可执行脚本 / 标准目录)'),
      ('${prefix}rw-r--r--', '644 (标准配置文件)'),
      ('${prefix}rw-------', '600 (仅所有者读写 / 密钥)'),
      ('${prefix}rwxrwxrwx', '777 (全开放权限)'),
    ];

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(
            '修改权限 (chmod) — ${entry.name}',
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: presets.map((p) {
              final isSelected = selectedPerm == p.$1;
              return ListTile(
                dense: true,
                leading: Icon(
                  isSelected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  color: isSelected ? TxColors.accent : TxColors.textMuted,
                  size: 17,
                ),
                title: Text(p.$2, style: const TextStyle(fontSize: 12.5)),
                subtitle: Text(
                  p.$1,
                  style: const TextStyle(
                    fontFamily: TxColors.monoFamily,
                    fontSize: 11,
                    color: TxColors.textMuted,
                  ),
                ),
                onTap: () => setState(() => selectedPerm = p.$1),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.of(ctx).pop();
                try {
                  await _session?.chmodRemoteEntry(
                    _currentPath,
                    entry,
                    selectedPerm,
                  );
                  await refreshDirectory();
                  pluginContext.showToast(
                    '已更新 ${entry.name} 权限为 $selectedPerm',
                  );
                } catch (e) {
                  pluginContext.showToast('修改权限失败: ${_friendlySftpError(e)}');
                }
              },
              child: const Text('应用权限'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSortPopupMenuButton() {
    return PopupMenuButton<String>(
      tooltip:
          '排序方式：按${_sortField.label} (${_sortAscending ? '升序' : '降序'})',
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 165),
      icon: const Icon(
        Icons.sort_rounded,
        size: 15.5,
        color: TxColors.iconDefault,
      ),
      onSelected: (val) {
        switch (val) {
          case 'field:name':
            setSortField(SftpSortField.name);
          case 'field:modifiedTime':
            setSortField(SftpSortField.modifiedTime);
          case 'field:size':
            setSortField(SftpSortField.size);
          case 'field:type':
            setSortField(SftpSortField.type);
          case 'field:permissions':
            setSortField(SftpSortField.permissions);
          case 'dir:asc':
            setSortAscending(true);
          case 'dir:desc':
            setSortAscending(false);
          case 'opt:foldersFirst':
            setFoldersFirst(!_foldersFirst);
        }
      },
      itemBuilder: (context) => [
        for (final f in SftpSortField.values)
          PopupMenuItem<String>(
            value: 'field:${f.name}',
            height: 32,
            child: Row(
              children: [
                Icon(
                  _sortField == f ? Icons.check_rounded : null,
                  size: 14,
                  color: TxColors.accent,
                ),
                const SizedBox(width: 8),
                Text('按${f.label}排序', style: const TextStyle(fontSize: 12.5)),
              ],
            ),
          ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'dir:asc',
          height: 32,
          child: Row(
            children: [
              Icon(
                _sortAscending ? Icons.check_rounded : null,
                size: 14,
                color: TxColors.accent,
              ),
              const SizedBox(width: 8),
              const Text('升序排列 (↑)', style: TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: 'dir:desc',
          height: 32,
          child: Row(
            children: [
              Icon(
                !_sortAscending ? Icons.check_rounded : null,
                size: 14,
                color: TxColors.accent,
              ),
              const SizedBox(width: 8),
              const Text('降序排列 (↓)', style: TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          value: 'opt:foldersFirst',
          height: 32,
          child: Row(
            children: [
              Icon(
                _foldersFirst
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 14.5,
                color: _foldersFirst ? TxColors.accent : TxColors.textMuted,
              ),
              const SizedBox(width: 8),
              const Text('文件夹始终置顶', style: TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSortHeaderBar(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: const BoxDecoration(
        color: TxColors.bgSidebar,
        border: Border(bottom: BorderSide(color: TxColors.borderSubtle)),
      ),
      child: Row(
        children: [
          _buildSortChip(SftpSortField.name, '名称'),
          const SizedBox(width: 4),
          _buildSortChip(SftpSortField.size, '大小'),
          const SizedBox(width: 4),
          _buildSortChip(SftpSortField.modifiedTime, '时间'),
          const SizedBox(width: 4),
          _buildSortChip(SftpSortField.type, '类型'),
          const Spacer(),
          Text(
            '$count 项',
            style: const TextStyle(fontSize: 10.5, color: TxColors.textMuted),
          ),
        ],
      ),
    );
  }

  Widget _buildSortChip(SftpSortField field, String label) {
    final active = _sortField == field;
    final arrow = active ? (_sortAscending ? ' ↑' : ' ↓') : '';
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => setSortField(field),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: active ? TxColors.bgElevated : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: active ? TxColors.borderDefault : Colors.transparent,
          ),
        ),
        child: Text(
          '$label$arrow',
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            color: active ? TxColors.textPrimary : TxColors.textMuted,
          ),
        ),
      ),
    );
  }

  static String _formatModifiedTime(DateTime dt) {
    final local = dt.toLocal();
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    if (local.year == now.year) {
      return '${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
    }
    return '${local.year}-${two(local.month)}-${two(local.day)}';
  }
}
