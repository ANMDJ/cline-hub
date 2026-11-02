import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_version.dart';

/// 服务器上的发布清单（`server/releases/latest.json`，由 `scripts/release-apk.mjs` 生成）。
class AppRelease {
  const AppRelease({
    required this.version,
    required this.build,
    this.notes = const <String>[],
    this.apkUrl,
    this.sha256,
    this.publishedAt,
  });

  factory AppRelease.fromJson(Map<String, dynamic> json) => AppRelease(
    version: (json['version'] as String?)?.trim() ?? '0.0.0',
    build: (json['build'] as num?)?.toInt() ?? 0,
    notes: (json['notes'] as List?)
            ?.whereType<String>()
            .map((item) => item.trim())
            .where((item) => item.isNotEmpty)
            .toList(growable: false) ??
        const <String>[],
    apkUrl: (json['apkUrl'] as String?)?.trim(),
    sha256: (json['sha256'] as String?)?.trim(),
    publishedAt: (json['publishedAt'] as String?)?.trim(),
  );

  final String version;
  final int build;
  final List<String> notes;
  final String? apkUrl;
  final String? sha256;
  final String? publishedAt;

  /// 服务器上的版本是否比当前安装的更新：先比版本号，再比 build 号。
  bool get isNewer {
    final byVersion = compareVersions(version, kAppVersion);
    if (byVersion != 0) return byVersion > 0;
    return build > kAppBuild;
  }
}

/// 拉取最新发布信息。没发布过（404）返回 null，其他错误抛异常由 UI 显示。
Future<AppRelease?> fetchLatestRelease({
  required String baseUrl,
  required String token,
}) async {
  final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/v1/app/latest');
  final response = await http
      .get(uri, headers: {'authorization': 'Bearer $token'})
      .timeout(const Duration(seconds: 12));
  if (response.statusCode == 404) return null;
  if (response.statusCode != 200) {
    throw Exception('HTTP ${response.statusCode}');
  }
  final decoded = jsonDecode(utf8.decode(response.bodyBytes));
  if (decoded is! Map) throw Exception('发布清单格式不对');
  return AppRelease.fromJson(decoded.cast<String, dynamic>());
}
