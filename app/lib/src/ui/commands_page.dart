import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'new_command_sheet.dart';
import 'session_detail_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// 命令页：看每条远程命令走到哪一步，结果直接在手机上读。
class CommandsPage extends StatelessWidget {
  const CommandsPage({super.key, required this.store});

  final HubStore store;

  @override
  Widget build(BuildContext context) {
    if (store.commands.isEmpty) {
      if (store.loadingCommands) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      if (store.commandsError != null) {
        return ErrorView(
          message: store.commandsError!,
          onRetry: store.refreshCommands,
        );
      }
      return EmptyState(
        icon: Icons.bolt_outlined,
        title: '还没有下发过命令',
        description: 'Windows 上 bridge 跑着时，这里发出去的 prompt 会被领取、执行，再把输出回写到这里。',
        action: FilledButton.icon(
          onPressed: () => showNewCommandSheet(context, store),
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('下发第一条'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: store.refreshCommands,
      color: kAccent,
      backgroundColor: kPanel,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 96),
        itemCount: store.commands.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == store.commands.length) return const _BridgeHint();
          final item = store.commands[index];
          return _CommandTile(
            item: item,
            onTap: () => _showCommandDetail(context, item, store),
          );
        },
      ),
    );
  }
}

class _CommandTile extends StatelessWidget {
  const _CommandTile({required this.item, required this.onTap});

  final CommandItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(item.status);
    return Material(
      color: kPanel,
      borderRadius: BorderRadius.circular(kRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(kRadius),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(kRadius),
            border: Border.all(color: kLine),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusDot(color: color),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel(item.status),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: color,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Pill(label: item.modeLabel, color: modeColor(item.mode)),
                  const Spacer(),
                  Text(
                    formatClock(item.createdAt),
                    style: const TextStyle(fontSize: 11.5, color: kMuted),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                item.prompt,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 13.5, height: 1.5),
              ),
              const SizedBox(height: 7),
              MetaLine(
                parts: [
                  item.deviceId,
                  relativeTime(item.createdAt),
                  '耗时 ${formatDuration(item.duration)}',
                ],
                icon: Icons.computer_rounded,
              ),
              if (item.resultText != null) ...[
                const SizedBox(height: 6),
                Text(
                  item.resultText!.replaceAll(RegExp(r'\s+'), ' ').trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.55,
                    color: Color(0xFFA9BBCB),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BridgeHint extends StatelessWidget {
  const _BridgeHint();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 6, bottom: 4),
      child: Text(
        '只显示最近 50 条。命令一直停在 pending，说明 bridge 没在跑或还没轮询到。',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, height: 1.6, color: kMuted),
      ),
    );
  }
}

void _showCommandDetail(BuildContext context, CommandItem item, HubStore store) {
  final pageContext = context;
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kPanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (sheetContext) {
      final color = statusColor(item.status);
      return DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.62,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (context, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 28),
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
            const SizedBox(height: 16),
            Row(
              children: [
                StatusDot(color: color),
                const SizedBox(width: 8),
                Text(
                  statusLabel(item.status),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
                const SizedBox(width: 8),
                Pill(label: item.modeLabel, color: modeColor(item.mode)),
                const Spacer(),
                CopyButton(text: item.id, label: '复制 ID'),
              ],
            ),
            const SizedBox(height: 6),
            MetaLine(
              parts: [
                item.deviceId,
                relativeTime(item.createdAt),
                '耗时 ${formatDuration(item.duration)}',
              ],
            ),
            const SizedBox(height: 16),
            const Text('指令', style: TextStyle(fontSize: 12, color: kMuted)),
            const SizedBox(height: 6),
            SelectableText(
              item.prompt,
              style: const TextStyle(fontSize: 13.5, height: 1.65),
            ),
            if (item.workspace != null) ...[
              const SizedBox(height: 10),
              MetaLine(parts: [item.workspace], icon: Icons.folder_outlined),
            ],
            // bridge 执行完会把新开会话的 ID 回写到这里，点一下直接进会话。
            if ((item.sessionId ?? '').isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: MetaLine(
                      parts: [item.sessionId!],
                      icon: Icons.forum_outlined,
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () {
                      Navigator.of(sheetContext).pop();
                      Navigator.of(pageContext).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SessionDetailPage(
                            store: store,
                            item: SessionItem(
                              deviceId: item.deviceId,
                              sessionId: item.sessionId!,
                            ),
                          ),
                        ),
                      );
                    },
                    icon: const Icon(Icons.arrow_forward_rounded, size: 14),
                    label: const Text(
                      '打开会话',
                      style: TextStyle(fontSize: 12.5),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
            ],
            if (item.resultText != null) ...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '输出',
                      style: TextStyle(fontSize: 12, color: kMuted),
                    ),
                  ),
                  CopyButton(text: item.resultText!, label: '复制输出'),
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
                child: SelectableText(item.resultText!, style: kMono),
              ),
            ],
            if (item.errorText != null) ...[
              const SizedBox(height: 16),
              const Text('错误', style: TextStyle(fontSize: 12, color: kMuted)),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: kDanger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kDanger.withValues(alpha: 0.3)),
                ),
                child: SelectableText(
                  item.errorText!,
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: kDanger,
                  ),
                ),
              ),
            ],
            if (item.isActive) ...[
              const SizedBox(height: 16),
              Text(
                item.status == 'pending'
                    ? '排队中，等 bridge 来领取…'
                    : 'bridge 已领取，正在执行…',
                style: const TextStyle(fontSize: 12, color: kWarn),
              ),
            ],
            if (sheetContext.mounted) const SizedBox(height: 8),
          ],
        ),
      );
    },
  );
}
