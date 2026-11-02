import 'package:cline_console/src/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('ElapsedText：有起止时间就显示时长', (tester) async {
    final start = DateTime(2026, 11, 2, 12, 0, 0);
    await tester.pumpWidget(
      host(
        ElapsedText(
          start: start,
          end: start.add(const Duration(minutes: 2, seconds: 5)),
          prefix: '耗时 ',
        ),
      ),
    );
    expect(find.text('耗时 2m05s'), findsOneWidget);
  });

  testWidgets('ElapsedText：没有开始时间给占位符', (tester) async {
    await tester.pumpWidget(host(const ElapsedText(start: null)));
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('ElapsedText：已结束但缺终态时间时不走表，显示占位符', (tester) async {
    await tester.pumpWidget(
      host(ElapsedText(start: DateTime(2026, 11, 2, 12), running: false)),
    );
    expect(find.text('—'), findsOneWidget);
  });
}
