import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'theme.dart';
import 'widgets.dart';

/// 动态页：bridge 推上来的 hook 事件（任务开始 / 结束 / 中断）。
///
/// 这条线不依赖 sessions.db 的采集节奏，能最快看到「Cline 刚干完一件事」。
class ActivityPage extends StatelessWidget {
  const ActivityPage({super.key, required this.store});

  final HubStore store;

  @override
  Widget build(BuildContext context) {
    if (store.hooks.isEmpty) {
      if (store.loadingHooks) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      if (store.hooksError != null) {
        return ErrorView(
          message: store.hooksError!,
          onRetry: store.refreshHooks,
        );
      }
      return const EmptyState(
        icon: Icons.notifications_none_rounded,
        title: '还没有事件',
        description: 'Cline 触发 hook 时，bridge 会立刻把事件推到这里；不用等会话采集完成。',
      );
    }

    return RefreshIndicator(
      onRefresh: store.refreshHooks,
      color: kAccent,
      backgroundColor: kPanel,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 96),
        itemCount: store.hooks.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == store.hooks.length) return _buildFooter(context);
          return _HookTile(item: store.hooks[index]);
        },
      ),
    );
  }

  Widget _buildFooter(BuildContext context) {
    if (store.loadingHooks) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (store.hasMoreHooks) {
      return Center(
        child: TextButton(
          onPressed: () => unawaited(store.loadMoreHooks()),
          child: const Text('加载更早', style: TextStyle(fontSize: 12)),
        ),
      );
    }
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text('到底了', style: TextStyle(fontSize: 11.5, color: kMuted)),
      ),
    );
  }
}

class _HookTile extends StatelessWidget {
  const _HookTile({required this.item});

  final HookItem item;

  @override
  Widget build(BuildContext context) {
    final event = item.event ?? 'unknown';
    final color = event.contains('fail') || event.contains('error')
        ? kDanger
        : event.contains('end') || event.contains('done')
        ? kAccent
        : kInfo;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Pill(label: event, color: color),
              const Spacer(),
              Text(
                relativeTime(item.receivedAt),
                style: const TextStyle(fontSize: 11.5, color: kMuted),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            item.title ?? '（无标题事件）',
            style: const TextStyle(
              fontSize: 13.5,
              height: 1.45,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (item.body != null) ...[
            const SizedBox(height: 5),
            Text(
              item.body!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.55,
                color: Color(0xFFA9BBCB),
              ),
            ),
          ],
          if (item.workspace != null || item.deviceId != null) ...[
            const SizedBox(height: 8),
            MetaLine(
              parts: [item.workspace, item.deviceId],
              icon: Icons.label_outline_rounded,
            ),
          ],
        ],
      ),
    );
  }
}
