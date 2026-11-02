import 'package:flutter_test/flutter_test.dart';

import 'package:cline_console/src/data/app_update.dart';
import 'package:cline_console/src/data/app_version.dart';

void main() {
  test('compareVersions 按段比较，不按字符串', () {
    expect(compareVersions('1.2.0', '1.1.9'), greaterThan(0));
    expect(compareVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(compareVersions('1.1.0', '1.1.0'), 0);
    expect(compareVersions('1.1', '1.1.0'), 0);
    expect(compareVersions('bad', '0.0.1'), lessThan(0));
  });

  test('AppRelease.isNewer 先比版本号再比 build', () {
    expect(
      const AppRelease(version: '1.2.0', build: 0).isNewer,
      isTrue,
    );
    expect(
      const AppRelease(version: kAppVersion, build: kAppBuild + 1).isNewer,
      isTrue,
    );
    expect(
      const AppRelease(version: kAppVersion, build: kAppBuild).isNewer,
      isFalse,
    );
    expect(
      const AppRelease(version: '0.9.0', build: 99).isNewer,
      isFalse,
    );
  });

  test('AppRelease.fromJson 容错：缺字段 / 类型不对都不炸', () {
    final release = AppRelease.fromJson(const <String, dynamic>{
      'version': '1.1.0',
      'build': 2,
      'notes': <Object>['a', 1, ' b '],
    });
    expect(release.version, '1.1.0');
    expect(release.build, 2);
    expect(release.notes, <String>['a', 'b']);
    expect(release.apkUrl, isNull);
  });
}
