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
import 'package:cline_console/src/ui/sessions_page.dart';
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

  testWidgets('命令页空状态给出发命令的入口', (tester) async {
    final settings = await configuredSettings();
    final store = HubStore(settings: settings, apiFactory: (_) => FakeHubApi());

    await tester.pumpWidget(wrap(CommandsPage(store: store)));
    await tester.pump();

    expect(find.text('还没有下发过命令'), findsOneWidget);
    expect(find.text('下发第一条'), findsOneWidget);

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
}
