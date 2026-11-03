import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/models.dart';
import '../state/hub_store.dart';
import '../util/format.dart';
import 'theme.dart';

/// 小色点：会话是否成功、命令在什么阶段，一眼看出来。
class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 6),
        ],
      ),
    );
  }
}

/// 状态 / 模式小标签。
class Pill extends StatelessWidget {
  const Pill({super.key, required this.label, this.color = kMuted, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: color,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(14),
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: kLine),
      ),
      // 卡片里可能放 SwitchListTile / ListTile：它们把水波纹画在最近的 Material 上，
      // 中间隔一层带背景色的 Container 会触发 debug 断言（assistive 提示「水波纹不可见」）。
      // 这里只补一层透明 Material，不改背景与圆角，避免整屏卡片样式漂移。
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title!,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: kMuted,
                      ),
                    ),
                  ),
                  ?trailing,
                ],
              ),
              const SizedBox(height: 10),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

/// 会话 / 命令卡片里的「项目 · 时间 · 模型」这类次要信息行。
class MetaLine extends StatelessWidget {
  const MetaLine({super.key, required this.parts, this.icon, this.trailing});

  final List<String?> parts;
  final IconData? icon;

  /// 行尾固定显示的内容（例如每秒刷新的耗时）：左侧文字先省略，它始终可见。
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = parts
        .whereType<String>()
        .where((part) => part.trim().isNotEmpty)
        .join(' · ');
    return Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 12, color: kMuted),
          const SizedBox(width: 4),
        ],
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _metaStyle,
          ),
        ),
        if (trailing != null) ...[
          const Text(' · ', style: _metaStyle),
          trailing!,
        ],
      ],
    );
  }
}

const TextStyle _metaStyle = TextStyle(fontSize: 11.5, color: kMuted);

/// 「耗时 1m23s」：命令还在跑时每秒重算一次。
///
/// `CommandItem.duration` 已经是 getter（执行中取 `DateTime.now()`），但列表只在
/// 数据变化时重建 —— SSE 空闲时可能几分钟没有新事件，手机上的秒数就停住不动了。
class ElapsedText extends StatefulWidget {
  const ElapsedText({
    super.key,
    required this.start,
    this.end,
    this.running = false,
    this.prefix = '',
    this.fallback = '—',
    this.style = _metaStyle,
  });

  final DateTime? start;

  /// 终态时间；`null` + [running] = 还在跑，每秒刷新。
  final DateTime? end;

  /// 是否按「执行中」处理：为真时才起定时器。
  final bool running;

  final String prefix;

  /// 没有开始时间（或已结束但没有结束时间）时显示的占位符。
  final String fallback;

  final TextStyle style;

  @override
  State<ElapsedText> createState() => _ElapsedTextState();
}

class _ElapsedTextState extends State<ElapsedText> {
  Timer? _timer;

  bool get _ticking =>
      widget.running && widget.start != null && widget.end == null;

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant ElapsedText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 命令从「执行中」翻成终态时要停掉定时器，否则空转一秒一次。
    _syncTimer();
  }

  void _syncTimer() {
    if (_ticking) {
      _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final start = widget.start;
    if (start == null) return Text(widget.fallback, style: widget.style);
    final end = widget.end ?? (_ticking ? DateTime.now() : null);
    if (end == null) return Text(widget.fallback, style: widget.style);
    final span = end.difference(start);
    final duration = span.isNegative ? Duration.zero : span;
    return Text(
      '${widget.prefix}${formatDuration(duration)}',
      style: widget.style,
    );
  }
}

/// 「只看一台设备」生效时的提示条（P39）。
///
/// 设备筛选的入口已经收进右侧抽屉：抽屉是藏起来的，列表被筛过必须一眼能看见，
/// 否则用户会以为别的机器的数据丢了。没筛设备时完全不占空间。
///
/// 过滤放在 App 侧：服务端已经按设备返回全量，命令只有最近 50 条、
/// 会话一页 60 条，本地筛一下比多发一次请求简单。
class ActiveDeviceFilterBar extends StatelessWidget {
  const ActiveDeviceFilterBar({super.key, required this.store});

  final HubStore store;

  @override
  Widget build(BuildContext context) {
    final filter = store.deviceFilter;
    if (filter == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 0),
      child: Row(
        children: [
          Flexible(
            child: Align(
              alignment: Alignment.centerLeft,
              child: Pill(
                label: '只看 ${store.deviceLabel(filter)}',
                color: kAccent,
                icon: Icons.computer_rounded,
              ),
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: () => store.setDeviceFilter(null),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: const Text('看全部设备', style: TextStyle(fontSize: 11.5)),
          ),
        ],
      ),
    );
  }
}

String sessionStatusLabel(SessionItem item) {
  final status = item.status;
  if (status != null && status.isNotEmpty) return statusLabel(status);
  return item.succeeded ? '已完成' : '未知';
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.description,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? description;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: kPanel,
                shape: BoxShape.circle,
                border: Border.all(color: kLine),
              ),
              child: Icon(icon, color: kMuted, size: 26),
            ),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (description != null) ...[
              const SizedBox(height: 8),
              Text(
                description!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 12.5,
                  height: 1.6,
                  color: kMuted,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class ErrorView extends StatelessWidget {
  const ErrorView({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off_rounded, color: kDanger, size: 30),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, height: 1.6, color: kMuted),
            ),
            if (onRetry != null) ...[
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 复制按钮：命令、结果、token 都要能一键带走。
class CopyButton extends StatelessWidget {
  const CopyButton({
    super.key,
    required this.text,
    this.label = '复制',
    this.tooltip,
  });

  final String text;
  final String label;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = TextButton.icon(
      onPressed: text.trim().isEmpty
          ? null
          : () async {
              await Clipboard.setData(ClipboardData(text: text));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('已复制到剪贴板'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
      icon: const Icon(Icons.copy_rounded, size: 14),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// 顶部那颗连接状态指示灯 + 文案。
class LinkBadge extends StatelessWidget {
  const LinkBadge({super.key, required this.state, this.detail});

  final LinkState state;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final (color, label) = switch (state) {
      LinkState.live => (kAccent, '实时'),
      LinkState.connecting => (kWarn, '连接中'),
      LinkState.retrying => (kWarn, '重连中'),
      LinkState.offline => (kDanger, '离线'),
      LinkState.idle => (kMuted, '未连接'),
    };
    return Tooltip(
      message: detail ?? label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            StatusDot(color: color, size: 6),
            const SizedBox(width: 5),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: color,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 长文本折叠阈值：字符数或行数任一超限就折叠。
const int kCollapseChars = 900;
const int kCollapseLines = 12;

/// 会话正文的 Markdown 样式（P8）。
///
/// 只覆盖「看得见」的几处：正文跟随传入的 [style]（保证气泡里的字号一致），
/// 代码块用等宽 + 深色底，链接用信息色。其余交给 `MarkdownStyleSheet.fromTheme`。
MarkdownStyleSheet markdownSheetOf(BuildContext context, TextStyle style) {
  final base = MarkdownStyleSheet.fromTheme(Theme.of(context));
  final size = style.fontSize ?? 13.5;
  return base.copyWith(
    p: style,
    a: style.copyWith(color: kInfo, decoration: TextDecoration.underline),
    em: style.copyWith(fontStyle: FontStyle.italic),
    strong: style.copyWith(fontWeight: FontWeight.w700),
    code: kMono.copyWith(fontSize: size - 1, color: kText),
    codeblockPadding: const EdgeInsets.all(10),
    codeblockDecoration: BoxDecoration(
      color: kBg,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: kLine),
    ),
    blockSpacing: 8,
    listBullet: style,
    blockquote: style.copyWith(color: kMuted),
    blockquotePadding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
    blockquoteDecoration: const BoxDecoration(
      color: kBgSoft,
      border: Border(left: BorderSide(color: kLine, width: 3)),
    ),
    h1: style.copyWith(fontSize: size + 5, fontWeight: FontWeight.w700),
    h2: style.copyWith(fontSize: size + 3, fontWeight: FontWeight.w700),
    h3: style.copyWith(fontSize: size + 1, fontWeight: FontWeight.w600),
    horizontalRuleDecoration: const BoxDecoration(
      border: Border(top: BorderSide(color: kLine)),
    ),
  );
}

/// 二级页：完整文本 + 复制。
///
/// 为什么不在气泡里原地展开：一条 3 万字的回复展开后会把整页布局顶开、
/// 滚动位置也跟着跳；二级页能独立滚动、独立复制，回退也不需要重新定位。
class TextViewerPage extends StatelessWidget {
  const TextViewerPage({
    super.key,
    required this.title,
    required this.text,
    this.mono = false,
    this.markdown = false,
    this.truncated = false,
  });

  final String title;
  final String text;

  /// 命令过程用等宽字体，正文用普通字体。
  final bool mono;

  /// 正文按 Markdown 渲染（会话消息 / 模型结果）。
  /// 命令输出是终端回放，必须保持原样，不能把 `*` `#` 当格式记号。
  final bool markdown;

  /// bridge 侧已截断：明确告诉用户「这不是全文」，而不是让 UI 假装完整。
  final bool truncated;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [CopyButton(text: text, label: '复制')],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
          children: [
            if (truncated) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: kWarn.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: kWarn.withValues(alpha: 0.35)),
                ),
                child: const Text(
                  '原始内容更长：bridge 上报时按上限截断了，完整文本只在电脑上。',
                  style: TextStyle(fontSize: 11.5, height: 1.6, color: kWarn),
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (markdown)
              MarkdownBody(
                data: text,
                selectable: true,
                styleSheet: markdownSheetOf(
                  context,
                  const TextStyle(fontSize: 13.5, height: 1.65, color: kText),
                ),
              )
            else
              SelectableText(
                text,
                style: mono
                    ? kMono.copyWith(fontSize: 12)
                    : const TextStyle(
                        fontSize: 13.5,
                        height: 1.65,
                        color: kText,
                      ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 会话正文：短文本直接显示，长文本折叠成 12 行 + 「展开全文」入口。
class MessageText extends StatelessWidget {
  const MessageText({
    super.key,
    required this.text,
    required this.style,
    this.title = '全文',
    this.truncated = false,
    this.markdown = false,
  });

  final String text;
  final TextStyle style;
  final String title;
  final bool truncated;

  /// 按 Markdown 渲染（会话正文 / 模型结果）。命令输出不要打开。
  final bool markdown;

  @override
  Widget build(BuildContext context) {
    final lines = '\n'.allMatches(text).length + 1;
    final collapsible = text.length > kCollapseChars || lines > kCollapseLines;
    if (!collapsible) {
      if (!markdown) return Text(text, style: style);
      return MarkdownBody(
        data: text,
        selectable: true,
        styleSheet: markdownSheetOf(context, style),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          text,
          maxLines: kCollapseLines,
          overflow: TextOverflow.ellipsis,
          style: style,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => TextViewerPage(
                    title: title,
                    text: text,
                    markdown: markdown,
                    truncated: truncated,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  '展开全文（${text.length} 字）',
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: kInfo,
                  ),
                ),
              ),
            ),
            if (truncated) ...[
              const SizedBox(width: 8),
              const Text(
                '原文更长',
                style: TextStyle(fontSize: 10.5, color: kWarn),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
