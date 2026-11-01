import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'session_detail_page.dart';
import 'theme.dart';
import 'widgets.dart';

/// 会话列表：搜索 + 下拉刷新 + 滚到底自动翻页。
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, required this.store});

  final HubStore store;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  /// 被折叠的工作目录分组 key。默认全部展开 —— 折叠是用户主动收起，不该藏内容。
  final Set<String> _collapsed = <String>{};

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.store.query;
    _scrollCtrl.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollCtrl.hasClients) return;
    final position = _scrollCtrl.position;
    if (position.pixels >= position.maxScrollExtent - 320) {
      unawaited(widget.store.loadMoreSessions());
    }
  }

  Future<void> _open(SessionItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SessionDetailPage(store: widget.store, item: item),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 10),
          child: TextField(
            controller: _searchCtrl,
            textInputAction: TextInputAction.search,
            onSubmitted: (value) => unawaited(store.setQuery(value)),
            style: const TextStyle(fontSize: 13.5),
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              hintText: '搜索 prompt 或结果…',
              prefixIcon: const Icon(
                Icons.search_rounded,
                size: 18,
                color: kMuted,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 38),
              suffixIconConstraints: const BoxConstraints(minWidth: 34),
              suffixIcon: _searchCtrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      tooltip: '清空',
                      onPressed: () {
                        _searchCtrl.clear();
                        setState(() {});
                        unawaited(store.setQuery(''));
                      },
                    ),
            ),
          ),
        ),
        Expanded(child: _buildBody(store)),
      ],
    );
  }

  Widget _buildBody(HubStore store) {
    if (store.sessions.isEmpty) {
      if (store.loadingSessions) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      if (store.sessionsError != null) {
        return ErrorView(
          message: store.sessionsError!,
          onRetry: store.refreshSessions,
        );
      }
      return EmptyState(
        icon: Icons.forum_outlined,
        title: store.query.isEmpty ? '还没有会话记录' : '没有匹配「${store.query}」的会话',
        description: store.query.isEmpty
            ? 'Windows 上的 bridge 跑起来后，Cline 每次执行结束都会出现在这里。'
            : '试试别的关键词，或清空搜索框。',
        action: store.query.isEmpty
            ? null
            : OutlinedButton(
                onPressed: () {
                  _searchCtrl.clear();
                  setState(() {});
                  unawaited(store.setQuery(''));
                },
                child: const Text('清空搜索'),
              ),
      );
    }

    // 分组只在有多个目录时才有意义；搜索是跨组的定向查找，平铺更好翻。
    final groups = store.sessionGroups;
    final grouped = store.query.isEmpty && groups.length > 1;
    final rows = <_SessionRow>[
      if (grouped)
        for (final group in groups) ...[
          _SessionRow.header(group),
          if (!_collapsed.contains(group.key))
            for (final item in group.items) _SessionRow.session(item),
        ]
      else
        for (final item in store.sessions) _SessionRow.session(item),
    ];

    return RefreshIndicator(
      onRefresh: store.refreshSessions,
      color: kAccent,
      backgroundColor: kPanel,
      child: ListView.separated(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 96),
        itemCount: rows.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == rows.length) return _buildFooter(store);
          final group = rows[index].group;
          if (group != null) {
            return _GroupHeader(
              group: group,
              collapsed: _collapsed.contains(group.key),
              onToggle: () => _toggleGroup(group.key),
            );
          }
          final item = rows[index].item!;
          return _SessionTile(item: item, onTap: () => _open(item));
        },
      ),
    );
  }

  void _toggleGroup(String key) {
    setState(() {
      if (!_collapsed.remove(key)) _collapsed.add(key);
    });
  }

  Widget _buildFooter(HubStore store) {
    if (store.loadingMoreSessions) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (store.hasMoreSessions) return const SizedBox(height: 8);
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 14),
      child: Center(
        child: Text('到底了', style: TextStyle(fontSize: 11.5, color: kMuted)),
      ),
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({required this.item, required this.onTap});

  final SessionItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(item.status, ok: item.succeeded);
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
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: StatusDot(color: color),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      item.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (item.status == 'running') ...[
                    const SizedBox(width: 8),
                    Pill(
                      label: '执行中',
                      color: kInfo,
                      icon: Icons.play_arrow_rounded,
                    ),
                  ],
                  if (item.commandCount > 0) ...[
                    const SizedBox(width: 8),
                    Pill(
                      label: '${item.commandCount} 命令',
                      color: kInfo,
                      icon: Icons.bolt_rounded,
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              MetaLine(
                parts: [item.workspace, relativeTime(item.sortAt), item.model],
              ),
              if (item.resultPreview != null) ...[
                const SizedBox(height: 6),
                Text(
                  item.resultPreview!.replaceAll(RegExp(r'\s+'), ' ').trim(),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12.5,
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

/// 列表里的一行：要么是工作目录分组头，要么是一条会话。
class _SessionRow {
  const _SessionRow.header(this.group) : item = null;

  const _SessionRow.session(this.item) : group = null;

  final SessionGroup? group;
  final SessionItem? item;
}

/// 工作目录分组头：点一下收起 / 展开；收起时右侧多显示条数和最近时间。
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.group,
    required this.collapsed,
    required this.onToggle,
  });

  final SessionGroup group;
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
              const SizedBox(width: 8),
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

