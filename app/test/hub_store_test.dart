import 'package:cline_console/src/data/hub_api.dart';
import 'package:cline_console/src/data/settings_store.dart';
import 'package:cline_console/src/models/models.dart';
import 'package:cline_console/src/state/hub_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

Future<SettingsStore> makeSettings({String deviceId = 'localone'}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  await settings.saveConnection(
    baseUrl: 'http://127.0.0.1:3100',
    token: 'clh_test_token_value',
    deviceId: deviceId,
  );
  return settings;
}

SessionItem sampleSession(String id, {String prompt = '要不要上 Docker'}) =>
    SessionItem(
      deviceId: 'localone',
      sessionId: id,
      workspace: 'kids_points_app',
      status: 'completed',
      userPrompt: prompt,
      resultOk: true,
      sortAt: DateTime(2026, 10, 31, 9),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('start() 拉三份列表并建立事件流', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      sessionItems: [sampleSession('s1')],
      commandItems: const [
        CommandItem(
          id: 'cmd_1',
          deviceId: 'localone',
          prompt: 'dir',
          mode: 'plan',
          status: 'done',
        ),
      ],
      hookItems: [HookItem(id: 1, event: 'agent_end', title: '任务结束')],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await store.start();

    expect(store.sessions, hasLength(1));
    expect(store.commands, hasLength(1));
    expect(store.hooks, hasLength(1));
    expect(store.link, LinkState.connecting);

    fake.emit('session', <String, dynamic>{'sessionId': 's1'});
    await Future<void>.delayed(Duration.zero);
    expect(store.link, LinkState.live);

    store.dispose();
    expect(fake.closed, isTrue);
  });

  test('session 事件会触发一次去抖后的刷新', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(sessionItems: [sampleSession('s1')]);
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    fake.sessionItems = [
      sampleSession('s2', prompt: '新会话'),
      sampleSession('s1'),
    ];
    fake.emit('session', <String, dynamic>{'sessionId': 's2'});
    await Future<void>.delayed(const Duration(milliseconds: 1100));

    expect(store.sessions.first.sessionId, 's2');
    store.dispose();
  });

  test('hook / command.update 事件直接落到内存列表', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: const [
        CommandItem(
          id: 'cmd_1',
          deviceId: 'localone',
          prompt: 'dir',
          mode: 'plan',
          status: 'pending',
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    fake.emit('hook', <String, dynamic>{
      'id': 9,
      'event': 'agent_end',
      'title': '结束',
    });
    fake.emit('hook', <String, dynamic>{
      'id': 9,
      'event': 'agent_end',
      'title': '结束',
    });
    fake.emit('command.update', <String, dynamic>{
      'id': 'cmd_1',
      'deviceId': 'localone',
      'prompt': 'dir',
      'mode': 'plan',
      'status': 'done',
      'resultText': 'ok',
    });
    await Future<void>.delayed(Duration.zero);

    expect(store.hooks, hasLength(1), reason: '同一 id 的 hook 不重复插入');
    expect(store.commands.single.status, 'done');
    expect(store.activeCommandCount, 0);
    store.dispose();
  });

  test('sendCommand 用默认设备并在本地列表里立即可见', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi();
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    final created = await store.sendCommand(prompt: '跑一遍测试', mode: 'act');

    expect(created.id, 'cmd_fake');
    expect(fake.sentCommands.single['deviceId'], 'localone');
    expect(fake.sentCommands.single['mode'], 'act');
    expect(store.commands.first.id, 'cmd_fake');
    store.dispose();
  });

  test('没有设备时可读的错误，而不是空指针', () async {
    final settings = await makeSettings(deviceId: '');
    final fake = FakeHubApi();
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    await expectLater(
      store.sendCommand(prompt: 'x', mode: 'plan'),
      throwsA(isA<ApiException>()),
    );
    store.dispose();
  });

  test('pause() 断流，resume() 重新拉数据', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(sessionItems: [sampleSession('s1')]);
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    store.pause();
    expect(store.link, LinkState.idle);

    fake.sessionItems = [
      sampleSession('s1'),
      sampleSession('s2', prompt: '离线期间的新会话'),
    ];
    store.resume();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(store.sessions, hasLength(2));
    store.dispose();
  });

  test('查询关键词会传给服务端并清空游标', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(sessionItems: [sampleSession('s1')]);
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    await store.setQuery('  Flutter  ');
    expect(store.query, 'Flutter');
    expect(fake.sessionQuery, 'Flutter');
    store.dispose();
  });

  test('knownWorkspaces 只收绝对路径，按出现次数降序去重', () async {
    final settings = await makeSettings();
    const chatRoot = r'C:\Users\alice\.cline\data\workspaces\chat\kids_points_app';
    final fake = FakeHubApi(
      sessionItems: [
        SessionItem(
          deviceId: 'localone',
          sessionId: 's1',
          workspace: 'kids_points_app', // 相对名，进不了候选
          workspaceRoot: chatRoot,
        ),
        SessionItem(
          deviceId: 'localone',
          sessionId: 's2',
          workspace: 'kids_points_app',
          workspaceRoot: chatRoot,
        ),
        SessionItem(
          deviceId: 'localone',
          sessionId: 's3',
          workspace: 'legacy', // 只有相对名 -> 丢掉
        ),
      ],
      commandItems: const [
        CommandItem(
          id: 'cmd_1',
          deviceId: 'localone',
          prompt: 'dir',
          mode: 'plan',
          status: 'done',
          workspace: r'C:\work\other',
        ),
        CommandItem(
          id: 'cmd_2',
          deviceId: 'localone',
          prompt: 'dir',
          mode: 'plan',
          status: 'done',
          workspace: 'other', // 相对名，丢掉
        ),
      ],
      hookItems: [
        HookItem(
          id: 1,
          event: 'agent_end',
          workspace: chatRoot,
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    expect(store.knownWorkspaces, [chatRoot, r'C:\work\other']);
    store.dispose();
  });

  test('knownWorkspaces 认 POSIX 绝对路径，最多给 6 条', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: [
        for (var i = 0; i < 8; i += 1)
          CommandItem(
            id: 'cmd_$i',
            deviceId: 'localone',
            prompt: 'ls',
            mode: 'plan',
            status: 'done',
            workspace: '/home/ubuntu/proj$i',
          ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    expect(store.knownWorkspaces, hasLength(6));
    expect(store.knownWorkspaces.first, '/home/ubuntu/proj0'); // 同票数按字典序
    expect(store.knownWorkspaces.every((path) => path.startsWith('/')), isTrue);
    store.dispose();
  });

  test('sessionGroups 按工作目录归并，组顺序跟时间走', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      sessionItems: [
        SessionItem(
          deviceId: 'localone',
          sessionId: 's1',
          workspace: 'b',
          workspaceRoot: r'C:\work\b',
          sortAt: DateTime(2026, 11, 1, 9),
        ),
        SessionItem(
          deviceId: 'localone',
          sessionId: 's2',
          workspace: 'a',
          workspaceRoot: r'C:\work\a',
          sortAt: DateTime(2026, 10, 31, 9),
        ),
        SessionItem(
          deviceId: 'localone',
          sessionId: 's3',
          workspace: 'b',
          workspaceRoot: r'C:\WORK\b', // 大小写不同，仍是同一个目录
          sortAt: DateTime(2026, 10, 30, 9),
        ),
        SessionItem(
          deviceId: 'localone',
          sessionId: 's4',
          sortAt: DateTime(2026, 10, 29, 9),
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    final groups = store.sessionGroups;
    expect(groups.map((group) => group.label), ['b', 'a', '未标注工作区']);
    expect(groups.first.items.map((item) => item.sessionId), ['s1', 's3']);
    expect(groups.first.path, r'C:\work\b');
    expect(groups.first.key, r'c:\work\b');
    expect(groups.first.items, hasLength(2));
    store.dispose();
  });
}
