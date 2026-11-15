import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/plugin_system/plugin_manager.dart';
import 'package:termx/core/theme/adaptive_layout.dart';
import 'package:termx/core/vault/vault_service.dart';
import 'package:termx/main.dart';
import 'package:termx/plugins/docker_inspector/docker_inspector_plugin.dart';
import 'package:termx/plugins/server_monitor/server_monitor_plugin.dart';
import 'package:termx/plugins/sftp_manager/sftp_manager_plugin.dart';
import 'package:termx/ui/widgets/terminal_pane_view.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  test(
    'VaultService stores credentials and generates Keychain audit items',
    () async {
      final vault = VaultService();
      const host = HostConfig(
        id: 'h_test_01',
        name: 'mac-keychain-node',
        host: '10.0.0.8',
        syncToICloudKeychain: true,
        requireBiometricUnlock: true,
      );

      await vault.saveCredential(
        host,
        HostSecretCredential(
          password: 'super-secret-password',
          updatedAt: DateTime(2026, 11, 14),
        ),
      );

      final readBack = await vault.readCredential(host);
      expect(readBack?.password, equals('super-secret-password'));

      final audits = vault.inspectAuditItems([host]);
      expect(audits.length, 1);
      expect(audits.first.key, 'com.termx.vault.credential.h_test_01');
      expect(audits.first.synchronizable, isTrue);
      expect(audits.first.biometricProtected, isTrue);
    },
  );

  test(
    'PluginManager supports hot-plugging and dynamic plugin registration',
    () async {
      final manager = PluginManager();
      final monitorPlugin = ServerMonitorPlugin();
      final sftpPlugin = SftpManagerPlugin();

      await manager.registerPlugin(monitorPlugin);
      await manager.registerPlugin(sftpPlugin);
      expect(manager.enabledPlugins.length, 2);

      // 动态卸载/禁用插件
      manager.setPluginEnabled(ServerMonitorPlugin.pluginId, false);
      expect(manager.enabledPlugins.length, 1);
      expect(manager.activePanelPluginId, SftpManagerPlugin.pluginId);

      // 动态安装扩展插件
      await manager.registerPlugin(DockerInspectorPlugin());
      expect(manager.allPlugins.length, 3);
      manager.dispose();
    },
  );

  test('AdaptiveBreakpoints resolves Phone, iPadOS, and Desktop modes', () {
    expect(
      AdaptiveBreakpoints.resolve(390, FormFactorOverride.auto),
      AdaptiveLayoutMode.compact,
    );
    expect(
      AdaptiveBreakpoints.resolve(820, FormFactorOverride.auto),
      AdaptiveLayoutMode.medium,
    );
    expect(
      AdaptiveBreakpoints.resolve(1440, FormFactorOverride.auto),
      AdaptiveLayoutMode.expanded,
    );
    expect(
      AdaptiveBreakpoints.resolve(1440, FormFactorOverride.ipad),
      AdaptiveLayoutMode.medium,
    );
  });

  testWidgets('TermXWorkbench renders main SSH terminal and plugins', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const TermXApp());
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('TermX'), findsOneWidget);
    if (Platform.isWindows) {
      expect(find.text('本地 PowerShell'), findsWidgets);
    }
    expect(find.text('prod-ap-tokyo-01'), findsNothing);
    expect(find.text('edge-gateway-hk'), findsNothing);
    expect(find.text('pg-primary-us-west'), findsNothing);
    if (Platform.isWindows) {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyE);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(find.byType(TerminalView), findsNWidgets(2));
      final splitStates = tester
          .stateList(find.byType(TerminalPaneView))
          .toList();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      final retainedStates = tester
          .stateList(find.byType(TerminalPaneView, skipOffstage: false))
          .toList();
      expect(retainedStates, containsAll(splitStates));
      expect(retainedStates.length, 3);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(
        tester.stateList(find.byType(TerminalPaneView)).toList(),
        splitStates,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await tester.pumpAndSettle();
      expect(find.text('终端快捷键'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
