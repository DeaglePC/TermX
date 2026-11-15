import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/models/host_store.dart';
import 'package:termx/core/models/remote_os.dart';
import 'package:termx/core/ssh/ssh_session_controller.dart';
import 'package:termx/ui/termx_workbench.dart';
import 'package:termx/ui/widgets/os_logo_icon.dart';

String buildProbeOutput({
  String banner = '',
  String uname = '',
  String model = '',
  String swVers = '',
  String osRelease = '',
  String legacy = '',
}) {
  return '''
$banner
__TERMX_OS_BEGIN__
$uname
__TERMX_MODEL__
$model
__TERMX_SWVERS__
$swVers
__TERMX_RELEASE__
$osRelease
__TERMX_LEGACY__
$legacy
__TERMX_END__
''';
}

class FakeOsSession extends SshSessionController {
  FakeOsSession({
    super.sessionId = 'os-test',
    super.host = const HostConfig(
      id: 'h1',
      name: 'Mix',
      host: '10.0.0.8',
    ),
    this.fakeState = SessionConnectionState.connected,
  });

  SessionConnectionState fakeState;

  @override
  SessionConnectionState get state => fakeState;
}

void main() {
  group('RemoteOsDetector', () {
    test('detects Ubuntu accurately even with ID_LIKE=debian and login banner', () {
      final info = RemoteOsDetector.parseProbeOutput(
        buildProbeOutput(
          banner: 'Welcome to Ubuntu 24.04.1 LTS (GNU/Linux 6.8.0-45-generic x86_64)',
          uname: 'Linux 6.8.0-45-generic x86_64',
          osRelease: '''
PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
ID=ubuntu
ID_LIKE=debian
''',
        ),
      );
      expect(info.type, RemoteOsType.ubuntu);
      expect(info.prettyName, 'Ubuntu 24.04.1 LTS');
    });

    test('detects CentOS Stream / CentOS 7+ via /etc/os-release and CentOS 6 via legacy file', () {
      final modern = RemoteOsDetector.parseProbeOutput(
        buildProbeOutput(
          uname: 'Linux 3.10.0-1160.el7.x86_64 x86_64',
          osRelease: '''
NAME="CentOS Linux"
VERSION="7 (Core)"
ID="centos"
ID_LIKE="rhel fedora"
PRETTY_NAME="CentOS Linux 7 (Core)"
''',
        ),
      );
      expect(modern.type, RemoteOsType.centos);
      expect(modern.prettyName, 'CentOS Linux 7 (Core)');

      final legacy = RemoteOsDetector.parseProbeOutput(
        buildProbeOutput(
          uname: 'Linux 2.6.32-754.el6.x86_64 x86_64',
          legacy: 'CentOS release 6.10 (Final)',
        ),
      );
      expect(legacy.type, RemoteOsType.centos);
      expect(legacy.prettyName, 'CentOS release 6.10 (Final)');
    });

    test('detects Raspberry Pi 64-bit (ID=debian + device-tree model with NUL) and 32-bit Raspbian', () {
      final pi64 = RemoteOsDetector.parseProbeOutput(
        buildProbeOutput(
          uname: 'Linux 6.6.51+rpt-rpi-2712 aarch64',
          model: 'Raspberry Pi 5 Model B Rev 1.0\x00',
          osRelease: '''
PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
NAME="Debian GNU/Linux"
ID=debian
''',
        ),
      );
      expect(pi64.type, RemoteOsType.raspberryPi);
      expect(pi64.prettyName, 'Raspberry Pi 5 Model B Rev 1.0');

      final pi32 = RemoteOsDetector.parseProbeOutput(
        buildProbeOutput(
          uname: 'Linux 6.1.21-v7+ armv7l',
          osRelease: '''
PRETTY_NAME="Raspbian GNU/Linux 11 (bullseye)"
ID=raspbian
ID_LIKE=debian
''',
        ),
      );
      expect(pi32.type, RemoteOsType.raspberryPi);
      expect(pi32.prettyName, 'Raspbian GNU/Linux 11 (bullseye)');
    });

    test('detects macOS via Darwin uname and sw_vers', () {
      final mac = RemoteOsDetector.parseProbeOutput(
        buildProbeOutput(
          uname: 'Darwin 24.1.0 arm64',
          swVers: '''
ProductName:		macOS
ProductVersion:		15.1
BuildVersion:		24B83
''',
        ),
      );
      expect(mac.type, RemoteOsType.macos);
      expect(mac.prettyName, 'macOS 15.1');
    });

    test('falls back to Linux logo when distro is unknown or bare Linux kernel', () {
      final unknownDistro = RemoteOsDetector.parseProbeOutput(
        buildProbeOutput(
          uname: 'Linux 5.10.134-16.al8.x86_64 x86_64',
          osRelease: '''
NAME="Alibaba Cloud Linux"
ID="alinux"
ID_LIKE="rhel fedora centos anolis"
PRETTY_NAME="Alibaba Cloud Linux 3.2104 LTS 64 bit"
''',
        ),
      );
      expect(unknownDistro.type, RemoteOsType.linux);
      expect(
        unknownDistro.prettyName,
        'Alibaba Cloud Linux 3.2104 LTS 64 bit',
      );

      final busyboxLinux = RemoteOsDetector.parseProbeOutput(
        buildProbeOutput(
          uname: 'Linux 5.15.150 mips',
        ),
      );
      expect(busyboxLinux.type, RemoteOsType.linux);
      expect(busyboxLinux.prettyName, 'Linux 5.15.150 mips');
    });

    test('detects Debian, Fedora, Rocky, Alma, Arch, Alpine, openSUSE, FreeBSD, Windows', () {
      expect(
        RemoteOsDetector.parseProbeOutput(
          buildProbeOutput(uname: 'Linux 6.1 x86_64', osRelease: 'ID=debian'),
        ).type,
        RemoteOsType.debian,
      );
      expect(
        RemoteOsDetector.parseProbeOutput(
          buildProbeOutput(uname: 'Linux 6.9 x86_64', osRelease: 'ID=fedora'),
        ).type,
        RemoteOsType.fedora,
      );
      expect(
        RemoteOsDetector.parseProbeOutput(
          buildProbeOutput(uname: 'Linux 5.14 x86_64', osRelease: 'ID="rocky"'),
        ).type,
        RemoteOsType.rocky,
      );
      expect(
        RemoteOsDetector.parseProbeOutput(
          buildProbeOutput(
            uname: 'Linux 5.14 x86_64',
            osRelease: 'ID="almalinux"',
          ),
        ).type,
        RemoteOsType.alma,
      );
      expect(
        RemoteOsDetector.parseProbeOutput(
          buildProbeOutput(uname: 'Linux 6.10 x86_64', osRelease: 'ID=arch'),
        ).type,
        RemoteOsType.arch,
      );
      expect(
        RemoteOsDetector.parseProbeOutput(
          buildProbeOutput(uname: 'Linux 6.6 x86_64', osRelease: 'ID=alpine'),
        ).type,
        RemoteOsType.alpine,
      );
      expect(
        RemoteOsDetector.parseProbeOutput(
          buildProbeOutput(
            uname: 'Linux 6.4 x86_64',
            osRelease: 'ID="opensuse-leap"',
          ),
        ).type,
        RemoteOsType.opensuse,
      );
      expect(
        RemoteOsDetector.parseProbeOutput(
          buildProbeOutput(uname: 'FreeBSD 14.1-RELEASE amd64'),
        ).type,
        RemoteOsType.freebsd,
      );
      expect(
        RemoteOsDetector.parseProbeOutput(
          '\r\nMicrosoft Windows [Version 10.0.22631.4317]\r\n',
        ).type,
        RemoteOsType.windows,
      );
    });
  });

  test('HostConfig persists and restores detectedOs metadata cleanly', () {
    const host = HostConfig(
      id: 'node-1',
      name: 'Pi Cluster',
      host: '192.168.1.50',
      detectedOs: RemoteOsType.raspberryPi,
      detectedOsPrettyName: 'Raspberry Pi 5 Model B Rev 1.0',
    );
    final json = host.toJson();
    expect(json['detectedOs'], 'raspberryPi');
    expect(json['detectedOsPrettyName'], 'Raspberry Pi 5 Model B Rev 1.0');

    final restored = HostConfig.fromJson(json);
    expect(restored.detectedOs, RemoteOsType.raspberryPi);
    expect(restored.detectedOsPrettyName, 'Raspberry Pi 5 Model B Rev 1.0');

    const unknownHost = HostConfig(
      id: 'node-2',
      name: 'Fresh',
      host: '192.168.1.51',
    );
    expect(unknownHost.toJson().containsKey('detectedOs'), isFalse);
  });

  testWidgets('OsLogoIcon and SessionOsStatusBadge paint all OS logos and states', (
    tester,
  ) async {
    final session = FakeOsSession(fakeState: SessionConnectionState.connecting);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Wrap(
                children: [
                  for (final os in RemoteOsType.values)
                    OsLogoIcon(os: os, size: 18),
                ],
              ),
              SessionOsStatusBadge(session: session, size: 15),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Update session OS dynamically as happens when SSH OS detection completes
    session.fakeState = SessionConnectionState.connected;
    session.applyDetectedOs(RemoteOsType.ubuntu, 'Ubuntu 24.04.1 LTS');
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Disconnected state renders translucent logo + corner status indicator
    session.fakeState = SessionConnectionState.disconnected;
    session.applyDetectedOs(RemoteOsType.macos, 'macOS 15.1');
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TermXWorkbench remembers detected OS logo in sidebar on next launch without connecting',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      Directory? tempDir;
      late List<HostConfig> loadedFromDisk;
      await tester.runAsync(() async {
        tempDir = await Directory.systemTemp.createTemp('termx-os-remember-');
        final writerStore = HostStore(directoryProvider: () async => tempDir!);
        await writerStore.save(const [
          HostConfig(
            id: 'host_mix',
            name: 'Mix',
            group: 'Home',
            host: '192.0.2.62',
            port: 22,
            username: 'devops',
            detectedOs: RemoteOsType.ubuntu,
            detectedOsPrettyName: 'Ubuntu 22.04.5 LTS',
          ),
        ]);
        final diskReader = HostStore(directoryProvider: () async => tempDir!);
        loadedFromDisk = await diskReader.load();
        await tempDir!.delete(recursive: true);
      });

      final memoryBackedStore = _PreloadedHostStore(loadedFromDisk);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(useMaterial3: true),
          home: TermXWorkbench(
            hostStore: memoryBackedStore,
            autoStartLocalShell: false,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      final mixTileFinder = find.ancestor(
        of: find.text('Mix'),
        matching: find.byType(HostSidebarItem),
      );
      expect(mixTileFinder, findsOneWidget);

      final logoFinder = find.descendant(
        of: mixTileFinder,
        matching: find.byType(OsLogoIcon),
      );
      expect(logoFinder, findsOneWidget);
      final logoWidget = tester.widget<OsLogoIcon>(logoFinder);
      expect(logoWidget.os, RemoteOsType.ubuntu);
      expect(logoWidget.tooltip, 'Ubuntu 22.04.5 LTS');

      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _PreloadedHostStore extends HostStore {
  _PreloadedHostStore(this._hosts);
  final List<HostConfig> _hosts;

  @override
  Future<List<HostConfig>> load() async => _hosts;
}
