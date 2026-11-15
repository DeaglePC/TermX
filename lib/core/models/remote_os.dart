/// 远程或本地主机操作系统类型枚举
enum RemoteOsType {
  ubuntu('Ubuntu'),
  centos('CentOS'),
  raspberryPi('Raspberry Pi'),
  macos('macOS'),
  debian('Debian'),
  fedora('Fedora'),
  redhat('Red Hat'),
  rocky('Rocky Linux'),
  alma('AlmaLinux'),
  arch('Arch Linux'),
  alpine('Alpine Linux'),
  opensuse('openSUSE'),
  freebsd('FreeBSD'),
  windows('Windows'),
  linux('Linux'),
  unknown('未知系统');

  final String displayName;
  const RemoteOsType(this.displayName);
}

class RemoteOsInfo {
  final RemoteOsType type;
  final String? prettyName;

  const RemoteOsInfo({
    required this.type,
    this.prettyName,
  });
}

/// 通过单次无侵入只读探针自动识别远端操作系统与发行版
class RemoteOsDetector {
  static const String posixProbeCommand =
      r'''sh -c 'printf "\n__TERMX_OS_BEGIN__\n"; uname -srm 2>/dev/null; printf "\n__TERMX_MODEL__\n"; cat /proc/device-tree/model /sys/firmware/devicetree/base/model 2>/dev/null; printf "\n"; grep -m1 -i "Raspberry Pi" /proc/cpuinfo 2>/dev/null; [ -f /etc/rpi-issue ] && printf "\nRPI_ISSUE\n"; printf "\n__TERMX_SWVERS__\n"; sw_vers 2>/dev/null; printf "\n__TERMX_RELEASE__\n"; cat /etc/os-release /usr/lib/os-release 2>/dev/null; printf "\n__TERMX_LEGACY__\n"; cat /etc/centos-release /etc/redhat-release /etc/lsb-release /etc/alpine-release 2>/dev/null; [ -f /etc/debian_version ] && printf "\nDEBIAN_VERSION_FILE\n"; [ -f /etc/arch-release ] && printf "\nARCH_RELEASE_FILE\n"; printf "\n__TERMX_END__\n"' ''';

  static const String windowsProbeCommand = 'cmd /c ver';

  static RemoteOsInfo parseProbeOutput(String raw) {
    final cleaned = raw.replaceAll('\x00', '').replaceAll('\r\n', '\n');

    final startIdx = cleaned.indexOf('__TERMX_OS_BEGIN__');
    if (startIdx < 0) {
      if (RegExp(r'microsoft\s+windows', caseSensitive: false)
          .hasMatch(cleaned)) {
        final line = cleaned
            .split('\n')
            .map((l) => l.trim())
            .firstWhere((l) => l.isNotEmpty, orElse: () => 'Windows');
        return RemoteOsInfo(type: RemoteOsType.windows, prettyName: line);
      }
      return const RemoteOsInfo(type: RemoteOsType.unknown);
    }

    final endIdx = cleaned.indexOf('__TERMX_END__', startIdx);
    final payload = endIdx >= 0
        ? cleaned.substring(startIdx + '__TERMX_OS_BEGIN__'.length, endIdx)
        : cleaned.substring(startIdx + '__TERMX_OS_BEGIN__'.length);

    String extractSection(String startMarker, [String? nextMarker]) {
      final s = payload.indexOf(startMarker);
      if (s < 0) return '';
      final contentStart = s + startMarker.length;
      if (nextMarker == null) return payload.substring(contentStart).trim();
      final e = payload.indexOf(nextMarker, contentStart);
      return (e >= 0
              ? payload.substring(contentStart, e)
              : payload.substring(contentStart))
          .trim();
    }

    final modelIdx = payload.indexOf('__TERMX_MODEL__');
    final unameLine = (modelIdx >= 0 ? payload.substring(0, modelIdx) : payload)
        .trim()
        .split('\n')
        .map((l) => l.trim())
        .firstWhere((l) => l.isNotEmpty, orElse: () => '');

    final modelSection = extractSection('__TERMX_MODEL__', '__TERMX_SWVERS__');
    final swVersSection =
        extractSection('__TERMX_SWVERS__', '__TERMX_RELEASE__');
    final osReleaseSection =
        extractSection('__TERMX_RELEASE__', '__TERMX_LEGACY__');
    final legacySection = extractSection('__TERMX_LEGACY__');

    final unameLower = unameLine.toLowerCase();

    // 1. macOS / Darwin
    if (unameLower.startsWith('darwin') ||
        RegExp(r'productname:\s*mac', caseSensitive: false)
            .hasMatch(swVersSection)) {
      String? pretty;
      final nameMatch = RegExp(
        r'^ProductName:\s*(.+)$',
        multiLine: true,
        caseSensitive: false,
      ).firstMatch(swVersSection);
      final verMatch = RegExp(
        r'^ProductVersion:\s*(.+)$',
        multiLine: true,
        caseSensitive: false,
      ).firstMatch(swVersSection);
      if (nameMatch != null) {
        final name = nameMatch.group(1)!.trim();
        final ver = verMatch?.group(1)?.trim();
        pretty = ver != null && ver.isNotEmpty ? '$name $ver' : name;
      }
      return RemoteOsInfo(
        type: RemoteOsType.macos,
        prettyName: pretty ?? 'macOS',
      );
    }

    // 2. FreeBSD / BSD
    if (unameLower.startsWith('freebsd')) {
      return RemoteOsInfo(
        type: RemoteOsType.freebsd,
        prettyName: unameLine.isNotEmpty ? unameLine : 'FreeBSD',
      );
    }

    // 解析 /etc/os-release 键值
    final osReleaseMap = <String, String>{};
    for (final line in osReleaseSection.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final eq = trimmed.indexOf('=');
      if (eq <= 0) continue;
      final key = trimmed.substring(0, eq).trim().toUpperCase();
      var value = trimmed.substring(eq + 1).trim();
      if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      osReleaseMap.putIfAbsent(key, () => value);
    }

    final distroId = (osReleaseMap['ID'] ?? '').trim().toLowerCase();
    final prettyName = osReleaseMap['PRETTY_NAME'] ?? osReleaseMap['NAME'];

    // 3. 树莓派 (Raspberry Pi 硬件模型 / rpi-issue / Raspbian)
    final modelLower = modelSection.toLowerCase();
    if (modelLower.contains('raspberry pi') ||
        modelSection.contains('RPI_ISSUE') ||
        distroId == 'raspbian' ||
        distroId == 'raspberrypi') {
      final modelLine = modelSection
          .split('\n')
          .map((l) => l.trim())
          .firstWhere(
            (l) => l.toLowerCase().contains('raspberry pi'),
            orElse: () => '',
          );
      return RemoteOsInfo(
        type: RemoteOsType.raspberryPi,
        prettyName: modelLine.isNotEmpty
            ? modelLine
            : (prettyName ?? 'Raspberry Pi OS'),
      );
    }

    // 4. 基于 /etc/os-release 的精确发行版识别（仅按 ID 匹配，避免衍生版因 ID_LIKE 误判）
    final byId = switch (distroId) {
      'ubuntu' => RemoteOsType.ubuntu,
      'centos' => RemoteOsType.centos,
      'debian' => RemoteOsType.debian,
      'fedora' => RemoteOsType.fedora,
      'rhel' || 'redhat' => RemoteOsType.redhat,
      'rocky' => RemoteOsType.rocky,
      'almalinux' || 'alma' => RemoteOsType.alma,
      'arch' || 'archarm' => RemoteOsType.arch,
      'alpine' => RemoteOsType.alpine,
      'opensuse' ||
      'opensuse-leap' ||
      'opensuse-tumbleweed' ||
      'sles' ||
      'sled' => RemoteOsType.opensuse,
      _ => null,
    };
    if (byId != null) {
      return RemoteOsInfo(type: byId, prettyName: prettyName ?? byId.displayName);
    }

    // 5. 兼容无 /etc/os-release 的旧版系统（如 CentOS 6、旧版 Ubuntu/Debian/Alpine/Arch）
    final legacyLower = legacySection.toLowerCase();
    if (distroId.isEmpty) {
      String? firstLegacyLine(Pattern match) => legacySection
          .split('\n')
          .map((l) => l.trim())
          .firstWhere(
            (l) =>
                l.isNotEmpty &&
                !l.endsWith('_FILE') &&
                l.toLowerCase().contains(match),
            orElse: () => '',
          );

      if (legacyLower.contains('centos')) {
        final line = firstLegacyLine('centos');
        return RemoteOsInfo(
          type: RemoteOsType.centos,
          prettyName: line != null && line.isNotEmpty ? line : 'CentOS',
        );
      }
      if (legacyLower.contains('red hat enterprise')) {
        final line = firstLegacyLine('red hat');
        return RemoteOsInfo(
          type: RemoteOsType.redhat,
          prettyName: line != null && line.isNotEmpty ? line : 'Red Hat',
        );
      }
      if (RegExp(r'distrib_id\s*=\s*"?ubuntu"?', caseSensitive: false)
          .hasMatch(legacySection)) {
        return const RemoteOsInfo(
          type: RemoteOsType.ubuntu,
          prettyName: 'Ubuntu',
        );
      }
      if (legacySection.contains('ARCH_RELEASE_FILE')) {
        return const RemoteOsInfo(
          type: RemoteOsType.arch,
          prettyName: 'Arch Linux',
        );
      }
      if (RegExp(r'^\d+\.\d+\.\d+', multiLine: true).hasMatch(legacySection) &&
          !legacySection.contains('DEBIAN_VERSION_FILE')) {
        return const RemoteOsInfo(
          type: RemoteOsType.alpine,
          prettyName: 'Alpine Linux',
        );
      }
      if (legacySection.contains('DEBIAN_VERSION_FILE')) {
        return const RemoteOsInfo(
          type: RemoteOsType.debian,
          prettyName: 'Debian',
        );
      }
    }

    // 6. 无法识别具体发行版，但确认为 Linux 内核 -> 统一展示 Linux (Tux) Logo
    if (unameLower.startsWith('linux') || osReleaseMap.isNotEmpty) {
      return RemoteOsInfo(
        type: RemoteOsType.linux,
        prettyName: prettyName ?? (unameLine.isNotEmpty ? unameLine : 'Linux'),
      );
    }

    // 7. Windows 下安装了 MSYS / Git Bash / Cygwin 的情况
    if (unameLower.contains('mingw') ||
        unameLower.contains('msys') ||
        unameLower.contains('cygwin') ||
        unameLower.contains('windows_nt')) {
      return RemoteOsInfo(
        type: RemoteOsType.windows,
        prettyName: unameLine.isNotEmpty ? unameLine : 'Windows',
      );
    }

    return const RemoteOsInfo(type: RemoteOsType.unknown);
  }
}
