import 'package:flutter/material.dart';

import '../data/hub_api.dart';
import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'theme.dart';
import 'widgets.dart';

/// 会话详情：概览 + 用户请求 + 结果全文 + 执行过的命令。
class SessionDetailPage extends StatefulWidget {
  const SessionDetailPage({super.key, required this.store, required this.item});

  final HubStore store;

  /// 先用列表里的摘要占位，详情到了再替换，避免白屏等待。
  final SessionItem item;

  @override
  State<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends State<SessionDetailPage> {
  SessionDetail? _detail;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await widget.store.api.session(widget.item.sessionId);
      if (!mounted) return;
      setState(() => _detail = detail);
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.friendly);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final summary = detail ?? widget.item;
    return Scaffold(
      appBar: AppBar(
        title: const Text('会话详情'),
        actions: [
          CopyButton(text: summary.sessionId, label: '复制 ID'),
          const SizedBox(width: 6),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        color: kAccent,
        backgroundColor: kPanel,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
          children: [
            _OverviewCard(item: summary),
            if (_error != null) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: '详情没拉到',
                trailing: TextButton(
                  onPressed: _load,
                  child: const Text('重试', style: TextStyle(fontSize: 12)),
                ),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 12.5,
                    height: 1.6,
                    color: kMuted,
                  ),
                ),
              ),
            ],
            if (summary.userPrompt != null) ...[
              const SizedBox(height: 12),
              SectionCard(
                title: '用户请求',
                trailing: CopyButton(text: summary.userPrompt!),
                child: SelectableText(
                  summary.userPrompt!,
                  style: const TextStyle(fontSize: 13.5, height: 1.6),
                ),
              ),
            ],
            const SizedBox(height: 12),
            _ResultCard(summary: summary, detail: detail, loading: _loading),
            const SizedBox(height: 12),
            _CommandsCard(
              commands: detail?.commands ?? const <SessionCommand>[],
              loading: _loading,
            ),
          ],
        ),
      ),
    );
  }
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.item});

  final SessionItem item;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(item.status, ok: item.succeeded);
    return SectionCard(
      title: '概览',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Pill(label: sessionStatusLabel(item), color: color),
              if (item.exitCode != null)
                Pill(
                  label: 'exit ${item.exitCode}',
                  color: item.exitCode == 0 ? kAccent : kDanger,
                ),
              Pill(
                label: item.deviceId,
                color: kMuted,
                icon: Icons.computer_rounded,
              ),
              if (item.workspace != null)
                Pill(label: item.workspace!, color: kInfo),
              if (item.commandCount > 0)
                Pill(label: '${item.commandCount} 命令', color: kWarn),
            ],
          ),
          const SizedBox(height: 12),
          MetaLine(
            parts: [item.model, item.provider, item.source],
            icon: Icons.memory_rounded,
          ),
          const SizedBox(height: 6),
          MetaLine(
            parts: [
              formatSpan(item.startedAt, item.endedAt),
              '耗时 ${formatDuration(item.duration)}',
              relativeTime(item.sortAt),
            ],
            icon: Icons.schedule_rounded,
          ),
          if (item.workspaceRoot != null) ...[
            const SizedBox(height: 6),
            MetaLine(parts: [item.workspaceRoot], icon: Icons.folder_outlined),
          ],
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.summary,
    required this.detail,
    required this.loading,
  });

  final SessionItem summary;
  final SessionDetail? detail;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final text = detail?.resultText ?? summary.resultPreview;
    return SectionCard(
      title: '结果',
      trailing: text == null ? null : CopyButton(text: text, label: '复制全文'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (loading && detail == null)
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          if (text == null)
            const Text(
              '这次执行没有留下结果文本（可能被中途取消）。',
              style: TextStyle(fontSize: 12.5, color: kMuted, height: 1.6),
            )
          else
            SelectableText(
              text,
              style: const TextStyle(fontSize: 13, height: 1.7),
            ),
          if (summary.resultTruncated) ...[
            const SizedBox(height: 10),
            const Text(
              '结果超长，bridge 已按上限截断（默认 4000 字）',
              style: TextStyle(fontSize: 11.5, color: kWarn),
            ),
          ],
          if (summary.resultError != null) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: kDanger.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: kDanger.withValues(alpha: 0.3)),
              ),
              child: SelectableText(
                summary.resultError!,
                style: const TextStyle(
                  fontSize: 12,
                  height: 1.6,
                  color: kDanger,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _CommandsCard extends StatelessWidget {
  const _CommandsCard({required this.commands, required this.loading});

  final List<SessionCommand> commands;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '执行过的命令${commands.isEmpty ? '' : '（${commands.length}）'}',
      child: commands.isEmpty
          ? Text(
              loading ? '正在拉取…' : '这次执行没有调用命令工具。',
              style: const TextStyle(
                fontSize: 12.5,
                color: kMuted,
                height: 1.6,
              ),
            )
          : Column(
              children: [
                for (var i = 0; i < commands.length; i++) ...[
                  if (i > 0) const Divider(height: 18),
                  _CommandRow(index: i + 1, command: commands[i]),
                ],
              ],
            ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  const _CommandRow({required this.index, required this.command});

  final int index;
  final SessionCommand command;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '$index.',
              style: const TextStyle(
                fontSize: 11.5,
                color: kMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 8),
            Pill(label: command.tool, color: kInfo),
            const Spacer(),
            CopyButton(text: command.command),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kLine),
          ),
          child: SelectableText(command.command, style: kMono),
        ),
      ],
    );
  }
}
