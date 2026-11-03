import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../util/format.dart';

/// 单份附件上限：与 Hub 的 `HUB_MAX_ATTACHMENT_BYTES` 默认值（8 MB）对齐。
/// 服务端还可以调大；这边的数字只是「别让用户选一个注定失败的文件」。
const int kMaxAttachmentBytes = 8 * 1024 * 1024;

/// 从系统文件选择器 / 相册里选出来的一份文件（内容已经读进内存）。
class PickedAttachment {
  const PickedAttachment({
    required this.name,
    required this.mimeType,
    required this.bytes,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;

  int get byteSize => bytes.length;

  bool get isImage => mimeType.startsWith('image/');

  String get sizeLabel => formatBytes(byteSize);
}

/// 选择失败的原因已经翻译成人话，直接显示在 snackbar 里。
class AttachmentPickException implements Exception {
  AttachmentPickException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 系统文件选择器（原生 MethodChannel）。
///
/// 为什么不引 `file_picker` / `image_picker`：客户端刻意只保留
/// http / shared_preferences / flutter_markdown_plus 三个依赖（ADR-31 / 42），
/// Android 侧一个 `ACTION_OPEN_DOCUMENT` 就够（和 `link_launcher.dart` 同一个思路）。
/// Web 预览 / 桌面没有原生侧，直接返回 `null`，由调用方提示「用手机 App 发」。
class AttachmentPicker {
  const AttachmentPicker();

  static const MethodChannel _channel = MethodChannel(
    'top.littlewish.cline_console/files',
  );

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// [imagesOnly] = 只列图片（「发送图片」）；否则列出所有文件（「发送文件」）。
  ///
  /// 返回 `null` 表示用户取消 / 当前平台不支持；超限与读失败都抛
  /// [AttachmentPickException]，调用方统一弹提示。
  Future<PickedAttachment?> pick({
    bool imagesOnly = false,
    int maxBytes = kMaxAttachmentBytes,
  }) async {
    if (!supported) return null;
    try {
      final raw = await _channel.invokeMapMethod<String, Object?>('pick', {
        'mime': imagesOnly ? 'image/*' : '*/*',
        'maxBytes': maxBytes,
      });
      if (raw == null) return null;
      final bytes = raw['bytes'];
      if (bytes is! Uint8List || bytes.isEmpty) return null;
      final name = (raw['name'] as String?)?.trim() ?? '';
      final mime = (raw['mimeType'] as String?)?.trim() ?? '';
      return PickedAttachment(
        name: name.isEmpty ? 'attachment' : name,
        mimeType: mime.isEmpty ? 'application/octet-stream' : mime,
        bytes: bytes,
      );
    } on MissingPluginException {
      // 旧包 / 测试环境：原生侧还没有这个方法。
      return null;
    } on PlatformException catch (error) {
      throw AttachmentPickException(switch (error.code) {
        'too_large' => '这个文件超过 ${formatBytes(maxBytes)}，换个小一点的',
        'read_failed' => '读不到这个文件：${error.message ?? '权限或文件已被移动'}',
        'no_picker' => '系统里没有可用的文件选择器',
        _ => '选择文件失败：${error.message ?? error.code}',
      });
    }
  }
}
