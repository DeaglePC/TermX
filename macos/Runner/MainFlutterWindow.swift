import Cocoa
import FlutterMacOS
import LocalAuthentication
import Security

class MainFlutterWindow: NSWindow {
  private let keychainService = "com.termx.ssh.keychain"

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)
    self.setFrameAutosaveName("TermXMainWindow")

    RegisterGeneratedPlugins(registry: flutterViewController)
    setupKeychainChannel(messenger: flutterViewController.engine.binaryMessenger)
    setupDesktopIoChannel(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  private func setupDesktopIoChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.termx.desktop/native_io",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "setWindowOpacity":
        let raw = (args["opacity"] as? NSNumber)?.doubleValue ?? 1.0
        let clamped = min(1.0, max(0.35, raw))
        self.isOpaque = clamped >= 0.999
        self.alphaValue = CGFloat(clamped)
        result(clamped)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func setupKeychainChannel(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "com.termx.ssh/keychain",
      binaryMessenger: messenger
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
      case "authenticate":
        let reason = args["reason"] as? String ?? "请验证身份以查看已保存的登录密码"
        self.authenticateDeviceOwner(reason: reason, result: result)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func authenticateDeviceOwner(reason: String, result: @escaping FlutterResult) {
    let context = LAContext()
    var authError: NSError?
    if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) {
      context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, evalError in
        DispatchQueue.main.async {
          if success {
            result(["status": "authenticated", "message": ""])
          } else if let laErr = evalError as? LAError,
                    laErr.code == .userCancel || laErr.code == .systemCancel || laErr.code == .appCancel {
            result(["status": "canceled", "message": "已取消身份验证"])
          } else {
            result(["status": "failed", "message": evalError?.localizedDescription ?? "身份验证未通过"])
          }
        }
      }
    } else {
      result(["status": "unavailable", "message": authError?.localizedDescription ?? "当前设备未配置 Touch ID 或系统密码"])
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
