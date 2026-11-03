import 'package:flutter/material.dart';

import '../data/file_picker.dart';

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

/// 附件卡片上的一行字：`报告.docx · 12.3 KB`（测试直接断言这个格式；
/// `ChatComposer` 的附件预览也用它，保证两处文案只维护一份）。
String attachmentSummary(PickedAttachment file) =>
    '${file.name} · ${file.sizeLabel}';

// 2026-11-04（P46）：原来这里还有 `AttachmentBar`（并排两个「发送文件 / 发送图片」
// 大按钮）。改成微信式输入条后，入口收进 `chat_composer.dart` 的「+」面板，
// 本文件只保留「怎么选文件」和「选完怎么显示」两件与平台相关的事。



