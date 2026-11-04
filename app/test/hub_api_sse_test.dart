import 'dart:convert';

import 'package:cline_console/src/data/hub_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 记录 SSE 那一次请求的 URL，供断言「URL 里是 ticket 还是 token」。
class SseProbe {
  Uri? last;
}

/// 同时服务 `POST /api/v1/sse-ticket` 与 `GET /api/v1/events`。
///
/// [ticketStatus] 用来模拟老 Hub（404）与失效 token（401）：只有 404 / 网络错误
/// 才允许退回 `?token=`，401 必须让上层拿到鉴权错误。
HttpHubApi apiWith(
  String frames, {
  SseProbe? probe,
  int ticketStatus = 200,
  String ticket = 'clt_test_ticket',
}) => HttpHubApi(
  baseUrl: 'http://127.0.0.1:3100/_h/testprefix',
  token: 'clh_test_token',
  client: MockClient.streaming((request, bodyStream) async {
    if (request.url.path == '/_h/testprefix/api/v1/sse-ticket') {
      expect(request.method, 'POST');
      expect(request.headers['authorization'], 'Bearer clh_test_token');
      if (ticketStatus != 200) {
        return http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode(<String, Object?>{
                'ok': false,
                'code': ticketStatus == 401 ? 'unauthorized' : 'not_found',
                'message': 'stub',
              }),
            ),
          ),
          ticketStatus,
          headers: const {'content-type': 'application/json'},
        );
      }
      return http.StreamedResponse(
        Stream.value(
          utf8.encode(
            jsonEncode(<String, Object?>{
              'ok': true,
              'ticket': ticket,
              'expiresInSec': 60,
            }),
          ),
        ),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }

    expect(request.url.path, '/_h/testprefix/api/v1/events');
    probe?.last = request.url;
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[utf8.encode(frames)]),
      200,
      headers: const {'content-type': 'text/event-stream; charset=utf-8'},
    );
  }),
);

void main() {
  test('先用一次性票据换 URL，再连 SSE（URL 里不再有 token）', () async {
    final probe = SseProbe();
    final api = apiWith(': connected\n\nevent: hook\ndata: {"id":7}\n\n', probe: probe);

    final events = await api.events().take(2).toList();

    expect(events.map((event) => event.type), <String>['open', 'hook']);
    expect(probe.last?.queryParameters['ticket'], 'clt_test_ticket');
    expect(probe.last?.queryParameters.containsKey('token'), isFalse);
    await api.close();
  });

  test('老 Hub 没有 /sse-ticket（404）时退回 ?token=，过渡期不断连', () async {
    final probe = SseProbe();
    final api = apiWith(': connected\n\n', probe: probe, ticketStatus: 404);

    final events = await api.events().take(1).toList();

    expect(events.single.type, 'open');
    expect(probe.last?.queryParameters['token'], 'clh_test_token');
    expect(probe.last?.queryParameters.containsKey('ticket'), isFalse);
    await api.close();
  });

  test('换票返回 401 时不退回 token：鉴权错误直接抛给上层', () async {
    final api = apiWith(': connected\n\n', ticketStatus: 401);

    await expectLater(
      api.events().toList(),
      throwsA(
        isA<ApiException>()
            .having((error) => error.status, 'status', 401)
            .having((error) => error.isAuth, 'isAuth', isTrue),
      ),
    );
    await api.close();
  });

  test('": connected" 先翻成一个 open 事件，之后才轮到业务事件', () async {
    final api = apiWith(
      ': connected\n\n'
      ': ping\n\n'
      'event: hook\ndata: {"id":7,"event":"agent_end"}\n\n',
    );

    final events = await api.events().take(2).toList();

    expect(events.map((event) => event.type), <String>['open', 'hook']);
    await api.close();
  });

  test('只有心跳时只发一个 open，不会每个 ping 都刷一次', () async {
    final api = apiWith(': ping\n\n: ping\n\n: ping\n\n');

    final events = await api.events().toList();

    expect(events.length, 1);
    expect(events.single.type, 'open');
    await api.close();
  });

  test('没有注释行（老版本 Hub）时行为不变', () async {
    final api = apiWith(
      'event: tick\ndata: {}\n\nevent: command\ndata: {"id":3,"status":"pending"}\n\n',
    );

    final events = await api.events().toList();

    expect(events.map((event) => event.type), <String>['tick', 'command']);
    expect(events.last.data['id'], 3);
    await api.close();
  });
}

