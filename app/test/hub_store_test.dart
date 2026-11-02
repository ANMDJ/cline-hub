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

  test('cancelCommand 立刻把命令置成「取消中」并保留进程信息', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      commandItems: const <CommandItem>[
        CommandItem(
          id: 'cmd_run',
          deviceId: 'localone',
          prompt: '跑一遍测试',
          mode: 'act',
          status: 'running',
          pid: 4242,
          runner: 'cline',
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();
    expect(store.activeCommandCount, 1);

    final updated = await store.cancelCommand('cmd_run');

    expect(fake.cancelledCommands, <String>['cmd_run']);
    expect(updated.status, 'cancelling');
    expect(updated.isCancelling, isTrue);
    expect(updated.isActive, isTrue);
    expect(updated.pid, 4242);
    expect(store.commands.single.status, 'cancelling');
    store.dispose();
  });

  test('同一个目录的正/反斜杠写法在分组与候选里都只算一个', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      sessionItems: <SessionItem>[
        SessionItem(
          deviceId: 'localone',
          sessionId: 's1',
          workspace: 'cline-hub',
          workspaceRoot:
              r'C:\Users\alice\.cline\data\workspaces\chat\cline-hub',
          project: 'cline-hub',
          projectRoot: r'C:\Users\alice\.cline\data\workspaces\chat\cline-hub',
          projectKind: 'project',
          status: 'completed',
          sortAt: DateTime(2026, 11, 2, 9),
        ),
        // 旧数据：项目识别上线前采集，project 三列全空，路径是 cline CLI 写的正斜杠
        SessionItem(
          deviceId: 'localone',
          sessionId: 's2',
          workspace: 'cline-hub',
          workspaceRoot: 'C:/Users/alice/.cline/data/workspaces/chat/cline-hub',
          status: 'completed',
          sortAt: DateTime(2026, 11, 1, 9),
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();
    await store.refreshWorkspaceOverview(force: true);

    expect(store.sessionGroups, hasLength(1), reason: '同一个项目只应有一组');
    expect(store.sessionGroups.single.items, hasLength(2));
    expect(store.sessionGroups.single.label, 'cline-hub');
    expect(store.knownWorkspaces, hasLength(1), reason: '候选里不该出现两个写法');
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
    const chatRoot =
        r'C:\Users\alice\.cline\data\workspaces\chat\kids_points_app';
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
      hookItems: [HookItem(id: 1, event: 'agent_end', workspace: chatRoot)],
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
    expect(groups.first.key, 'c:/work/b');
    expect(groups.first.items, hasLength(2));
    store.dispose();
  });

  test('设备过滤只影响可见列表，原始全量不变', () async {
    final settings = await makeSettings(deviceId: 'localone');
    final fake = FakeHubApi(
      sessionItems: [
        SessionItem(
          deviceId: 'localone',
          sessionId: 's1',
          workspace: 'cline-hub',
          sortAt: DateTime(2026, 11, 2, 9),
        ),
        SessionItem(
          deviceId: 'laptop',
          sessionId: 's2',
          workspace: 'kids_points_app',
          sortAt: DateTime(2026, 11, 2, 8),
        ),
        SessionItem(
          deviceId: 'localone',
          sessionId: 's3',
          workspace: 'cline-hub',
          sortAt: DateTime(2026, 11, 2, 7),
        ),
      ],
      commandItems: const [
        CommandItem(
          id: 'cmd_1',
          deviceId: 'localone',
          prompt: 'dir',
          mode: 'plan',
          status: 'done',
        ),
        CommandItem(
          id: 'cmd_2',
          deviceId: 'laptop',
          prompt: 'npm test',
          mode: 'act',
          status: 'running',
        ),
      ],
      hookItems: const [
        HookItem(id: 1, deviceId: 'localone', event: 'session_done'),
        HookItem(id: 2, deviceId: 'laptop', event: 'session_done'),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    expect(store.knownDevices, ['laptop', 'localone']); // 设置里那台也一直在
    expect(store.visibleSessions, hasLength(3)); // 默认不过滤

    store.setDeviceFilter('laptop');
    expect(store.visibleSessions.map((item) => item.sessionId), ['s2']);
    expect(store.visibleCommands.map((item) => item.id), ['cmd_2']);
    expect(store.visibleHooks.map((item) => item.id), [2]);
    // 全量列表不受影响：上拉分页 / 通知还要用它
    expect(store.sessions, hasLength(3));
    expect(store.commands, hasLength(2));

    store.setDeviceFilter(null);
    expect(store.visibleSessions, hasLength(3));
    expect(store.deviceFilter, isNull);
    store.dispose();
  });

  test('设备列表：没有数据的新设备也会出现在 chip 里，显示名优先用 name', () async {
    final settings = await makeSettings();
    final fake = FakeHubApi(
      deviceItems: const [
        DeviceItem(id: 'localone', name: 'LocalOne-Windows'),
        DeviceItem(id: 'laptop', name: '办公本'),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await store.start();

    expect(store.devices, hasLength(2));
    expect(store.loadingDevices, isFalse);
    expect(store.knownDevices, ['laptop', 'localone']);
    expect(store.deviceLabel('laptop'), '办公本');
    expect(store.deviceLabel('localone'), 'LocalOne-Windows');
    // 老 Hub / 已删除设备：退回 id，不要让 chip 变成空白
    expect(store.deviceLabel('unknown'), 'unknown');
    store.dispose();
  });
}
