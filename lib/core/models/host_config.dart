import 'dart:convert';

import 'remote_os.dart';

enum AuthMethod {
  password,
  privateKey,
  demoSandbox,
  localShell,
}

/// 主机连接元数据（非敏感字段存于本地配置，敏感密码/私钥存于系统 Keychain 钥匙串）
class HostConfig {
  final String id;
  final String name;
  final String group;
  final String host;
  final int port;
  final String username;
  final AuthMethod authMethod;
  final List<String> tags;
  final bool syncToICloudKeychain;
  final bool requireBiometricUnlock;
  final String? initCommand;
  final String? jumpHostId;
  final DateTime? lastConnectedAt;
  final RemoteOsType? detectedOs;
  final String? detectedOsPrettyName;
  final int? tabColorValue;

  const HostConfig({
    required this.id,
    required this.name,
    required this.host,
    this.group = '默认分组',
    this.port = 22,
    this.username = 'root',
    this.authMethod = AuthMethod.password,
    this.tags = const [],
    this.syncToICloudKeychain = true,
    this.requireBiometricUnlock = false,
    this.initCommand,
    this.jumpHostId,
    this.lastConnectedAt,
    this.detectedOs,
    this.detectedOsPrettyName,
    this.tabColorValue,
  });

  /// Keychain 中对应的唯一凭证键名
  String get keychainAccountKey => 'com.termx.vault.credential.$id';

  HostConfig copyWith({
    String? id,
    String? name,
    String? group,
    String? host,
    int? port,
    String? username,
    AuthMethod? authMethod,
    List<String>? tags,
    bool? syncToICloudKeychain,
    bool? requireBiometricUnlock,
    String? initCommand,
    String? jumpHostId,
    DateTime? lastConnectedAt,
    RemoteOsType? detectedOs,
    String? detectedOsPrettyName,
    int? tabColorValue,
    bool clearTabColor = false,
  }) {
    return HostConfig(
      id: id ?? this.id,
      name: name ?? this.name,
      group: group ?? this.group,
      host: host ?? this.host,
      port: port ?? this.port,
      username: username ?? this.username,
      authMethod: authMethod ?? this.authMethod,
      tags: tags ?? this.tags,
      syncToICloudKeychain: syncToICloudKeychain ?? this.syncToICloudKeychain,
      requireBiometricUnlock:
          requireBiometricUnlock ?? this.requireBiometricUnlock,
      initCommand: initCommand ?? this.initCommand,
      jumpHostId: jumpHostId ?? this.jumpHostId,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      detectedOs: detectedOs ?? this.detectedOs,
      detectedOsPrettyName: detectedOsPrettyName ?? this.detectedOsPrettyName,
      tabColorValue:
          clearTabColor ? null : (tabColorValue ?? this.tabColorValue),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'group': group,
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        'tags': tags,
        'syncToICloudKeychain': syncToICloudKeychain,
        'requireBiometricUnlock': requireBiometricUnlock,
        'initCommand': initCommand,
        'jumpHostId': jumpHostId,
        'lastConnectedAt': lastConnectedAt?.toIso8601String(),
        if (detectedOs != null && detectedOs != RemoteOsType.unknown)
          'detectedOs': detectedOs!.name,
        if (detectedOsPrettyName != null)
          'detectedOsPrettyName': detectedOsPrettyName,
        if (tabColorValue != null) 'tabColorValue': tabColorValue,
      };

  factory HostConfig.fromJson(Map<String, dynamic> json) {
    final osName = json['detectedOs'] as String?;
    final parsedOs = osName == null
        ? null
        : RemoteOsType.values.where((e) => e.name == osName).firstOrNull;
    return HostConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      group: (json['group'] as String?) ?? '默认分组',
      host: json['host'] as String,
      port: (json['port'] as int?) ?? 22,
      username: (json['username'] as String?) ?? 'root',
      authMethod: AuthMethod.values.firstWhere(
        (e) => e.name == json['authMethod'],
        orElse: () => AuthMethod.password,
      ),
      tags: (json['tags'] as List<dynamic>?)?.cast<String>() ?? const [],
      syncToICloudKeychain: (json['syncToICloudKeychain'] as bool?) ?? true,
      requireBiometricUnlock:
          (json['requireBiometricUnlock'] as bool?) ?? false,
      initCommand: json['initCommand'] as String?,
      jumpHostId: json['jumpHostId'] as String?,
      lastConnectedAt: json['lastConnectedAt'] != null
          ? DateTime.tryParse(json['lastConnectedAt'] as String)
          : null,
      detectedOs: parsedOs,
      detectedOsPrettyName: json['detectedOsPrettyName'] as String?,
      tabColorValue: json['tabColorValue'] as int?,
    );
  }
}

/// 存储在系统钥匙串 (Apple Keychain / Windows Credential Locker / Android Keystore) 中的机密凭证载荷
class HostSecretCredential {
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
  final DateTime updatedAt;

  const HostSecretCredential({
    this.password,
    this.privateKeyPem,
    this.passphrase,
    required this.updatedAt,
  });

  String encode() => jsonEncode({
        'password': password,
        'privateKeyPem': privateKeyPem,
        'passphrase': passphrase,
        'updatedAt': updatedAt.toIso8601String(),
      });

  factory HostSecretCredential.decode(String raw) {
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return HostSecretCredential(
      password: map['password'] as String?,
      privateKeyPem: map['privateKeyPem'] as String?,
      passphrase: map['passphrase'] as String?,
      updatedAt: DateTime.tryParse((map['updatedAt'] as String?) ?? '') ??
          DateTime.now(),
    );
  }
}
