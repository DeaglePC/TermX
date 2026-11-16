import 'package:flutter/material.dart';

import '../../core/plugin_system/plugin_interface.dart';
import '../../core/theme/ui_tokens.dart';

class PortForwardRule {
  final String id;
  final String name;
  final String mode; // Local (-L) or Remote (-R)
  final int localPort;
  final String targetHost;
  final int targetPort;
  bool active;

  PortForwardRule({
    required this.id,
    required this.name,
    required this.mode,
    required this.localPort,
    required this.targetHost,
    required this.targetPort,
    this.active = true,
  });
}

/// [内置插件 4] SSH 端口转发隧道管理插件 (`plugin.port_forward`)
class PortForwardPlugin extends TermXPlugin {
  static const String pluginId = 'plugin.port_forward';

  final List<PortForwardRule> _rules = [
    PortForwardRule(
      id: 'pf1',
      name: '内网 PostgreSQL 数据库隧道',
      mode: 'Local (-L)',
      localPort: 15432,
      targetHost: '127.0.0.1',
      targetPort: 5432,
      active: true,
    ),
    PortForwardRule(
      id: 'pf2',
      name: 'Redis 缓存调试映射',
      mode: 'Local (-L)',
      localPort: 16379,
      targetHost: '127.0.0.1',
      targetPort: 6379,
      active: false,
    ),
  ];

  @override
  PluginManifest get manifest => const PluginManifest(
        id: pluginId,
        name: 'SSH 端口转发隧道',
        version: '1.0.0',
        author: 'TermX Core Team',
        description: '可视化管理 SSH Local (-L) 与 Remote (-R) 加密端口转发隧道。',
        icon: Icons.alt_route_rounded,
        accentColor: Color(0xFFBB9AF7),
        permissions: [
          PluginPermission.sshExec,
          PluginPermission.uiPanel,
        ],
      );

  @override
  Widget buildPanelWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) {
    if (pluginContext.activeSession?.isLocalSession == true) {
      return localSessionNotice();
    }
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        return ListView.builder(
          padding: const EdgeInsets.all(10),
          itemCount: _rules.length,
          itemBuilder: (context, idx) {
            final rule = _rules[idx];
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              decoration: BoxDecoration(
                color: TxColors.bgPanel,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: TxColors.borderSubtle),
              ),
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 2,
                ),
                value: rule.active,
                activeThumbColor: TxColors.accent,
                title: Text(
                  rule.name,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: TxColors.textPrimary,
                  ),
                ),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Text(
                    '${rule.mode}  127.0.0.1:${rule.localPort} -> ${rule.targetHost}:${rule.targetPort}',
                    style: const TextStyle(
                      fontFamily: TxColors.monoFamily,
                      fontSize: 11.5,
                      color: TxColors.textMuted,
                    ),
                  ),
                ),
                onChanged: (val) {
                  rule.active = val;
                  notifyListeners();
                  pluginContext.showToast(
                    val
                        ? '已激活隧道: 127.0.0.1:${rule.localPort} -> ${rule.targetPort}'
                        : '已停止隧道: ${rule.name}',
                  );
                },
              ),
            );
          },
        );
      },
    );
  }
}
