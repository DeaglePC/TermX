import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class DesktopFileDropListener {
  void onNativeDragEntered(Offset globalPosition) {}
  void onNativeDragUpdated(Offset globalPosition) {}
  void onNativeDragExited() {}
  void onNativeFilesDropped(Offset globalPosition, List<String> paths);
}

/// 桌面端原生系统文件对话框与跨应用文件拖拽桥接层 (Win32 OLE IDropTarget & IFileDialog)
class DesktopNativeBridge {
  DesktopNativeBridge._() {
    _channel.setMethodCallHandler(_handleNativeCallback);
  }

  static final DesktopNativeBridge instance = DesktopNativeBridge._();
  static const MethodChannel _channel = MethodChannel(
    'com.termx.desktop/native_io',
  );

  final ObserverList<DesktopFileDropListener> _listeners =
      ObserverList<DesktopFileDropListener>();

  /// 供自动化测试注入保存路径选择器的回调覆盖
  @visibleForTesting
  Future<String?> Function({
    required String suggestedName,
    String? initialDirectory,
  })?
  debugSaveFileOverride;

  @visibleForTesting
  Future<List<String>> Function({
    bool allowMultiple,
    String? initialDirectory,
  })?
  debugPickFilesOverride;

  @visibleForTesting
  Future<String?> Function({String? initialDirectory})?
  debugPickDirectoryOverride;

  @visibleForTesting
  Future<double> Function(double opacity)? debugSetWindowOpacityOverride;

  bool get supportsWindowOpacity =>
      Platform.isWindows ||
      Platform.isMacOS ||
      debugSetWindowOpacityOverride != null;

  /// 设置桌面端顶层窗口整体透明度（范围限制在 0.35 ~ 1.0，防止窗口彻底不可见）
  Future<double> setWindowOpacity(double opacity) async {
    final clamped = opacity.clamp(0.35, 1.0).toDouble();
    if (debugSetWindowOpacityOverride != null) {
      return debugSetWindowOpacityOverride!(clamped);
    }
    if (!Platform.isWindows && !Platform.isMacOS) {
      return clamped;
    }
    try {
      final res = await _channel.invokeMethod<num>('setWindowOpacity', {
        'opacity': clamped,
      });
      return (res?.toDouble() ?? clamped).clamp(0.35, 1.0).toDouble();
    } catch (_) {
      return clamped;
    }
  }

  /// 调用 Windows 原生身份验证（优先 Windows Hello 指纹 / 人脸识别 / PIN，未配置时回退 Windows 账户密码）
  Future<({String status, String message})> authenticateWindowsUser({
    required String reason,
  }) async {
    if (!Platform.isWindows) {
      return (status: 'unavailable', message: '非 Windows 平台');
    }
    try {
      final res = await _channel.invokeMapMethod<String, dynamic>(
        'authenticateUser',
        {'reason': reason},
      );
      if (res == null) {
        return (status: 'failed', message: '系统身份验证未返回结果');
      }
      final status = (res['status'] as String?) ?? 'failed';
      final message = (res['message'] as String?) ?? '';
      return (status: status, message: message);
    } on MissingPluginException {
      return _fallbackAuthenticatePowerShell(reason: reason);
    } on PlatformException catch (e) {
      if (e.code == 'MissingPluginException') {
        return _fallbackAuthenticatePowerShell(reason: reason);
      }
      return (status: 'failed', message: e.message ?? '系统身份验证调用失败');
    } catch (_) {
      return _fallbackAuthenticatePowerShell(reason: reason);
    }
  }

  Future<({String status, String message})> _fallbackAuthenticatePowerShell({
    required String reason,
  }) async {
    try {
      final safeReason = reason.replaceAll("'", "''");
      final script =
          r'[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; '
          r'$null = [Windows.Security.Credentials.UI.UserConsentVerifier, Windows.Security.Credentials.UI, ContentType = WindowsRuntime]; '
          r'$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq "AsTask" -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq "IAsyncOperation`1" })[0]; '
          r'$availOp = [Windows.Security.Credentials.UI.UserConsentVerifier]::CheckAvailabilityAsync(); '
          r'$availTask = $asTask.MakeGenericMethod([Windows.Security.Credentials.UI.UserConsentVerifierAvailability]).Invoke($null, @($availOp)); '
          r'$avail = $availTask.GetAwaiter().GetResult(); '
          r'if ($avail -eq "Available" -or $avail -eq "DeviceBusy") { '
          "\$verOp = [Windows.Security.Credentials.UI.UserConsentVerifier]::RequestVerificationAsync('$safeReason'); "
          r'$verTask = $asTask.MakeGenericMethod([Windows.Security.Credentials.UI.UserConsentVerificationResult]).Invoke($null, @($verOp)); '
          r'$ver = $verTask.GetAwaiter().GetResult(); '
          r'if ($ver -eq "Verified") { Write-Output "authenticated" } '
          r'elseif ($ver -eq "Canceled") { Write-Output "canceled" } '
          r'else { Write-Output "failed" } '
          r'} else { Write-Output "unavailable" }';
      final proc = await Process.run('powershell', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        script,
      ]);
      final out = (proc.stdout as String).trim().split(RegExp(r'\r?\n')).last;
      return switch (out) {
        'authenticated' => (status: 'authenticated', message: ''),
        'canceled' => (status: 'canceled', message: '已取消身份验证'),
        'unavailable' => (
          status: 'unavailable',
          message: '请重启 TermX 客户端以启用 Windows 账户密码回退验证，或在系统设置中开启 Windows Hello',
        ),
        _ => (status: 'failed', message: '系统身份验证未通过'),
      };
    } catch (_) {
      return (status: 'failed', message: '无法唤起 Windows Hello 身份验证');
    }
  }

  bool get supportsNativeDialogs =>
      Platform.isWindows ||
      debugSaveFileOverride != null ||
      debugPickFilesOverride != null;

  void addDropListener(DesktopFileDropListener listener) {
    _listeners.add(listener);
  }

  void removeDropListener(DesktopFileDropListener listener) {
    _listeners.remove(listener);
  }

  Future<dynamic> _handleNativeCallback(MethodCall call) async {
    final args = (call.arguments as Map?)?.cast<String, dynamic>() ?? const {};
    final x = (args['x'] as num?)?.toDouble() ?? 0.0;
    final y = (args['y'] as num?)?.toDouble() ?? 0.0;
    final pos = Offset(x, y);

    switch (call.method) {
      case 'onDragEntered':
        for (final listener in List<DesktopFileDropListener>.of(_listeners)) {
          if (_listeners.contains(listener)) {
            listener.onNativeDragEntered(pos);
          }
        }
      case 'onDragUpdated':
        for (final listener in List<DesktopFileDropListener>.of(_listeners)) {
          if (_listeners.contains(listener)) {
            listener.onNativeDragUpdated(pos);
          }
        }
      case 'onDragExited':
        for (final listener in List<DesktopFileDropListener>.of(_listeners)) {
          if (_listeners.contains(listener)) {
            listener.onNativeDragExited();
          }
        }
      case 'onFilesDropped':
        final rawPaths = (args['paths'] as List?) ?? const [];
        final paths = rawPaths
            .map((e) => e.toString())
            .where((p) => p.isNotEmpty)
            .toList();
        if (paths.isEmpty) return;
        for (final listener in List<DesktopFileDropListener>.of(_listeners)) {
          if (_listeners.contains(listener)) {
            listener.onNativeFilesDropped(pos, paths);
          }
        }
    }
  }

  @visibleForTesting
  void simulateDragEnter(Offset globalPosition) {
    for (final l in List<DesktopFileDropListener>.of(_listeners)) {
      l.onNativeDragEntered(globalPosition);
    }
  }

  @visibleForTesting
  void simulateDragExit() {
    for (final l in List<DesktopFileDropListener>.of(_listeners)) {
      l.onNativeDragExited();
    }
  }

  @visibleForTesting
  void simulateDrop(Offset globalPosition, List<String> paths) {
    for (final l in List<DesktopFileDropListener>.of(_listeners)) {
      l.onNativeFilesDropped(globalPosition, paths);
    }
  }

  /// 打开系统原生“另存为”文件保存路径选择框，用户取消时返回 null
  Future<String?> saveFileDialog({
    required String suggestedName,
    String? initialDirectory,
  }) async {
    if (debugSaveFileOverride != null) {
      return debugSaveFileOverride!(
        suggestedName: suggestedName,
        initialDirectory: initialDirectory,
      );
    }
    if (!Platform.isWindows) return null;
    try {
      final path = await _channel.invokeMethod<String>('saveFile', {
        'suggestedName': suggestedName,
        if (initialDirectory != null && initialDirectory.isNotEmpty)
          'initialDirectory': initialDirectory,
      });
      if (path == null || path.trim().isEmpty) return null;
      return path.trim();
    } on MissingPluginException {
      return _fallbackSaveFilePowerShell(
        suggestedName: suggestedName,
        initialDirectory: initialDirectory,
      );
    } catch (_) {
      return null;
    }
  }

  /// 打开系统原生文件选择对话框（支持多选文件上传）
  Future<List<String>> pickFilesDialog({
    bool allowMultiple = true,
    String? initialDirectory,
  }) async {
    if (debugPickFilesOverride != null) {
      return debugPickFilesOverride!(
        allowMultiple: allowMultiple,
        initialDirectory: initialDirectory,
      );
    }
    if (!Platform.isWindows) return const [];
    try {
      final list = await _channel.invokeListMethod<String>('pickFiles', {
        'allowMultiple': allowMultiple,
        if (initialDirectory != null && initialDirectory.isNotEmpty)
          'initialDirectory': initialDirectory,
      });
      return list?.where((p) => p.trim().isNotEmpty).toList() ?? const [];
    } on MissingPluginException {
      return _fallbackPickFilesPowerShell(
        allowMultiple: allowMultiple,
        initialDirectory: initialDirectory,
      );
    } catch (_) {
      return const [];
    }
  }

  /// 打开系统原生文件夹选择对话框（用于整目录下载保存位置选择）
  Future<String?> pickDirectoryDialog({String? initialDirectory}) async {
    if (debugPickDirectoryOverride != null) {
      return debugPickDirectoryOverride!(initialDirectory: initialDirectory);
    }
    if (!Platform.isWindows) return null;
    try {
      final path = await _channel.invokeMethod<String>('pickDirectory', {
        if (initialDirectory != null && initialDirectory.isNotEmpty)
          'initialDirectory': initialDirectory,
      });
      if (path == null || path.trim().isEmpty) return null;
      return path.trim();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _fallbackSaveFilePowerShell({
    required String suggestedName,
    String? initialDirectory,
  }) async {
    try {
      final safeName = suggestedName.replaceAll("'", "''");
      final safeDir = (initialDirectory ?? '').replaceAll("'", "''");
      final script =
          'Add-Type -AssemblyName System.Windows.Forms; '
          r'$dlg = New-Object System.Windows.Forms.SaveFileDialog; '
          r'$dlg.Title = "选择 SFTP 下载保存位置"; '
          "\$dlg.FileName = '$safeName'; "
          "${safeDir.isNotEmpty ? "\$dlg.InitialDirectory = '$safeDir'; " : ''}"
          r'$dlg.Filter = "所有文件 (*.*)|*.*"; '
          r'if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { '
          r'[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; '
          r'Write-Output $dlg.FileName }';
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-Sta',
        '-Command',
        script,
      ]);
      final out = (res.stdout as String).trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _fallbackPickFilesPowerShell({
    required bool allowMultiple,
    String? initialDirectory,
  }) async {
    try {
      final safeDir = (initialDirectory ?? '').replaceAll("'", "''");
      final multi = allowMultiple ? r'$true' : r'$false';
      final script =
          'Add-Type -AssemblyName System.Windows.Forms; '
          r'$dlg = New-Object System.Windows.Forms.OpenFileDialog; '
          r'$dlg.Title = "选择要通过 SFTP 上传的文件"; '
          '\$dlg.Multiselect = $multi; '
          "${safeDir.isNotEmpty ? "\$dlg.InitialDirectory = '$safeDir'; " : ''}"
          r'if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { '
          r'[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; '
          r'$dlg.FileNames | ForEach-Object { Write-Output $_ } }';
      final res = await Process.run('powershell', [
        '-NoProfile',
        '-Sta',
        '-Command',
        script,
      ]);
      return (res.stdout as String)
          .split(RegExp(r'\r?\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }
}
