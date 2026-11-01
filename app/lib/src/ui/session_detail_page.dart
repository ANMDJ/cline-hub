import 'dart:async';

import 'package:flutter/material.dart';

import '../data/hub_api.dart';
import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'theme.dart';
import 'widgets.dart';

/// 会话详情：概览 + 逐条对话 + 底部「继续这个会话」。
///
/// 对话来自 Hub 的 session_messages（bridge 增量上报）。一条会话动辄两三百条，
/// 所以用 SliverList 懒加载；running 时每 3 秒补一次增量，退出页面即停。
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
  List<SessionMessage> _messages = const <SessionMessage>[];
  bool _loading = true;
  String? _error;
  String? _messagesError;
  Timer? _liveTimer;
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  bool _sending = false;
  /// 继续对话的执行模式：plan = 只读；act = 会改文件。默认 plan。
  String _mode = 'plan';
  bool _loadingOlder = false;
  bool _hasOlder = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  SessionItem get _summary => _detail ?? widget.item;

  bool get _isLive => _summary.status == 'running';

  /// 主对话流：只保留 user / assistant 正文。
  List<SessionMessage> get _chatMessages =>
      _messages.where((m) => !m.isCommand).toList(growable: false);

  /// messageId 形如 `msg_xxx:3`，同一 message 的正文与工具调用共享前缀。
  static String _baseId(String messageId) {
    final i = messageId.lastIndexOf(':');
    return i > 0 ? messageId.substring(0, i) : messageId;
  }

  /// 每条 Cline 消息对应的命令（同名 message 的多条 tool_use 归到一起）。
  Map<String, List<SessionMessage>> get _commandGroups {
    final map = <String, List<SessionMessage>>{};
    for (final m in _messages) {
      if (!m.isCommand) continue;
      (map[_baseId(m.messageId)] ??= <SessionMessage>[]).add(m);
    }
    return map;
  }

  /// 会话还在跑：每 3 秒补一次会话快照 + 消息增量。
  /// 定时器只在页面存活期间存在，退出去就停，后台不耗电。
  void _scheduleLive() {
    _liveTimer?.cancel();
    if (!_isLive) return;
    _liveTimer = Timer(const Duration(seconds: 3), () async {
      if (!mounted) return;
      await _refreshLive();
      _scheduleLive();
    });
  }

  Future<void> _refreshLive() async {
    // 只有原本就贴在底部时才自动跟着滚，免得把正在翻历史的用户拽走。
    final wasNearBottom = _scroll.hasClients &&
        (_scroll.position.maxScrollExtent - _scroll.position.pixels) < 160;
    try {
      final detail = await widget.store.api.session(widget.item.sessionId);
      final messages = await _fetchMessages();
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _messages = messages;
        _messagesError = null;
      });
      if (wasNearBottom) _jumpToBottomSoon();
    } catch (_) {
      // 轮询失败不弹错：网络恢复后下一轮自己追上
    }
  }

  /// 增量拉取：从最后一条往前退 6 条重拉。
  /// 流式回复的同一条消息内容会一直变长，只按 seq 追新会漏掉它的更新。
  Future<List<SessionMessage>> _fetchMessages() async {
    final last = _messages.isEmpty ? null : _messages.last.seq;
    final incoming = await widget.store.api.sessionMessages(
      widget.item.sessionId,
      after: last == null ? null : (last - 6).clamp(0, last),
    );
    if (incoming.isEmpty) return _messages;

    final byKey = <String, SessionMessage>{
      for (final message in _messages) message.key: message,
      for (final message in incoming) message.key: message,
    };
    return byKey.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
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

    await _loadMessages();
    if (mounted) _scheduleLive();
  }

  Future<void> _loadMessages() async {
    try {
      // 首屏只要最近 60 条，更早的滑到顶部再拉（会话动辄几百条）。
      final messages = await widget.store.api.sessionMessages(
        widget.item.sessionId,
        limit: 60,
      );
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _messagesError = null;
        _hasOlder = messages.length >= 60;
      });
      _jumpToBottomSoon();
    } on ApiException catch (error) {
      if (mounted) setState(() => _messagesError = error.friendly);
    } catch (error) {
      if (mounted) setState(() => _messagesError = '$error');
    }
  }

  /// 首次/刷新后贴到最新一条（底部）。
  void _jumpToBottomSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels <= 80) unawaited(_loadOlder());
  }

  /// 滑到顶部时向前翻历史：before=<当前最小 seq>，插入头部并补偿滚动位置。
  Future<void> _loadOlder() async {
    if (_loadingOlder || !_hasOlder || _messages.isEmpty) return;
    _loadingOlder = true;
    final beforeSeq = _messages.first.seq;
    final extentBefore = _scroll.hasClients ? _scroll.position.maxScrollExtent : 0.0;
    final pixelsBefore = _scroll.hasClients ? _scroll.position.pixels : 0.0;
    try {
      final older = await widget.store.api.sessionMessages(
        widget.item.sessionId,
        limit: 60,
        before: beforeSeq,
      );
      if (!mounted) return;
      if (older.isEmpty) {
        setState(() => _hasOlder = false);
        return;
      }
      setState(() {
        final byKey = <String, SessionMessage>{
          for (final m in older) m.key: m,
          for (final m in _messages) m.key: m,
        };
        _messages = byKey.values.toList()..sort((a, b) => a.seq.compareTo(b.seq));
        _hasOlder = older.length >= 60;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final delta = _scroll.position.maxScrollExtent - extentBefore;
        _scroll.jumpTo(pixelsBefore + delta);
      });
    } catch (_) {
      // 翻历史失败不打扰用户，下次滑到顶部再试
    } finally {
      _loadingOlder = false;
    }
  }

  /// 「继续这个会话」：这句话会变成一条 act 命令，
  /// bridge 用 `cline --id <sessionId>` 接续原会话，过程和回复仍回到这里。
  Future<void> _send() async {
    final text = _composer.text.trim();
    if (text.isEmpty || _sending) return;

    setState(() => _sending = true);
    try {
      await widget.store.api.sendCommand(
        deviceId: widget.item.deviceId,
        prompt: text,
        mode: _mode,
        workspace: _summary.workspaceRoot,
        sessionId: widget.item.sessionId,
      );
      _composer.clear();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已发到电脑，Cline 会在这个会话里接着干'),
          duration: Duration(seconds: 3),
        ),
      );
      _jumpToBottomSoon();
      _scheduleLive();
    } on ApiException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败：${error.friendly}')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final summary = _summary;
    // 主对话流只放正文；命令按 messageId 分组，塞进对应气泡的按钮里。
    final chat = _chatMessages;
    final groups = _commandGroups;
    return Scaffold(
      appBar: AppBar(
        title: const Text('会话详情'),
        actions: [
          CopyButton(text: summary.sessionId, label: '复制 ID'),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: RefreshIndicator(
              onRefresh: _load,
              color: kAccent,
              backgroundColor: kPanel,
              child: CustomScrollView(
                controller: _scroll,
                physics: const AlwaysScrollableScrollPhysics(),
                slivers: [
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
                    sliver: SliverList(
                      delegate: SliverChildListDelegate([
                        _OverviewCard(item: summary),
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          SectionCard(
                            title: '详情没拉到',
                            trailing: TextButton(
                              onPressed: _load,
                              child: const Text(
                                '重试',
                                style: TextStyle(fontSize: 12),
                              ),
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
                        if (_messagesError != null) ...[
                          const SizedBox(height: 12),
                          SectionCard(
                            title: '对话没拉到',
                            trailing: TextButton(
                              onPressed: _loadMessages,
                              child: const Text(
                                '重试',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                            child: Text(
                              _messagesError!,
                              style: const TextStyle(
                                fontSize: 12.5,
                                height: 1.6,
                                color: kMuted,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            const Text(
                              '对话',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: kMuted,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${chat.length} 条',
                              style: const TextStyle(
                                fontSize: 11.5,
                                color: kMuted,
                              ),
                            ),
                            const Spacer(),
                            if (_isLive)
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.6,
                                  color: kAccent,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ]),
                    ),
                  ),
                  // 会话动辄两三百条，必须懒加载：一次性 Column 会直接卡住首屏。
                  SliverPadding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: _MessageBubble(
                            message: chat[index],
                            commands: groups[_baseId(chat[index].messageId)] ??
                                const <SessionMessage>[],
                          ),
                        ),
                        childCount: chat.length,
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                      child: _ConversationFooter(
                        loading: _loading && _messages.isEmpty,
                        live: _isLive,
                        empty: _messages.isEmpty,
                      ),
                    ),
                  ),
                  const SliverToBoxAdapter(child: SizedBox(height: 12)),
                ],
              ),
            ),
          ),
          _Composer(
            controller: _composer,
            sending: _sending,
            onSend: _send,
            mode: _mode,
            onModeChanged: (value) => setState(() => _mode = value),
          ),
        ],
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
          if (item.project != null || item.projectRoot != null) ...[
            const SizedBox(height: 6),
            MetaLine(
              parts: [item.project, item.projectRoot],
              icon: Icons.work_outline_rounded,
            ),
          ],
          if (item.workspaceRoot != null) ...[
            const SizedBox(height: 6),
            MetaLine(parts: [item.workspaceRoot], icon: Icons.folder_outlined),
          ],
        ],
      ),
    );
  }
}

class _ConversationFooter extends StatelessWidget {
  const _ConversationFooter({
    required this.loading,
    required this.live,
    required this.empty,
  });

  final bool loading;
  final bool live;
  final bool empty;

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: LinearProgressIndicator(minHeight: 2),
      );
    }
    if (live) {
      return Row(
        children: [
          const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: kAccent),
          ),
          const SizedBox(width: 8),
          const Text(
            'Cline 正在处理，回复会一条条出现在上面…',
            style: TextStyle(fontSize: 11.5, color: kMuted),
          ),
        ],
      );
    }
    if (empty) {
      return const Text(
        '这个会话还没有可显示的消息。\n历史会话第一次打开时，bridge 会把完整对话回填上来（每轮 2 个会话，稍等一会儿再下拉刷新）。',
        style: TextStyle(fontSize: 12, height: 1.7, color: kMuted),
      );
    }
    return const SizedBox(height: 4);
  }
}

/// 一条消息：真人输入靠右、Cline 回复靠左、工具调用单独一条窄条。
class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.commands = const <SessionMessage>[],
  });

  final SessionMessage message;

  /// 这条消息里产生的工具调用；主流程不渲染，只在气泡下留一个入口。
  final List<SessionMessage> commands;

  @override
  Widget build(BuildContext context) {
    if (message.isCommand) return _CommandBubble(message: message);

    final isUser = message.isUser;
    final width = MediaQuery.of(context).size.width;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(maxWidth: width * 0.86),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(
          color: isUser ? kAccent.withValues(alpha: 0.14) : kPanel,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(12),
            topRight: const Radius.circular(12),
            bottomLeft: Radius.circular(isUser ? 12 : 3),
            bottomRight: Radius.circular(isUser ? 3 : 12),
          ),
          border: Border.all(
            color: isUser ? kAccent.withValues(alpha: 0.32) : kLine,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              message.text,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.62,
                color: isUser ? kText : const Color(0xFFD6E2EE),
              ),
            ),
            if (message.ts != null) ...[
              const SizedBox(height: 4),
              Text(
                formatClock(message.ts),
                style: const TextStyle(fontSize: 10.5, color: kMuted),
              ),
            ],
            if (commands.isNotEmpty) ...[
              const SizedBox(height: 7),
              Align(
                alignment: Alignment.centerLeft,
                child: InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => SessionCommandsPage(commands: commands),
                    ),
                  ),
                  child: Pill(
                    label: '${commands.length} 条命令',
                    color: kInfo,
                    icon: Icons.terminal_rounded,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 命令过程默认只露两行：一次任务动辄上百条命令，全展开会把对话冲没。
class _CommandBubble extends StatefulWidget {
  const _CommandBubble({required this.message});

  final SessionMessage message;

  @override
  State<_CommandBubble> createState() => _CommandBubbleState();
}

class _CommandBubbleState extends State<_CommandBubble> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final collapsible = message.text.length > 80 || message.text.contains('\n');
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 8),
      decoration: BoxDecoration(
        color: kBgSoft,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.terminal_rounded,
                size: 12,
                color: kInfo,
              ),
              const SizedBox(width: 5),
              Text(
                message.tool ?? 'tool',
                style: const TextStyle(
                  fontSize: 10.5,
                  color: kInfo,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              if (collapsible)
                InkWell(
                  onTap: () => setState(() => _expanded = !_expanded),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    child: Text(
                      _expanded ? '收起' : '展开',
                      style: const TextStyle(fontSize: 10.5, color: kMuted),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 5),
          Text(
            message.text,
            maxLines: _expanded ? null : 2,
            overflow: _expanded ? null : TextOverflow.ellipsis,
            style: kMono.copyWith(
              fontSize: 11.5,
              height: 1.5,
              color: const Color(0xFFA9BBCB),
            ),
          ),
        ],
      ),
    );
  }
}

/// 底部输入框：「继续对话」→ 一条 act 命令 → bridge 在电脑上新建一个 cline 会话。
class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.sending,
    required this.onSend,
    required this.mode,
    required this.onModeChanged,
  });

  final TextEditingController controller;
  final bool sending;
  final VoidCallback onSend;

  /// 执行模式：plan = 只读；act = 会改文件。
  final String mode;
  final ValueChanged<String> onModeChanged;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: const BoxDecoration(
          color: kBgSoft,
          border: Border(top: BorderSide(color: kLine)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModeBar(mode: mode, onChanged: onModeChanged),
            const SizedBox(height: 6),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => onSend(),
                    style: const TextStyle(fontSize: 13.5, height: 1.4),
                    decoration: InputDecoration(
                      hintText: '继续对话（会新建 Cline 会话）…',
                      hintStyle: const TextStyle(fontSize: 13, color: kMuted),
                      filled: true,
                      fillColor: kPanel,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: kLine),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: kLine),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: kAccent),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  onPressed: sending ? null : onSend,
                  style: IconButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: kBg,
                    disabledBackgroundColor: kLine,
                    minimumSize: const Size(42, 42),
                  ),
                  icon: sending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: kBg,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 模式切换：PLAN（只读）/ ACT（会改文件），右侧一句风险提示。
class _ModeBar extends StatelessWidget {
  const _ModeBar({required this.mode, required this.onChanged});

  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final act = mode == 'act';
    return Row(
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment<String>(value: 'plan', label: Text('PLAN')),
            ButtonSegment<String>(value: 'act', label: Text('ACT')),
          ],
          selected: <String>{mode},
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const WidgetStatePropertyAll<TextStyle>(
              TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
            ),
            side: const WidgetStatePropertyAll<BorderSide>(
              BorderSide(color: kLine),
            ),
            foregroundColor: WidgetStateProperty.resolveWith<Color>((states) {
              if (states.contains(WidgetState.selected)) {
                return act ? kDanger : kInfo;
              }
              return kMuted;
            }),
          ),
          onSelectionChanged: (values) => onChanged(values.first),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            act ? 'ACT：会直接改文件' : 'PLAN：只读，不改文件',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: act ? kDanger : kMuted),
          ),
        ),
      ],
    );
  }
}

/// 二级页：某条 Cline 消息里执行过的全部命令。
/// 主对话流只保留「N 条命令」入口，避免上百条命令把对话冲没。
class SessionCommandsPage extends StatelessWidget {
  const SessionCommandsPage({super.key, required this.commands});

  final List<SessionMessage> commands;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('命令过程 (${commands.length})')),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 28),
        itemCount: commands.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, index) =>
            _CommandBubble(message: commands[index]),
      ),
    );
  }
}
