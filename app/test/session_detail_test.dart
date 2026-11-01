import 'package:cline_console/src/data/settings_store.dart';
import 'package:cline_console/src/models/models.dart';
import 'package:cline_console/src/state/hub_store.dart';
import 'package:cline_console/src/ui/session_detail_page.dart';
import 'package:cline_console/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

Future<SettingsStore> _settings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  await settings.saveConnection(
    baseUrl: 'http://127.0.0.1:3100',
    token: 'clh_test_token_value',
    deviceId: 'localone',
  );
  return settings;
}

FakeHubApi _fake() => FakeHubApi(
  messageItems: const <SessionMessage>[
    SessionMessage(
      messageId: 'u1:0',
      role: 'user',
      kind: 'text',
      text: '要不要上 Docker',
      seq: 0,
    ),
    SessionMessage(
      messageId: 'a1:0',
      role: 'assistant',
      kind: 'text',
      text: '结论先说：现在不用。',
      seq: 1,
    ),
    SessionMessage(
      messageId: 'a1:1',
      role: 'assistant',
      kind: 'command',
      text: 'ls -la\ncat package.json | head -20\nnpm run build',
      tool: 'run_commands',
      seq: 2,
    ),
  ],
  detail: SessionDetail(
    deviceId: 'localone',
    sessionId: 's1',
    workspace: 'kids_points_app',
    workspaceRoot: 'C:\\work\\kids_points_app',
    status: 'completed',
    userPrompt: '要不要上 Docker',
  ),
);

Widget _wrap(HubStore store) => MaterialApp(
  theme: buildTheme(),
  home: SessionDetailPage(
    store: store,
    item: const SessionItem(deviceId: 'localone', sessionId: 's1'),
  ),
);

void main() {
  testWidgets('详情页逐条渲染对话，命令默认折叠成两行', (tester) async {
    final settings = await _settings();
    final fake = _fake();
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();

    // 用户消息和助手回复各一条，不再被压成"最后一条"
    expect(find.text('要不要上 Docker'), findsOneWidget);
    expect(find.text('结论先说：现在不用。'), findsOneWidget);
    expect(find.text('2 条'), findsOneWidget); // 只数正文，命令不算进对话流

    // 命令过程收在气泡下方的入口里，主对话流不再直接渲染
    expect(find.text('1 条命令'), findsOneWidget);
    expect(find.text('run_commands'), findsNothing);

    // 点开入口 → 二级页里能看到命令与「展开」
    await tester.tap(find.text('1 条命令'));
    await tester.pumpAndSettle();
    expect(find.text('命令过程 (1)'), findsOneWidget);
    expect(find.text('run_commands'), findsOneWidget);
    expect(find.text('展开'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(fake.messageCalls, greaterThan(0));
    store.dispose();
  });

  testWidgets('底部输入框把消息作为同一会话的 act 命令发出', (tester) async {
    final settings = await _settings();
    final fake = _fake();
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '继续把测试补全');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(fake.sentCommands, hasLength(1));
    final sent = fake.sentCommands.single;
    expect(sent['prompt'], '继续把测试补全');
    expect(sent['mode'], 'act');
    // 关键：带上 sessionId，bridge 才会用 cline --id 续在原会话里
    expect(sent['sessionId'], 's1');
    expect(sent['workspace'], 'C:\\work\\kids_points_app');

    store.dispose();
  });

  testWidgets('没有消息时给出回填提示而不是空白', (tester) async {
    final settings = await _settings();
    final fake = FakeHubApi(
      detail: const SessionDetail(
        deviceId: 'localone',
        sessionId: 's2',
        status: 'completed',
      ),
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SessionDetailPage(
          store: store,
          item: const SessionItem(deviceId: 'localone', sessionId: 's2'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('还没有可显示的消息'), findsOneWidget);
    store.dispose();
  });
}
