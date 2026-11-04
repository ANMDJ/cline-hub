import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/file_picker.dart';
import '../data/hub_api.dart';
import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'attachment_bar.dart';
import 'chat_composer.dart';
import 'theme.dart';
import 'widgets.dart';

/// messageId 形如 `msg_xxx:3`，同一条 Cline 消息的正文与工具调用共享前缀。
String _baseMessageId(String messageId) {
  final i = messageId.lastIndexOf(':');
  return i > 0 ? messageId.substring(0, i) : messageId;
}

/// 会话详情：右上角「概览」弹层 + 逐条对话 + 底部「继续这个会话」。
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

  /// 正在选文件（系统选择器回来之前不重复弹）。
  bool _picking = false;

  /// 随「继续对话」一起发过去的文件 / 图片（P38）。
  PickedAttachment? _attachment;
  /// 继续对话的执行模式：plan = 只读；act = 会改文件。默认 plan。
  String _mode = 'plan';
  bool _loadingOlder = false;
  bool _hasOlder = true;

  /// 会话开头（seq 最小的几条）：首屏只加载了尾部，这块单独取一次。
  List<SessionMessage> _head = const <SessionMessage>[];
  bool _showJumpToLatest = false;

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

  /// 会话开头那几条正文（命令已折叠）。
  List<SessionMessage> get _headMessages =>
      _head.where((m) => !m.isCommand).toList(growable: false);

  /// 开头与已加载尾部之间缺了多少条（0 表示连着，不需要提示）。
  int get _headGap {
    if (_head.isEmpty || _messages.isEmpty) return 0;
    final gap = _messages.first.seq - _head.last.seq - 1;
    return gap > 0 ? gap : 0;
  }

  /// 每条 Cline 消息对应的命令（同名 message 的多条 tool_use 归到一起）。
  Map<String, List<SessionMessage>> get _commandGroups {
    final map = <String, List<SessionMessage>>{};
    for (final m in _messages) {
      if (!m.isCommand) continue;
      (map[_baseMessageId(m.messageId)] ??= <SessionMessage>[]).add(m);
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

  /// 默认模式跟着这个会话最近一条命令走。
  ///
  /// 之前硬编码 `plan`：用户刚用 ACT 下发过，一进详情页却又显示 PLAN，
  /// 看起来像「系统把我的选择忘了」（2026-11-02 反馈）。
  void _syncModeFromCommands() {
    final mine = widget.store.commands
        .where((item) => item.sessionId == widget.item.sessionId)
        .toList(growable: false);
    if (mine.isEmpty) return;
    mine.sort((a, b) {
      final left = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final right = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return left.compareTo(right);
    });
    final mode = mine.last.mode == 'act' ? 'act' : 'plan';
    if (mode != _mode && mounted) setState(() => _mode = mode);
  }

  /// 复制整段对话：按 seq 拼「用户 / 助手」正文，命令过程附 `$ 命令`。
  /// 会话动辄几百条，这里只拼已经加载到内存的部分，并在提示里说明条数。
  Future<void> _copyConversation() async {
    final lines = <String>[];
    for (final message in _messages) {
      if (message.isCommand) {
        lines.add('\$ ${message.text}');
      } else {
        lines.add('${message.isUser ? '用户' : '助手'}：${message.text}');
      }
    }
    if (lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('还没有可复制的内容')),
      );
      return;
    }
    await Clipboard.setData(ClipboardData(text: lines.join('\n\n')));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${lines.length} 条消息')),
    );
  }

  Future<void> _load() async {
    _syncModeFromCommands();
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
    await _loadHead();
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

  /// 取「会话开头」：服务端只要有 `after` 就按 seq 升序取，
  /// 所以 `after=-1` 就是从第 0 条开始拿 N 条。
  /// 注意不能用 `after=0` —— 那会把 seq=0 的用户原话漏掉。
  Future<void> _loadHead() async {
    try {
      final head = await widget.store.api.sessionMessages(
        widget.item.sessionId,
        limit: 12,
        after: -1,
      );
      if (!mounted) return;
      setState(() => _head = head);
    } catch (_) {
      // 开头拉不到不影响主对话：静默忽略，下拉刷新会再试
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
    final position = _scroll.position;
    if (position.pixels <= 80) unawaited(_loadOlder());
    // 离底部太远时给一个「回到最新」的快捷入口（几百条的会话翻上去就回不来）。
    final farFromBottom = (position.maxScrollExtent - position.pixels) > 320;
    if (farFromBottom != _showJumpToLatest) {
      setState(() => _showJumpToLatest = farFromBottom);
    }
  }

  void _jumpToLatest() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
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

  /// 选附件：内容读进内存，随下一条「继续对话」一起发出去。
  Future<void> _pick(bool imagesOnly) async {
    setState(() => _picking = true);
    final picked = await pickAttachmentForCommand(
      context,
      imagesOnly: imagesOnly,
    );
    if (!mounted) return;
    setState(() {
      _picking = false;
      if (picked != null) _attachment = picked;
    });
  }

  /// 「继续这个会话」：这句话会变成一条 act 命令，
  /// bridge 用 `cline --id <sessionId>` 接续原会话，过程和回复仍回到这里。
  Future<void> _send() async {
    final text = _composer.text.trim();
    final attachment = _attachment;
    // 只发文件也可以：输入框留空时由 bridge 补一句「先读这个文件」。
    if ((text.isEmpty && attachment == null) || _sending) return;

    setState(() => _sending = true);
    try {
      String? attachmentId;
      if (attachment != null) {
        final uploaded = await widget.store.api.uploadAttachment(
          deviceId: widget.item.deviceId,
          name: attachment.name,
          mimeType: attachment.mimeType,
          bytes: attachment.bytes,
        );
        attachmentId = uploaded.id;
      }
      await widget.store.api.sendCommand(
        deviceId: widget.item.deviceId,
        prompt: text,
        mode: _mode,
        workspace: _summary.workspaceRoot,
        sessionId: widget.item.sessionId,
        attachmentId: attachmentId,
      );
      _composer.clear();
      if (!mounted) return;
      setState(() => _attachment = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            attachment == null
                ? '已发到电脑，Cline 会在这个会话里接着干'
                : '已发到电脑（附件 ${attachment.name}），Cline 会在这个会话里接着干',
          ),
          duration: const Duration(seconds: 3),
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

  /// 「选择题」的回答：作为一条新命令下发。
  ///
  /// 无头 CLI 的会话是一次性的（`stdio: ignore`，进程跑完就退出），bridge 没有
  /// 办法往正在跑的会话里注入回答；所以语义是「带着原问题和选择，新开一条命令」。
  Future<void> _chooseOption(SessionMessage question, String option) async {
    if (_sending) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text('把选择发成新命令？'),
        content: Text(
          '原会话已经结束，bridge 不能中途注入回答。\n\n'
          '会以 ${_mode == 'act' ? 'ACT' : 'PLAN'} 模式新开一条命令，并带上你的选择：\n$option',
          style: const TextStyle(fontSize: 13, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('下发'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _sending = true);
    try {
      await widget.store.api.sendCommand(
        deviceId: widget.item.deviceId,
        prompt: '关于问题「${question.text}」，我选择：$option。请按这个选择继续。',
        mode: _mode,
        workspace: _summary.workspaceRoot,
        sessionId: widget.item.sessionId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已下发选择，等 bridge 执行')),
      );
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
    final head = _headMessages;
    final headGap = _headGap;
    final groups = _commandGroups;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('会话详情'),
            const SizedBox(width: 8),
            Flexible(
              child: Pill(
                label: sessionStatusLabel(summary),
                color: statusColor(summary.status, ok: summary.succeeded),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '概览',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.info_outline_rounded, size: 20),
            onPressed: () => showSessionOverview(context, summary),
          ),
          IconButton(
            icon: const Icon(Icons.copy_all_rounded, size: 20),
            tooltip: '复制整段对话',
            onPressed: _copyConversation,
          ),
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
                        if (head.isNotEmpty && headGap > 0) ...[
                          const SizedBox(height: 12),
                          _HeadSection(
                            messages: head,
                            commands: groups,
                            onChoose: _chooseOption,
                          ),
                          const SizedBox(height: 8),
                          _GapHint(count: headGap),
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
                            onChoose: _chooseOption,
                            commands: groups[_baseMessageId(chat[index].messageId)] ??
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
          _ComposerBar(
            controller: _composer,
            sending: _sending,
            picking: _picking,
            attachment: _attachment,
            onPickFile: () => _pick(false),
            onPickImage: () => _pick(true),
            onClearAttachment: () => setState(() => _attachment = null),
            onSend: _send,
            mode: _mode,
            onModeChanged: (value) => setState(() => _mode = value),
          ),
        ],
      ),
      floatingActionButton: _showJumpToLatest
          ? FloatingActionButton.small(
              tooltip: '回到最新',
              onPressed: _jumpToLatest,
              backgroundColor: kPanel,
              foregroundColor: kAccent,
              child: const Icon(Icons.arrow_downward_rounded, size: 18),
            )
          : null,
    );
  }
}

/// 会话开头：首屏只加载了最近几十条，这里把最开始那几句也摆出来。
class _HeadSection extends StatelessWidget {
  const _HeadSection({
    required this.messages,
    required this.commands,
    required this.onChoose,
  });

  final List<SessionMessage> messages;
  final Map<String, List<SessionMessage>> commands;
  final void Function(SessionMessage question, String option) onChoose;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '会话开头',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < messages.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _MessageBubble(
              message: messages[i],
              onChoose: onChoose,
              commands: commands[_baseMessageId(messages[i].messageId)] ??
                  const <SessionMessage>[],
            ),
          ],
        ],
      ),
    );
  }
}

/// 开头与已加载尾部之间的缺口提示。
class _GapHint extends StatelessWidget {
  const _GapHint({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider(color: kLine, height: 1)),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Text(
            '… 中间省略 $count 条 · 上滑可继续加载 …',
            style: const TextStyle(fontSize: 11, color: kMuted),
          ),
        ),
        const Expanded(child: Divider(color: kLine, height: 1)),
      ],
    );
  }
}

/// 右上角「概览」弹层：把原来压在首屏的元信息收进来，正文从顶部开始。
void showSessionOverview(BuildContext context, SessionItem item) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kBgSoft,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => DraggableScrollableSheet(
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
          const SizedBox(height: 10),
          const Text(
            '概览',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 12),
          _OverviewContent(item: item),
        ],
      ),
    ),
  );
}

class _OverviewContent extends StatelessWidget {
  const _OverviewContent({required this.item});

  final SessionItem item;

  @override
  Widget build(BuildContext context) {
    final color = statusColor(item.status, ok: item.succeeded);
    final detail = item is SessionDetail ? item as SessionDetail : null;
    final resultText = detail?.resultText?.trim() ?? '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            StatusDot(color: color),
            const SizedBox(width: 8),
            Text(
              sessionStatusLabel(item),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
            const Spacer(),
            Pill(
              label: item.deviceId,
              color: kMuted,
              icon: Icons.computer_rounded,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (item.exitCode != null)
              Pill(
                label: 'exit ${item.exitCode}',
                color: item.exitCode == 0 ? kAccent : kDanger,
              ),
            if (item.workspace != null)
              Pill(label: item.workspace!, color: kInfo),
            if (item.commandCount > 0)
              Pill(label: '${item.commandCount} 命令', color: kWarn),
            if (item.projectKind == 'loose')
              const Pill(label: '散会话', color: kMuted),
          ],
        ),
        const SizedBox(height: 14),
        SectionCard(
          title: '运行',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
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
            ],
          ),
        ),
        if (item.project != null || item.projectRoot != null) ...[
          const SizedBox(height: 10),
          SectionCard(
            title: '项目',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (item.project != null)
                  Text(
                    item.project!,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (item.projectRoot != null) ...[
                  const SizedBox(height: 6),
                  SelectableText(
                    item.projectRoot!,
                    style: kMono.copyWith(fontSize: 11.5, color: kMuted),
                  ),
                ],
              ],
            ),
          ),
        ],
        if (item.workspaceRoot != null) ...[
          const SizedBox(height: 10),
          SectionCard(
            title: '工作目录',
            child: SelectableText(
              item.workspaceRoot!,
              style: kMono.copyWith(fontSize: 11.5, color: kMuted),
            ),
          ),
        ],
        if ((item.prompt ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 10),
          SectionCard(
            title: '开头提问',
            trailing: CopyButton(text: item.prompt!, label: '复制'),
            child: Text(
              item.prompt!.trim(),
              style: const TextStyle(fontSize: 12.5, height: 1.6),
            ),
          ),
        ],
        if (resultText.isNotEmpty) ...[
          const SizedBox(height: 10),
          SectionCard(
            title: '结果',
            trailing: CopyButton(text: resultText, label: '复制'),
            child: MessageText(
              text: resultText,
              title: '会话结果',
              markdown: true,
              truncated: detail?.resultTruncated ?? false,
              style: const TextStyle(
                fontSize: 12.5,
                height: 1.6,
                color: Color(0xFFA9BBCB),
              ),
            ),
          ),
        ],
      ],
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
    required this.onChoose,
  });

  final SessionMessage message;

  /// 这条消息里产生的工具调用；主流程不渲染，只在气泡下留一个入口。
  final List<SessionMessage> commands;

  /// 「选择题」选中后回调（由页面负责变成一条新命令）。
  final void Function(SessionMessage question, String option) onChoose;

  @override
  Widget build(BuildContext context) {
    if (message.isCommand) return _CommandBubble(message: message);
    if (message.isQuestion) {
      return _QuestionBubble(
        message: message,
        onChoose: (option) => onChoose(message, option),
      );
    }

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
            MessageText(
              text: message.text,
              title: isUser ? '我的提问' : '助手回复',
              markdown: true,
              truncated: message.truncated,
              style: TextStyle(
                fontSize: 13.5,
                height: 1.62,
                color: isUser ? kText : const Color(0xFFD6E2EE),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                if (message.ts != null)
                  Text(
                    formatClock(message.ts),
                    style: const TextStyle(fontSize: 10.5, color: kMuted),
                  ),
                const Spacer(),
                CopyButton(text: message.text, label: '复制'),
              ],
            ),
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

/// 「选择题」气泡：问题正文 + 可点选项。
///
/// 之前在手机上看不到 `ask_question`，会话就卡在那儿等输入（2026-11-02 反馈）。
class _QuestionBubble extends StatelessWidget {
  const _QuestionBubble({required this.message, required this.onChoose});

  final SessionMessage message;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.92,
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: kPlan.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: kPlan.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.help_outline_rounded, size: 14, color: kPlan),
                const SizedBox(width: 6),
                const Text(
                  '需要你选择',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: kPlan,
                  ),
                ),
                const Spacer(),
                if (message.ts != null)
                  Text(
                    formatClock(message.ts),
                    style: const TextStyle(fontSize: 10.5, color: kMuted),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            MessageText(
              text: message.text,
              title: '问题',
              markdown: true,
              style: const TextStyle(fontSize: 13.5, height: 1.6),
            ),
            const SizedBox(height: 8),
            ...message.options.map(
              (option) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => onChoose(option),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      foregroundColor: kText,
                      side: BorderSide(color: kPlan.withValues(alpha: 0.45)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                    child: Text(
                      option,
                      style: const TextStyle(fontSize: 12.5, height: 1.45),
                    ),
                  ),
                ),
              ),
            ),
            const Text(
              '原会话已结束：点选项会带着这句选择新开一条命令。',
              style: TextStyle(fontSize: 10.5, height: 1.5, color: kMuted),
            ),
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
              CopyButton(text: message.text, label: '复制'),
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
          if (message.truncated)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '已截断：完整命令在电脑上',
                style: TextStyle(fontSize: 10.5, color: kWarn),
              ),
            ),
        ],
      ),
    );
  }
}

/// 底部输入区：PLAN/ACT + 微信式输入条（P46）。
///
/// 「继续对话」= 一条命令 → bridge 在电脑上新建 / 接续 Cline 会话；
/// 附件走输入条左侧的「+」，不再单独占一行按钮。
class _ComposerBar extends StatelessWidget {
  const _ComposerBar({
    required this.controller,
    required this.sending,
    required this.picking,
    required this.attachment,
    required this.onPickFile,
    required this.onPickImage,
    required this.onClearAttachment,
    required this.onSend,
    required this.mode,
    required this.onModeChanged,
  });

  final TextEditingController controller;
  final bool sending;

  /// 系统文件选择器正开着（按钮先别重复触发）。
  final bool picking;

  /// 已选的附件：会和这句话一起发出去（P38）。
  final PickedAttachment? attachment;
  final VoidCallback onPickFile;
  final VoidCallback onPickImage;
  final VoidCallback onClearAttachment;
  final VoidCallback onSend;

  /// 执行模式：plan = 只读；act = 会改文件。
  final String mode;
  final ValueChanged<String> onModeChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: kBgSoft,
        border: Border(top: BorderSide(color: kLine)),
      ),
      child: SafeArea(
        top: false,
        child: ChatComposer(
          leading: _ModeSwitch(mode: mode, onChanged: onModeChanged),
          controller: controller,
          sending: sending,
          picking: picking,
          attachment: attachment,
          onPickFile: onPickFile,
          onPickImage: onPickImage,
          onClearAttachment: onClearAttachment,
          onSend: onSend,
          hintText: '继续对话（会新建 Cline 会话）…',
          helper: '输入框里写要对这个文件做什么；留空就只让它读一遍并总结。',
        ),
      ),
    );
  }
}

/// 模式切换：PLAN（只读）/ ACT（会改文件）。
///
/// P50：从输入框上方单独一行挪到输入条同一行（和「+」「发送」齐平），
/// 少占一行高度；风险提示收进 Tooltip，不再单独占位。
class _ModeSwitch extends StatelessWidget {
  const _ModeSwitch({required this.mode, required this.onChanged});

  final String mode;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final act = mode == 'act';
    return Tooltip(
      message: act ? 'ACT：会直接改文件' : 'PLAN：只读，不改文件',
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment<String>(value: 'plan', label: Text('PLAN')),
          ButtonSegment<String>(value: 'act', label: Text('ACT')),
        ],
        selected: <String>{mode},
        showSelectedIcon: false,
        style: compactModeSegmentStyle(modeColor(mode)),
        onSelectionChanged: (values) => onChanged(values.first),
      ),
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
