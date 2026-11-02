import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 用系统浏览器打开外链（目前只有 APK 下载地址）。
///
/// 为什么不引 url_launcher：客户端从第一天起只保留 http / shared_preferences
/// 两个依赖（ADR-31）。Android 侧 ACTION_VIEW 一行就够；Web 预览没有原生侧，
/// 直接返回 false，由调用方退回到「复制链接」。
///
/// 安全边界：只放行 http / https。下载地址就这两种，`intent://`、`file://`
/// 之类的 scheme 一律不接（手机发来的链接不可信时才不会变成任意 Intent 跳板）。
class LinkLauncher {
  const LinkLauncher();

  static const MethodChannel _channel = MethodChannel(
    'top.littlewish.cline_console/links',
  );

  static bool isHttpUrl(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return false;
    return (uri.scheme == 'http' || uri.scheme == 'https') &&
        uri.host.isNotEmpty;
  }

  bool get supported => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// 返回 true = 已经交给系统浏览器；false = 当前平台不支持 / 地址不合法 / 没有浏览器。
  Future<bool> open(String url) async {
    if (!supported || !isHttpUrl(url)) return false;
    try {
      return await _channel.invokeMethod<bool>('openUrl', <String, Object?>{
            'url': url.trim(),
          }) ??
          false;
    } on MissingPluginException {
      // 旧包 / 测试环境：没有这个原生方法。
      return false;
    } on PlatformException {
      return false;
    }
  }
}
