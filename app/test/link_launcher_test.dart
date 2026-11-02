import 'package:cline_console/src/data/link_launcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // MethodChannel 需要 Binding 才能找 binaryMessenger（没注册原生实现时抛
  // MissingPluginException，被 LinkLauncher 吞掉并返回 false）。
  TestWidgetsFlutterBinding.ensureInitialized();

  test('isHttpUrl 只放行 http / https，且必须有 host', () {
    expect(LinkLauncher.isHttpUrl('https://hub.littlewish.top:8443/app/a.apk'), isTrue);
    expect(LinkLauncher.isHttpUrl('  http://127.0.0.1:8080/a.apk  '), isTrue);
    expect(LinkLauncher.isHttpUrl('http://'), isFalse);
    expect(LinkLauncher.isHttpUrl('intent://evil#Intent;end'), isFalse);
    expect(LinkLauncher.isHttpUrl('file:///C:/a.apk'), isFalse);
    expect(LinkLauncher.isHttpUrl('javascript:alert(1)'), isFalse);
    expect(LinkLauncher.isHttpUrl(''), isFalse);
    expect(LinkLauncher.isHttpUrl('not a url'), isFalse);
  });

  test('没有原生实现时 open 返回 false，调用方应回退到复制', () async {
    const launcher = LinkLauncher();
    // flutter test 里 defaultTargetPlatform 是 android，但没有注册原生通道：
    // MissingPluginException 会被吞掉并返回 false，UI 于是去复制链接。
    expect(launcher.supported, isTrue);
    expect(
      await launcher.open('https://hub.littlewish.top:8443/app/a.apk'),
      isFalse,
    );
  });

  test('地址不合法时即使平台支持也直接拒绝，不碰平台通道', () async {
    const launcher = LinkLauncher();
    expect(await launcher.open('file:///C:/a.apk'), isFalse);
  });
}
