import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 一条要弹到系统通知栏的消息。
///
/// `key` 决定通知 id：同一条命令 / 同一个会话重复弹时只覆盖旧通知，不会叠一屏。
class HubNotification {
  const HubNotification({
    required this.key,
    required this.title,
    required this.body,
  });

  final String key;
  final String title;
  final String body;

  /// Android 的 notify(id, ...) 只接受 int；取正数避免与系统保留段混淆。
  int get id => key.hashCode & 0x7fffffff;
}

/// 通知出口。抽象出接口是为了测试里能换成一个记录器，
/// 也方便 Web 预览直接落到 [NoopHubNotifier]。
abstract class HubNotifier {
  bool get supported;

  /// 请求（或确认）通知权限；返回用户最终是否允许。
  Future<bool> ensurePermission();

  Future<void> show(HubNotification notification);
}

/// Android 原生实现：`MainActivity` 里注册的 MethodChannel。
///
/// 为什么不用 flutter_local_notifications：客户端从第一天起就只保留
/// http / shared_preferences 两个依赖（ADR-31），而这个需求只需要
/// 「建通道 + 发通知 + 要权限」三件事，系统 API 一百行就能写完；
/// 引插件还会连带要求 core library desugaring，给发版添新的失败点（ADR-35）。
class LocalHubNotifier implements HubNotifier {
  static const MethodChannel _channel = MethodChannel(
    'top.littlewish.cline_console/notify',
  );

  @override
  bool get supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<bool> ensurePermission() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('ensurePermission') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<void> show(HubNotification notification) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>('show', <String, Object?>{
        'id': notification.id,
        'title': notification.title,
        'body': notification.body,
      });
    } on MissingPluginException {
      // 旧包 / Web / 测试环境：通知是锦上添花，不能因此影响主流程。
    } on PlatformException {
      // 用户关了权限时系统会抛，不打扰界面。
    }
  }
}

/// 什么都不做：Web 预览、测试、或用户关掉通知时使用。
class NoopHubNotifier implements HubNotifier {
  const NoopHubNotifier();

  @override
  bool get supported => false;

  @override
  Future<bool> ensurePermission() async => false;

  @override
  Future<void> show(HubNotification notification) async {}
}
