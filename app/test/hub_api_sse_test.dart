import 'dart:convert';

import 'package:cline_console/src/data/hub_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 把一段 SSE 文本当成服务端响应体，模拟 `/api/v1/events`。
HttpHubApi apiWith(String frames) => HttpHubApi(
  baseUrl: 'http://127.0.0.1:3100/_h/testprefix',
  token: 'clh_test_token',
  client: MockClient.streaming((request, bodyStream) async {
    expect(request.url.path, '/_h/testprefix/api/v1/events');
    expect(request.url.queryParameters['token'], 'clh_test_token');
    return http.StreamedResponse(
      Stream<List<int>>.fromIterable(<List<int>>[utf8.encode(frames)]),
      200,
      headers: const {'content-type': 'text/event-stream; charset=utf-8'},
    );
  }),
);

void main() {
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
