import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/host_config.dart';
import '../platform/desktop_native_bridge.dart';

/// 系统级机主身份验证结果状态
enum VaultAuthOutcome {
  authenticated,
  canceled,
  failed,
  unavailable,
}

/// 系统级机主身份验证结果（指纹 / 人脸识别 / PIN / 操作系统密码）
class VaultAuthResult {
  final VaultAuthOutcome outcome;
  final String message;

  const VaultAuthResult(this.outcome, [this.message = '']);

  bool get isAuthenticated => outcome == VaultAuthOutcome.authenticated;
}

/// 钥匙串条目状态（用于在 UI 中展示 Apple Keychain / 系统凭据库透明审计信息）
class KeychainItemAudit {
  final HostConfig host;
  final String key;
  final String hostName;
  final String backendName;
  final String digestFingerprint;
  final bool synchronizable;
  final bool biometricProtected;
  final DateTime updatedAt;

  const KeychainItemAudit({
    required this.host,
    required this.key,
    required this.hostName,
    required this.backendName,
    required this.digestFingerprint,
    required this.synchronizable,
    required this.biometricProtected,
    required this.updatedAt,
  });
}

/// 跨平台安全凭据与钥匙串中心 (Unified Credential Vault)
/// - macOS / iOS / iPadOS: 通过原生 MethodChannel ('com.termx.ssh/keychain') 直接调用
///   Apple Security.framework 与 LocalAuthentication (Touch ID / Face ID / 系统密码)。
/// - Windows: DPAPI 当前用户加密存储 + Windows Hello (指纹 / 人脸识别 / PIN) 与 Windows 账户密码验证。
/// - Android: Android Keystore + BiometricPrompt / Keyguard (指纹 / 人脸 / 锁屏密码)。
class VaultService extends ChangeNotifier {
  static const _secureStorage = FlutterSecureStorage(
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );
  static const MethodChannel _keychainChannel = MethodChannel(
    'com.termx.ssh/keychain',
  );
  static const String _biometricPrefKey = 'termx.vault.biometric_lock_enabled';

  final Map<String, HostSecretCredential> _memoryCache = {};
  bool _iCloudKeychainEnabled = true;
  bool _biometricLockEnabled = false;

  /// 供自动化测试覆盖系统生物识别/密码弹窗逻辑
  @visibleForTesting
  Future<VaultAuthResult> Function(String reason)? debugAuthOverride;

  /// 供自动化测试使用内存凭据存储替代真实系统钥匙串
  @visibleForTesting
  Map<String, String>? debugStorageOverride;

  bool get iCloudKeychainEnabled => _iCloudKeychainEnabled;
  bool get biometricLockEnabled => _biometricLockEnabled;

  bool get _isApplePlatform => !kIsWeb && (Platform.isMacOS || Platform.isIOS);

  /// 获取当前平台底层安全凭据引擎名称
  String get platformVaultBackendName {
    if (kIsWeb) return 'Web Crypto Storage';
    if (Platform.isMacOS) {
      return _iCloudKeychainEnabled
          ? 'macOS Keychain (Security.framework + iCloud Keychain)'
          : 'macOS Local Keychain (Security.framework)';
    }
    if (Platform.isIOS) {
      return _iCloudKeychainEnabled
          ? 'iOS/iPadOS Keychain (Secure Enclave + iCloud Keychain)'
          : 'iOS/iPadOS Local Keychain (Secure Enclave)';
    }
    if (Platform.isWindows) {
      return 'Windows DPAPI 加密库 + Windows Hello 身份保护';
    }
    if (Platform.isAndroid) {
      return 'Android Keystore (Hardware-backed Vault)';
    }
    return 'System Secret Service';
  }

  /// 当前平台支持的身份验证方式简短说明
  String get shortAuthMethodLabel {
    if (kIsWeb) return '系统身份';
    if (Platform.isWindows) return 'Windows Hello（指纹 / 人脸 / PIN）或系统密码';
    if (Platform.isMacOS) return 'Touch ID 指纹或系统密码';
    if (Platform.isIOS) return 'Face ID / Touch ID 或锁屏密码';
    if (Platform.isAndroid) return '指纹 / 人脸识别或锁屏密码';
    return '系统身份凭据';
  }

  Future<void> loadPreferences() async {
    try {
      if (debugStorageOverride != null) {
        _biometricLockEnabled = debugStorageOverride![_biometricPrefKey] == '1';
        notifyListeners();
        return;
      }
      final raw = await _secureStorage.read(key: _biometricPrefKey);
      if (raw != null) {
        _biometricLockEnabled = raw == '1';
        notifyListeners();
      }
    } catch (_) {}
  }

  void setICloudKeychainEnabled(bool value) {
    _iCloudKeychainEnabled = value;
    notifyListeners();
  }

  void setBiometricLockEnabled(bool value) {
    _biometricLockEnabled = value;
    notifyListeners();
    if (debugStorageOverride != null) {
      debugStorageOverride![_biometricPrefKey] = value ? '1' : '0';
      return;
    }
    unawaited(
      _secureStorage
          .write(key: _biometricPrefKey, value: value ? '1' : '0')
          .catchError((Object _) {}),
    );
  }

  /// 调起操作系统原生机主身份验证（指纹 / 人脸识别 / PIN / 登录密码）
  Future<VaultAuthResult> authenticateUser({
    String reason = '请验证系统身份以查看已保存的登录凭据',
  }) async {
    if (debugAuthOverride != null) {
      return debugAuthOverride!(reason);
    }
    if (kIsWeb) {
      return const VaultAuthResult(
        VaultAuthOutcome.unavailable,
        'Web 环境不支持原生生物识别验证',
      );
    }

    if (Platform.isWindows) {
      final res = await DesktopNativeBridge.instance.authenticateWindowsUser(
        reason: reason,
      );
      return switch (res.status) {
        'authenticated' => const VaultAuthResult(
          VaultAuthOutcome.authenticated,
        ),
        'canceled' => VaultAuthResult(
          VaultAuthOutcome.canceled,
          res.message.isEmpty ? '已取消身份验证' : res.message,
        ),
        'unavailable' => VaultAuthResult(
          VaultAuthOutcome.unavailable,
          res.message.isEmpty ? '当前系统未启用可用的身份验证方式' : res.message,
        ),
        _ => VaultAuthResult(
          VaultAuthOutcome.failed,
          res.message.isEmpty ? '系统身份验证未通过' : res.message,
        ),
      };
    }

    if (Platform.isMacOS || Platform.isIOS || Platform.isAndroid) {
      try {
        final res = await _keychainChannel.invokeMapMethod<String, dynamic>(
          'authenticate',
          {'reason': reason},
        );
        final status = (res?['status'] as String?) ?? 'failed';
        final msg = (res?['message'] as String?) ?? '';
        return switch (status) {
          'authenticated' => const VaultAuthResult(
            VaultAuthOutcome.authenticated,
          ),
          'canceled' => VaultAuthResult(
            VaultAuthOutcome.canceled,
            msg.isEmpty ? '已取消身份验证' : msg,
          ),
          'unavailable' => VaultAuthResult(
            VaultAuthOutcome.unavailable,
            msg.isEmpty ? '当前设备未配置生物识别或锁屏密码' : msg,
          ),
          _ => VaultAuthResult(
            VaultAuthOutcome.failed,
            msg.isEmpty ? '身份验证未通过' : msg,
          ),
        };
      } on MissingPluginException {
        return const VaultAuthResult(
          VaultAuthOutcome.unavailable,
          '当前运行环境尚未注册原生身份验证插件',
        );
      } catch (e) {
        return VaultAuthResult(VaultAuthOutcome.failed, '身份验证异常：$e');
      }
    }

    return const VaultAuthResult(
      VaultAuthOutcome.unavailable,
      '当前操作系统暂未接入原生身份验证接口',
    );
  }

  static bool hasNonEmptySecret(HostSecretCredential? cred) {
    if (cred == null) return false;
    return (cred.password != null && cred.password!.isNotEmpty) ||
        (cred.privateKeyPem != null && cred.privateKeyPem!.trim().isNotEmpty) ||
        (cred.passphrase != null && cred.passphrase!.isNotEmpty);
  }

  /// 检查指定主机是否已保存非空凭据（仅返回布尔值，绝不向 UI 暴露明文密码）
  Future<bool> hasSavedCredential(HostConfig host) async {
    try {
      final cred = await readCredential(host);
      return hasNonEmptySecret(cred);
    } catch (_) {
      return false;
    }
  }

  /// 将主机登录凭据（密码、SSH 私钥、Passphrase）安全写入系统钥匙串
  Future<void> saveCredential(
    HostConfig host,
    HostSecretCredential credential,
  ) async {
    if (debugStorageOverride != null) {
      debugStorageOverride![host.keychainAccountKey] = credential.encode();
      _memoryCache[host.keychainAccountKey] = credential;
      notifyListeners();
      return;
    }
    if (_isApplePlatform) {
      await _keychainChannel.invokeMethod<bool>('write', {
        'key': host.keychainAccountKey,
        'value': credential.encode(),
        'synchronizable': host.syncToICloudKeychain && _iCloudKeychainEnabled,
      });
    } else {
      await _secureStorage.write(
        key: host.keychainAccountKey,
        value: credential.encode(),
      );
    }
    _memoryCache[host.keychainAccountKey] = credential;
    notifyListeners();
  }

  /// 从系统钥匙串读取主机登录凭据
  Future<HostSecretCredential?> readCredential(HostConfig host) async {
    if (debugStorageOverride != null) {
      final raw = debugStorageOverride![host.keychainAccountKey];
      if (raw == null || raw.isEmpty) return null;
      final cred = HostSecretCredential.decode(raw);
      _memoryCache[host.keychainAccountKey] = cred;
      return cred;
    }
    if (_isApplePlatform) {
      final raw = await _keychainChannel.invokeMethod<String>('read', {
        'key': host.keychainAccountKey,
        'synchronizable': host.syncToICloudKeychain && _iCloudKeychainEnabled,
      });
      if (raw != null && raw.isNotEmpty) {
        final decoded = HostSecretCredential.decode(raw);
        _memoryCache[host.keychainAccountKey] = decoded;
        return decoded;
      }
      return null;
    } else {
      final raw = await _secureStorage.read(key: host.keychainAccountKey);
      if (raw == null) return null;
      final credential = HostSecretCredential.decode(raw);
      _memoryCache[host.keychainAccountKey] = credential;
      return credential;
    }
  }

  /// 从系统钥匙串彻底删除对应主机凭据
  Future<void> deleteCredential(HostConfig host) async {
    if (debugStorageOverride != null) {
      debugStorageOverride!.remove(host.keychainAccountKey);
      _memoryCache.remove(host.keychainAccountKey);
      notifyListeners();
      return;
    }
    if (_isApplePlatform) {
      await _keychainChannel.invokeMethod<bool>('delete', {
        'key': host.keychainAccountKey,
        'synchronizable': host.syncToICloudKeychain && _iCloudKeychainEnabled,
      });
    } else {
      await _secureStorage.delete(key: host.keychainAccountKey);
    }
    _memoryCache.remove(host.keychainAccountKey);
    notifyListeners();
  }

  /// 导出当前钥匙串审计条目列表（仅展示 SHA-256 指纹与钥匙串同步状态，绝不暴露明文密码）
  List<KeychainItemAudit> inspectAuditItems(List<HostConfig> hosts) {
    return hosts
        .where((h) => h.authMethod != AuthMethod.localShell)
        .map((host) {
          final cached = _memoryCache[host.keychainAccountKey];
          final rawDigest = sha256
              .convert(
                utf8.encode(
                  '${host.keychainAccountKey}:${cached?.encode() ?? "seed"}',
                ),
              )
              .toString()
              .substring(0, 16)
              .toUpperCase();
          return KeychainItemAudit(
            host: host,
            key: host.keychainAccountKey,
            hostName: '${host.name} (${host.username}@${host.host})',
            backendName: platformVaultBackendName,
            digestFingerprint: 'SHA256:$rawDigest',
            synchronizable: host.syncToICloudKeychain && _iCloudKeychainEnabled,
            biometricProtected:
                host.requireBiometricUnlock || _biometricLockEnabled,
            updatedAt: cached?.updatedAt ?? DateTime.now(),
          );
        })
        .toList();
  }
}
