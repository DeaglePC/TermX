import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/models/host_config.dart';
import '../../core/plugin_system/plugin_manager.dart';
import '../../core/theme/ui_tokens.dart';
import '../../core/vault/vault_service.dart';
import 'terminal_tab_button.dart';

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
        return AlertDialog(
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
            width: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TxColors.bgPanel,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: TxColors.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.shield_outlined,
                        color: TxColors.success,
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '当前凭据存储后端：${vaultService.platformVaultBackendName}',
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: TxColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              '所有 SSH 密码与私钥均加密存储在操作系统原生凭据保险库中，不以明文落盘。',
                              style: TextStyle(
                                fontSize: 11,
                                color: TxColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (Platform.isMacOS || Platform.isIOS) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: vaultService.iCloudKeychainEnabled,
                    onChanged: vaultService.setICloudKeychainEnabled,
                    title: const Text(
                      'iCloud 钥匙串跨设备同步',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    subtitle: const Text(
                      '在 Mac、iPhone 与 iPad 之间同步已保存的 SSH 凭据',
                      style: TextStyle(fontSize: 11, color: TxColors.textMuted),
                    ),
                  ),
                  SwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: vaultService.biometricLockEnabled,
                    onChanged: vaultService.setBiometricLockEnabled,
                    title: const Text(
                      '读取凭据前要求 Touch ID / Face ID 验证',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
                const Divider(height: 18),
                const Text(
                  '已保存凭据摘要',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: TxColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
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
  String? initialGroup,
  List<String> existingGroups = const [],
}) {
  return showHostFormDialog(
    context: context,
    onSave: onSave,
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
    this.onDelete,
    this.initialGroup,
    this.existingGroups = const [],
  });

  final HostConfig? existingHost;
  final HostSecretCredential? initialCredential;
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
  bool _saving = false;
  String? _saveError;

  bool get _isEditing => widget.existingHost != null;
  bool get _isApple => Platform.isMacOS || Platform.isIOS;

  @override
  void initState() {
    super.initState();
    final h = widget.existingHost;
    final cred = widget.initialCredential;
    _nameCtrl = TextEditingController(text: h?.name ?? '');
    _groupCtrl = TextEditingController(
      text: h?.group ?? widget.initialGroup ?? '默认分组',
    );
    _hostCtrl = TextEditingController(text: h?.host ?? '');
    _portCtrl = TextEditingController(text: '${h?.port ?? 22}');
    _userCtrl = TextEditingController(text: h?.username ?? 'root');
    _passCtrl = TextEditingController(text: cred?.password ?? '');
    _pemCtrl = TextEditingController(text: cred?.privateKeyPem ?? '');
    _passphraseCtrl = TextEditingController(text: cred?.passphrase ?? '');
    _initCmdCtrl = TextEditingController(text: h?.initCommand ?? '');
    _tagsCtrl = TextEditingController(text: h?.tags.join(', ') ?? '');

    _authMethod = (h == null || h.authMethod == AuthMethod.localShell)
        ? AuthMethod.password
        : h.authMethod;
    _syncICloud = h?.syncToICloudKeychain ?? _isApple;
    _requireBiometric = h?.requireBiometricUnlock ?? false;
    _tabColorValue = h?.tabColorValue;
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

    final secret = HostSecretCredential(
      password: _passCtrl.text,
      privateKeyPem: _pemCtrl.text,
      passphrase: _passphraseCtrl.text.trim().isEmpty
          ? null
          : _passphraseCtrl.text,
      updatedAt: DateTime.now(),
    );

    try {
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

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: Row(
          children: [
            Icon(
              _isEditing ? Icons.edit_outlined : Icons.dns_outlined,
              size: 18,
              color: TxColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              _isEditing ? '编辑 SSH 服务器会话' : '新建 SSH 服务器连接',
              style: const TextStyle(
                fontSize: 15.5,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: 490,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextField(
                        controller: _nameCtrl,
                        decoration: const InputDecoration(
                          labelText: '主机别名',
                          hintText: '例如 Mix / Prod-Node',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _groupCtrl,
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          labelText: '所属分组',
                          hintText: '例如 Home / 生产集群',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        '常用分组：',
                        style: TextStyle(
                          fontSize: 11,
                          color: TxColors.textMuted,
                        ),
                      ),
                      for (final g in <String>{
                        ...widget.existingGroups.where(
                          (e) => e.trim().isNotEmpty && e.trim() != '本机',
                        ),
                        '默认分组',
                        '家庭 NAS',
                        '生产环境',
                        '开发测试',
                      })
                        InkWell(
                          borderRadius: BorderRadius.circular(5),
                          onTap: () => setState(() => _groupCtrl.text = g),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: _groupCtrl.text.trim() == g
                                  ? TxColors.bgSelected
                                  : TxColors.bgChrome,
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: _groupCtrl.text.trim() == g
                                    ? TxColors.accent
                                    : TxColors.borderSubtle,
                              ),
                            ),
                            child: Text(
                              g,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: _groupCtrl.text.trim() == g
                                    ? TxColors.textPrimary
                                    : TxColors.textSecondary,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _hostCtrl,
                        decoration: const InputDecoration(
                          labelText: '服务器地址 (Host / IP)',
                          hintText: '例如 192.168.31.62',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _portCtrl,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: '端口',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _userCtrl,
                  decoration: const InputDecoration(
                    labelText: '登录用户名 (Username)',
                    hintText: '例如 root / ubuntu / dpc',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<AuthMethod>(
                  initialValue: _authMethod,
                  dropdownColor: TxColors.bgElevated,
                  decoration: const InputDecoration(
                    labelText: '认证方式',
                    isDense: true,
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
                const SizedBox(height: 10),
                if (_authMethod == AuthMethod.password)
                  TextField(
                    controller: _passCtrl,
                    obscureText: _obscurePassword,
                    decoration: InputDecoration(
                      labelText: 'SSH 登录密码',
                      prefixIcon: const Icon(Icons.lock_outline, size: 17),
                      suffixIcon: IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                        icon: Icon(
                          _obscurePassword
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                          size: 16,
                        ),
                        onPressed: () => setState(
                          () => _obscurePassword = !_obscurePassword,
                        ),
                      ),
                      isDense: true,
                    ),
                  ),
                if (_authMethod == AuthMethod.privateKey) ...[
                  TextField(
                    controller: _pemCtrl,
                    maxLines: 4,
                    style: const TextStyle(
                      fontFamily: TxColors.monoFamily,
                      fontSize: 11,
                    ),
                    decoration: const InputDecoration(
                      labelText:
                          'SSH 私钥内容 (-----BEGIN OPENSSH PRIVATE KEY-----)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _passphraseCtrl,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: '私钥口令 Passphrase（可选）',
                      isDense: true,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _tagsCtrl,
                        decoration: const InputDecoration(
                          labelText: '备注标签（可选，逗号分隔）',
                          hintText: '例如 NAS, Ubuntu',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _initCmdCtrl,
                        decoration: const InputDecoration(
                          labelText: '登录后初始命令（可选）',
                          hintText: '例如 tmux a',
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text(
                        '标签颜色：',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: TxColors.textSecondary,
                        ),
                      ),
                      Tooltip(
                        message: '默认无色',
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => setState(() => _tabColorValue = null),
                          child: Container(
                            width: 19,
                            height: 19,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: TxColors.bgChrome,
                              border: Border.all(
                                color: _tabColorValue == null
                                    ? TxColors.textPrimary
                                    : TxColors.borderDefault,
                                width: _tabColorValue == null ? 1.6 : 1.0,
                              ),
                            ),
                            child: const Icon(
                              Icons.format_color_reset_outlined,
                              size: 11,
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
                              () => _tabColorValue = preset.color.toARGB32(),
                            ),
                            child: Container(
                              width: 19,
                              height: 19,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: preset.color,
                                border: Border.all(
                                  color:
                                      _tabColorValue == preset.color.toARGB32()
                                      ? Colors.white
                                      : Colors.black26,
                                  width:
                                      _tabColorValue == preset.color.toARGB32()
                                      ? 1.8
                                      : 1.0,
                                ),
                              ),
                              child: _tabColorValue == preset.color.toARGB32()
                                  ? const Icon(
                                      Icons.check,
                                      size: 11,
                                      color: Colors.black87,
                                    )
                                  : null,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                if (_isApple)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _syncICloud,
                    onChanged: (v) => setState(() => _syncICloud = v ?? true),
                    title: const Text(
                      '同步至 iCloud 钥匙串',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                if (_isApple)
                  CheckboxListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    value: _requireBiometric,
                    onChanged: (v) =>
                        setState(() => _requireBiometric = v ?? false),
                    title: const Text(
                      '连接前要求 Face ID / Touch ID 验证',
                      style: TextStyle(fontSize: 12.5),
                    ),
                  ),
                if (_saveError != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      _saveError!,
                      style: const TextStyle(color: TxColors.danger),
                    ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          if (_isEditing && widget.onDelete != null)
            TextButton.icon(
              onPressed: _saving ? null : _confirmDelete,
              style: TextButton.styleFrom(foregroundColor: TxColors.danger),
              icon: const Icon(Icons.delete_outline_rounded, size: 15),
              label: const Text('删除主机'),
            ),
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _saving ? null : _submitSave,
            child: Text(
              _saving
                  ? '正在保存…'
                  : (_isEditing ? '保存修改' : '保存并连接'),
            ),
          ),
        ],
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
        return AlertDialog(
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
                label: const Text(
                  '加载 Docker 容器扩展',
                  style: TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '按需启用或停用工作台扩展面板与状态栏指标组件：',
                  style: TextStyle(fontSize: 12, color: TxColors.textMuted),
                ),
                const SizedBox(height: 10),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 340),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: plugins.length,
                    itemBuilder: (context, idx) {
                      final p = plugins[idx];
                      final m = p.manifest;
                      final enabled = pluginManager.isPluginEnabled(m.id);
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: TxColors.bgPanel,
                          borderRadius: BorderRadius.circular(7),
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
                                      Text(
                                        m.name,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                          color: TxColors.textPrimary,
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
