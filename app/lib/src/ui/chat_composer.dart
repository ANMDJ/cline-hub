import 'package:flutter/material.dart';

import '../data/file_picker.dart';
import 'attachment_bar.dart';
import 'theme.dart';

/// 微信式输入条（P46）。
///
/// 原来的做法是在输入框上方并排两个 `OutlinedButton`（「发送文件」「发送图片」），
/// 再加一个已选附件卡片：占掉两行高度，每进一个页面还要重新认一遍这两个按钮。
/// 现在收成微信那一套：
///
/// ```
/// [ 已选附件：缩略图 / 名字 · 大小 ·   × ]   ← 只在有附件时出现
/// [ + ] [ 圆角输入框                ] [发送]  ← 发送在右侧，没内容时是灰的
/// [  图片 ]   [  文件 ]                      ← 点「+」展开，再点一次收起
/// ```
///
/// 两处调用共用这一个组件（会话详情 / 下发面板），行为才不会一边一个样。
/// 「选文件」仍然走 `attachment_bar.dart` 的原生选择器，这里只负责交互与排版。
class ChatComposer extends StatefulWidget {
  const ChatComposer({
    super.key,
    required this.controller,
    required this.onSend,
    required this.onPickFile,
    required this.onPickImage,
    required this.onClearAttachment,
    this.attachment,
    this.sending = false,
    this.picking = false,
    this.showSendButton = true,
    this.autofocus = false,
    this.hintText = '发消息…',
    this.helper,
    this.sendTooltip = '发送',
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final VoidCallback onPickFile;
  final VoidCallback onPickImage;
  final VoidCallback onClearAttachment;

  /// 已选附件：会和这句话一起发出去；`null` = 纯文字。
  final PickedAttachment? attachment;

  /// 正在发送（按钮转圈，不再接受点击）。
  final bool sending;

  /// 系统选择器正开着：别让用户连点两次「+」。
  final bool picking;

  /// 会话详情用 true（发送就是发这句话）；下发面板用 false（底部已有「下发」按钮）。
  final bool showSendButton;

  final bool autofocus;

  final String hintText;

  /// 有附件时补一句「在输入框写要对这个文件做什么」。
  final String? helper;

  final String sendTooltip;

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  /// 微信点「+」是就地展开面板，不是弹新页面；再点一次收起。
  bool _panelOpen = false;
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChanged);
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChanged);
    _focus.dispose();
    super.dispose();
  }

  /// 点回输入框就收起面板：键盘和附件面板不同时占屏幕（和微信一致）。
  void _onFocusChanged() {
    if (_focus.hasFocus && _panelOpen && mounted) {
      setState(() => _panelOpen = false);
    }
  }

  void _togglePanel() {
    setState(() => _panelOpen = !_panelOpen);
    if (_panelOpen) _focus.unfocus();
  }

  void _pick(bool imagesOnly) {
    setState(() => _panelOpen = false);
    if (imagesOnly) {
      widget.onPickImage();
    } else {
      widget.onPickFile();
    }
  }

  bool get _busy => widget.sending || widget.picking;

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (attachment != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
            child: _AttachmentPreview(
              file: attachment,
              busy: _busy,
              onClear: widget.onClearAttachment,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _PlusButton(open: _panelOpen, busy: _busy, onTap: _togglePanel),
              const SizedBox(width: 6),
              Expanded(child: _inputField()),
              if (widget.showSendButton) ...[
                const SizedBox(width: 6),
                _sendButton(attachment),
              ],
            ],
          ),
        ),
        if (attachment != null && widget.helper != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.helper!,
                style: const TextStyle(fontSize: 11, height: 1.5, color: kMuted),
              ),
            ),
          ),
        AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _panelOpen
              ? _AttachmentPanel(
                  busy: _busy,
                  onPickFile: () => _pick(false),
                  onPickImage: () => _pick(true),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }

  Widget _inputField() {
    return TextField(
      controller: widget.controller,
      focusNode: _focus,
      autofocus: widget.autofocus,
      minLines: 1,
      maxLines: 4,
      textInputAction: TextInputAction.send,
      onSubmitted: (_) => widget.onSend(),
      style: const TextStyle(fontSize: 14, height: 1.4),
      decoration: InputDecoration(
        hintText: widget.hintText,
        hintStyle: const TextStyle(fontSize: 13, color: kMuted),
        filled: true,
        fillColor: kPanel,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: kLine),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: kLine),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: BorderSide(color: kAccent.withValues(alpha: 0.65)),
        ),
      ),
    );
  }

  /// 没内容时按钮变灰但仍然在（不给用户「按钮怎么不见了」的疑惑）。
  Widget _sendButton(PickedAttachment? attachment) {
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final canSend =
            !_busy && (value.text.trim().isNotEmpty || attachment != null);
        return IconButton.filled(
          onPressed: canSend ? widget.onSend : null,
          tooltip: widget.sendTooltip,
          style: IconButton.styleFrom(
            backgroundColor: kAccent,
            foregroundColor: kBg,
            disabledBackgroundColor: kLine,
            disabledForegroundColor: kMuted,
            minimumSize: const Size(42, 42),
          ),
          icon: widget.sending
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: kBg),
                )
              : const Icon(Icons.send_rounded, size: 18),
        );
      },
    );
  }
}

/// 左侧「+」：展开时转 45° 变成「×」，是「再点一次收起」的唯一提示。
class _PlusButton extends StatelessWidget {
  const _PlusButton({
    required this.open,
    required this.busy,
    required this.onTap,
  });

  final bool open;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: busy ? null : onTap,
      tooltip: open ? '收起附件' : '发送文件 / 图片',
      style: IconButton.styleFrom(
        backgroundColor: kPanel,
        foregroundColor: open ? kAccent : kMuted,
        minimumSize: const Size(42, 42),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(21),
          side: BorderSide(color: open ? kAccent.withValues(alpha: 0.6) : kLine),
        ),
      ),
      icon: AnimatedRotation(
        turns: open ? 0.125 : 0,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOutCubic,
        child: const Icon(Icons.add_rounded, size: 20),
      ),
    );
  }
}

/// 已选附件：图片给真缩略图，其它给文件图标 + 「名字 · 大小」。
///
/// 图片走 `Image.memory`（内容已经在内存里，不再读一次盘）；解码失败
/// （坏文件 / 测试里的假字节）退回图标，不能因为一张图把整个输入区打崩。
class _AttachmentPreview extends StatelessWidget {
  const _AttachmentPreview({
    required this.file,
    required this.busy,
    required this.onClear,
  });

  final PickedAttachment file;
  final bool busy;
  final VoidCallback onClear;

  static const double _size = 40;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 4, 8),
      decoration: BoxDecoration(
        color: kPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: kLine),
      ),
      child: Row(
        children: [
          ClipRRect(borderRadius: BorderRadius.circular(8), child: _thumb()),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  attachmentSummary(file),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12.5, height: 1.3),
                ),
                const SizedBox(height: 3),
                Text(
                  file.isImage
                      ? '图片 · 随这句话一起发到电脑'
                      : '文件 · 随这句话一起发到电脑',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10.5, color: kMuted),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: busy ? null : onClear,
            tooltip: '移除附件',
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.close_rounded, size: 16),
          ),
        ],
      ),
    );
  }

  Widget _thumb() {
    if (!file.isImage) {
      return Container(
        width: _size,
        height: _size,
        color: kBgSoft,
        child: const Icon(
          Icons.insert_drive_file_rounded,
          size: 20,
          color: kMuted,
        ),
      );
    }
    return Image.memory(
      file.bytes,
      width: _size,
      height: _size,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) => Container(
        width: _size,
        height: _size,
        color: kBgSoft,
        child: const Icon(Icons.image_outlined, size: 20, color: kMuted),
      ),
    );
  }
}

/// 「+」展开后的九宫格（现在两格）：图片 / 文件。
///
/// 与老的两个大按钮相比，这里多了 `busy` 态：系统选择器开着的时候点不动，
/// 避免连续弹两次相册。
class _AttachmentPanel extends StatelessWidget {
  const _AttachmentPanel({
    required this.busy,
    required this.onPickFile,
    required this.onPickImage,
  });

  final bool busy;
  final VoidCallback onPickFile;
  final VoidCallback onPickImage;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: kLine)),
      ),
      child: Row(
        children: [
          _PanelTile(
            icon: Icons.photo_library_rounded,
            label: '图片',
            color: kInfo,
            busy: busy,
            onTap: onPickImage,
          ),
          const SizedBox(width: 20),
          _PanelTile(
            icon: Icons.insert_drive_file_rounded,
            label: '文件',
            color: kWarn,
            busy: busy,
            onTap: onPickFile,
          ),
        ],
      ),
    );
  }
}

class _PanelTile extends StatelessWidget {
  const _PanelTile({
    required this.icon,
    required this.label,
    required this.color,
    required this.busy,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // 整块（图标 + 文字）都可点：只让图标可点的话，手指落在文字上会「没反应」。
    return InkWell(
      onTap: busy ? null : onTap,
      borderRadius: BorderRadius.circular(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: kPanel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kLine),
            ),
            child: Icon(icon, size: 24, color: busy ? kMuted : color),
          ),
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(fontSize: 11.5, color: kMuted)),
        ],
      ),
    );
  }
}

