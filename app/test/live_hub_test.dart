// 可选的真机冒烟：验证 App 的客户端代码能读懂真实 Hub 的返回。
//
//   HUB_LIVE_URL='http://82.157.153.22/_h/<前缀>' \
//   HUB_LIVE_TOKEN='clh_...' \
//   flutter test test/live_hub_test.dart
//
// 两个环境变量没设就整组跳过，CI 里不会因为没网而红。
import 'dart:io';

import 'package:cline_console/src/data/hub_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final baseUrl = Platform.environment['HUB_LIVE_URL'] ?? '';
  final token = Platform.environment['HUB_LIVE_TOKEN'] ?? '';
  final skipReason = baseUrl.isEmpty || token.isEmpty
      ? 'HUB_LIVE_URL / HUB_LIVE_TOKEN 未设置，跳过真机冒烟'
      : null;

  group('live hub', () {
    test('health：服务和数据库都在', () async {
      final api = HttpHubApi(baseUrl: baseUrl, token: token);
      final health = await api.health();
      await api.close();

      expect(health.service, 'cline-hub');
      expect(health.version, isNotEmpty);
      expect(health.dbOk, isTrue, reason: 'Hub 连不上 Postgres');
      expect(health.dbLatencyMs, isNotNull);
    }, skip: skipReason);

    test('sessions：列表结构可解析', () async {
      final api = HttpHubApi(baseUrl: baseUrl, token: token);
      final page = await api.sessions(limit: 5);
      await api.close();

      expect(page.items.length, lessThanOrEqualTo(5));
      for (final item in page.items) {
        expect(item.sessionId, isNotEmpty);
        expect(item.deviceId, isNotEmpty);
      }
      // 有下一页时必须给游标，且游标可被服务端接受
      expect(page.nextCursor == null || page.nextCursor!.contains('|'), isTrue);
    }, skip: skipReason);

    test('commands / hooks：列表结构可解析', () async {
      final api = HttpHubApi(baseUrl: baseUrl, token: token);
      final commands = await api.commands(limit: 5);
      final hooks = await api.hooks(limit: 5);
      await api.close();

      for (final command in commands) {
        expect(command.id, isNotEmpty);
        expect(command.status, isNotEmpty);
      }
      for (final hook in hooks) {
        expect(hook.id, greaterThan(0));
      }
    }, skip: skipReason);

    test('错误 token 会被翻译成授权失败（health 是匿名接口，验不出 token）', () async {
      final api = HttpHubApi(
        baseUrl: baseUrl,
        token: 'clh_0000000000000000000000000000000000',
      );
      try {
        // health 是 auth: 'none'，坏 token 也能拿到 200——这正是向导要额外打一次 sessions 的原因
        final health = await api.health();
        expect(health.service, 'cline-hub');

        await api.sessions(limit: 1);
        fail('坏 token 不应该拿到会话列表');
      } on ApiException catch (error) {
        expect(error.status, 401);
        expect(error.friendly, contains('token'));
      } finally {
        await api.close();
      }
    }, skip: skipReason);

    test('少了前缀就是 404，提示指向 baseUrl', () async {
      final broken = baseUrl.replaceFirst(RegExp(r'/_h/[^/]+$'), '');
      final api = HttpHubApi(baseUrl: broken, token: token);
      try {
        await api.health();
        fail('不带前缀不应该拿到 health');
      } on ApiException catch (error) {
        expect(error.status, 404);
        expect(error.friendly, contains('/_h/'));
      } finally {
        await api.close();
      }
    }, skip: skipReason);
  });
}
