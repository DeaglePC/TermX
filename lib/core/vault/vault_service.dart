import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/host_config.dart';

/// 钥匙串条目状态（用于在 UI 中展示 Apple Keychain / 系统凭据库透明审计信息）
class KeychainItemAudit {
  final String key;
  final String hostName;
  final String backendName;
  final String digestFingerprint;
  final bool synchronizable;
  final bool biometricProtected;
  final DateTime updatedAt;

  const KeychainItemAudit({
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
///   Apple Security.framework (SecItemAdd / SecItemCopyMatching / SecItemDelete)，
///   支持 kSecAttrSynchronizable (iCloud 钥匙串同步) 与 kSecAttrAccessibleWhenUnlocked。
/// - Windows: flutter_secure_storage 使用当前 Windows 用户的 DPAPI 加密落盘。
/// - Android: flutter_secure_storage 使用系统安全存储。
class VaultService extends ChangeNotifier {
  static const _secureStorage = FlutterSecureStorage(
    wOptions: WindowsOptions(useBackwardCompatibility: false),
  );
  static const MethodChannel _appleKeychainChannel = MethodChannel(
    'com.termx.ssh/keychain',
  );

  final Map<String, HostSecretCredential> _memoryCache = {};
  bool _iCloudKeychainEnabled = true;
  bool _biometricLockEnabled = false;

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
      return 'Windows DPAPI（当前用户加密存储）';
    }
    if (Platform.isAndroid) {
      return 'Android Keystore (Hardware-backed Vault)';
    }
    return 'System Secret Service';
  }

  void setICloudKeychainEnabled(bool value) {
    _iCloudKeychainEnabled = value;
    notifyListeners();
  }

  void setBiometricLockEnabled(bool value) {
    _biometricLockEnabled = value;
    notifyListeners();
  }

  /// 将主机登录凭据（密码、SSH 私钥、Passphrase）安全写入系统钥匙串
  Future<void> saveCredential(
    HostConfig host,
    HostSecretCredential credential,
  ) async {
    if (_isApplePlatform) {
      await _appleKeychainChannel.invokeMethod<bool>('write', {
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
    if (_isApplePlatform) {
      final raw = await _appleKeychainChannel.invokeMethod<String>('read', {
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
    if (_isApplePlatform) {
      await _appleKeychainChannel.invokeMethod<bool>('delete', {
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
    return hosts.map((host) {
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
        key: host.keychainAccountKey,
        hostName: '${host.name} (${host.username}@${host.host})',
        backendName: platformVaultBackendName,
        digestFingerprint: 'SHA256:$rawDigest',
        synchronizable: host.syncToICloudKeychain && _iCloudKeychainEnabled,
        biometricProtected:
            host.requireBiometricUnlock || _biometricLockEnabled,
        updatedAt: cached?.updatedAt ?? DateTime.now(),
      );
    }).toList();
  }
}
