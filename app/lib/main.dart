import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/data/settings_store.dart';
import 'src/ui/theme.dart';

/// 冷启动不能先等 SettingsStore 读完再 runApp。
///
/// Android 上 SharedPreferences 首次访问要等一个 platform channel，
/// 慢的时候（冷启动 / 低端机）会先黑屏或白屏一闪。这里先立刻把一帧画出来，
/// 读完设置再换成真正的 App，观感上就是「一直停在同一块深色底上」。
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const _BootstrappingApp());
}

class _BootstrappingApp extends StatefulWidget {
  const _BootstrappingApp();

  @override
  State<_BootstrappingApp> createState() => _BootstrappingAppState();
}

class _BootstrappingAppState extends State<_BootstrappingApp> {
  SettingsStore? _settings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await SettingsStore.load();
    if (!mounted) return;
    setState(() => _settings = settings);
  }

  @override
  Widget build(BuildContext context) {
    final settings = _settings;
    if (settings == null) return const _LaunchScreen();
    return ClineConsoleApp(settings: settings);
  }
}

/// 占位启动屏：颜色跟 App 主题一致，读设置期间只有一个转圈，不会闪白。
class _LaunchScreen extends StatelessWidget {
  const _LaunchScreen();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: kBg,
        body: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: kAccent),
          ),
        ),
      ),
    );
  }
}

