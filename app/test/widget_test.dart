// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:cline_console/src/data/settings_store.dart';
import 'package:cline_console/src/models/models.dart';
import 'package:cline_console/src/state/hub_store.dart';
import 'package:cline_console/src/ui/commands_page.dart';
import 'package:cline_console/src/ui/session_detail_page.dart';
import 'package:cline_console/src/ui/session_tile.dart';
import 'package:cline_console/src/ui/sessions_page.dart';
import 'package:cline_console/src/ui/settings_page.dart';
import 'package:cline_console/src/ui/workspaces_page.dart';
import 'package:cline_console/src/ui/setup_page.dart';
import 'package:cline_console/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

Future<SettingsStore> configuredSettings() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  await settings.saveConnection(
    baseUrl: 'http://127.0.0.1:3100',
    token: 'clh_test_token_value',
    deviceId: 'localone',
  );
  return settings;
}

Widget wrap(Widget child) => MaterialApp(
  theme: buildTheme(),
  home: Scaffold(body: child),
);

void main() {
  testWidgets('会话列表显示标题、工作区与命令数', (tester) async {
    final settings = await configuredSettings();
    final fake = FakeHubApi(
      sessionItems: [
        SessionItem(
          deviceId: 'localone',
          sessionId: 's1',
          workspace: 'kids_points_app',
          status: 'completed',
          userPrompt: '要不要上 Docker',
          resultPreview: '结论先说：现在不用。',
          resultOk: true,
          commandCount: 3,
          sortAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshSessions();

    await tester.pumpWidget(wrap(SessionsPage(store: store)));
    await tester.pump();

    expect(find.text('要不要上 Docker'), findsOneWidget);
    expect(find.textContaining('kids_points_app'), findsOneWidget);
    expect(find.text('3 命令'), findsOneWidget);

    store.dispose();
  });

  testWidgets('设备筛选提示条只在筛选生效时出现，可一键看全部', (tester) async {
    final settings = await configuredSettings();
    final fake = FakeHubApi(
      deviceItems: [
        DeviceItem(
          id: 'localone',
          name: 'LocalOne-Windows',
          lastSeenAt: DateTime.now(),
        ),
        DeviceItem(
          id: 'localtwo',
          name: 'LocalTwo-Mac',
          lastSeenAt: DateTime.now(),
        ),
      ],
      sessionItems: [
        SessionItem(
          deviceId: 'localtwo',
          sessionId: 's2',
          workspace: 'kids_points_app',
          userPrompt: '改登录页',
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshDevices();
    await store.refreshSessions();

    await tester.pumpWidget(wrap(ListenableBuilder(
      listenable: store,
      builder: (context, _) => SessionsPage(store: store),
    )));
    await tester.pump();
    // 没筛设备时完全不占空间（筛选入口已经挪进右侧抽屉）。
    expect(find.text('看全部设备'), findsNothing);

    store.setDeviceFilter('localtwo');
    await tester.pump();
    expect(find.text('只看 LocalTwo-Mac'), findsOneWidget);

    await tester.tap(find.text('看全部设备'));
    await tester.pump();
    expect(store.deviceFilter, isNull);
    expect(find.text('看全部设备'), findsNothing);

    store.dispose();
  });

  testWidgets('命令页空状态给出发命令的入口', (tester) async {
    final settings = await configuredSettings();
    final store = HubStore(settings: settings, apiFactory: (_) => FakeHubApi());

    await tester.pumpWidget(wrap(CommandsPage(store: store)));
    await tester.pump();

    expect(find.text('还没有下发过命令'), findsOneWidget);
    expect(find.text('下发第一条'), findsOneWidget);

    store.dispose();
  });

  testWidgets('设置页不再重复放设备列表，只留默认设备手填兜底', (tester) async {
    // 设置页比一屏长：给足高度，让「默认执行设备」那张卡也建出来。
    tester.view.physicalSize = const Size(411, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = await configuredSettings();
    final fake = FakeHubApi(
      deviceItems: [
        DeviceItem(
          id: 'localone',
          name: 'LocalOne-Windows',
          lastSeenAt: DateTime.now(),
          sessionCount: 12,
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshDevices();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SettingsPage(settings: settings, store: store),
      ),
    );
    await tester.pump();

    // 设备列表只在右侧抽屉里（P39）：设置页再放一份会各刷各的在线状态。
    expect(find.text('已接入设备'), findsNothing);
    expect(find.text('默认执行设备（手填兜底）'), findsOneWidget);
    expect(find.textContaining('右侧菜单里点一台电脑就能切默认'), findsOneWidget);

    store.dispose();
  });

  testWidgets('向导：空表单点保存提示先填地址', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await SettingsStore.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SetupPage(settings: settings),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('保存并进入'));
    await tester.pumpAndSettle();

    expect(find.text('先填 Hub 地址'), findsOneWidget);
    expect(settings.isConfigured, isFalse);
  });

  testWidgets('向导：填好后保存，配置写入 store', (tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final settings = await SettingsStore.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: SetupPage(settings: settings),
      ),
    );
    await tester.pump();

    await tester.enterText(
      find.byType(TextField).first,
      'http://82.157.153.22/_h/deadbeef',
    );
    await tester.enterText(
      find.byType(TextField).last,
      'clh_0123456789abcdef0123456789abcdef',
    );
    await tester.tap(find.text('保存并进入'));
    await tester.pumpAndSettle();

    expect(settings.isConfigured, isTrue);
    expect(settings.baseUrl, 'http://82.157.153.22/_h/deadbeef');
    expect(settings.maskedToken.contains('…'), isTrue);
  });

  testWidgets('下发面板：工作目录可点选可手输', (tester) async {
    // 面板内容比默认 800x600 高，用手机尺寸视口，避免 chip 落在视口外。
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = await configuredSettings();
    const projectPath = r'C:\Users\alice\projects\kids_points_app';
    final fake = FakeHubApi(
      sessionItems: [
        SessionItem(
          deviceId: 'localone',
          sessionId: 's1',
          workspace: 'kids_points_app',
          workspaceRoot: projectPath,
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    await tester.pumpWidget(wrap(CommandsPage(store: store)));
    await tester.pump();
    await tester.tap(find.text('下发第一条'));
    await tester.pumpAndSettle();

    // 输入框还在（可手输），旁边多了 chip（可点选）
    final workspaceField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText ==
              r'C:\Users\alice\projects\kids_points_app',
    );
    expect(workspaceField, findsOneWidget);
    expect(find.text('工作目录（bridge 没配默认目录时必填）'), findsOneWidget);
    expect(find.text('留空'), findsOneWidget);
    expect(find.text(r'…\projects\kids_points_app'), findsOneWidget);
    // 没配默认目录时留空会被 bridge 直接拒绝：文案要先说清楚（P49）。
    expect(find.textContaining('会被直接拒绝'), findsOneWidget);

    await tester.tap(find.text(r'…\projects\kids_points_app'));
    await tester.pump();
    expect(
      tester.widget<TextField>(workspaceField).controller?.text,
      projectPath,
    );

    await tester.tap(find.widgetWithText(ChoiceChip, '留空'));
    await tester.pump();
    expect(tester.widget<TextField>(workspaceField).controller?.text, '');

    store.dispose();
  });

  testWidgets('会话列表按最近对话时间扁平排序，不再分组', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = await configuredSettings();
    final fake = FakeHubApi(sessionItems: _projectSessions());
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    await tester.pumpWidget(wrap(SessionsPage(store: store)));
    await tester.pump();

    // 扁平列表：没有组头
    expect(find.text('2 条'), findsNothing);
    expect(find.text('1 条'), findsNothing);

    // 顺序 = 最近对话时间倒序（服务端 sortAt 已排好，客户端不再重排）
    final tiles =
        tester.widgetList<SessionTile>(find.byType(SessionTile)).toList();
    expect(
      tiles.map((tile) => tile.item.sessionId).toList(),
      ['s1', 's2', 's3'],
    );

    store.dispose();
  });

  testWidgets('工作区页按项目分组，可收起单组', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = await configuredSettings();
    final fake = FakeHubApi(sessionItems: _projectSessions());
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.start();

    await tester.pumpWidget(wrap(WorkspacesPage(store: store)));
    await tester.pump();
    await tester.pump();

    // 进页会整批拉一次（服务端上限 200），分组条数不受主列表分页影响
    expect(fake.lastSessionsLimit, HubStore.workspaceOverviewLimit);
    expect(store.workspaceSessions.length, 3);

    // 两个组头：2 条的 kids_points_app、1 条的 hub
    expect(find.text('2 条'), findsOneWidget);
    expect(find.text('1 条'), findsOneWidget);
    expect(find.text('改登录页'), findsOneWidget);
    // 组头必须写清来自哪台电脑（没起名字时退回 device id），
    // 否则两台机器上同名项目分成两组时看不出差别。
    expect(find.text('localone'), findsNWidgets(2));

    // 收起 2 条的那组，另一组不受影响
    await tester.tap(find.text('2 条'));
    await tester.pump();

    expect(find.text('改登录页'), findsNothing);
    expect(find.text('补测试'), findsNothing);
    expect(find.text('修 SSE'), findsOneWidget);
    expect(find.text('2 条'), findsOneWidget); // 组头还在

    // 再点一次展开回来
    await tester.tap(find.text('2 条'));
    await tester.pump();
    expect(find.text('改登录页'), findsOneWidget);

    store.dispose();
  });

  testWidgets('命令详情能跳到它创建出来的会话', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = await configuredSettings();
    final fake = FakeHubApi(
      commandItems: [
        CommandItem(
          id: 'cmd_link',
          deviceId: 'localone',
          prompt: '跑一下测试',
          mode: 'act',
          status: 'done',
          workspace: r'C:\work\hub',
          sessionId: '1793548380890_qij68',
          createdAt: DateTime.now(),
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshCommands();

    await tester.pumpWidget(wrap(CommandsPage(store: store)));
    await tester.pump();

    await tester.tap(find.text('跑一下测试'));
    await tester.pumpAndSettle();

    expect(find.text('打开会话'), findsOneWidget);
    expect(find.text('1793548380890_qij68'), findsOneWidget);

    await tester.tap(find.text('打开会话'));
    await tester.pumpAndSettle();

    expect(find.byType(SessionDetailPage), findsOneWidget);

    store.dispose();
  });

  testWidgets('命令详情可以取消运行中的命令（二次确认）', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = await configuredSettings();
    final fake = FakeHubApi(
      commandItems: [
        CommandItem(
          id: 'cmd_cancel',
          deviceId: 'localone',
          prompt: '跑很久的任务',
          mode: 'act',
          status: 'running',
          workspace: r'C:\work\hub',
          createdAt: DateTime.now(),
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshCommands();

    await tester.pumpWidget(wrap(CommandsPage(store: store)));
    await tester.pump();

    await tester.tap(find.text('跑很久的任务'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('取消这条命令'));
    await tester.tap(find.text('取消这条命令'));
    await tester.pumpAndSettle();

    // 二次确认：还没点「取消命令」时不能发请求。
    expect(fake.cancelledCommands, isEmpty);

    await tester.tap(find.text('取消命令'));
    await tester.pumpAndSettle();

    expect(fake.cancelledCommands, <String>['cmd_cancel']);
    expect(find.textContaining('已请求取消'), findsWidgets);

    store.dispose();
  });
}

/// 三条会话：两条在 kids_points_app、一条在 hub，按最近对话时间倒序。
List<SessionItem> _projectSessions() => [
      SessionItem(
        deviceId: 'localone',
        sessionId: 's1',
        workspace: 'kids_points_app',
        workspaceRoot: r'C:\work\kids_points_app',
        project: 'kids_points_app',
        projectRoot: r'C:\work\kids_points_app',
        projectKind: 'project',
        userPrompt: '改登录页',
        status: 'completed',
        resultOk: true,
        sortAt: DateTime(2026, 10, 31, 10),
      ),
      SessionItem(
        deviceId: 'localone',
        sessionId: 's2',
        workspace: 'kids_points_app',
        workspaceRoot: r'C:\work\kids_points_app',
        project: 'kids_points_app',
        projectRoot: r'C:\work\kids_points_app',
        projectKind: 'project',
        userPrompt: '补测试',
        status: 'completed',
        resultOk: true,
        sortAt: DateTime(2026, 10, 30, 10),
      ),
      SessionItem(
        deviceId: 'localone',
        sessionId: 's3',
        workspace: 'hub',
        workspaceRoot: r'C:\work\hub',
        project: 'hub',
        projectRoot: r'C:\work\hub',
        projectKind: 'project',
        userPrompt: '修 SSE',
        status: 'completed',
        resultOk: true,
        sortAt: DateTime(2026, 10, 29, 10),
      ),
    ];

