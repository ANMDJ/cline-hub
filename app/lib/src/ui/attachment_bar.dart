import 'package:flutter/material.dart';

import '../data/file_picker.dart';
import 'theme.dart';

/// 选一份附件，并把「这个平台没有选择器 / 文件太大 / 读失败」统一翻译成 snackbar。
///
/// 下发面板与会话输入框共用同一个入口：两处的行为必须一致，否则用户会以为
/// 「这个页面的发送文件坏了」。
Future<PickedAttachment?> pickAttachmentForCommand(
  BuildContext context, {
  required bool imagesOnly,
}) async {
  final picker = const AttachmentPicker();
  if (!picker.supported) {
    _snack(context, '当前平台没有系统文件选择器（Web 预览 / 测试）；用手机 App 发送附件');
    return null;
  }
  try {
    return await picker.pick(imagesOnly: imagesOnly);
  } on AttachmentPickException catch (error) {
    _snack(context, error.message);
    return null;
  } catch (error) {
    _snack(context, '选择文件失败：$error');
    return null;
  }
}

void _snack(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
  );
}

/// 附件卡片上的一行字：`报告.docx · 12.3 KB`（测试直接断言这个格式）。
String attachmentSummary(PickedAttachment file) =>
    '${file.name} · ${file.sizeLabel}';

/// 「发送文件 / 发送图片」两个入口 + 已选附件。
///
/// 选中之后输入框里的文字就变成「要对这个文件做什么」，所以这里只负责选文件，
/// 指令仍然走原来的输入框（两处调用都保持这个分工）。
class AttachmentBar extends StatelessWidget {
  const AttachmentBar({
    super.key,
    required this.picked,
    required this.busy,
    required this.onPickFile,
    required this.onPickImage,
    required this.onClear,
    this.hint,
  });

  final PickedAttachment? picked;
  final bool busy;
  final VoidCallback onPickFile;
  final VoidCallback onPickImage;
  final VoidCallback onClear;

  /// 选中之后提示用户「在输入框写一句要求（可留空）」。
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final file = picked;
    if (file == null) {
      return Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          OutlinedButton.icon(
            onPressed: busy ? null : onPickFile,
            icon: const Icon(Icons.attach_file_rounded, size: 15),
            label: const Text('发送文件', style: TextStyle(fontSize: 12)),
            style: _buttonStyle,
          ),
          OutlinedButton.icon(
            onPressed: busy ? null : onPickImage,
            icon: const Icon(Icons.image_outlined, size: 15),
            label: const Text('发送图片', style: TextStyle(fontSize: 12)),
            style: _buttonStyle,
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
          decoration: BoxDecoration(
            color: kBgSoft,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: kAccent.withValues(alpha: 0.35)),
          ),
          child: Row(
            children: [
              Icon(
                file.isImage ? Icons.image_rounded : Icons.insert_drive_file_rounded,
                size: 16,
                color: kAccent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  attachmentSummary(file),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, height: 1.4),
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
        ),
        if (hint != null) ...[
          const SizedBox(height: 6),
          Text(
            hint!,
            style: const TextStyle(fontSize: 11, height: 1.5, color: kMuted),
          ),
        ],
      ],
    );
  }

  static final ButtonStyle _buttonStyle = OutlinedButton.styleFrom(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    minimumSize: Size.zero,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    foregroundColor: kAccent,
    side: BorderSide(color: kAccent.withValues(alpha: 0.4)),
  );
}
