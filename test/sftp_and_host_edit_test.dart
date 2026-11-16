import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/models/host_store.dart';
import 'package:termx/core/models/remote_os.dart';
import 'package:termx/core/platform/desktop_native_bridge.dart';
import 'package:termx/core/plugin_system/plugin_interface.dart';
import 'package:termx/core/ssh/ssh_session_controller.dart';
import 'package:termx/plugins/sftp_manager/sftp_manager_plugin.dart';
import 'package:termx/ui/termx_workbench.dart';

class FakeSftpSession extends SshSessionController {
  FakeSftpSession({
    super.sessionId = 'sftp-nonroot',
    super.host = const HostConfig(
      id: 'h_dpc',
      name: 'Mix',
      host: '192.0.2.62',
      username: 'dpc',
    ),
    this.fakeState = SessionConnectionState.connected,
    this.homePath = '/home/dpc',
  });

  SessionConnectionState fakeState;
  final String homePath;
  final Map<String, List<RemoteFileEntry>> remoteTree = {
    '/': [
      RemoteFileEntry(
        name: 'home',
        fullPath: '/home',
        isDirectory: true,
        sizeBytes: 4096,
        permissions: 'drwxr-xr-x',
        modifiedAt: DateTime(2026, 11, 15),
      ),
      RemoteFileEntry(
        name: 'root',
        fullPath: '/root',
        isDirectory: true,
        sizeBytes: 4096,
        permissions: 'drwx------',
        modifiedAt: DateTime(2026, 11, 15),
      ),
    ],
    '/home': [
      RemoteFileEntry(
        name: 'dpc',
        fullPath: '/home/dpc',
        isDirectory: true,
        sizeBytes: 4096,
        permissions: 'drwxr-xr-x',
        modifiedAt: DateTime(2026, 11, 15),
      ),
    ],
    '/home/dpc': [
      RemoteFileEntry(
        name: '.bashrc',
        fullPath: '/home/dpc/.bashrc',
        isDirectory: false,
        sizeBytes: 3526,
        permissions: '-rw-r--r--',
        modifiedAt: DateTime(2026, 11, 15),
      ),
      RemoteFileEntry(
        name: 'projects',
        fullPath: '/home/dpc/projects',
        isDirectory: true,
        sizeBytes: 4096,
        permissions: 'drwxrwxr-x',
        modifiedAt: DateTime(2026, 11, 15),
      ),
    ],
  };

  @override
  SessionConnectionState get state => fakeState;

  @override
  Future<String> resolveSftpHomeDirectory() async => homePath;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    if (path == '/root') {
      throw Exception('SftpStatusError: Permission denied (code 3)');
    }
    final items = remoteTree[path];
    if (items == null) {
      throw Exception('SftpStatusError: No such file (code 2)');
    }
    return List<RemoteFileEntry>.from(items);
  }

  @override
  Future<void> createRemoteDirectory(
    String parentPath,
    String folderName,
  ) async {
    final fullPath = parentPath == '/'
        ? '/$folderName'
        : '$parentPath/$folderName';
    final list = remoteTree.putIfAbsent(parentPath, () => []);
    if (!list.any((e) => e.name == folderName)) {
      list.add(
        RemoteFileEntry(
          name: folderName,
          fullPath: fullPath,
          isDirectory: true,
          sizeBytes: 4096,
          permissions: 'drwxr-xr-x',
          modifiedAt: DateTime(2026, 11, 15),
        ),
      );
    }
    remoteTree.putIfAbsent(fullPath, () => []);
  }

  @override
  Future<void> uploadLocalFile({
    required File localFile,
    required String remoteDirPath,
    String? remoteFileName,
    required void Function(double progress) onProgress,
  }) async {
    final fileName =
        remoteFileName ?? localFile.path.split(RegExp(r'[/\\]')).last;
    final fullPath = remoteDirPath == '/'
        ? '/$fileName'
        : '$remoteDirPath/$fileName';
    final content = localFile.readAsStringSync();
    onProgress(0.5);
    final list = remoteTree.putIfAbsent(remoteDirPath, () => []);
    list.removeWhere((e) => e.name == fileName);
    list.add(
      RemoteFileEntry(
        name: fileName,
        fullPath: fullPath,
        isDirectory: false,
        sizeBytes: localFile.lengthSync(),
        permissions: '-rw-r--r--',
        modifiedAt: DateTime(2026, 11, 15),
        textContent: content,
      ),
    );
    onProgress(1.0);
  }

  @override
  Future<void> downloadRemoteFileToLocal({
    required RemoteFileEntry entry,
    required File destinationFile,
    required void Function(double progress) onProgress,
  }) async {
    destinationFile.parent.createSync(recursive: true);
    onProgress(0.5);
    destinationFile.writeAsStringSync(
      entry.textContent ?? 'export PATH=\$HOME/bin:\$PATH\n',
    );
    onProgress(1.0);
  }
}

class MemoryHostStore extends HostStore {
  MemoryHostStore(List<HostConfig> initial) : saved = List.of(initial);
  List<HostConfig> saved;

  @override
  Future<List<HostConfig>> load() async => List.of(saved);

  @override
  Future<void> save(List<HostConfig> hosts) async {
    saved = hosts
        .where((h) => h.authMethod != AuthMethod.localShell)
        .toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets(
    'SftpManagerPlugin opens non-root home directory, navigates up to /, and recovers from Permission denied',
    (tester) async {
      final session = FakeSftpSession();
      addTearDown(session.dispose);
      final plugin = SftpManagerPlugin();
      addTearDown(plugin.dispose);

      plugin.onActiveSessionChanged(session);

      final ctx = PluginContext(
        activeSession: session,
        showToast: (_) {},
        requestOpenPanel: (_) {},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 600,
              child: Builder(
                builder: (c) => plugin.buildPanelWidget(c, ctx),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Starts in /home/dpc instead of /root!
      expect(plugin.currentPath, '/home/dpc');
      expect(find.text('projects'), findsOneWidget);
      expect(find.text('.bashrc'), findsOneWidget);
      expect(find.text('上传 / 拖入文件'), findsOneWidget);
      expect(find.text('新建文件'), findsOneWidget);
      expect(find.text('新建目录'), findsOneWidget);

      // Verify PC click targets on SFTP action & sort buttons are >= 30px tall
      expect(
        tester.getSize(find.ancestor(
          of: find.text('新建文件'),
          matching: find.byType(InkWell),
        ).first).height,
        greaterThanOrEqualTo(34),
      );
      expect(
        tester.getSize(find.ancestor(
          of: find.text('大小'),
          matching: find.byType(InkWell),
        ).first).height,
        greaterThanOrEqualTo(30),
      );

      // Navigate up: /home/dpc -> /home -> /
      await plugin.navigateUp();
      await tester.pumpAndSettle();
      expect(plugin.currentPath, '/home');
      expect(find.text('dpc'), findsOneWidget);

      await plugin.navigateUp();
      await tester.pumpAndSettle();
      expect(plugin.currentPath, '/');
      expect(find.text('root'), findsOneWidget);

      // Clicking /root as non-root shows friendly Permission denied & Home recovery button
      await tester.tap(find.text('root'));
      await tester.pumpAndSettle();
      expect(plugin.currentPath, '/root');
      expect(find.textContaining('Permission denied'), findsOneWidget);

      await tester.tap(find.text('回到主目录 (~)'));
      await tester.pumpAndSettle();
      expect(plugin.currentPath, '/home/dpc');
      expect(find.text('projects'), findsOneWidget);
    },
  );

  testWidgets(
    'Saved SSH host in sidebar can be edited and persisted via edit button',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = MemoryHostStore(const [
        HostConfig(
          id: 'host_mix',
          name: 'Mix',
          group: 'Home',
          host: '192.0.2.62',
          port: 22,
          username: 'dpc',
          detectedOs: RemoteOsType.ubuntu,
          detectedOsPrettyName: 'Ubuntu 22.04.5 LTS',
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: TermXWorkbench(
            hostStore: store,
            autoStartLocalShell: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Mix'), findsOneWidget);
      expect(find.text('dpc@192.0.2.62:22'), findsOneWidget);

      // Tap edit icon on Mix card
      await tester.tap(find.byTooltip('编辑会话配置'));
      await tester.pumpAndSettle();

      expect(find.text('编辑 SSH 服务器会话'), findsOneWidget);
      expect(find.text('主机别名'), findsOneWidget);
      expect(find.text('登录用户名 (Username)'), findsOneWidget);

      // Change alias from Mix to Mix-NAS and username from dpc to ubuntu
      final aliasField = find.byKey(const Key('host_form_alias_input'));
      await tester.enterText(aliasField, 'Mix-NAS');

      final userField = find.byKey(const Key('host_form_user_input'));
      await tester.enterText(userField, 'ubuntu');

      await tester.tap(find.text('保存修改'));
      await tester.pumpAndSettle();

      expect(find.text('Mix-NAS'), findsOneWidget);
      expect(find.text('ubuntu@192.0.2.62:22'), findsOneWidget);
      expect(store.saved.single.name, 'Mix-NAS');
      expect(store.saved.single.username, 'ubuntu');
      // Same IP & port -> preserved detected Ubuntu logo!
      expect(store.saved.single.detectedOs, RemoteOsType.ubuntu);

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'SFTP download prompts for save path, respects cancel, and writes to chosen path',
    (tester) async {
      final tempDir = await tester.runAsync(
        () => Directory.systemTemp.createTemp('termx_sftp_dl_'),
      );
      addTearDown(() async {
        DesktopNativeBridge.instance.debugSaveFileOverride = null;
        if (tempDir != null && tempDir.existsSync()) {
          await tester.runAsync(() => tempDir.delete(recursive: true));
        }
      });

      final session = FakeSftpSession();
      addTearDown(session.dispose);
      final plugin = SftpManagerPlugin();
      addTearDown(plugin.dispose);
      plugin.onActiveSessionChanged(session);

      final ctx = PluginContext(
        activeSession: session,
        showToast: (_) {},
        requestOpenPanel: (_) {},
      );

      late BuildContext panelBuildContext;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 600,
              child: Builder(
                builder: (c) {
                  panelBuildContext = c;
                  return plugin.buildPanelWidget(c, ctx);
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final bashrc = plugin.entries.firstWhere((e) => e.name == '.bashrc');

      // 1. User cancels save dialog -> no transfer task created
      DesktopNativeBridge.instance.debugSaveFileOverride =
          ({required suggestedName, initialDirectory}) async => null;
      await plugin.downloadRemoteFile(panelBuildContext, bashrc, ctx);
      await tester.pumpAndSettle();
      expect(plugin.transferTasks, isEmpty);

      // 2. User picks a custom save path -> file written to that exact path
      final chosenPath = '${tempDir!.path}${Platform.pathSeparator}my_bashrc_backup.txt';
      String? capturedSuggestedName;
      DesktopNativeBridge.instance.debugSaveFileOverride =
          ({required suggestedName, initialDirectory}) async {
        capturedSuggestedName = suggestedName;
        return chosenPath;
      };

      await plugin.downloadRemoteFile(panelBuildContext, bashrc, ctx);
      await tester.pumpAndSettle();

      expect(capturedSuggestedName, '.bashrc');
      expect(plugin.transferTasks, hasLength(1));
      expect(plugin.transferTasks.single.completed, isTrue);
      expect(plugin.transferTasks.single.targetNote, chosenPath);
      expect(File(chosenPath).existsSync(), isTrue);
    },
  );

  testWidgets(
    'SFTP panel supports PC drag-and-drop overlay and uploads dropped files and folders',
    (tester) async {
      final tempDir = await tester.runAsync(() async {
        final dir = await Directory.systemTemp.createTemp('termx_sftp_drop_');
        await File('${dir.path}${Platform.pathSeparator}deploy.sh')
            .writeAsString('#!/bin/bash\necho ok\n');
        final subDir = Directory('${dir.path}${Platform.pathSeparator}configs');
        await subDir.create();
        await File('${subDir.path}${Platform.pathSeparator}app.yaml')
            .writeAsString('port: 8080\n');
        return dir;
      });
      addTearDown(() async {
        if (tempDir != null && tempDir.existsSync()) {
          await tester.runAsync(() => tempDir.delete(recursive: true));
        }
      });

      final session = FakeSftpSession();
      addTearDown(session.dispose);
      final plugin = SftpManagerPlugin();
      addTearDown(plugin.dispose);
      plugin.onActiveSessionChanged(session);

      final ctx = PluginContext(
        activeSession: session,
        showToast: (_) {},
        requestOpenPanel: (_) {},
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: Scaffold(
            body: SizedBox(
              width: 380,
              height: 600,
              child: Builder(
                builder: (c) => plugin.buildPanelWidget(c, ctx),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final panelCenter = tester.getCenter(find.text('projects'));

      // Drag enter -> drop overlay appears showing target remote path
      DesktopNativeBridge.instance.simulateDragEnter(panelCenter);
      await tester.pump();
      expect(plugin.isDragHovering, isTrue);
      expect(find.textContaining('松开鼠标上传至 /home/dpc'), findsOneWidget);

      // Drag exit -> overlay disappears
      DesktopNativeBridge.instance.simulateDragExit();
      await tester.pump();
      expect(plugin.isDragHovering, isFalse);

      // Drop single file + directory -> both uploaded recursively
      DesktopNativeBridge.instance.simulateDragEnter(panelCenter);
      await tester.pump();
      DesktopNativeBridge.instance.simulateDrop(panelCenter, [
        '${tempDir!.path}${Platform.pathSeparator}deploy.sh',
        '${tempDir.path}${Platform.pathSeparator}configs',
      ]);
      await tester.pumpAndSettle();

      expect(plugin.isDragHovering, isFalse);
      expect(plugin.entries.any((e) => e.name == 'deploy.sh'), isTrue);
      expect(
        plugin.entries.any((e) => e.name == 'configs' && e.isDirectory),
        isTrue,
      );
      expect(find.text('deploy.sh'), findsAtLeastNWidgets(1));
      expect(find.text('configs'), findsOneWidget);
      expect(
        session.remoteTree['/home/dpc/configs']?.any((e) => e.name == 'app.yaml'),
        isTrue,
      );
    },
  );

  testWidgets(
    'macOS session resolves /Users/<username> on connect and SFTP supports custom sorting',
    (tester) async {
      final macSession = FakeSftpSession(
        sessionId: 'sftp-mac',
        host: const HostConfig(
          id: 'h_mac',
          name: 'MacStudio',
          host: '192.0.2.88',
          username: 'patrickdu',
          detectedOs: RemoteOsType.macos,
        ),
        fakeState: SessionConnectionState.connecting,
        homePath: '/Users/patrickdu',
      );
      addTearDown(macSession.dispose);

      macSession.remoteTree['/Users/patrickdu'] = [
        RemoteFileEntry(
          name: 'notes.txt',
          fullPath: '/Users/patrickdu/notes.txt',
          isDirectory: false,
          sizeBytes: 512,
          permissions: '-rw-r--r--',
          modifiedAt: DateTime(2026, 11, 10, 9, 0),
        ),
        RemoteFileEntry(
          name: 'archive.tar.gz',
          fullPath: '/Users/patrickdu/archive.tar.gz',
          isDirectory: false,
          sizeBytes: 10485760,
          permissions: '-rw-r--r--',
          modifiedAt: DateTime(2026, 11, 15, 2, 30),
        ),
        RemoteFileEntry(
          name: 'build.sh',
          fullPath: '/Users/patrickdu/build.sh',
          isDirectory: false,
          sizeBytes: 2048,
          permissions: '-rwxr-xr-x',
          modifiedAt: DateTime(2026, 11, 12, 18, 0),
        ),
        RemoteFileEntry(
          name: 'Desktop',
          fullPath: '/Users/patrickdu/Desktop',
          isDirectory: true,
          sizeBytes: 4096,
          permissions: 'drwxr-xr-x',
          modifiedAt: DateTime(2026, 11, 14, 12, 0),
        ),
      ];

      final plugin = SftpManagerPlugin();
      addTearDown(plugin.dispose);

      // Attach while still connecting (reproduces real SSH connect sequence!)
      plugin.onActiveSessionChanged(macSession);

      // Now transition connecting -> connected
      macSession.fakeState = SessionConnectionState.connected;
      macSession.notifyListeners();
      await tester.pumpAndSettle();

      // Resolved to /Users/patrickdu instead of /home/patrickdu!
      expect(plugin.currentPath, '/Users/patrickdu');
      expect(plugin.entries.first.name, 'Desktop');

      // Sort by size (default descending on first select -> largest file first after folders)
      plugin.setSortField(SftpSortField.size);
      expect(plugin.sortAscending, isFalse);
      expect(
        plugin.entries.map((e) => e.name).toList(),
        ['Desktop', 'archive.tar.gz', 'build.sh', 'notes.txt'],
      );

      // Toggle size ascending -> smallest file first after folders
      plugin.setSortField(SftpSortField.size);
      expect(plugin.sortAscending, isTrue);
      expect(
        plugin.entries.map((e) => e.name).toList(),
        ['Desktop', 'notes.txt', 'build.sh', 'archive.tar.gz'],
      );

      // Sort by modifiedTime descending with foldersFirst disabled
      plugin.setFoldersFirst(false);
      plugin.setSortField(SftpSortField.modifiedTime);
      expect(
        plugin.entries.map((e) => e.name).toList(),
        ['archive.tar.gz', 'Desktop', 'build.sh', 'notes.txt'],
      );
    },
  );

  testWidgets(
    'Host groups collapse/expand in sidebar and top session tabs support custom colors',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final store = MemoryHostStore(const [
        HostConfig(
          id: 'host_mac',
          name: 'Mac-Mini',
          group: '家庭设备',
          host: '192.0.2.88',
          username: 'patrickdu',
          authMethod: AuthMethod.demoSandbox,
          detectedOs: RemoteOsType.macos,
        ),
        HostConfig(
          id: 'host_prod',
          name: 'Prod-API',
          group: '生产环境',
          host: '10.0.1.20',
          username: 'ubuntu',
          authMethod: AuthMethod.demoSandbox,
          detectedOs: RemoteOsType.ubuntu,
        ),
      ]);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: TermXWorkbench(
            hostStore: store,
            autoStartLocalShell: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Both group headers and hosts are visible
      expect(find.text('家庭设备'), findsOneWidget);
      expect(find.text('生产环境'), findsOneWidget);
      expect(find.text('Mac-Mini'), findsOneWidget);
      expect(find.text('Prod-API'), findsOneWidget);

      // Collapse '生产环境' -> 'Prod-API' hides, 'Mac-Mini' remains visible
      await tester.tap(find.text('生产环境'));
      await tester.pump();
      expect(find.text('Prod-API'), findsNothing);
      expect(find.text('Mac-Mini'), findsOneWidget);

      // Expand '生产环境' -> 'Prod-API' returns
      await tester.tap(find.text('生产环境'));
      await tester.pump();
      expect(find.text('Prod-API'), findsOneWidget);

      // Open Mac-Mini session tab and customize tab color via right-click menu
      await tester.tap(find.text('Mac-Mini'));
      await tester.pump(const Duration(milliseconds: 500));

      // Right-click the top tab
      final tabFinder = find.descendant(
        of: find.byType(ReorderableListView),
        matching: find.text('Mac-Mini'),
      );
      expect(tabFinder, findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(tabFinder),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryMouseButton,
      );
      await gesture.up();
      await tester.pumpAndSettle();

      // Tap '珊瑚红' swatch in the tab menu
      await tester.tap(find.byTooltip('珊瑚红'));
      await tester.pumpAndSettle();

      final savedMac = store.saved.firstWhere((h) => h.id == 'host_mac');
      expect(savedMac.tabColorValue, const Color(0xFFF7768E).toARGB32());

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
