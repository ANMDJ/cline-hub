import 'package:flutter/material.dart';

import '../data/hub_api.dart';
import '../data/settings_store.dart';
import 'home_shell.dart';
import 'setup_page.dart';

/// 没配置连接就进向导，配置好了进主界面。
///
/// key 带上 baseUrl + token：换了服务器 / 换了 token 时整个 HomeShell 重建，
/// 保证 SSE、缓存列表、分页游标全部从头来，不留旧连接的残渣。
class Gate extends StatelessWidget {
  const Gate({super.key, required this.settings, this.apiFactory});

  final SettingsStore settings;
  final HubApi Function(SettingsStore settings)? apiFactory;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        if (!settings.isConfigured) {
          return SetupPage(settings: settings);
        }
        return KeyedSubtree(
          key: ValueKey<String>('${settings.baseUrl}|${settings.token}'),
          child: HomeShell(settings: settings, apiFactory: apiFactory),
        );
      },
    );
  }
}
