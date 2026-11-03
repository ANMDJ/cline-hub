import 'dart:typed_data';

import 'package:cline_console/src/data/file_picker.dart';
import 'package:cline_console/src/ui/chat_composer.dart';
import 'package:cline_console/src/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// P46：微信式输入条。
///
/// 这里只断言「交互契约」，排版好看与否不归测试管：
///   * 没内容时发送键是禁用的（避免空发一条命令）；
///   * 点「+」就地展开「图片 / 文件」，选完自动收起；
///   * 有附件时即使不写字也能发，并且能看到附件名与大小；
///   * 下发面板把 `showSendButton` 关掉后不出现第二个发送键。

Widget _wrap(Widget child) =>
    MaterialApp(theme: buildTheme(), home: Scaffold(body: child));

PickedAttachment _file({String name = 'report.txt', int size = 3}) =>
    PickedAttachment(
      name: name,
      mimeType: 'text/plain',
      bytes: Uint8List.fromList(List<int>.filled(size, 65)),
    );

void main() {
  testWidgets('空输入时发送键禁用，输入文字后才可点', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var sent = 0;

    await tester.pumpWidget(
      _wrap(
        ChatComposer(
          controller: controller,
          onSend: () => sent++,
          onPickFile: () {},
          onPickImage: () {},
          onClearAttachment: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    IconButton sendButton() => tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send_rounded),
    );

    expect(sendButton().onPressed, isNull);

    await tester.enterText(find.byType(TextField), '跑一遍测试');
    await tester.pump();
    expect(sendButton().onPressed, isNotNull);
    await tester.tap(find.byIcon(Icons.send_rounded));
    expect(sent, 1);

    // 只有空白不算内容：别让人误发一条空命令。
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(sendButton().onPressed, isNull);
  });

  testWidgets('点「+」展开图片 / 文件，选完自动收起', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var files = 0;
    var images = 0;

    await tester.pumpWidget(
      _wrap(
        ChatComposer(
          controller: controller,
          onSend: () {},
          onPickFile: () => files++,
          onPickImage: () => images++,
          onClearAttachment: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 收起状态：面板里的两个入口都不在
    expect(find.text('图片'), findsNothing);
    expect(find.text('文件'), findsNothing);

    await tester.tap(find.byTooltip('发送文件 / 图片'));
    await tester.pumpAndSettle();
    expect(find.text('图片'), findsOneWidget);
    expect(find.text('文件'), findsOneWidget);

    await tester.tap(find.text('图片'));
    await tester.pumpAndSettle();
    expect(images, 1);
    expect(files, 0);
    expect(find.text('图片'), findsNothing, reason: '选完要收起来，别挡着输入框');

    // 再展开点「文件」走另一条路
    await tester.tap(find.byTooltip('发送文件 / 图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('文件'));
    await tester.pumpAndSettle();
    expect(files, 1);

    // 面板展开时再点「+」应该收起（措辞变成「收起附件」）
    await tester.tap(find.byTooltip('发送文件 / 图片'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('收起附件'));
    await tester.pumpAndSettle();
    expect(find.text('文件'), findsNothing);
  });

  testWidgets('带附件时显示名字 / 大小，不写字也能发，能移除', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var cleared = 0;
    var sent = 0;

    await tester.pumpWidget(
      _wrap(
        ChatComposer(
          controller: controller,
          attachment: _file(name: '报告.docx', size: 2048),
          onSend: () => sent++,
          onPickFile: () {},
          onPickImage: () {},
          onClearAttachment: () => cleared++,
          helper: '写一句要对这个文件做什么',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('报告.docx · 2.0 KB'), findsOneWidget);
    expect(find.text('写一句要对这个文件做什么'), findsOneWidget);

    final sendButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.send_rounded),
    );
    expect(sendButton.onPressed, isNotNull, reason: '只发文件也是合法指令');

    await tester.tap(find.byIcon(Icons.send_rounded));
    expect(sent, 1);

    await tester.tap(find.byTooltip('移除附件'));
    expect(cleared, 1);
  });

  testWidgets('下发面板：showSendButton=false 不渲染第二个发送键', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      _wrap(
        ChatComposer(
          controller: controller,
          showSendButton: false,
          onSend: () {},
          onPickFile: () {},
          onPickImage: () {},
          onClearAttachment: () {},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.send_rounded), findsNothing);
    expect(find.byTooltip('发送文件 / 图片'), findsOneWidget);
  });
}
