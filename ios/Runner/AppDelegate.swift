import Flutter
import UIKit
import Security

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let keychainService = "com.termx.ssh.keychain"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "com.termx.ssh/keychain",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      let key = args["key"] as? String ?? ""
      let sync = args["synchronizable"] as? Bool ?? true

      switch call.method {
      case "write":
        let value = args["value"] as? String ?? ""
        let status = self.writeKeychain(key: key, value: value, synchronizable: sync)
        result(status == errSecSuccess)
      case "read":
        result(self.readKeychain(key: key, synchronizable: sync))
      case "delete":
        let status = self.deleteKeychain(key: key, synchronizable: sync)
        result(status == errSecSuccess || status == errSecItemNotFound)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func writeKeychain(key: String, value: String, synchronizable: Bool) -> OSStatus {
    guard let data = value.data(using: .utf8) else { return errSecParam }
    _ = deleteKeychain(key: key, synchronizable: synchronizable)
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
    ]
    if synchronizable {
      query[kSecAttrSynchronizable as String] = kCFBooleanTrue
    }
    let status = SecItemAdd(query as CFDictionary, nil)
    if status == errSecMissingEntitlement && synchronizable {
      query.removeValue(forKey: kSecAttrSynchronizable as String)
      return SecItemAdd(query as CFDictionary, nil)
    }
    return status
  }

  private func readKeychain(key: String, synchronizable: Bool) -> String? {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key,
      kSecReturnData as String: kCFBooleanTrue!,
      kSecMatchLimit as String: kSecMatchLimitOne
    ]
    if synchronizable {
      query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    }
    var item: CFTypeRef?
    var status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecMissingEntitlement && synchronizable {
      query.removeValue(forKey: kSecAttrSynchronizable as String)
      status = SecItemCopyMatching(query as CFDictionary, &item)
    }
    guard status == errSecSuccess, let data = item as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private func deleteKeychain(key: String, synchronizable: Bool) -> OSStatus {
    var query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: key
    ]
    if synchronizable {
      query[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
    }
    let status = SecItemDelete(query as CFDictionary)
    if status == errSecMissingEntitlement && synchronizable {
      query.removeValue(forKey: kSecAttrSynchronizable as String)
      return SecItemDelete(query as CFDictionary)
    }
    return status
  }
}
