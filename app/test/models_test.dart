import 'package:cline_console/src/models/models.dart';
import 'package:cline_console/src/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionItem', () {
    test('解析列表项并优先用 userPrompt 当标题', () {
      final item = SessionItem.fromJson(<String, dynamic>{
        'deviceId': 'localone',
        'sessionId': '1793406873889_kz6g7',
        'workspace': 'kids_points_app',
        'status': 'completed',
        'exitCode': 0,
        'model': 'cline-free/x',
        'startedAt': '2026-10-30T23:14:33.889Z',
        'endedAt': '2026-10-31T01:02:11.000Z',
        'userPrompt': '要不要上 Docker',
        'prompt': '结论先说…',
        'resultOk': true,
        'commandCount': 26,
        'sortAt': '2026-10-31T01:02:11.000Z',
      });

      expect(item.title, '要不要上 Docker');
      expect(item.commandCount, 26);
      expect(item.succeeded, isTrue);
      expect(
        item.duration,
        const Duration(hours: 1, minutes: 47, seconds: 37, milliseconds: 111),
      );
    });

    test('空对象不会炸，字段全是兜底值', () {
      final item = SessionItem.fromJson(const <String, dynamic>{});
      expect(item.sessionId, '');
      expect(item.title, '（无标题会话）');
      expect(item.succeeded, isFalse);
      expect(item.duration, isNull);
    });
  });

  group('SessionDetail', () {
    test('带上 resultText 和 commands', () {
      final detail = SessionDetail.fromJson(<String, dynamic>{
        'deviceId': 'localone',
        'sessionId': 's1',
        'resultText': '全部 42 个测试通过',
        'commands': [
          {'id': 't1', 'tool': 'run_commands', 'command': 'npm test'},
        ],
      });
      expect(detail.resultText, '全部 42 个测试通过');
      expect(detail.commands.single.tool, 'run_commands');
      expect(detail.commands.single.command, 'npm test');
    });
  });

  group('CommandItem', () {
    test('状态与耗时', () {
      final running = CommandItem.fromJson(<String, dynamic>{
        'id': 'cmd_1',
        'deviceId': 'localone',
        'prompt': 'dir',
        'mode': 'act',
        'status': 'running',
        'startedAt': DateTime.now()
            .subtract(const Duration(seconds: 5))
            .toIso8601String(),
      });
      expect(running.isActive, isTrue);
      expect(running.modeLabel, 'ACT');
      expect(running.duration, isNotNull);

      final done = CommandItem.fromJson(<String, dynamic>{
        'id': 'cmd_2',
        'status': 'done',
        'mode': 'yolo',
        'startedAt': '2026-10-31T09:00:00.000Z',
        'finishedAt': '2026-10-31T09:00:06.000Z',
      });
      expect(done.isActive, isFalse);
      expect(done.modeLabel, 'YOLO');
      expect(done.duration, const Duration(seconds: 6));
    });
  });

  group('HubEvent', () {
    test('SSE 的 data 是 JSON 时拆成 map', () {
      final event = HubEvent.fromSse('hook', '{"id":7,"event":"agent_end"}');
      expect(event.type, 'hook');
      expect(event.data['event'], 'agent_end');
    });

    test('data 不是 JSON 时保留原文', () {
      final event = HubEvent.fromSse('message', 'hello');
      expect(event.data['raw'], 'hello');
    });
  });

  group('时间格式', () {
    final now = DateTime(2026, 11, 1, 12, 0, 0);

    test('相对时间', () {
      expect(
        relativeTime(now.subtract(const Duration(seconds: 10)), now: now),
        '刚刚',
      );
      expect(
        relativeTime(now.subtract(const Duration(minutes: 5)), now: now),
        '5 分钟前',
      );
      expect(
        relativeTime(now.subtract(const Duration(hours: 3)), now: now),
        '3 小时前',
      );
      expect(
        relativeTime(now.subtract(const Duration(days: 3)), now: now),
        '3 天前',
      );
      expect(relativeTime(DateTime(2026, 10, 20, 8), now: now), '10-20');
    });

    test('时长', () {
      expect(formatDuration(const Duration(seconds: 42)), '42s');
      expect(formatDuration(const Duration(minutes: 3, seconds: 7)), '3m07s');
      expect(formatDuration(const Duration(hours: 2, minutes: 5)), '2h05m');
      expect(formatDuration(null), '—');
    });
  });
}
