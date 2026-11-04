import 'package:cline_console/src/data/notifier.dart';
import 'package:cline_console/src/data/settings_store.dart';
import 'package:cline_console/src/models/models.dart';
import 'package:cline_console/src/state/hub_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

/// 通知出口的假实现：只记录「弹了什么」，不碰平台通道。
class RecordingNotifier implements HubNotifier {
  final List<HubNotification> shown = <HubNotification>[];
  int permissionCalls = 0;
  bool permission = true;

  /// 保活服务的调用记录（P34）：`startKeepAlive` 的文案按调用顺序存。
  final List<String> keepAliveStarts = <String>[];
  int keepAliveStops = 0;

  @override
  bool get supported => true;

  @override
  Future<bool> ensurePermission() async {
    permissionCalls++;
    return permission;
  }

  @override
  Future<void> show(HubNotification notification) async {
    shown.add(notification);
  }

  @override
  Future<void> startKeepAlive(String text) async {
    keepAliveStarts.add(text);
  }

  @override
  Future<void> stopKeepAlive() async {
    keepAliveStops++;
  }
}

/// 模拟 Web / 非 Android：`supported=false` 时不该碰保活服务。
class UnsupportedNotifier extends RecordingNotifier {
  @override
  bool get supported => false;
}

Future<SettingsStore> makeSettings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  await settings.saveConnection(
    baseUrl: 'http://127.0.0.1:3100',
    token: 'clh_test_token_value',
    deviceId: 'localone',
  );
  return settings;
}

CommandItem command(
  String id,
  String status, {
  String mode = 'act',
  String prompt = '跑一遍测试',
  String? resultText,
  String? errorText,
  String? sessionId,
  bool rejectedBeforeStart = false,
  String? rejectedReason,
}) => CommandItem(
  id: id,
  deviceId: 'localone',
  prompt: prompt,
  mode: mode,
  status: status,
  resultText: resultText,
  errorText: errorText,
  sessionId: sessionId,
  rejectedBeforeStart: rejectedBeforeStart,
  rejectedReason: rejectedReason,
);

Map<String, dynamic> event(CommandItem item) => <String, dynamic>{
  'id': item.id,
  'deviceId': item.deviceId,
  'prompt': item.prompt,
  'mode': item.mode,
  'status': item.status,
  'resultText': item.resultText,
  'errorText': item.errorText,
  'sessionId': item.sessionId,
  'rejectedBeforeStart': item.rejectedBeforeStart,
  'rejectedReason': item.rejectedReason,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('命令从执行中翻成 done 只弹一次，正文去掉 ANSI', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();

    final done = command(
      'cmd_1',
      'done',
      resultText: '\u001b[2mAll tests passed\u001b[0m\n\n耗时 12s',
    );
    fake.emit('command.update', event(done));
    await Future<void>.delayed(Duration.zero);

    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.title, '命令完成 · ACT');
    expect(notifier.shown.single.body, 'All tests passed 耗时 12s');

    // SSE 重连会重放最后一条：同一个 commandId + status 不重复弹。
    fake.emit('command.update', event(done));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown, hasLength(1));

    // 首次见到的历史命令（previous == null）不弹，避免打开 App 刷屏。
    fake.emit('command', event(command('cmd_old', 'done')));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown, hasLength(1));

    store.dispose();
  });

  test('失败命令的正文优先用 errorText；关掉开关后不再弹', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();

    fake.emit(
      'command.update',
      event(
        command(
          'cmd_1',
          'failed',
          resultText: 'partial output',
          errorText: 'exit code 1: workspace not allowed',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.title, '命令失败 · ACT');
    expect(notifier.shown.single.body, 'exit code 1: workspace not allowed');

    // 用户关掉通知开关后，新命令不再弹。
    await settings.setNotifyCommands(false);
    fake.emit(
      'command.update',
      event(command('cmd_2', 'running')),
    );
    fake.emit(
      'command.update',
      event(command('cmd_2', 'done', resultText: 'ok')),
    );
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown, hasLength(1));

    store.dispose();
  });

  test('执行前被拒的命令：通知标题是「未执行」，不是「失败」', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();

    fake.emit(
      'command.update',
      event(
        command(
          'cmd_1',
          'failed',
          rejectedBeforeStart: true,
          rejectedReason: 'workspace_missing',
          errorText: 'no usable workspace: workspace "C:\\nope" 在本机不存在',
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.title, '命令未执行 · ACT');
    expect(notifier.shown.single.body, contains('在本机不存在'));

    store.dispose();
  });

  test('session_done 弹会话通知，agent_end 不弹', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi();
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();

    fake.emit('hook', <String, dynamic>{
      'id': 9,
      'event': 'session_done',
      'title': 'cline-hub',
      'body': '关掉了多余的定时器',
    });
    fake.emit('hook', <String, dynamic>{
      'id': 10,
      'event': 'agent_end',
      'title': 'Cline',
      'body': '任务结束',
    });
    await Future<void>.delayed(Duration.zero);

    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.title, '会话完成 · cline-hub');
    expect(notifier.shown.single.body, '关掉了多余的定时器');

    store.dispose();
  });

  test('同一条任务：命令完成 + session_done 只弹一条', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();

    // bridge 跑完命令：先 PATCH 命令（带 sessionId），30 秒后再合成 session_done。
    final done = command(
      'cmd_1',
      'done',
      sessionId: '1793628160515_lvoyc',
      resultText: '全部通过',
    );
    fake.emit('command.update', event(done));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown, hasLength(1));

    fake.emit('hook', <String, dynamic>{
      'id': 185,
      'event': 'session_done',
      'sessionId': '1793628160515_lvoyc',
      'title': 'cline-hub',
      'body': '全部通过',
    });
    await Future<void>.delayed(Duration.zero);

    // 同一个 sessionId 已经提醒过：会话那条不再弹，避免「同一个任务两条消息」。
    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.title, '命令完成 · ACT');

    store.dispose();
  });

  test('session_done 先到、命令终态后到，也只弹一条', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();

    fake.emit('hook', <String, dynamic>{
      'id': 186,
      'event': 'session_done',
      'sessionId': 's_twin',
      'title': 'kids_points_app',
      'body': '跑完了',
    });
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown, hasLength(1));

    fake.emit(
      'command.update',
      event(command('cmd_1', 'done', sessionId: 's_twin', resultText: '跑完了')),
    );
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown, hasLength(1), reason: '同一条任务不该再弹第二条');

    store.dispose();
  });

  test('后台补发的命令通知，不会被随后到达的 session_done 再弹一次', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();

    store.pause();
    // 息屏期间命令跑完（此时还没到 30 秒的终态稳定窗口）。
    fake.commandItems = <CommandItem>[
      command('cmd_1', 'done', sessionId: 's_bg', resultText: '后台跑完了'),
    ];
    // 回前台：先补一条「命令完成」。
    store.resume();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notifier.shown, hasLength(1));

    // 紧接着 bridge 的 30 秒稳定窗口到了，推来 session_done。
    fake.emit('hook', <String, dynamic>{
      'id': 187,
      'event': 'session_done',
      'sessionId': 's_bg',
      'title': 'cline-hub',
      'body': '后台跑完了',
    });
    await Future<void>.delayed(Duration.zero);
    expect(notifier.shown, hasLength(1), reason: '息屏回前台只该看到一条');

    store.dispose();
  });

  test('回到前台补发后台期间结束的命令', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();

    store.pause();
    // 后台期间命令跑完了（后台没有 SSE，收不到 command.update）。
    fake.commandItems = <CommandItem>[
      command('cmd_1', 'done', resultText: '后台跑完了'),
    ];
    store.resume();
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.body, '后台跑完了');

    store.dispose();
  });

  // ------------------------------------------------------------------ 保活服务
  test('有活跃命令时拉起保活服务，同一条命令再推 running 不会重复拉起', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'pending')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.keepAliveStarts, <String>['有 1 条命令正在执行']);
    expect(notifier.keepAliveStops, 0);

    fake.emit('command.update', event(command('cmd_1', 'running')));
    await Future<void>.delayed(Duration.zero);
    expect(notifier.keepAliveStarts, hasLength(1), reason: '0→1 只开一次');

    store.dispose();
  });

  test('保活期间退到后台不断流，锁屏也能收到命令完成', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();
    await Future<void>.delayed(Duration.zero);
    expect(notifier.keepAliveStarts, hasLength(1));

    store.pause();
    expect(
      store.link,
      isNot(LinkState.idle),
      reason: '有前台服务保活时不该断 SSE',
    );

    fake.emit(
      'command.update',
      event(command('cmd_1', 'done', resultText: '锁屏跑完了')),
    );
    await Future<void>.delayed(Duration.zero);

    expect(notifier.shown, hasLength(1));
    expect(notifier.shown.single.body, '锁屏跑完了');
    expect(notifier.keepAliveStops, 1);

    // 保活停掉后补一次断流，回前台再重连。
    expect(store.link, LinkState.idle);

    store.dispose();
  });

  test('命令跑到终态后收起保活服务，完成通知照旧弹', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();
    await Future<void>.delayed(Duration.zero);
    expect(notifier.keepAliveStarts, hasLength(1));

    fake.emit(
      'command.update',
      event(command('cmd_1', 'done', resultText: '全部通过')),
    );
    await Future<void>.delayed(Duration.zero);

    expect(notifier.keepAliveStops, 1);
    expect(notifier.shown, hasLength(1));

    store.dispose();
  });

  test('排队中的命令被取消后收起保活服务', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'pending')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();
    await Future<void>.delayed(Duration.zero);
    expect(notifier.keepAliveStarts, hasLength(1));

    fake.emit('command.update', event(command('cmd_1', 'cancelled')));
    await Future<void>.delayed(Duration.zero);

    expect(notifier.keepAliveStops, 1);

    store.dispose();
  });

  test('关掉「锁屏也提醒」后不再拉起保活服务', () async {
    final settings = await makeSettings();
    await settings.setKeepAlive(false);
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.keepAliveStarts, isEmpty);

    store.dispose();
  });

  test('平台不支持（Web / 测试）时不碰保活服务', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = UnsupportedNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();
    await Future<void>.delayed(Duration.zero);

    expect(notifier.keepAliveStarts, isEmpty);

    store.dispose();
  });

  test('设置页切换开关后立刻生效，不用等下一条命令', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: <CommandItem>[command('cmd_1', 'running')],
    );
    final notifier = RecordingNotifier();
    final store = HubStore(
      settings: settings,
      apiFactory: (_) => fake,
      notifier: notifier,
    );
    await store.start();
    await Future<void>.delayed(Duration.zero);
    expect(notifier.keepAliveStarts, hasLength(1));

    await settings.setKeepAlive(false);
    store.syncKeepAliveNow();
    await Future<void>.delayed(Duration.zero);
    expect(notifier.keepAliveStops, 1);

    await settings.setKeepAlive(true);
    store.syncKeepAliveNow();
    await Future<void>.delayed(Duration.zero);
    expect(notifier.keepAliveStarts, hasLength(2));

    store.dispose();
  });
}
