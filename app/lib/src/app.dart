import 'package:flutter/material.dart';

import 'data/hub_api.dart';
import 'data/settings_store.dart';
import 'ui/gate.dart';
import 'ui/theme.dart';

class ClineConsoleApp extends StatelessWidget {
  const ClineConsoleApp({super.key, required this.settings, this.apiFactory});

  final SettingsStore settings;

  /// 测试时注入假实现；线上为 null，由 HubStore 自己 new HttpHubApi。
  final HubApi Function(SettingsStore settings)? apiFactory;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ClineHub',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: Gate(settings: settings, apiFactory: apiFactory),
    );
  }
}
