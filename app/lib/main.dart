import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/data/settings_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final settings = await SettingsStore.load();
  runApp(ClineConsoleApp(settings: settings));
}
