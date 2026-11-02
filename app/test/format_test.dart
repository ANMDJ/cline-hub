import 'package:cline_console/src/util/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('stripAnsi', () {
    test('去掉 SGR 颜色与光标控制', () {
      expect(
        stripAnsi('\u001b[2mThe\u001b[0m \u001b[32muser\u001b[0m\u001b[?25l'),
        'The user',
      );
    });

    test('去掉被截断的半个序列', () {
      expect(stripAnsi('\u001b['), '');
      expect(stripAnsi('[2m 残留'), '[2m 残留');
    });

    test('普通文本原样保留', () {
      expect(stripAnsi('npm test 通过'), 'npm test 通过');
    });
  });

  group('inlinePreview', () {
    test('折叠换行与多余空白', () {
      expect(inlinePreview('  a\n\n b\tc  '), 'a b c');
    });

    test('把带颜色码的命令输出洗成一行', () {
      expect(
        inlinePreview(
          '\u001b[2m[thinking] \u001b[0m\u001b[2mThe\u001b[0m\u001b[2m user\u001b[0m',
        ),
        '[thinking] The user',
      );
    });
  });

  group('workspaceLabel', () {
    test('正斜杠 / 反斜杠 / 尾斜杠都取到同一段', () {
      expect(
        workspaceLabel(r'C:\Users\alice\projects\kids_points_app'),
        'kids_points_app',
      );
      expect(
        workspaceLabel('C:/Users/alice/projects/kids_points_app/'),
        'kids_points_app',
      );
      expect(workspaceLabel('  D:\\work\\cline-hub//  '), 'cline-hub');
    });

    test('空值与空串给占位符', () {
      expect(workspaceLabel(null), '未指定目录');
      expect(workspaceLabel('   '), '未指定目录');
      expect(workspaceLabel('', fallback: '-'), '-');
    });
  });
}
