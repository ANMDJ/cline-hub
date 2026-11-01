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

  testWidgets('底部输入框默认按 plan 发送，切到 ACT 后按 act 发送', (tester) async {
    final settings = await _settings();
    final fake = _fake();
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();

    // 默认 plan：只读，不会悄悄改文件
    await tester.enterText(find.byType(TextField), '继续把测试补全');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(fake.sentCommands, hasLength(1));
    expect(fake.sentCommands.single['mode'], 'plan');
    expect(fake.sentCommands.single['sessionId'], 's1');

    // 等「已发送」的 SnackBar 淡出，否则它会盖住发送按钮
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    // 手动切到 ACT：这次才允许改文件
    await tester.tap(find.text('ACT'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '把测试补全并跑一遍');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pumpAndSettle();

    expect(fake.sentCommands, hasLength(2));
    final sent = fake.sentCommands.last;
    expect(sent['prompt'], '把测试补全并跑一遍');
    expect(sent['mode'], 'act');
    // 关键：带上 sessionId，bridge 才会在原会话里续聊
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

  testWidgets('概览收到右上角按钮里，点开才显示', (tester) async {
    final settings = await _settings();
    final fake = FakeHubApi(
      messageItems: const <SessionMessage>[
        SessionMessage(
          messageId: 'u1:0',
          role: 'user',
          kind: 'text',
          text: '要不要上 Docker',
          seq: 0,
        ),
      ],
      detail: const SessionDetail(
        deviceId: 'localone',
        sessionId: 's1',
        workspace: 'kids_points_app',
        workspaceRoot: r'C:\work\kids_points_app',
        project: 'kids_points_app',
        projectRoot: r'C:\work\kids_points_app',
        projectKind: 'project',
        status: 'completed',
        provider: 'deepseek',
        model: 'deepseek-flash',
        prompt: '要不要上 Docker',
      ),
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();

    // 首屏不再有概览卡，正文直接开始
    expect(find.text('概览'), findsNothing);
    expect(find.text('项目'), findsNothing);

    await tester.tap(find.byIcon(Icons.info_outline_rounded));
    await tester.pumpAndSettle();

    expect(find.text('概览'), findsOneWidget);
    expect(find.text('运行'), findsOneWidget);
    expect(find.text('项目'), findsOneWidget);
    expect(find.text('开头提问'), findsOneWidget);
    expect(find.textContaining('deepseek'), findsWidgets);
    expect(find.text('kids_points_app'), findsWidgets);

    // 点遮罩关闭
    await tester.tapAt(const Offset(200, 40));
    await tester.pumpAndSettle();
    expect(find.text('概览'), findsNothing);

    store.dispose();
  });

  testWidgets('会话很长时，顶部补出「会话开头」并标注省略条数', (tester) async {
    final settings = await _settings();
    final messages = <SessionMessage>[
      for (var i = 0; i < 100; i++)
        SessionMessage(
          messageId: 'm$i:0',
          role: i.isEven ? 'user' : 'assistant',
          kind: 'text',
          text: i == 0 ? '第一句话：帮我搭好后端' : '第 $i 条消息',
          seq: i,
        ),
    ];
    final fake = FakeHubApi(
      messageItems: messages,
      detail: const SessionDetail(
        deviceId: 'localone',
        sessionId: 's1',
        status: 'completed',
      ),
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    // 历史已经翻到头：上滑只触发一次空请求，不会把开头并入正文
    fake.ignoreBefore = true;

    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();

    // 首屏贴着底部（尾部 60 条），先滚到顶部才能看到「会话开头」
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 4000));
    await tester.pumpAndSettle();

    expect(find.text('会话开头'), findsOneWidget);
    expect(find.text('第一句话：帮我搭好后端'), findsOneWidget);

    // 标题在顶部，缺口提示在开头卡片下方，往下滚一点才会构建出来
    await tester.scrollUntilVisible(
      find.textContaining('中间省略'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    // 缺口 = 40 - 11 - 1 = 28
    expect(find.textContaining('中间省略 28 条'), findsOneWidget);

    store.dispose();
  });
}
