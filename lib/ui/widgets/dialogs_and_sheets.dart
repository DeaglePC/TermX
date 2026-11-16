import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/models/host_config.dart';
import '../../core/plugin_system/plugin_manager.dart';
import '../../core/theme/ui_tokens.dart';
import '../../core/vault/vault_service.dart';
import 'terminal_tab_button.dart';

Future<void> _verifyAndShowPlainCredentialDialog({
  required BuildContext context,
  required VaultService vaultService,
  required HostConfig host,
}) async {
  final auth = await vaultService.authenticateUser(
    reason: '验证系统身份以查看服务器 "${host.name}" (${host.username}@${host.host}) 已保存的凭据',
  );
  if (!context.mounted) return;
  if (!auth.isAuthenticated) {
    if (auth.outcome != VaultAuthOutcome.canceled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            auth.message.isEmpty ? '身份验证未通过，无法查看明文凭据' : auth.message,
          ),
        ),
      );
    }
    return;
  }

  final cred = await vaultService.readCredential(host);
  if (!context.mounted) return;
  if (!VaultService.hasNonEmptySecret(cred)) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('该主机当前未保存任何密码或私钥内容')));
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (dlgCtx) {
      final hasPwd = cred?.password != null && cred!.password!.isNotEmpty;
      final hasPem =
          cred?.privateKeyPem != null && cred!.privateKeyPem!.trim().isNotEmpty;
      return AlertDialog(
        title: Row(
          children: [
            const Icon(
              Icons.verified_user_outlined,
              size: 18,
              color: TxColors.success,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '已解密凭据 · ${host.name}',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '账号：${host.username}@${host.host}:${host.port}',
                style: const TextStyle(
                  fontSize: 12,
                  color: TxColors.textSecondary,
                ),
              ),
              const SizedBox(height: 10),
              if (hasPwd) ...[
                const Text(
                  'SSH 登录密码：',
                  style: TextStyle(fontSize: 11.5, color: TxColors.textMuted),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: TxColors.bgChrome,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TxColors.borderDefault),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SelectableText(
                          cred.password!,
                          style: const TextStyle(
                            fontSize: 13,
                            fontFamily: TxColors.monoFamily,
                            color: TxColors.textPrimary,
                          ),
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '复制密码',
                        icon: const Icon(Icons.copy_rounded, size: 15),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: cred.password!));
                          ScaffoldMessenger.of(dlgCtx).showSnackBar(
                            const SnackBar(content: Text('已复制密码到剪贴板')),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
              if (hasPem) ...[
                if (hasPwd) const SizedBox(height: 10),
                const Text(
                  'SSH 私钥内容：',
                  style: TextStyle(fontSize: 11.5, color: TxColors.textMuted),
                ),
                const SizedBox(height: 4),
                Container(
                  constraints: const BoxConstraints(maxHeight: 140),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: TxColors.bgChrome,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TxColors.borderDefault),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      cred.privateKeyPem!,
                      style: const TextStyle(
                        fontSize: 11,
                        fontFamily: TxColors.monoFamily,
                        color: TxColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dlgCtx).pop(),
            child: const Text('完成并重新锁定'),
          ),
        ],
      );
    },
  );
}

/// 1. 安全凭据与系统钥匙串管理弹窗
Future<void> showKeychainVaultDialog({
  required BuildContext context,
  required VaultService vaultService,
  required List<HostConfig> hosts,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: vaultService,
      builder: (ctx, _) {
        final audits = vaultService.inspectAuditItems(hosts);
        final isCompactDlg = MediaQuery.sizeOf(ctx).width < 600;
        return AlertDialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: isCompactDlg ? 16 : 32,
            vertical: 20,
          ),
          scrollable: true,
          title: const Row(
            children: [
              Icon(
                Icons.key_outlined,
                size: 18,
                color: TxColors.textSecondary,
              ),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '安全凭据管理',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 640,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: TxColors.bgPanel,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: TxColors.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.shield_outlined,
                        color: TxColors.success,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '当前凭据存储后端：${vaultService.platformVaultBackendName}',
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '所有密码与私钥均加密存储；查看或复制已保存密码时强制要求验证 ${vaultService.shortAuthMethodLabel}。',
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.4,
                                color: TxColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (Platform.isMacOS || Platform.isIOS)
                  SwitchListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    value: vaultService.iCloudKeychainEnabled,
                    onChanged: vaultService.setICloudKeychainEnabled,
                    title: const Text(
                      'iCloud 钥匙串跨设备同步',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: const Text(
                      '在 Mac、iPhone 与 iPad 之间同步已保存的 SSH 凭据',
                      style: TextStyle(fontSize: 11.5, color: TxColors.textMuted),
                    ),
                  ),
                SwitchListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  value: vaultService.biometricLockEnabled,
                  onChanged: vaultService.setBiometricLockEnabled,
                  title: const Text(
                    '建立 SSH 连接前也要求验证系统身份',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  subtitle: Text(
                    '开启后每次连接远程服务器前需通过 ${vaultService.shortAuthMethodLabel} 验证',
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: TxColors.textMuted,
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Divider(height: 1),
                ),
                const Text(
                  '已保存凭据摘要',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: TxColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: audits.isEmpty
                      ? const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: Text(
                              '暂无已保存的远程主机凭据',
                              style: TextStyle(
                                fontSize: 12,
                                color: TxColors.textMuted,
                              ),
                            ),
                          ),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: audits.length,
                          itemBuilder: (context, i) {
                            final item = audits[i];
                            return Container(
                              margin: const EdgeInsets.only(bottom: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 7,
                              ),
                              decoration: BoxDecoration(
                                color: TxColors.bgChrome,
                                borderRadius: BorderRadius.circular(5),
                                border: Border.all(
                                  color: TxColors.borderSubtle,
                                ),
                              ),
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.key_rounded,
                                    size: 14,
                                    color: TxColors.textMuted,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.hostName,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                            color: TxColors.textPrimary,
                                          ),
                                        ),
                                        Text(
                                          '${item.key}  ·  ${item.digestFingerprint}',
                                          style: const TextStyle(
                                            fontSize: 10.5,
                                            fontFamily: TxColors.monoFamily,
                                            color: TxColors.textMuted,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (item.synchronizable &&
                                      (Platform.isMacOS || Platform.isIOS))
                                    Container(
                                      margin: const EdgeInsets.only(right: 6),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: TxColors.bgElevated,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: TxColors.borderDefault,
                                        ),
                                      ),
                                      child: const Text(
                                        'iCloud',
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: TxColors.textSecondary,
                                        ),
                                      ),
                                    ),
                                  if (item.host.authMethod !=
                                      AuthMethod.demoSandbox)
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      tooltip: '验证身份后查看凭据（指纹 / 人脸 / 密码）',
                                      icon: const Icon(
                                        Icons.fingerprint_rounded,
                                        size: 16,
                                        color: TxColors.iconDefault,
                                      ),
                                      onPressed: () =>
                                          _verifyAndShowPlainCredentialDialog(
                                            context: ctx,
                                            vaultService: vaultService,
                                            host: item.host,
                                          ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}

/// 2. 新增 / 编辑 SSH 主机与写入钥匙串凭据弹窗
Future<HostConfig?> showAddHostDialog({
  required BuildContext context,
  required Future<void> Function(HostConfig host, HostSecretCredential secret)
  onSave,
  VaultService? vaultService,
  String? initialGroup,
  List<String> existingGroups = const [],
}) {
  return showHostFormDialog(
    context: context,
    onSave: onSave,
    vaultService: vaultService,
    initialGroup: initialGroup,
    existingGroups: existingGroups,
  );
}

Future<HostConfig?> showHostFormDialog({
  required BuildContext context,
  required Future<void> Function(HostConfig host, HostSecretCredential secret)
  onSave,
  HostConfig? existingHost,
  HostSecretCredential? initialCredential,
  VaultService? vaultService,
  bool hasSavedCredential = false,
  Future<void> Function(HostConfig host)? onDelete,
  String? initialGroup,
  List<String> existingGroups = const [],
}) {
  return showDialog<HostConfig>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _HostFormDialog(
      existingHost: existingHost,
      initialCredential: initialCredential,
      vaultService: vaultService,
      hasSavedCredential: hasSavedCredential,
      onSave: onSave,
      onDelete: onDelete,
      initialGroup: initialGroup,
      existingGroups: existingGroups,
    ),
  );
}

class _HostFormDialog extends StatefulWidget {
  const _HostFormDialog({
    required this.onSave,
    this.existingHost,
    this.initialCredential,
    this.vaultService,
    this.hasSavedCredential = false,
    this.onDelete,
    this.initialGroup,
    this.existingGroups = const [],
  });

  final HostConfig? existingHost;
  final HostSecretCredential? initialCredential;
  final VaultService? vaultService;
  final bool hasSavedCredential;
  final Future<void> Function(HostConfig host, HostSecretCredential secret)
  onSave;
  final Future<void> Function(HostConfig host)? onDelete;
  final String? initialGroup;
  final List<String> existingGroups;

  @override
  State<_HostFormDialog> createState() => _HostFormDialogState();
}

class _HostFormDialogState extends State<_HostFormDialog> {
  late final TextEditingController _nameCtrl;
  late final TextEditingController _groupCtrl;
  late final TextEditingController _hostCtrl;
  late final TextEditingController _portCtrl;
  late final TextEditingController _userCtrl;
  late final TextEditingController _passCtrl;
  late final TextEditingController _pemCtrl;
  late final TextEditingController _passphraseCtrl;
  late final TextEditingController _initCmdCtrl;
  late final TextEditingController _tagsCtrl;

  late AuthMethod _authMethod;
  late bool _syncICloud;
  late bool _requireBiometric;
  int? _tabColorValue;
  bool _obscurePassword = true;
  bool _obscurePassphrase = true;
  late bool _credentialLocked;
  bool _resettingLockedCredential = false;
  bool _verifyingAuth = false;
  String? _authFeedback;
  bool _saving = false;
  String? _saveError;

  bool get _isEditing => widget.existingHost != null;
  bool get _isApple => Platform.isMacOS || Platform.isIOS;

  String get _shortAuthLabel =>
      widget.vaultService?.shortAuthMethodLabel ??
      (Platform.isWindows
          ? 'Windows Hello（指纹 / 人脸 / PIN）或系统密码'
          : (Platform.isMacOS
                ? 'Touch ID 指纹或系统密码'
                : (Platform.isIOS
                      ? 'Face ID / Touch ID 或锁屏密码'
                      : '指纹 / 人脸识别或锁屏密码')));

  @override
  void initState() {
    super.initState();
    final h = widget.existingHost;
    final cred = widget.initialCredential;
    final hasExistingSecret =
        _isEditing &&
        (widget.hasSavedCredential || VaultService.hasNonEmptySecret(cred));

    // 编辑已有主机且存在已保存凭据时，绝不在通过系统身份验证前向输入框装填任何明文密码/私钥
    _credentialLocked = hasExistingSecret;

    _nameCtrl = TextEditingController(text: h?.name ?? '');
    _groupCtrl = TextEditingController(
      text: h?.group ?? widget.initialGroup ?? '默认分组',
    );
    _hostCtrl = TextEditingController(text: h?.host ?? '');
    _portCtrl = TextEditingController(text: '${h?.port ?? 22}');
    _userCtrl = TextEditingController(text: h?.username ?? 'root');
    _passCtrl = TextEditingController(
      text: _credentialLocked ? '' : (cred?.password ?? ''),
    );
    _pemCtrl = TextEditingController(
      text: _credentialLocked ? '' : (cred?.privateKeyPem ?? ''),
    );
    _passphraseCtrl = TextEditingController(
      text: _credentialLocked ? '' : (cred?.passphrase ?? ''),
    );
    _initCmdCtrl = TextEditingController(text: h?.initCommand ?? '');
    _tagsCtrl = TextEditingController(text: h?.tags.join(', ') ?? '');

    _authMethod = (h == null || h.authMethod == AuthMethod.localShell)
        ? AuthMethod.password
        : h.authMethod;
    _syncICloud = h?.syncToICloudKeychain ?? _isApple;
    _requireBiometric = h?.requireBiometricUnlock ?? false;
    _tabColorValue = h?.tabColorValue;
  }

  Future<void> _unlockSavedCredential() async {
    if (_verifyingAuth) return;
    final host = widget.existingHost;
    if (host == null) return;

    setState(() {
      _verifyingAuth = true;
      _authFeedback = null;
    });

    try {
      final vault = widget.vaultService;
      if (vault == null) {
        setState(() {
          _verifyingAuth = false;
          _authFeedback = '当前上下文未绑定安全凭据中心，无法解密查看原密码。';
        });
        return;
      }

      final auth = await vault.authenticateUser(
        reason: '验证系统身份以查看服务器 "${host.name}" (${host.username}@${host.host}) 已保存的凭据',
      );
      if (!mounted) return;

      if (!auth.isAuthenticated) {
        setState(() {
          _verifyingAuth = false;
          _authFeedback = auth.outcome == VaultAuthOutcome.canceled
              ? '已取消身份验证，原登录凭据仍处于加密锁定状态'
              : (auth.message.isEmpty ? '身份验证未通过，无法查看已保存密码' : auth.message);
        });
        return;
      }

      final unlockedCred =
          await vault.readCredential(host) ?? widget.initialCredential;
      if (!mounted) return;

      setState(() {
        _verifyingAuth = false;
        _credentialLocked = false;
        _resettingLockedCredential = false;
        _authFeedback = null;
        _passCtrl.text = unlockedCred?.password ?? '';
        _pemCtrl.text = unlockedCred?.privateKeyPem ?? '';
        _passphraseCtrl.text = unlockedCred?.passphrase ?? '';
        // 验证通过后直接展示明文密码，方便核对或复制
        _obscurePassword = false;
        _obscurePassphrase = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _verifyingAuth = false;
        _authFeedback = '读取凭据失败：$e';
      });
    }
  }

  @override
  void dispose() {
    for (final c in [
      _nameCtrl,
      _groupCtrl,
      _hostCtrl,
      _portCtrl,
      _userCtrl,
      _passCtrl,
      _pemCtrl,
      _passphraseCtrl,
      _initCmdCtrl,
      _tagsCtrl,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _confirmDelete() async {
    final target = widget.existingHost;
    final onDelete = widget.onDelete;
    if (target == null || onDelete == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '删除已保存会话',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Text(
          '确定要删除 "${target.name}" (${target.username}@${target.host}:${target.port}) 及其保存的登录凭据吗？',
          style: const TextStyle(fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: TxColors.danger,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await onDelete(target);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = '删除失败，请检查本地配置文件访问权限。';
        });
      }
    }
  }

  Future<void> _submitSave() async {
    setState(() {
      _saving = true;
      _saveError = null;
    });

    final old = widget.existingHost;
    final hostAddr = _hostCtrl.text.trim().isEmpty
        ? '127.0.0.1'
        : _hostCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim()) ?? 22;
    final name = _nameCtrl.text.trim().isEmpty
        ? hostAddr
        : _nameCtrl.text.trim();
    final group = _groupCtrl.text.trim().isEmpty
        ? '默认分组'
        : _groupCtrl.text.trim();
    final username = _userCtrl.text.trim().isEmpty
        ? 'root'
        : _userCtrl.text.trim();
    final initCmd = _initCmdCtrl.text.trim();
    final tags = _tagsCtrl.text
        .split(RegExp(r'[,，]'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();

    // 仅当服务器地址/端口/认证模式未改变时保留已记住的系统类型与版本
    final keepDetectedOs =
        old != null &&
        old.host == hostAddr &&
        old.port == port &&
        old.authMethod == _authMethod;

    final config = HostConfig(
      id: old?.id ?? 'host_${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      group: group,
      host: hostAddr,
      port: port,
      username: username,
      authMethod: _authMethod,
      tags: tags,
      syncToICloudKeychain: _syncICloud,
      requireBiometricUnlock: _requireBiometric,
      initCommand: initCmd.isEmpty ? null : initCmd,
      jumpHostId: old?.jumpHostId,
      lastConnectedAt: old?.lastConnectedAt,
      detectedOs: keepDetectedOs ? old.detectedOs : null,
      detectedOsPrettyName: keepDetectedOs ? old.detectedOsPrettyName : null,
      tabColorValue: _tabColorValue,
    );

    try {
      HostSecretCredential secret;
      if (_credentialLocked && !_resettingLockedCredential && old != null) {
        final preserved =
            await widget.vaultService?.readCredential(old) ??
            widget.initialCredential;
        secret =
            preserved ??
            HostSecretCredential(
              password: '',
              privateKeyPem: '',
              updatedAt: DateTime.now(),
            );
      } else {
        secret = HostSecretCredential(
          password: _passCtrl.text,
          privateKeyPem: _pemCtrl.text,
          passphrase: _passphraseCtrl.text.trim().isEmpty
              ? null
              : _passphraseCtrl.text,
          updatedAt: DateTime.now(),
        );
      }
      await widget.onSave(config, secret);
      if (mounted) {
        Navigator.of(context).pop(config);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = '保存失败，请检查本地配置文件和系统安全存储的访问权限后重试。';
        });
      }
    }
  }

  static const EdgeInsets _fieldContentPadding = EdgeInsets.symmetric(
    horizontal: 13,
    vertical: 11,
  );

  Widget _buildLabeledField({
    required String label,
    required Widget child,
    Widget? trailingAction,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w500,
                  color: TxColors.textSecondary,
                ),
              ),
            ),
            if (trailingAction != null) trailingAction,
          ],
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _buildLockedCredentialBox({required bool isPrivateKey}) {
    final titleText = isPrivateKey
        ? 'SSH 私钥与口令已加密保存  ·  ••••••••••••'
        : 'SSH 登录密码已加密保存  ·  ••••••••••••';
    final resetLabel = isPrivateKey ? '更换私钥' : '更改密码';

    final actionButtons = Wrap(
      spacing: 10,
      runSpacing: 8,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
          onPressed: _verifyingAuth ? null : _unlockSavedCredential,
          icon: Icon(
            _verifyingAuth
                ? Icons.hourglass_top_rounded
                : Icons.fingerprint_rounded,
            size: 16,
          ),
          label: Text(
            _verifyingAuth ? '正在验证身份…' : '验证身份查看',
            style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500),
          ),
        ),
        OutlinedButton.icon(
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
            side: const BorderSide(color: TxColors.borderStrong),
          ),
          onPressed: _verifyingAuth
              ? null
              : () {
                  setState(() {
                    _resettingLockedCredential = true;
                    _authFeedback = null;
                    _passCtrl.clear();
                    _pemCtrl.clear();
                    _passphraseCtrl.clear();
                    _obscurePassword = true;
                    _obscurePassphrase = true;
                  });
                },
          icon: const Icon(Icons.edit_outlined, size: 15),
          label: Text(
            resetLabel,
            style: const TextStyle(fontSize: 12.5),
          ),
        ),
      ],
    );

    final infoColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.verified_user_outlined,
              size: 18,
              color: TxColors.success,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                titleText,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TxColors.textPrimary,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 5),
        Text(
          '修改主机信息可直接保存；查看或复制原凭据需先验证 $_shortAuthLabel。',
          style: const TextStyle(
            fontSize: 12,
            height: 1.45,
            color: TxColors.textMuted,
          ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
          decoration: BoxDecoration(
            color: TxColors.bgChrome,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: TxColors.borderDefault),
          ),
          child: LayoutBuilder(
            builder: (context, boxConstraints) {
              final useRow = boxConstraints.maxWidth >= 500;
              if (useRow) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(child: infoColumn),
                    const SizedBox(width: 16),
                    actionButtons,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  infoColumn,
                  const SizedBox(height: 12),
                  actionButtons,
                ],
              );
            },
          ),
        ),
        if (_authFeedback != null)
          Padding(
            padding: const EdgeInsets.only(top: 7, left: 2),
            child: Text(
              _authFeedback!,
              style: const TextStyle(fontSize: 12, color: TxColors.warning),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: LayoutBuilder(
        builder: (context, viewport) {
          final availW = viewport.maxWidth.isFinite
              ? viewport.maxWidth
              : MediaQuery.sizeOf(context).width;
          final availH = viewport.maxHeight.isFinite
              ? viewport.maxHeight
              : MediaQuery.sizeOf(context).height;
          final safePad = MediaQuery.paddingOf(context);
          final isWide = availW >= 660;
          final dialogWidth = isWide
              ? 680.0
              : (availW - safePad.horizontal - 24).clamp(260.0, 680.0);

          final userField = _buildLabeledField(
            label: '登录用户名 (Username)',
            child: TextField(
              key: const Key('host_form_user_input'),
              controller: _userCtrl,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                hintText: '例如 root / ubuntu / dpc',
                isDense: false,
                contentPadding: _fieldContentPadding,
              ),
            ),
          );

          final authMethodField = _buildLabeledField(
            label: '认证方式',
            child: DropdownButtonFormField<AuthMethod>(
              initialValue: _authMethod,
              isExpanded: true,
              dropdownColor: TxColors.bgElevated,
              style: const TextStyle(
                fontSize: 13.5,
                color: TxColors.textPrimary,
              ),
              decoration: const InputDecoration(
                isDense: false,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 13,
                  vertical: 9.5,
                ),
              ),
              items: const [
                DropdownMenuItem(
                  value: AuthMethod.password,
                  child: Text('密码认证'),
                ),
                DropdownMenuItem(
                  value: AuthMethod.privateKey,
                  child: Text('SSH 私钥认证'),
                ),
                DropdownMenuItem(
                  value: AuthMethod.demoSandbox,
                  child: Text('离线沙盒演示节点'),
                ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _authMethod = v);
              },
            ),
          );

          final tagsField = _buildLabeledField(
            label: '备注标签（可选）',
            child: TextField(
              controller: _tagsCtrl,
              style: const TextStyle(fontSize: 13.5),
              decoration: const InputDecoration(
                hintText: '逗号分隔，如 NAS, Ubuntu',
                isDense: false,
                contentPadding: _fieldContentPadding,
              ),
            ),
          );

          final initCmdField = _buildLabeledField(
            label: '登录后初始命令（可选）',
            child: TextField(
              controller: _initCmdCtrl,
              style: const TextStyle(
                fontSize: 13.5,
                fontFamily: TxColors.monoFamily,
              ),
              decoration: const InputDecoration(
                hintText: '例如 tmux a',
                isDense: false,
                contentPadding: _fieldContentPadding,
              ),
            ),
          );

          return SafeArea(
            child: Dialog(
              insetPadding: EdgeInsets.symmetric(
                horizontal: isWide ? 32 : 12,
                vertical: isWide ? 20 : 12,
              ),
              backgroundColor: const Color(0xFF16191F),
              surfaceTintColor: Colors.transparent,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: TxColors.borderDefault),
              ),
              child: SizedBox(
                width: dialogWidth,
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: (availH - safePad.vertical - (isWide ? 40 : 24))
                        .clamp(180.0, 920.0),
                  ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 顶部标题栏
                    Padding(
                      padding: const EdgeInsets.fromLTRB(26, 18, 18, 14),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: TxColors.bgElevated,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: TxColors.borderDefault),
                            ),
                            child: Icon(
                              _isEditing
                                  ? Icons.edit_outlined
                                  : Icons.dns_outlined,
                              size: 17,
                              color: TxColors.accent,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _isEditing
                                      ? '编辑 SSH 服务器会话'
                                      : '新建 SSH 服务器连接',
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: TxColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _isEditing
                                      ? '管理服务器连接地址、加密登录凭据与标签分组'
                                      : '填写远程主机连接参数，登录密码与私钥将加密存入系统凭据库',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: TxColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            tooltip: '关闭',
                            onPressed: _saving
                                ? null
                                : () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.close_rounded, size: 19),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),

                    // 主体滚动表单区域
                    Flexible(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          isWide ? 26 : 18,
                          18,
                          isWide ? 26 : 18,
                          18,
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // 第一行：主机别名 + 所属分组
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: _buildLabeledField(
                                    label: '主机别名',
                                    child: TextField(
                                      key: const Key('host_form_alias_input'),
                                      controller: _nameCtrl,
                                      style: const TextStyle(fontSize: 13.5),
                                      decoration: const InputDecoration(
                                        hintText: '例如 Mix / Prod-Node',
                                        isDense: false,
                                        contentPadding: _fieldContentPadding,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  flex: 2,
                                  child: _buildLabeledField(
                                    label: '所属分组',
                                    child: TextField(
                                      key: const Key('host_form_group_input'),
                                      controller: _groupCtrl,
                                      onChanged: (_) => setState(() {}),
                                      style: const TextStyle(fontSize: 13.5),
                                      decoration: const InputDecoration(
                                        hintText: '例如 Home / 生产集群',
                                        isDense: false,
                                        contentPadding: _fieldContentPadding,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                const Text(
                                  '常用分组：',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: TxColors.textMuted,
                                  ),
                                ),
                                for (final g in <String>{
                                  ...widget.existingGroups.where(
                                    (e) =>
                                        e.trim().isNotEmpty && e.trim() != '本机',
                                  ),
                                  '默认分组',
                                  '家庭 NAS',
                                  '生产环境',
                                  '开发测试',
                                })
                                  InkWell(
                                    borderRadius: BorderRadius.circular(6),
                                    onTap: () =>
                                        setState(() => _groupCtrl.text = g),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 10,
                                        vertical: 4.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _groupCtrl.text.trim() == g
                                            ? TxColors.bgSelected
                                            : TxColors.bgChrome,
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: _groupCtrl.text.trim() == g
                                              ? TxColors.accent
                                              : TxColors.borderSubtle,
                                        ),
                                      ),
                                      child: Text(
                                        g,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          fontWeight:
                                              _groupCtrl.text.trim() == g
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                          color: _groupCtrl.text.trim() == g
                                              ? TxColors.textPrimary
                                              : TxColors.textSecondary,
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),

                            const SizedBox(height: 15),

                            // 第二行：服务器地址 + 端口
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  flex: isWide ? 4 : 3,
                                  child: _buildLabeledField(
                                    label: '服务器地址 (Host / IP)',
                                    child: TextField(
                                      key: const Key('host_form_host_input'),
                                      controller: _hostCtrl,
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        fontFamily: TxColors.monoFamily,
                                      ),
                                      decoration: const InputDecoration(
                                        hintText:
                                            '例如 192.168.31.62 或 example.com',
                                        isDense: false,
                                        contentPadding: _fieldContentPadding,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  flex: 1,
                                  child: _buildLabeledField(
                                    label: 'SSH 端口',
                                    child: TextField(
                                      key: const Key('host_form_port_input'),
                                      controller: _portCtrl,
                                      keyboardType: TextInputType.number,
                                      style: const TextStyle(
                                        fontSize: 13.5,
                                        fontFamily: TxColors.monoFamily,
                                      ),
                                      decoration: const InputDecoration(
                                        hintText: '22',
                                        isDense: false,
                                        contentPadding: _fieldContentPadding,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 15),

                            // 第三行：PC 双列并排（登录用户名 + 认证方式），窄屏纵向排布
                            if (isWide)
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(flex: 3, child: userField),
                                  const SizedBox(width: 16),
                                  Expanded(flex: 2, child: authMethodField),
                                ],
                              )
                            else ...[
                              userField,
                              const SizedBox(height: 14),
                              authMethodField,
                            ],

                            if (_authMethod != AuthMethod.demoSandbox) ...[
                              const SizedBox(height: 15),

                              if (_authMethod == AuthMethod.password) ...[
                                if (_credentialLocked &&
                                    !_resettingLockedCredential)
                                  _buildLockedCredentialBox(isPrivateKey: false)
                                else
                                  _buildLabeledField(
                                    label: _resettingLockedCredential
                                        ? '输入新的 SSH 登录密码（保存后覆盖原密码）'
                                        : 'SSH 登录密码',
                                    trailingAction: _resettingLockedCredential
                                        ? TextButton.icon(
                                            style: TextButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                  ),
                                            ),
                                            onPressed: () => setState(() {
                                              _resettingLockedCredential =
                                                  false;
                                              _passCtrl.clear();
                                            }),
                                            icon: const Icon(
                                              Icons.undo_rounded,
                                              size: 14,
                                            ),
                                            label: const Text(
                                              '取消更改（保留原保存密码）',
                                              style: TextStyle(fontSize: 12),
                                            ),
                                          )
                                        : null,
                                    child: TextField(
                                      key: const Key(
                                        'host_form_password_input',
                                      ),
                                      controller: _passCtrl,
                                      obscureText: _obscurePassword,
                                      style: const TextStyle(fontSize: 13.5),
                                      decoration: InputDecoration(
                                        hintText: _resettingLockedCredential
                                            ? '请输入新密码'
                                            : '输入服务器 SSH 登录密码',
                                        isDense: false,
                                        contentPadding: _fieldContentPadding,
                                        prefixIcon: const Icon(
                                          Icons.lock_outline,
                                          size: 18,
                                        ),
                                        suffixIcon: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_isEditing &&
                                                !_credentialLocked &&
                                                !_resettingLockedCredential &&
                                                _passCtrl.text.isNotEmpty)
                                              IconButton(
                                                tooltip: '复制密码',
                                                icon: const Icon(
                                                  Icons.copy_rounded,
                                                  size: 16,
                                                ),
                                                onPressed: () {
                                                  Clipboard.setData(
                                                    ClipboardData(
                                                      text: _passCtrl.text,
                                                    ),
                                                  );
                                                  ScaffoldMessenger.of(
                                                    context,
                                                  ).showSnackBar(
                                                    const SnackBar(
                                                      content: Text(
                                                        '已复制密码到剪贴板',
                                                      ),
                                                    ),
                                                  );
                                                },
                                              ),
                                            IconButton(
                                              tooltip: _obscurePassword
                                                  ? '显示密码'
                                                  : '隐藏密码',
                                              icon: Icon(
                                                _obscurePassword
                                                    ? Icons.visibility_outlined
                                                    : Icons
                                                          .visibility_off_outlined,
                                                size: 17,
                                              ),
                                              onPressed: () => setState(
                                                () => _obscurePassword =
                                                    !_obscurePassword,
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],

                              if (_authMethod == AuthMethod.privateKey) ...[
                                if (_credentialLocked &&
                                    !_resettingLockedCredential)
                                  _buildLockedCredentialBox(isPrivateKey: true)
                                else ...[
                                  _buildLabeledField(
                                    label: _resettingLockedCredential
                                        ? '输入新的 SSH 私钥内容（保存后覆盖原私钥）'
                                        : 'SSH 私钥内容 (PEM / OpenSSH)',
                                    trailingAction: _resettingLockedCredential
                                        ? TextButton.icon(
                                            style: TextButton.styleFrom(
                                              visualDensity:
                                                  VisualDensity.compact,
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 6,
                                                  ),
                                            ),
                                            onPressed: () => setState(() {
                                              _resettingLockedCredential =
                                                  false;
                                              _pemCtrl.clear();
                                              _passphraseCtrl.clear();
                                            }),
                                            icon: const Icon(
                                              Icons.undo_rounded,
                                              size: 14,
                                            ),
                                            label: const Text(
                                              '取消更换（保留原保存私钥）',
                                              style: TextStyle(fontSize: 12),
                                            ),
                                          )
                                        : null,
                                    child: TextField(
                                      controller: _pemCtrl,
                                      maxLines: 4,
                                      style: const TextStyle(
                                        fontFamily: TxColors.monoFamily,
                                        fontSize: 12,
                                      ),
                                      decoration: const InputDecoration(
                                        hintText:
                                            '-----BEGIN OPENSSH PRIVATE KEY-----',
                                        isDense: false,
                                        contentPadding: EdgeInsets.all(12),
                                        border: OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  _buildLabeledField(
                                    label: '私钥口令 Passphrase（可选）',
                                    child: TextField(
                                      controller: _passphraseCtrl,
                                      obscureText: _obscurePassphrase,
                                      style: const TextStyle(fontSize: 13.5),
                                      decoration: InputDecoration(
                                        hintText: '若私钥未设口令可留空',
                                        isDense: false,
                                        contentPadding: _fieldContentPadding,
                                        suffixIcon: IconButton(
                                          tooltip: _obscurePassphrase
                                              ? '显示口令'
                                              : '隐藏口令',
                                          icon: Icon(
                                            _obscurePassphrase
                                                ? Icons.visibility_outlined
                                                : Icons.visibility_off_outlined,
                                            size: 17,
                                          ),
                                          onPressed: () => setState(
                                            () => _obscurePassphrase =
                                                !_obscurePassphrase,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ],

                            const Padding(
                              padding: EdgeInsets.symmetric(vertical: 16),
                              child: Divider(height: 1),
                            ),

                            // 第四行：备注标签 + 登录后初始命令
                            if (isWide)
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(child: tagsField),
                                  const SizedBox(width: 16),
                                  Expanded(child: initCmdField),
                                ],
                              )
                            else ...[
                              tagsField,
                              const SizedBox(height: 14),
                              initCmdField,
                            ],

                            const SizedBox(height: 15),

                            // 第五行：标签页配色
                            Wrap(
                              spacing: 10,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                const Text(
                                  '标签颜色：',
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w500,
                                    color: TxColors.textSecondary,
                                  ),
                                ),
                                Tooltip(
                                  message: '默认无色',
                                  child: InkWell(
                                    customBorder: const CircleBorder(),
                                    onTap: () =>
                                        setState(() => _tabColorValue = null),
                                    child: Container(
                                      width: 24,
                                      height: 24,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: TxColors.bgChrome,
                                        border: Border.all(
                                          color: _tabColorValue == null
                                              ? TxColors.textPrimary
                                              : TxColors.borderDefault,
                                          width: _tabColorValue == null
                                              ? 1.8
                                              : 1.0,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.format_color_reset_outlined,
                                        size: 13,
                                        color: TxColors.textSecondary,
                                      ),
                                    ),
                                  ),
                                ),
                                for (final preset in TabColorPreset.presets)
                                  Tooltip(
                                    message: preset.name,
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: () => setState(
                                        () => _tabColorValue = preset.color
                                            .toARGB32(),
                                      ),
                                      child: Container(
                                        width: 24,
                                        height: 24,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: preset.color,
                                          border: Border.all(
                                            color:
                                                _tabColorValue ==
                                                    preset.color.toARGB32()
                                                ? Colors.white
                                                : Colors.black26,
                                            width:
                                                _tabColorValue ==
                                                    preset.color.toARGB32()
                                                ? 2.0
                                                : 1.0,
                                          ),
                                        ),
                                        child:
                                            _tabColorValue ==
                                                preset.color.toARGB32()
                                            ? const Icon(
                                                Icons.check,
                                                size: 13,
                                                color: Colors.black87,
                                              )
                                            : null,
                                      ),
                                    ),
                                  ),
                              ],
                            ),

                            if (_isApple ||
                                _authMethod != AuthMethod.demoSandbox) ...[
                              const SizedBox(height: 15),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 9,
                                ),
                                decoration: BoxDecoration(
                                  color: TxColors.bgChrome,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: TxColors.borderSubtle,
                                  ),
                                ),
                                child: Column(
                                  children: [
                                    if (_isApple) ...[
                                      Row(
                                        children: [
                                          const Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  '同步至 iCloud 钥匙串',
                                                  style: TextStyle(
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w500,
                                                    color: TxColors.textPrimary,
                                                  ),
                                                ),
                                                SizedBox(height: 2),
                                                Text(
                                                  '在 Mac、iPhone 与 iPad 之间加密同步此服务器凭据',
                                                  style: TextStyle(
                                                    fontSize: 11.5,
                                                    color: TxColors.textMuted,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Switch(
                                            value: _syncICloud,
                                            activeThumbColor: TxColors.accent,
                                            onChanged: (v) => setState(
                                              () => _syncICloud = v,
                                            ),
                                          ),
                                        ],
                                      ),
                                      if (_authMethod != AuthMethod.demoSandbox)
                                        const Padding(
                                          padding: EdgeInsets.symmetric(
                                            vertical: 8,
                                          ),
                                          child: Divider(height: 1),
                                        ),
                                    ],
                                    if (_authMethod != AuthMethod.demoSandbox)
                                      InkWell(
                                        borderRadius: BorderRadius.circular(6),
                                        onTap: () => setState(
                                          () => _requireBiometric =
                                              !_requireBiometric,
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 2,
                                          ),
                                          child: Row(
                                            children: [
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment:
                                                      CrossAxisAlignment.start,
                                                  children: [
                                                    const Text(
                                                      '连接前要求验证系统身份',
                                                      style: TextStyle(
                                                        fontSize: 13,
                                                        fontWeight:
                                                            FontWeight.w500,
                                                        color: TxColors
                                                            .textPrimary,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 2),
                                                    Text(
                                                      '每次建立 SSH 连接前需通过 $_shortAuthLabel 验证',
                                                      style: const TextStyle(
                                                        fontSize: 11.5,
                                                        color:
                                                            TxColors.textMuted,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Switch(
                                                value: _requireBiometric,
                                                activeThumbColor:
                                                    TxColors.accent,
                                                onChanged: (v) => setState(
                                                  () => _requireBiometric = v,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],

                            if (_saveError != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  _saveError!,
                                  style: const TextStyle(
                                    fontSize: 12.5,
                                    color: TxColors.danger,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),

                    const Divider(height: 1),
                    // 底部操作栏：删除按钮居左隔离防误触，取消/保存居右对齐
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        isWide ? 20 : 12,
                        13,
                        isWide ? 26 : 16,
                        16,
                      ),
                      child: Row(
                        children: [
                          if (_isEditing && widget.onDelete != null)
                            TextButton.icon(
                              onPressed: _saving ? null : _confirmDelete,
                              style: TextButton.styleFrom(
                                foregroundColor: TxColors.danger,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                              ),
                              icon: const Icon(
                                Icons.delete_outline_rounded,
                                size: 16,
                              ),
                              label: const Text(
                                '删除主机',
                                style: TextStyle(fontSize: 13),
                              ),
                            ),
                          const Spacer(),
                          OutlinedButton(
                            onPressed: _saving
                                ? null
                                : () => Navigator.of(context).pop(),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 11,
                              ),
                              side: const BorderSide(
                                color: TxColors.borderDefault,
                              ),
                            ),
                            child: const Text(
                              '取消',
                              style: TextStyle(fontSize: 13),
                            ),
                          ),
                          const SizedBox(width: 12),
                          FilledButton(
                            onPressed: _saving ? null : _submitSave,
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 11,
                              ),
                            ),
                            child: Text(
                              _saving
                                  ? '正在保存…'
                                  : (_isEditing ? '保存修改' : '保存并连接'),
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          );
        },
      ),
    );
  }
}

/// 3. 扩展管理弹窗
Future<void> showPluginManagerDialog({
  required BuildContext context,
  required PluginManager pluginManager,
  required VoidCallback onInstallSampleCommunityPlugin,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => ListenableBuilder(
      listenable: pluginManager,
      builder: (ctx, _) {
        final plugins = pluginManager.allPlugins;
        final isCompactDlg = MediaQuery.sizeOf(ctx).width < 600;
        return AlertDialog(
          insetPadding: EdgeInsets.symmetric(
            horizontal: isCompactDlg ? 16 : 32,
            vertical: 20,
          ),
          title: Row(
            children: [
              const Icon(
                Icons.widgets_outlined,
                size: 18,
                color: TxColors.textSecondary,
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  '扩展管理',
                  style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: onInstallSampleCommunityPlugin,
                icon: const Icon(Icons.add_rounded, size: 15),
                label: Text(
                  isCompactDlg ? 'Docker 扩展' : '加载 Docker 容器扩展',
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 640,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '按需启用或停用工作台扩展面板与状态栏指标组件：',
                  style: TextStyle(fontSize: 12.5, color: TxColors.textMuted),
                ),
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: plugins.length,
                    itemBuilder: (context, idx) {
                      final p = plugins[idx];
                      final m = p.manifest;
                      final enabled = pluginManager.isPluginEnabled(m.id);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: TxColors.bgPanel,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: enabled
                                ? TxColors.borderDefault
                                : TxColors.borderSubtle,
                          ),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.all(7),
                              decoration: BoxDecoration(
                                color: TxColors.bgElevated,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: TxColors.borderSubtle,
                                ),
                              ),
                              child: Icon(
                                m.icon,
                                color: enabled
                                    ? TxColors.textPrimary
                                    : TxColors.textMuted,
                                size: 18,
                              ),
                            ),
                            const SizedBox(width: 11),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Flexible(
                                        child: Text(
                                          m.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            color: TxColors.textPrimary,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'v${m.version}',
                                        style: const TextStyle(
                                          fontSize: 10.5,
                                          fontFamily: TxColors.monoFamily,
                                          color: TxColors.textMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    m.description,
                                    style: const TextStyle(
                                      fontSize: 11.5,
                                      color: TxColors.textSecondary,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Wrap(
                                    spacing: 6,
                                    runSpacing: 4,
                                    children: m.permissions.map((perm) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: TxColors.bgChrome,
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(
                                            color: TxColors.borderSubtle,
                                          ),
                                        ),
                                        child: Text(
                                          perm.description,
                                          style: const TextStyle(
                                            fontSize: 10,
                                            fontFamily: TxColors.monoFamily,
                                            color: TxColors.textMuted,
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ],
                              ),
                            ),
                            Switch(
                              value: enabled,
                              activeThumbColor: TxColors.accent,
                              onChanged: (v) =>
                                  pluginManager.setPluginEnabled(m.id, v),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    ),
  );
}
