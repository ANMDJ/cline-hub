import 'dart:typed_data';

import 'package:cline_console/src/data/file_picker.dart';
import 'package:cline_console/src/data/settings_store.dart';
import 'package:cline_console/src/models/models.dart';
import 'package:cline_console/src/state/hub_store.dart';
import 'package:cline_console/src/ui/attachment_bar.dart';
import 'package:cline_console/src/ui/commands_page.dart';
import 'package:cline_console/src/ui/home_drawer.dart';
import 'package:cline_console/src/ui/theme.dart';
import 'package:cline_console/src/util/format.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_api.dart';

/// P38：发送文件 / 图片 + 右侧设备菜单。
///
/// 覆盖三件容易悄悄坏掉的事：
///   * 附件元数据 / 大小文案的解析（服务端少字段时不能崩）；
///   * 「先上传再下发」的顺序与参数（attachmentId 必须真的到命令里）；
///   * 抽屉里能看到设备、点一下能切默认（设备列表从设置页挪出来后唯一的入口）。

Future<SettingsStore> configuredSettings({String deviceId = 'localone'}) async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final settings = await SettingsStore.load();
  await settings.saveConnection(
    baseUrl: 'http://127.0.0.1:3100',
    token: 'clh_test_token_value',
    deviceId: deviceId,
  );
  return settings;
}

Widget wrap(Widget child) => MaterialApp(theme: buildTheme(), home: child);

PickedAttachment sampleFile({int size = 5}) => PickedAttachment(
  name: 'report.txt',
  mimeType: 'text/plain',
  bytes: Uint8List.fromList(List<int>.filled(size, 65)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('formatBytes：附件大小显示成人话', () {
    expect(formatBytes(0), '0 B');
    expect(formatBytes(999), '999 B');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1024 * 1024 * 3), '3.0 MB');
    expect(formatBytes(null), '0 B');
  });

  test('AttachmentInfo：解析元数据（含入库时间），缺名字时退回 id', () {
    final info = AttachmentInfo.fromJson(const <String, dynamic>{
      'id': 'att_1',
      'name': '周报.docx',
      'mimeType': 'image/png',
      'byteSize': 2048,
      'createdAt': '2026-11-03T04:30:00.000Z',
    });
    expect(info.label, '周报.docx');
    expect(info.byteSize, 2048);
    expect(info.isImage, isTrue);
    expect(info.isEmpty, isFalse);
    // 入库时间会被转成本地时区：只断言「有值且是同一时刻」。
    expect(info.createdAt, isNotNull);
    expect(
      info.createdAt!.toUtc(),
      DateTime.utc(2026, 11, 3, 4, 30),
    );

    final bare = AttachmentInfo.fromJson(const <String, dynamic>{'id': 'att_2'});
    expect(bare.label, 'att_2');
    expect(bare.byteSize, 0);
    expect(bare.isImage, isFalse);
    expect(bare.createdAt, isNull);
  });

  test('CommandItem：带附件的命令能解析出 attachment', () {
    final item = CommandItem.fromJson(const <String, dynamic>{
      'id': 'cmd_1',
      'deviceId': 'localone',
      'prompt': '把错别字改掉',
      'mode': 'act',
      'status': 'pending',
      'attachment': <String, dynamic>{
        'id': 'att_1',
        'name': 'a.png',
        'mimeType': 'image/png',
        'byteSize': 12,
      },
    });
    expect(item.attachment?.id, 'att_1');
    expect(item.attachment?.label, 'a.png');

    final plain = CommandItem.fromJson(const <String, dynamic>{
      'id': 'cmd_2',
      'deviceId': 'localone',
      'prompt': 'dir',
      'mode': 'plan',
      'status': 'done',
    });
    expect(plain.attachment, isNull);
  });

  test('attachmentSummary：名字 + 大小', () {
    expect(attachmentSummary(sampleFile(size: 1024)), 'report.txt · 1.0 KB');
  });

  test('上传附件 → 下发命令：attachmentId 真的传下去了', () async {
    final settings = await configuredSettings();
    final fake = FakeHubApi();
    final store = HubStore(settings: settings, apiFactory: (_) => fake);

    final uploaded = await store.uploadAttachment(file: sampleFile(size: 5));
    expect(uploaded.id, 'att_fake_1');
    expect(fake.uploadedAttachments.single['deviceId'], 'localone');
    expect(fake.uploadedAttachments.single['byteSize'], 5);

    await store.sendCommand(
      prompt: '',
      mode: 'plan',
      attachmentId: uploaded.id,
    );
    expect(fake.sentCommands.single['attachmentId'], 'att_fake_1');
    expect(fake.sentCommands.single['prompt'], '');

    store.dispose();
  });

  test('AttachmentPicker：没有原生侧时安静地返回 null', () async {
    // 测试环境没有 MainActivity 的 files channel：不能抛异常，否则「发送文件」
    // 会把整个面板打崩。
    expect(await const AttachmentPicker().pick(), isNull);
  });

  testWidgets('下发面板：有「发送文件 / 发送图片」，空指令要点出提示', (tester) async {
    tester.view.physicalSize = const Size(411, 914);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final settings = await configuredSettings();
    final store = HubStore(settings: settings, apiFactory: (_) => FakeHubApi());
    await store.start();

    await tester.pumpWidget(wrap(Scaffold(body: CommandsPage(store: store))));
    await tester.pump();
    await tester.tap(find.text('下发第一条'));
    await tester.pumpAndSettle();

    expect(find.text('发送文件'), findsOneWidget);
    expect(find.text('发送图片'), findsOneWidget);

    // 指令和附件都空：不能静默失败，要明确告诉用户缺什么。
    await tester.tap(find.text('下发'));
    await tester.pump();
    expect(find.text('指令和附件至少填一个'), findsOneWidget);

    store.dispose();
  });

  testWidgets('右侧菜单：设备列表可切默认，浏览筛选与工作区入口都在这里', (tester) async {
    // 手机尺寸：抽屉内容变多了（浏览 + 电脑 + 操作），要确认整条都能点到。
    tester.view.physicalSize = const Size(411, 914);
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
          pendingCommands: 1,
        ),
        DeviceItem(
          id: 'localtwo',
          name: 'LocalTwo-Mac',
          lastSeenAt: DateTime.now().subtract(const Duration(hours: 3)),
        ),
      ],
    );
    final store = HubStore(settings: settings, apiFactory: (_) => fake);
    await store.refreshDevices();

    var openedSettings = false;
    var openedWorkspaces = false;
    await tester.pumpWidget(
      wrap(
        Scaffold(
          endDrawer: HomeDrawer(
            store: store,
            onOpenSettings: () => openedSettings = true,
            onOpenWorkspaces: () => openedWorkspaces = true,
          ),
          body: const SizedBox.shrink(),
        ),
      ),
    );

    tester.state<ScaffoldState>(find.byType(Scaffold)).openEndDrawer();
    await tester.pumpAndSettle();

    expect(find.text('电脑'), findsOneWidget);
    expect(find.text('LocalOne-Windows · localone'), findsOneWidget);
    expect(find.textContaining('在线 · 会话 12'), findsOneWidget);
    expect(find.textContaining('离线 · 会话 0'), findsOneWidget);
    expect(find.textContaining('上报'), findsOneWidget);
    expect(find.text('默认'), findsOneWidget);

    // P39：设备 chip 与「按工作区浏览」从页面顶栏挪进抽屉。
    expect(find.text('按工作区浏览'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '全部设备'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, 'LocalTwo-Mac'), findsOneWidget);

    // chip 只筛列表，不改下发目标。
    await tester.tap(find.widgetWithText(ChoiceChip, 'LocalTwo-Mac'));
    await tester.pumpAndSettle();
    expect(store.deviceFilter, 'localtwo');
    expect(settings.deviceId, 'localone');

    await tester.tap(find.widgetWithText(ChoiceChip, '全部设备'));
    await tester.pumpAndSettle();
    expect(store.deviceFilter, isNull);

    // 点第二台 → 默认设备切过去，标记也跟着走。
    await tester.tap(find.text('LocalTwo-Mac · localtwo'));
    await tester.pumpAndSettle();
    expect(settings.deviceId, 'localtwo');
    expect(store.devices, hasLength(2));

    await tester.tap(find.text('按工作区浏览'));
    await tester.pumpAndSettle();
    expect(openedWorkspaces, isTrue);

    // 点「按工作区浏览」会先关抽屉；要看设置就再打开一次。
    tester.state<ScaffoldState>(find.byType(Scaffold)).openEndDrawer();
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(openedSettings, isTrue);

    store.dispose();
  });
}
