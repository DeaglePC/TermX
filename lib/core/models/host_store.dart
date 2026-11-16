import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'host_config.dart';

/// Only non-secret connection metadata belongs in this file.
class HostStore {
  HostStore({Future<Directory> Function()? directoryProvider})
    : _isInMemoryTestFallback =
          directoryProvider == null &&
          Platform.environment['FLUTTER_TEST'] == 'true',
      _directoryProvider = directoryProvider ?? getApplicationSupportDirectory;

  final bool _isInMemoryTestFallback;
  final Future<Directory> Function() _directoryProvider;
  Future<void> _pendingWrite = Future<void>.value();
  List<HostConfig> _testMemoryHosts = const [];

  Future<File> get configFile async {
    final directory = await _directoryProvider();
    return File('${directory.path}${Platform.pathSeparator}hosts.json');
  }

  Future<List<HostConfig>> load() async {
    if (_isInMemoryTestFallback) {
      return List<HostConfig>.of(_testMemoryHosts);
    }
    final file = await configFile;
    if (!await file.exists()) return [];
    final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    if (data['version'] != 1 || data['hosts'] is! List) {
      throw const FormatException('不支持的主机配置文件格式');
    }
    return (data['hosts'] as List)
        .map((item) => HostConfig.fromJson(item as Map<String, dynamic>))
        .where((host) => host.authMethod != AuthMethod.localShell)
        .toList();
  }

  Future<void> save(List<HostConfig> hosts) {
    if (_isInMemoryTestFallback) {
      _testMemoryHosts = hosts
          .where((host) => host.authMethod != AuthMethod.localShell)
          .toList();
      return Future<void>.value();
    }
    final encoded = const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'hosts': hosts
          .where((host) => host.authMethod != AuthMethod.localShell)
          .map((host) => host.toJson())
          .toList(),
    });
    final write = _pendingWrite.then((_) async {
      final file = await configFile;
      await file.parent.create(recursive: true);
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(encoded, flush: true);
      try {
        await temporary.rename(file.path);
      } on FileSystemException {
        // Windows Defender / 文件索引短暂占用目标文件时回退为直接覆盖写入
        await file.writeAsString(encoded, flush: true);
        if (await temporary.exists()) {
          try {
            await temporary.delete();
          } catch (_) {}
        }
      }
    });
    _pendingWrite = write.then<void>((_) {}, onError: (Object _) {});
    return write;
  }
}
