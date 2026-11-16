package com.termx.ssh.termx

import android.app.Activity
import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.database.ContentObserver
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.termx.ssh/keychain"
        private const val REQUEST_CONFIRM_CREDENTIAL = 9401
        private const val SETTING_ADB_WIFI_ENABLED = "adb_wifi_enabled"
    }

    private var pendingAuthResult: MethodChannel.Result? = null
    private var adbSettingObserver: ContentObserver? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        registerAdbKeepAwakeObserver()
        syncKeepScreenOnForAdb()
    }

    override fun onResume() {
        super.onResume()
        syncKeepScreenOnForAdb()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            syncKeepScreenOnForAdb()
        }
    }

    override fun onDestroy() {
        adbSettingObserver?.let {
            runCatching { contentResolver.unregisterContentObserver(it) }
        }
        adbSettingObserver = null
        super.onDestroy()
    }

    private fun isAdbDebuggingEnabled(): Boolean {
        val usbAdb = runCatching {
            Settings.Global.getInt(contentResolver, Settings.Global.ADB_ENABLED, 0) == 1
        }.getOrDefault(false)
        val wifiAdb = runCatching {
            Settings.Global.getInt(contentResolver, SETTING_ADB_WIFI_ENABLED, 0) == 1
        }.getOrDefault(false)
        return usbAdb || wifiAdb
    }

    private fun syncKeepScreenOnForAdb() {
        if (isAdbDebuggingEnabled()) {
            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setTurnScreenOn(true)
            }
        } else {
            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
                setTurnScreenOn(false)
            }
        }
    }

    private fun registerAdbKeepAwakeObserver() {
        if (adbSettingObserver != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                syncKeepScreenOnForAdb()
            }
        }
        runCatching {
            contentResolver.registerContentObserver(
                Settings.Global.getUriFor(Settings.Global.ADB_ENABLED),
                false,
                observer
            )
            contentResolver.registerContentObserver(
                Settings.Global.getUriFor(SETTING_ADB_WIFI_ENABLED),
                false,
                observer
            )
            adbSettingObserver = observer
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "authenticate") {
                    val reason = call.argument<String>("reason") ?: "请验证您的指纹、人脸或锁屏密码以查看凭据"
                    authenticateDeviceOwner(reason, result)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun authenticateDeviceOwner(reason: String, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val prompt = BiometricPrompt.Builder(this)
                .setTitle("TermX 安全身份验证")
                .setDescription(reason)
                .setAllowedAuthenticators(
                    BiometricManager.Authenticators.BIOMETRIC_STRONG or
                        BiometricManager.Authenticators.BIOMETRIC_WEAK or
                        BiometricManager.Authenticators.DEVICE_CREDENTIAL
                )
                .build()

            prompt.authenticate(
                CancellationSignal(),
                mainExecutor,
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(res: BiometricPrompt.AuthenticationResult?) {
                        result.success(mapOf("status" to "authenticated", "message" to ""))
                    }

                    override fun onAuthenticationError(errorCode: Int, errString: CharSequence?) {
                        val status = if (
                            errorCode == BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED ||
                            errorCode == BiometricPrompt.BIOMETRIC_ERROR_CANCELED
                        ) "canceled" else "failed"
                        result.success(
                            mapOf(
                                "status" to status,
                                "message" to (errString?.toString() ?: "身份验证未通过")
                            )
                        )
                    }
                }
            )
            return
        }

        val km = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        if (km != null && km.isDeviceSecure) {
            @Suppress("DEPRECATION")
            val intent = km.createConfirmDeviceCredentialIntent("TermX 安全身份验证", reason)
            if (intent != null) {
                pendingAuthResult?.success(mapOf("status" to "canceled", "message" to "验证已被新请求替代"))
                pendingAuthResult = result
                startActivityForResult(intent, REQUEST_CONFIRM_CREDENTIAL)
                return
            }
        }
        result.success(mapOf("status" to "unavailable", "message" to "当前设备未设置指纹、人脸或锁屏密码"))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQUEST_CONFIRM_CREDENTIAL) {
            val pending = pendingAuthResult
            pendingAuthResult = null
            if (resultCode == Activity.RESULT_OK) {
                pending?.success(mapOf("status" to "authenticated", "message" to ""))
            } else {
                pending?.success(mapOf("status" to "canceled", "message" to "已取消身份验证"))
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }
}
