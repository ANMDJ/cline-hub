import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'session_detail_page.dart';
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
    return Column(
      children: [
        // 设备筛选在右侧抽屉里选；筛过设备才出现一条提示（P39）。
        ActiveDeviceFilterBar(store: store),
        Expanded(child: _buildList()),
      ],
    );
  }

  Widget _buildList() {
    final items = store.visibleHooks;
    if (items.isEmpty) {
      if (store.loadingHooks) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      if (store.hooksError != null) {
        return ErrorView(
          message: store.hooksError!,
          onRetry: store.refreshHooks,
        );
      }
      if (store.hooks.isNotEmpty) {
        return EmptyState(
          icon: Icons.filter_alt_off_outlined,
          title: '设备 ${store.deviceFilter} 还没有事件',
          description: '切回「全部设备」能看到其它机器上的事件。',
          action: OutlinedButton(
            onPressed: () => store.setDeviceFilter(null),
            child: const Text('查看全部设备'),
          ),
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
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == items.length) return _buildFooter(context);
          return _HookTile(item: items[index], store: store);
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
  const _HookTile({required this.item, required this.store});

  final HookItem item;
  final HubStore store;

  /// 事件名转中文。
  ///
  /// bridge 的兜底通知只用三个固定名字（session_done / session_failed /
  /// session_cancelled），Cline 自己的 hook 名字什么样都有，所以这里用包含匹配。
  static _EventStyle _styleFor(String event) {
    final lower = event.toLowerCase();
    if (lower.contains('fail') || lower.contains('error')) {
      return const _EventStyle('执行失败', kDanger, Icons.error_outline_rounded);
    }
    if (lower.contains('cancel')) {
      return const _EventStyle('已取消', kWarn, Icons.block_rounded);
    }
    if (lower.contains('done') ||
        lower.contains('complete') ||
        lower.contains('end')) {
      return const _EventStyle(
        '已完成',
        kAccent,
        Icons.check_circle_outline_rounded,
      );
    }
    if (lower.contains('start') || lower.contains('begin')) {
      return const _EventStyle(
        '开始执行',
        kInfo,
        Icons.play_circle_outline_rounded,
      );
    }
    return _EventStyle(event, kInfo, Icons.notifications_none_rounded);
  }

  void _open(BuildContext context) {
    final sessionId = item.sessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailPage(
          store: store,
          item: SessionItem(
            deviceId: item.deviceId ?? '',
            sessionId: sessionId,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final event = item.event ?? 'unknown';
    final style = _styleFor(event);
    final openable = (item.sessionId ?? '').isNotEmpty;

    return GestureDetector(
      onTap: openable ? () => _open(context) : null,
      child: SectionCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Pill(label: style.label, color: style.color, icon: style.icon),
                const Spacer(),
                Text(
                  relativeTime(item.receivedAt),
                  style: const TextStyle(fontSize: 11.5, color: kMuted),
                ),
                if (openable) ...[
                  const SizedBox(width: 2),
                  const Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: kMuted,
                  ),
                ],
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
      ),
    );
  }
}

class _EventStyle {
  const _EventStyle(this.label, this.color, this.icon);

  final String label;
  final Color color;
  final IconData icon;
}
