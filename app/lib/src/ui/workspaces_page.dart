import 'dart:async';

import 'package:flutter/material.dart';

import '../state/hub_store.dart';
import 'session_detail_page.dart';
import 'session_tile.dart';
import '../util/format.dart';
import 'theme.dart';
import 'widgets.dart';

/// 工作区二级页：按「项目」（bridge 识别出的项目根）分组浏览会话。
///
/// 主列表是扁平的最新优先；要「按项目翻」时才进这里。散会话（无项目）永远排最后。
class WorkspacesPage extends StatefulWidget {
  const WorkspacesPage({super.key, required this.store});

  final HubStore store;

  @override
  State<WorkspacesPage> createState() => _WorkspacesPageState();
}

class _WorkspacesPageState extends State<WorkspacesPage> {
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    // 整批拉一次：分组条数才准（主列表只是「滚到哪算哪」的分页结果）。
    unawaited(widget.store.refreshWorkspaceOverview());
  }

  void _toggle(String key) => setState(() {
        if (!_collapsed.remove(key)) _collapsed.add(key);
      });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final groups = widget.store.sessionGroups;
        final ordered = <SessionGroup>[
          ...groups.where((g) => !g.loose),
          ...groups.where((g) => g.loose),
        ];
        return Scaffold(
          appBar: AppBar(title: Text('工作区 (${ordered.length})')),
          body: _buildBody(ordered),
        );
      },
    );
  }

  Widget _buildBody(List<SessionGroup> ordered) {
    final store = widget.store;
    if (ordered.isEmpty) {
      if (store.loadingWorkspaces) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      final error = store.workspacesError;
      if (error != null) {
        return ErrorView(
          message: error,
          onRetry: () => unawaited(store.refreshWorkspaceOverview(force: true)),
        );
      }
      return const Center(
        child: Text('还没有会话', style: TextStyle(color: kMuted)),
      );
    }

    return RefreshIndicator(
      onRefresh: () => store.refreshWorkspaceOverview(force: true),
      color: kAccent,
      backgroundColor: kPanel,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
        itemCount: ordered.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final group = ordered[index];
          final collapsed = _collapsed.contains(group.key);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              WorkspaceGroupHeader(
                group: group,
                deviceLabel: store.deviceLabel(group.deviceId),
                collapsed: collapsed,
                onToggle: () => _toggle(group.key),
              ),
              if (!collapsed)
                for (final item in group.items)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: SessionTile(
                      item: item,
                      deviceLabel: store.deviceLabel(group.deviceId),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SessionDetailPage(
                            store: widget.store,
                            item: item,
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

/// 组头空间有限：设备名来自 `clients.name`，长度不受控，太长就截断。
String _shortenDevice(String label) {
  final trimmed = label.trim();
  if (trimmed.length <= 14) return trimmed;
  return '${trimmed.substring(0, 13)}…';
}

/// 工作区组头：项目名 + 来源设备；点一下收起/展开，收起时右侧显示条数与最近时间。
class WorkspaceGroupHeader extends StatelessWidget {
  const WorkspaceGroupHeader({
    super.key,
    required this.group,
    required this.deviceLabel,
    required this.collapsed,
    required this.onToggle,
  });

  final SessionGroup group;

  /// 这台电脑在 Hub 上的显示名（`clients.name`，没有名字时退回 id）。
  final String deviceLabel;

  final bool collapsed;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final latest = group.items.first.sortAt;
    return Material(
      color: kBgSoft,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: kLine),
      ),
      child: InkWell(
        onTap: onToggle,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
          child: Row(
            children: [
              Icon(
                collapsed
                    ? Icons.chevron_right_rounded
                    : Icons.expand_more_rounded,
                size: 18,
                color: kMuted,
              ),
              const SizedBox(width: 4),
              const Icon(Icons.folder_outlined, size: 14, color: kMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  group.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: kMono.copyWith(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              // 多台电脑时最容易混：同名项目分组并排出现，组头必须写清来自哪台机器。
              Pill(
                label: _shortenDevice(deviceLabel),
                color: kAccent,
                icon: Icons.computer_rounded,
              ),
              const SizedBox(width: 6),
              Pill(label: '${group.items.length} 条', color: kInfo),
              if (collapsed && latest != null) ...[
                const SizedBox(width: 8),
                Text(
                  relativeTime(latest),
                  style: const TextStyle(fontSize: 11, color: kMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}