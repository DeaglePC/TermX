import 'package:flutter/material.dart';

import '../../core/plugin_system/plugin_interface.dart';
import '../../core/theme/ui_tokens.dart';

class CommandSnippet {
  final String id;
  final String title;
  final String category;
  final String command;

  const CommandSnippet({
    required this.id,
    required this.title,
    required this.category,
    required this.command,
  });
}

/// [内置插件 3] 快捷指令片段库 (`plugin.snippets`)
/// 解决手机端与 iPad 端输入冗长运维脚本痛点，一键向活跃 SSH 终端下发命令
class SnippetsPlugin extends TermXPlugin {
  static const String pluginId = 'plugin.snippets';

  final List<CommandSnippet> _snippets = [
    const CommandSnippet(
      id: 's1',
      title: '查看运行中 Docker 容器状态',
      category: 'Docker',
      command: 'docker ps',
    ),
    const CommandSnippet(
      id: 's2',
      title: '检查磁盘分区占用率',
      category: 'System',
      command: 'df -h',
    ),
    const CommandSnippet(
      id: 's3',
      title: '查看系统实时负载快照',
      category: 'System',
      command: 'top',
    ),
    const CommandSnippet(
      id: 's4',
      title: '列出当前目录详细文件权限',
      category: 'Files',
      command: 'll',
    ),
    const CommandSnippet(
      id: 's5',
      title: '读取 Nginx 主配置文件',
      category: 'Nginx',
      command: 'cat /root/nginx/nginx.conf',
    ),
    const CommandSnippet(
      id: 's6',
      title: '查看内核与发行版信息',
      category: 'System',
      command: 'uname -a',
    ),
  ];

  @override
  PluginManifest get manifest => const PluginManifest(
        id: pluginId,
        name: '快捷命令片段 (Snippets)',
        version: '1.1.0',
        author: 'TermX Core Team',
        description: '为手机与 iPad 触控场景定制的一键脚本片段库，免去移动端繁琐拼写。',
        icon: Icons.terminal_rounded,
        accentColor: Color(0xFFE0AF68),
        permissions: [
          PluginPermission.terminalIo,
          PluginPermission.uiPanel,
          PluginPermission.localStorage,
        ],
      );

  void addSnippet(CommandSnippet snippet) {
    _snippets.insert(0, snippet);
    notifyListeners();
  }

  @override
  Widget buildPanelWidget(
    BuildContext context,
    PluginContext pluginContext,
  ) {
    return ListenableBuilder(
      listenable: this,
      builder: (context, _) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 10, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    '点击片段发送到当前终端',
                    style: TextStyle(fontSize: 11.5, color: TxColors.textMuted),
                  ),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () => _showAddDialog(context),
                    icon: const Icon(Icons.add_rounded, size: 14),
                    label: const Text('新建片段', style: TextStyle(fontSize: 11)),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemCount: _snippets.length,
                itemBuilder: (context, idx) {
                  final item = _snippets[idx];
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
                      contentPadding: const EdgeInsets.only(left: 10, right: 4),
                      onTap: () {
                        pluginContext.writeToTerminal(item.command);
                        pluginContext.showToast('已执行片段: ${item.command}');
                      },
                      title: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: TxColors.bgElevated,
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(color: TxColors.borderDefault),
                            ),
                            child: Text(
                              item.category,
                              style: const TextStyle(
                                fontSize: 9.5,
                                color: TxColors.textSecondary,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 7),
                          Expanded(
                            child: Text(
                              item.title,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500,
                                color: TxColors.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      subtitle: Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          item.command,
                          style: const TextStyle(
                            fontFamily: TxColors.monoFamily,
                            fontSize: 11,
                            color: TxColors.textMuted,
                          ),
                        ),
                      ),
                      trailing: IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '发送到终端执行',
                        icon: const Icon(
                          Icons.play_arrow_rounded,
                          size: 18,
                          color: TxColors.iconDefault,
                        ),
                        onPressed: () {
                          pluginContext.writeToTerminal(item.command);
                          pluginContext.showToast('已执行片段: ${item.command}');
                        },
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final titleCtrl = TextEditingController();
    final catCtrl = TextEditingController(text: 'Custom');
    final cmdCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(
          '新建命令片段',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: '片段名称 (如 重启网关)'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: catCtrl,
              decoration: const InputDecoration(labelText: '分类标签'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: cmdCtrl,
              style: const TextStyle(fontFamily: TxColors.monoFamily),
              decoration: const InputDecoration(labelText: 'Shell 命令内容'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (titleCtrl.text.trim().isNotEmpty &&
                  cmdCtrl.text.trim().isNotEmpty) {
                addSnippet(
                  CommandSnippet(
                    id: DateTime.now().millisecondsSinceEpoch.toString(),
                    title: titleCtrl.text.trim(),
                    category: catCtrl.text.trim(),
                    command: cmdCtrl.text.trim(),
                  ),
                );
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
