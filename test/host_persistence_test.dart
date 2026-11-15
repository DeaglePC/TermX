import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage_windows/flutter_secure_storage_windows.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:termx/core/models/host_config.dart';
import 'package:termx/core/models/host_store.dart';
import 'package:termx/core/vault/vault_service.dart';

class TestPaths extends PathProviderPlatform {
  TestPaths(this.directory);
  final Directory directory;

  @override
  Future<String?> getApplicationSupportPath() async => directory.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late HostStore store;
  const host = HostConfig(
    id: 'persist-test',
    name: 'My server',
    host: '192.0.2.10',
    port: 2222,
    username: 'operator',
    authMethod: AuthMethod.privateKey,
    group: 'Test',
    tags: ['ssh'],
    syncToICloudKeychain: false,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('termx-persistence-');
    store = HostStore(directoryProvider: () async => directory);
  });
  tearDown(() async => directory.delete(recursive: true));

  test('Host metadata survives a new store and replacement saves', () async {
    expect(await store.load(), isEmpty);
    const local = HostConfig(
      id: 'local',
      name: 'PowerShell',
      host: 'localhost',
      authMethod: AuthMethod.localShell,
    );
    await store.save([local, host]);
    final freshStore = HostStore(directoryProvider: () async => directory);
    final restored = await freshStore.load();
    expect(restored.single.toJson(), host.toJson());
    await freshStore.save([host.copyWith(port: 2200)]);
    expect((await store.load()).single.port, 2200);
    final json = await (await store.configFile).readAsString();
    expect(jsonDecode(json)['hosts'], hasLength(1));
    expect(json, isNot(contains('password')));
    expect(json, isNot(contains('privateKeyPem')));
  });

  test('Corrupt configuration is reported without overwriting it', () async {
    final file = await store.configFile;
    await file.writeAsString('broken configuration');
    await expectLater(store.load(), throwsFormatException);
    expect(await file.readAsString(), 'broken configuration');
  });

  test(
    'Windows credentials survive new vaults and are encrypted on disk',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final oldPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = TestPaths(directory);
      addTearDown(() => PathProviderPlatform.instance = oldPaths);
      FlutterSecureStorageWindows.registerWith();
      const password = 'termx-test-password-只用于测试';
      final credential = HostSecretCredential(
        password: password,
        privateKeyPem: 'termx-test-private-key',
        passphrase: 'test-passphrase',
        updatedAt: DateTime(2026, 11, 14),
      );
      final writer = VaultService();
      await writer.saveCredential(host, credential);
      writer.dispose();

      // New plugin and vault instances cannot reuse any in-memory credential.
      FlutterSecureStorageWindows.registerWith();
      final reader = VaultService();
      addTearDown(reader.dispose);
      final restored = await reader.readCredential(host);
      expect(restored?.encode(), credential.encode());
      final encryptedFile = File(
        '${directory.path}/flutter_secure_storage.dat',
      );
      final diskContents = utf8.decode(
        await encryptedFile.readAsBytes(),
        allowMalformed: true,
      );
      expect(diskContents, isNot(contains(password)));
      expect(diskContents, isNot(contains('termx-test-private-key')));
      await reader.deleteCredential(host);
      FlutterSecureStorageWindows.registerWith();
      final afterDelete = VaultService();
      addTearDown(afterDelete.dispose);
      expect(await afterDelete.readCredential(host), isNull);
    },
    skip: !Platform.isWindows,
  );
}
