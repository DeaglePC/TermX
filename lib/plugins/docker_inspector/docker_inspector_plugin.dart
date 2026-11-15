import 'package:flutter/material.dart';

import '../../core/plugin_system/plugin_interface.dart';
import '../../core/theme/ui_tokens.dart';

/// [动态扩展演示插件 5] Docker 容器可视化管理插件 (`plugin.docker_ui`)
/// 用于展示 TermX 插件化架构可在几十行代码内扩展全新运维功能并挂载到所有 UI 插槽
class DockerInspectorPlugin extends TermXPlugin {
  static const String pluginId = 'plugin.docker_ui';

  final List<Map<String, String>> _containers = [
    {
      'id': 'a81f940b2c19',
      'name': 'api-gateway',
      'image': 'nginx:alpine',
      'status': 'Up 14 days',
      'ports': '0.0.0.0:443->443/tcp',
    },
    {
      'id': '79c20e1b55d1',
      'name': 'redis-cache',
      'image': 'redis:7-alpine',
      'status': 'Up 14 days',
      'ports': '0.0.0.0:6379->6379/tcp',
    },
    {
      'id': '3e19a8410f02',
      'name': 'pg-primary',
      'image': 'postgres:16',
      'status': 'Up 9 days',
      'ports': '5432/tcp',
    },
  ];

  @override
  PluginManifest get manifest => const PluginManifest(
        id: pluginId,
        name: 'Docker 容器管家 (Community Plugin)',
        version: '1.0.0',
        author: 'TermX Plugin Ecosystem',
        description: '动态挂载演示插件：通过 SSH 通道管理远端 Docker 容器启停与实时日志查看。',
        icon: Icons.directions_boat_filled_outlined,
        accentColor: Color(0xFF2AC3DE),
        permissions: [
          PluginPermission.sshExec,
          PluginPermission.terminalIo,
          PluginPermission.uiStatusBar,
          PluginPermission.uiPanel,
        ],
      );

  @override
  Widget buildStatusBarWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) {
    if (pluginContext.activeSession?.isLocalSession == true) {
      return const SizedBox.shrink();
    }
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => pluginContext.requestOpenPanel(pluginId),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.widgets_outlined,
              size: 12,
              color: TxColors.textMuted,
            ),
            const SizedBox(width: 4),
            Text(
              'Docker (${_containers.length})',
              style: const TextStyle(
                fontSize: 10.5,
                fontFamily: TxColors.monoFamily,
                color: TxColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget buildPanelWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) {
    if (pluginContext.activeSession?.isLocalSession == true) {
      return localSessionNotice();
    }
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: _containers.length,
      itemBuilder: (context, idx) {
        final c = _containers[idx];
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          decoration: BoxDecoration(
            color: TxColors.bgPanel,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: TxColors.borderSubtle),
          ),
          child: ListTile(
            dense: true,
            visualDensity: VisualDensity.compact,
            leading: Container(
              width: 7,
              height: 7,
              decoration: const BoxDecoration(
                color: TxColors.success,
                shape: BoxShape.circle,
              ),
            ),
            title: Text(
              '${c['name']} (${c['image']})',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: TxColors.textPrimary,
              ),
            ),
            subtitle: Text(
              '${c['status']}  ·  ${c['ports']}',
              style: const TextStyle(
                fontSize: 10.5,
                fontFamily: TxColors.monoFamily,
                color: TxColors.textMuted,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '查看容器日志 (docker logs)',
                  icon: const Icon(
                    Icons.article_outlined,
                    size: 15,
                    color: TxColors.iconDefault,
                  ),
                  onPressed: () {
                    pluginContext.writeToTerminal(
                      'docker logs --tail 50 ${c['name']}',
                    );
                  },
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: '重启容器 (docker restart)',
                  icon: const Icon(
                    Icons.refresh_rounded,
                    size: 15,
                    color: TxColors.iconDefault,
                  ),
                  onPressed: () {
                    pluginContext.writeToTerminal(
                      'docker restart ${c['name']}',
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
