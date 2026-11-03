import 'package:cline_console/src/data/hub_api.dart';
import 'package:cline_console/src/data/settings_store.dart';
import 'package:cline_console/src/models/models.dart';
import 'package:cline_console/src/state/hub_store.dart';
import 'package:cline_console/src/ui/home_drawer.dart';
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

DeepSeekBalance sampleBalance({
  String total = '86.42',
  bool cached = false,
  bool stale = false,
}) => DeepSeekBalance(
  configured: true,
  isAvailable: true,
  balances: <DeepSeekBalanceInfo>[
    DeepSeekBalanceInfo(
      currency: 'CNY',
      totalBalance: total,
      grantedBalance: '10.00',
      toppedUpBalance: '76.42',
    ),
  ],
  fetchedAt: DateTime.now().subtract(const Duration(seconds: 20)),
  cached: cached,
  stale: stale,
);

void main() {
  test('余额模型：解析 Hub 返回的币种与金额，展示成 ¥x.xx', () {
    final balance = DeepSeekBalance.fromJson(<String, dynamic>{
      'ok': true,
      'configured': true,
      'isAvailable': true,
      'balances': <Map<String, dynamic>>[
        <String, dynamic>{
          'currency': 'CNY',
          'totalBalance': '110.00',
          'grantedBalance': '10.00',
          'toppedUpBalance': '100.00',
        },
      ],
      'fetchedAt': '2026-11-03T04:00:00.000Z',
      'cached': true,
    });

    expect(balance.configured, isTrue);
    expect(balance.isAvailable, isTrue);
    expect(balance.hasBalance, isTrue);
    expect(balance.totalText, '¥110.00');
    expect(balance.breakdownText, '充值 100.00 · 赠金 10.00');
    expect(balance.cached, isTrue);
    expect(balance.stale, isFalse);
    expect(balance.fetchedAt, isNotNull);
  });

  test('余额模型：USD 用 \$，只有总额时明细为空', () {
    final balance = DeepSeekBalance.fromJson(<String, dynamic>{
      'configured': true,
      'balances': <Map<String, dynamic>>[
        <String, dynamic>{'currency': 'usd', 'totalBalance': '12.34'},
      ],
    });

    expect(balance.totalText, r'$12.34');
    expect(balance.breakdownText, isNull);
    expect(balance.primary!.currency, 'USD');
  });

  test('余额模型：字段缺失 / 未配置时不崩', () {
    final empty = DeepSeekBalance.fromJson(<String, dynamic>{});
    expect(empty.configured, isFalse);
    expect(empty.hasBalance, isFalse);
    expect(empty.totalText, '—');

    // 老 Hub 只给 balances、不给 configured：按「已配置」处理。
    final legacy = DeepSeekBalance.fromJson(<String, dynamic>{
      'balances': <Map<String, dynamic>>[
        <String, dynamic>{'currency': 'CNY', 'totalBalance': '1.00'},
      ],
    });
    expect(legacy.configured, isTrue);
    expect(legacy.totalText, '¥1.00');

    final unconfigured = DeepSeekBalance.fromJson(<String, dynamic>{
      'configured': false,
      'hint': '去 server/.env 配 DEEPSEEK_API_KEY',
    });
    expect(unconfigured.configured, isFalse);
    expect(unconfigured.hint, contains('DEEPSEEK_API_KEY'));
  });

  test('store：refreshBalance 成功时写入余额并清掉错误', () async {
    final settings = await configuredSettings();
    final fake = FakeHubApi(deepseekBalanceItem: sampleBalance());
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await store.refreshBalance();

    expect(fake.deepseekBalanceCalls, 1);
    expect(fake.lastBalanceRefresh, isFalse);
    expect(store.balance?.totalText, '¥86.42');
    expect(store.balanceError, isNull);
    expect(store.loadingBalance, isFalse);
    store.dispose();
  });

  test('store：force 刷新会要求 Hub 跳过缓存', () async {
    final settings = await configuredSettings();
    final fake = FakeHubApi(deepseekBalanceItem: sampleBalance());
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await store.refreshBalance(force: true);

    expect(fake.lastBalanceRefresh, isTrue);
    store.dispose();
  });

  test('store：查询失败时保留上一份余额，错误翻成中文', () async {
    final settings = await configuredSettings();
    final fake = FakeHubApi(deepseekBalanceItem: sampleBalance());
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshBalance();

    fake.deepseekError = ApiException(
      502,
      'deepseek_auth_failed',
      'DeepSeek rejected the API key (401/403)',
    );
    await store.refreshBalance(force: true);

    expect(store.balance?.totalText, '¥86.42');
    expect(store.balanceError, contains('DEEPSEEK_API_KEY'));
    store.dispose();
  });

  test('store：旧 Hub 没有这条路由时按「未配置」显示，不报红', () async {
    final settings = await configuredSettings();
    final fake = FakeHubApi()
      ..deepseekError = ApiException(404, 'not_found', 'GET /x not found');
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    await store.refreshBalance();

    expect(store.balanceError, isNull);
    expect(store.balance?.configured, isFalse);
    expect(store.balance?.hint, contains('部署新版 Hub'));
    store.dispose();
  });

  testWidgets('抽屉：余额卡片显示总额、明细与「缓存」标记', (tester) async {
    final settings = await configuredSettings();
    final fake = FakeHubApi(deepseekBalanceItem: sampleBalance(cached: true));
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshBalance();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: HomeDrawer(
            store: store,
            onOpenSettings: () {},
            onOpenWorkspaces: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('DeepSeek 余额'), findsOneWidget);
    expect(find.text('¥86.42'), findsOneWidget);
    expect(find.text('充值 76.42 · 赠金 10.00'), findsOneWidget);
    expect(find.textContaining('缓存'), findsOneWidget);
    store.dispose();
  });

  testWidgets('抽屉：没配 Key 时提示去服务器配置，而不是报错', (tester) async {
    final settings = await configuredSettings();
    final fake = FakeHubApi();
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshBalance();

    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(),
        home: Scaffold(
          body: HomeDrawer(
            store: store,
            onOpenSettings: () {},
            onOpenWorkspaces: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Hub 未配置 DEEPSEEK_API_KEY'), findsOneWidget);
    expect(find.textContaining('server/.env'), findsOneWidget);
    store.dispose();
  });
}
