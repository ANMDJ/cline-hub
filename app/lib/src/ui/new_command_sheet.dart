import 'package:flutter/material.dart';

import '../data/hub_api.dart';
import '../state/hub_store.dart';
import 'theme.dart';

Future<void> showNewCommandSheet(BuildContext context, HubStore store) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kPanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetContext) => Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
      ),
      child: _NewCommandSheet(store: store),
    ),
  );
}

class _NewCommandSheet extends StatefulWidget {
  const _NewCommandSheet({required this.store});

  final HubStore store;

  @override
  State<_NewCommandSheet> createState() => _NewCommandSheetState();
}

class _NewCommandSheetState extends State<_NewCommandSheet> {
  late final TextEditingController _promptCtrl = TextEditingController();
  late final TextEditingController _deviceCtrl = TextEditingController(
    text: widget.store.activeDeviceId,
  );
  late final TextEditingController _workspaceCtrl = TextEditingController();
  String _mode = 'plan';
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _promptCtrl.dispose();
    _deviceCtrl.dispose();
    _workspaceCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final prompt = _promptCtrl.text.trim();
    final device = _deviceCtrl.text.trim();
    final workspace = _workspaceCtrl.text.trim();
    if (prompt.isEmpty) {
      setState(() => _error = '指令不能为空');
      return;
    }
    if (prompt.length > 4000) {
      setState(() => _error = 'Hub 限制 prompt 最多 4000 字，当前 ${prompt.length} 字');
      return;
    }
    if (device.isEmpty) {
      setState(() => _error = '要指定执行设备（deviceId），比如 localone');
      return;
    }
    if (workspace.length > 1000) {
      setState(
        () => _error = 'Hub 限制 workspace 最多 1000 字，当前 ${workspace.length} 字',
      );
      return;
    }

    setState(() {
      _sending = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);

    try {
      final created = await widget.store.sendCommand(
        prompt: prompt,
        mode: _mode,
        deviceId: device,
        workspace: workspace,
      );
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text('已下发 ${created.id}，等 bridge 领取')),
      );
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.friendly;
          _sending = false;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
          _sending = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final devices = store.knownDevices;
    final workspaces = store.knownWorkspaces;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: kLine,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              const Expanded(
                child: Text(
                  '下发命令',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: '关闭',
              ),
            ],
          ),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'plan',
                label: Text('PLAN', style: TextStyle(fontSize: 12)),
              ),
              ButtonSegment(
                value: 'act',
                label: Text('ACT', style: TextStyle(fontSize: 12)),
              ),
              ButtonSegment(
                value: 'yolo',
                label: Text('YOLO', style: TextStyle(fontSize: 12)),
              ),
            ],
            selected: {_mode},
            showSelectedIcon: false,
            onSelectionChanged: (selection) =>
                setState(() => _mode = selection.first),
          ),
          const SizedBox(height: 8),
          Text(
            switch (_mode) {
              'act' => '直接动手，关键步骤还会问你。',
              'yolo' => '全自动，不再逐条确认。',
              _ => '只出方案，不改文件（默认，最安全）。',
            },
            style: const TextStyle(fontSize: 11.5, color: kMuted, height: 1.6),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _promptCtrl,
            minLines: 4,
            maxLines: 8,
            textInputAction: TextInputAction.newline,
            autofocus: true,
            style: const TextStyle(fontSize: 13.5, height: 1.5),
            decoration: const InputDecoration(
              hintText: '要 Windows 上做什么？例如：跑一遍 kids_points_app 的测试并总结失败项',
            ),
          ),
          const SizedBox(height: 16),
          const Text('执行设备', style: TextStyle(fontSize: 12, color: kMuted)),
          const SizedBox(height: 6),
          TextField(
            controller: _deviceCtrl,
            autocorrect: false,
            style: kMono,
            decoration: const InputDecoration(hintText: 'localone'),
          ),
          if (devices.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final id in devices)
                  ChoiceChip(
                    label: Text(id, style: const TextStyle(fontSize: 11.5)),
                    selected: _deviceCtrl.text.trim() == id,
                    onSelected: (_) {
                      _deviceCtrl.text = id;
                      setState(() {});
                    },
                  ),
              ],
            ),
          ],
          const SizedBox(height: 16),
          const Text('工作目录（可选）', style: TextStyle(fontSize: 12, color: kMuted)),
          const SizedBox(height: 6),
          TextField(
            controller: _workspaceCtrl,
            autocorrect: false,
            style: kMono,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText: r'C:\Users\alice\projects\kids_points_app',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ChoiceChip(
                label: const Text('默认', style: TextStyle(fontSize: 11.5)),
                selected: _workspaceCtrl.text.trim().isEmpty,
                onSelected: (_) {
                  _workspaceCtrl.text = '';
                  setState(() {});
                },
              ),
              for (final path in workspaces)
                ChoiceChip(
                  label: Text(
                    _tailPath(path),
                    style: const TextStyle(fontSize: 11.5),
                  ),
                  selected: _workspaceCtrl.text.trim() == path,
                  onSelected: (_) {
                    _workspaceCtrl.text = path;
                    setState(() {});
                  },
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            workspaces.isEmpty
                ? '留空走 bridge 的 commands.defaultWorkspace；也可以直接粘一个绝对路径。'
                : '点一下就填好；留空（默认）表示用 bridge 的 commands.defaultWorkspace。',
            style: const TextStyle(fontSize: 11, height: 1.5, color: kMuted),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: kBgSoft,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: kLine),
            ),
            child: const Text(
              '提示：bridge 默认模板会把 prompt 当 PowerShell 脚本执行；想让它真的调用 Cline，'
              '把 config.commands.template 改成 cline --yolo "{prompt}"，这时 mode 才有意义。',
              style: TextStyle(fontSize: 11.5, height: 1.6, color: kMuted),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kDanger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDanger.withValues(alpha: 0.3)),
              ),
              child: Text(
                _error!,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: kDanger,
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _sending ? null : _submit,
              icon: const Icon(Icons.send_rounded, size: 16),
              label: Text(_sending ? '下发中…' : '下发'),
            ),
          ),
        ],
      ),
    );
  }
}

/// chips 上只显示路径尾部两级：完整值点一下就填进输入框，一行不至于撑爆。
String _tailPath(String path) {
  final separator = path.contains('\\') ? '\\' : '/';
  final parts = path
      .split(RegExp(r'[\\/]'))
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.length <= 2) return path;
  return '…$separator${parts.sublist(parts.length - 2).join(separator)}';
}
