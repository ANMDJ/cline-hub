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
}) => CommandItem(
  id: id,
  deviceId: 'localone',
  prompt: prompt,
  mode: mode,
  status: status,
  resultText: resultText,
  errorText: errorText,
);

Map<String, dynamic> event(CommandItem item) => <String, dynamic>{
  'id': item.id,
  'deviceId': item.deviceId,
  'prompt': item.prompt,
  'mode': item.mode,
  'status': item.status,
  'resultText': item.resultText,
  'errorText': item.errorText,
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
}
