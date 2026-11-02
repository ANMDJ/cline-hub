// 构造函数用的是「公开命名参数 → 私有字段」的写法：Dart 不允许 `this._x`
// 作为命名参数，所以这里没法用 initializing formal。
// ignore_for_file: prefer_initializing_formals

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'hub_api.dart' show normalizeBaseUrl;

/// 连接配置（baseUrl / token / 上次用的设备）落盘到 SharedPreferences。
///
/// 只存明文 token 到应用私有目录：这是「自建单人使用」的取舍，
/// 换来的是换手机时不用重新扫码登录；真要多用户再说。
class SettingsStore extends ChangeNotifier {
  SettingsStore(
    this._prefs, {
    String baseUrl = '',
    String token = '',
    String deviceId = '',
    bool notifyCommands = true,
    bool notifySessions = true,
  }) : _baseUrl = baseUrl,
       _token = token,
       _deviceId = deviceId,
       _notifyCommands = notifyCommands,
       _notifySessions = notifySessions;

  static const _kBaseUrl = 'hub.baseUrl';
  static const _kToken = 'hub.token';
  static const _kDeviceId = 'hub.deviceId';
  static const _kNotifyCommands = 'notify.commands';
  static const _kNotifySessions = 'notify.sessions';

  static Future<SettingsStore> load({SharedPreferences? prefs}) async {
    final store = prefs ?? await SharedPreferences.getInstance();
    return SettingsStore(
      store,
      baseUrl: store.getString(_kBaseUrl) ?? '',
      token: store.getString(_kToken) ?? '',
      deviceId: store.getString(_kDeviceId) ?? '',
      // 没存过时默认开启：新装用户第一晚就能收到「命令跑完了」。
      notifyCommands: store.getBool(_kNotifyCommands) ?? true,
      notifySessions: store.getBool(_kNotifySessions) ?? true,
    );
  }

  final SharedPreferences _prefs;
  String _baseUrl;
  String _token;
  String _deviceId;
  bool _notifyCommands;
  bool _notifySessions;

  String get baseUrl => _baseUrl;
  String get token => _token;
  String get deviceId => _deviceId;

  /// 命令完成 / 失败时弹系统通知。
  bool get notifyCommands => _notifyCommands;

  /// 会话结束 / 失败 / 中断时弹系统通知（bridge 的 `session_*` 事件）。
  bool get notifySessions => _notifySessions;

  bool get notificationsEnabled => _notifyCommands || _notifySessions;

  bool get isConfigured =>
      _baseUrl.trim().isNotEmpty && _token.trim().isNotEmpty;

  /// `clh_1a2b3c4d…f9e8`：够认出来，又不会在截图里泄露整串 token。
  String get maskedToken {
    if (_token.isEmpty) return '（未设置）';
    if (_token.length <= 12) return '•' * _token.length;
    return '${_token.substring(0, 9)}…${_token.substring(_token.length - 4)}';
  }

  Future<void> saveConnection({
    required String baseUrl,
    required String token,
    String? deviceId,
  }) async {
    _baseUrl = normalizeBaseUrl(baseUrl);
    _token = token.trim();
    if (deviceId != null) _deviceId = deviceId.trim();
    await _prefs.setString(_kBaseUrl, _baseUrl);
    await _prefs.setString(_kToken, _token);
    await _prefs.setString(_kDeviceId, _deviceId);
    notifyListeners();
  }

  Future<void> setDeviceId(String value) async {
    final trimmed = value.trim();
    if (trimmed == _deviceId) return;
    _deviceId = trimmed;
    await _prefs.setString(_kDeviceId, _deviceId);
    notifyListeners();
  }

  Future<void> setNotifyCommands(bool value) async {
    if (_notifyCommands == value) return;
    _notifyCommands = value;
    await _prefs.setBool(_kNotifyCommands, value);
    notifyListeners();
  }

  Future<void> setNotifySessions(bool value) async {
    if (_notifySessions == value) return;
    _notifySessions = value;
    await _prefs.setBool(_kNotifySessions, value);
    notifyListeners();
  }

  Future<void> signOut() async {
    _baseUrl = '';
    _token = '';
    await _prefs.remove(_kBaseUrl);
    await _prefs.remove(_kToken);
    notifyListeners();
  }
}
