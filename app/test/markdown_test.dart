import 'package:cline_console/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

/// P8：正文按 Markdown 渲染，命令输出保持原文。
void main() {
  const style = TextStyle(fontSize: 13.5, height: 1.6);

  testWidgets('markdown: true 用 MarkdownBody 渲染，标题不再显示 ##', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageText(text: '## 小标题', style: style, markdown: true),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(find.textContaining('##'), findsNothing);
    expect(find.textContaining('小标题'), findsWidgets);
  });

  testWidgets('默认不解析 Markdown（命令输出必须保持原样）', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MessageText(text: '## 不是标题', style: style),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsNothing);
    expect(find.text('## 不是标题'), findsOneWidget);
  });

  testWidgets('表格能渲染，窄屏不抛 overflow', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: MessageText(
              text: '| 项 | 值 |\n|---|---|\n| build | 6 |',
              style: style,
              markdown: true,
            ),
          ),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('长文本折叠后仍把 markdown 传给二级页', (tester) async {
    final long = '## 标题\n\n${'正文。' * 600}';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MessageText(text: long, style: style, markdown: true),
        ),
      ),
    );

    expect(find.byType(MarkdownBody), findsNothing, reason: '折叠态先用纯文本预览');
    await tester.tap(find.textContaining('展开全文'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownBody), findsOneWidget);
  });
}
