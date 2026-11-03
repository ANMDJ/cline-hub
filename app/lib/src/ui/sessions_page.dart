import 'dart:async';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../state/hub_store.dart';
import 'session_detail_page.dart';
import 'session_tile.dart';
import 'theme.dart';
import 'widgets.dart';

/// 会话列表：搜索 + 下拉刷新 + 滚到底自动翻页。
///
/// 顶部只留搜索框：设备筛选与「按工作区浏览」都在右侧抽屉里（P39），
/// 筛选生效时才多一条 `ActiveDeviceFilterBar` 提示。
class SessionsPage extends StatefulWidget {
  const SessionsPage({super.key, required this.store});

  final HubStore store;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

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
        // 只有筛过设备时才出现（抽屉里选的，这里负责提醒 + 一键看全部）。
        ActiveDeviceFilterBar(store: widget.store),

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

    // 扁平列表：服务端已按「最后一次对话时间」倒序，最上面永远是最新会话。
    final items = store.visibleSessions;
    if (items.isEmpty) {
      // 有数据但被设备过滤挡掉了：给一个明确的出口，别让人以为数据丢了。
      return EmptyState(
        icon: Icons.filter_alt_off_outlined,
        title: '设备 ${store.deviceFilter} 还没有会话',
        description: '切回「全部设备」能看到其它机器上的会话。',
        action: OutlinedButton(
          onPressed: () => store.setDeviceFilter(null),
          child: const Text('查看全部设备'),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: store.refreshSessions,
      color: kAccent,
      backgroundColor: kPanel,
      child: ListView.separated(
        controller: _scrollCtrl,
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 96),
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == items.length) return _buildFooter(store);
          final item = items[index];
          return SessionTile(
            item: item,
            // 单设备时不重复报设备名；接了两台电脑后每条会话都要能看出出处。
            deviceLabel: store.knownDevices.length > 1
                ? store.deviceLabel(item.deviceId)
                : null,
            onTap: () => _open(item),
          );
        },
      ),
    );
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
