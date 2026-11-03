import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_update.dart';
import '../data/app_version.dart';
import '../data/hub_api.dart';
import '../data/link_launcher.dart';
import '../data/settings_store.dart';
import '../state/hub_store.dart';
import 'theme.dart';
import 'widgets.dart';

/// 设置：连接信息、健康检查、通知、默认设备（手填兜底）、换连接、版本。
///
/// 设备列表 / 浏览筛选 / 点选默认设备都在右侧抽屉里（P38/P39），这里不重复放一份：
/// 同一个「设备」概念出现两处、状态还得各自刷新，是上一版最容易看出不一致的地方。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.settings, required this.store});

  final SettingsStore settings;
  final HubStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _deviceCtrl = TextEditingController(
    text: widget.settings.deviceId,
  );
  bool _checking = false;
  String? _healthLine;
  String? _healthError;

  bool _checkingUpdate = false;
  bool _checkedUpdate = false;
  AppRelease? _release;
  String? _updateError;

  bool _requestingNotify = false;
  String? _notifyStatus;

  final LinkLauncher _links = const LinkLauncher();

  /// 有新版本时直接交给系统浏览器下载，不用再「复制链接 → 打开浏览器 → 粘贴」。
  /// 打不开（Web 预览 / 没有浏览器 / 地址不合法）就退回复制，至少不会卡住。
  Future<void> _openDownload(AppRelease release) async {
    final url = release.apkUrl ?? '';
    final opened = await _links.open(url);
    if (!mounted || opened) return;
    await Clipboard.setData(ClipboardData(text: url));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('这个环境打不开浏览器，已复制下载地址'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _requestNotifyPermission() async {
    setState(() => _requestingNotify = true);
    final granted = await widget.store.notifier.ensurePermission();
    if (!mounted) return;
    setState(() {
      _requestingNotify = false;
      _notifyStatus = widget.store.notifier.supported
          ? (granted ? '已允许' : '未授予：通知不会出现，去系统设置里打开')
          : '当前平台没有系统通知（Web 预览 / 测试）';
    });
  }

  @override
  void dispose() {
    _deviceCtrl.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _healthLine = null;
      _healthError = null;
    });
    try {
      final health = await widget.store.api.health();
      if (!mounted) return;
      setState(() {
        _healthLine =
            '${health.service} v${health.version} · 运行 ${formatUptime(health.uptimeSec)}\n'
            '数据库 ${health.dbOk ? '正常' : '异常'}（${health.dbLatencyMs ?? '?'}ms）· SSE 连接 ${health.sseClients} 条';
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _healthError = error.friendly);
    } catch (error) {
      if (mounted) setState(() => _healthError = '$error');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  /// 检查更新：读 Hub 的 `/api/v1/app/latest`（服务器上没有清单时返回 404）。
  Future<void> _checkUpdate() async {
    setState(() {
      _checkingUpdate = true;
      _checkedUpdate = true;
      _updateError = null;
    });
    try {
      final release = await fetchLatestRelease(
        baseUrl: widget.settings.baseUrl,
        token: widget.settings.token,
      );
      if (!mounted) return;
      setState(() => _release = release);
    } catch (error) {
      if (mounted) setState(() => _updateError = '$error');
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  void _showChangelog() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text('更新日志'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final entry in kChangelog) ...[
                Text(
                  '${entry.version} · ${entry.date}',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: kAccent,
                  ),
                ),
                const SizedBox(height: 4),
                for (final item in entry.items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '· $item',
                      style: const TextStyle(fontSize: 12, height: 1.6),
                    ),
                  ),
                const SizedBox(height: 12),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveDevice() async {
    await widget.settings.setDeviceId(_deviceCtrl.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('默认设备已保存'), duration: Duration(seconds: 1)),
    );
  }

  Future<void> _signOut() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: kPanel,
        title: const Text('换一套连接？'),
        content: const Text(
          '会清空本机保存的地址和 token，回到首次启动的向导。App 里的数据都在服务器上，不会丢。',
          style: TextStyle(fontSize: 13, height: 1.6, color: kMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('清空并退出', style: TextStyle(color: kDanger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.settings.signOut();
    if (mounted) Navigator.of(context).pop();
  }

  String formatUptime(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final minutes = seconds ~/ 60;
    if (minutes < 60) return '${minutes}m';
    final hours = minutes ~/ 60;
    if (hours < 24) return '${hours}h${minutes % 60}m';
    return '${hours ~/ 24}d${hours % 24}h';
  }

  Widget _kv(String label, String value, {bool mono = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: kMuted, height: 1.5),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: mono
                  ? kMono
                  : const TextStyle(fontSize: 12.5, height: 1.5, color: kText),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = widget.settings;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 32),
        children: [
          SectionCard(
            title: '连接',
            trailing: LinkBadge(
              state: widget.store.link,
              detail: widget.store.linkError,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _kv('地址', settings.baseUrl, mono: true),
                _kv('token', settings.maskedToken, mono: true),
                _kv(
                  '默认设备',
                  settings.deviceId.isEmpty ? '（未设置）' : settings.deviceId,
                  mono: true,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: 'Hub 健康',
            trailing: TextButton(
              onPressed: _checking ? null : _check,
              child: Text(
                _checking ? '检查中…' : '检查',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_healthLine == null && _healthError == null)
                  const Text(
                    '点「检查」拉一次 /api/v1/health，确认服务、数据库和 SSE 都在。',
                    style: TextStyle(fontSize: 12, height: 1.65, color: kMuted),
                  ),
                if (_healthLine != null)
                  Text(
                    _healthLine!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.7,
                      color: kAccent,
                    ),
                  ),
                if (_healthError != null)
                  Text(
                    _healthError!,
                    style: const TextStyle(
                      fontSize: 12.5,
                      height: 1.7,
                      color: kDanger,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '通知',
            trailing: TextButton(
              onPressed: _requestingNotify ? null : _requestNotifyPermission,
              child: Text(
                _requestingNotify ? '请求中…' : '请求权限',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    '命令完成 / 失败',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: const Text(
                    '远程命令跑到终态时弹系统通知（含失败原因）',
                    style: TextStyle(fontSize: 11, height: 1.5, color: kMuted),
                  ),
                  value: settings.notifyCommands,
                  onChanged: (value) async {
                    await settings.setNotifyCommands(value);
                    if (mounted) setState(() {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    '会话完成 / 失败',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: const Text(
                    'bridge 发现会话从「执行中」翻成终态时提醒',
                    style: TextStyle(fontSize: 11, height: 1.5, color: kMuted),
                  ),
                  value: settings.notifySessions,
                  onChanged: (value) async {
                    await settings.setNotifySessions(value);
                    if (mounted) setState(() {});
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    '锁屏也提醒',
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: const Text(
                    '命令运行期间挂一个 dataSync 前台服务（会显示一条不可划走的常驻通知），'
                    '锁屏后也能收到完成通知；Android 15+ 系统限制最长 6 小时',
                    style: TextStyle(fontSize: 11, height: 1.5, color: kMuted),
                  ),
                  value: settings.keepAliveEnabled,
                  onChanged: (value) async {
                    await settings.setKeepAlive(value);
                    // 开关立即生效：不用等下一轮命令才开 / 停服务。
                    widget.store.syncKeepAliveNow();
                    if (mounted) setState(() {});
                  },
                ),
                const SizedBox(height: 4),
                Text(
                  _notifyStatus ??
                      'Android 13+ 需要授予通知权限。手机下发的命令：开着「锁屏也提醒」时，'
                          '命令运行期间 App 保持 SSE 连接，跑完能立刻提醒；关掉则等回到 App 才补发。'
                          '电脑上自己开的会话仍由 ntfy 推送。',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.6,
                    color: _notifyStatus == null ? kMuted : kText,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '默认执行设备（手填兜底）',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _deviceCtrl,
                  autocorrect: false,
                  style: kMono,
                  decoration: const InputDecoration(hintText: 'localone'),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Expanded(
                      child: Text(
                        '平时在右侧菜单里点一台电脑就能切默认，这里只给「还没上报过、列表里看不到」的'
                        '设备兜底。下发面板里仍可临时改目标。',
                        style: TextStyle(
                          fontSize: 11.5,
                          height: 1.6,
                          color: kMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _saveDevice,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 36),
                      ),
                      child: const Text('保存', style: TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const SectionCard(
            title: '安全提示',
            child: Text(
              '线上入口是 https://hub.littlewish.top:8443（备案期的临时 HTTPS 端口）。'
              '如果自己部署时用了 http://<IP>:3100 这种明文入口，同一网络的人能看到 token —— '
              '公共 Wi-Fi 下别用；换过地址或怀疑泄露时，在服务器上轮换 device / app token。',
              style: TextStyle(fontSize: 12, height: 1.7, color: kMuted),
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '换个 Hub',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '清空本机的地址和 token，重新走一遍向导。',
                  style: TextStyle(fontSize: 12, height: 1.65, color: kMuted),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _signOut,
                  icon: const Icon(Icons.logout_rounded, size: 16),
                  label: const Text('清空并退出'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kDanger,
                    side: BorderSide(color: kDanger.withValues(alpha: 0.4)),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          SectionCard(
            title: '版本与更新',
            trailing: TextButton(
              onPressed: _checkingUpdate ? null : _checkUpdate,
              child: Text(
                _checkingUpdate ? '检查中…' : '检查更新',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Cline Console $kAppVersion（build $kAppBuild）',
                  style: const TextStyle(fontSize: 12.5, height: 1.7),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Hub API v1 · Flutter Android 客户端 · 数据只存在你自己的服务器',
                  style: TextStyle(fontSize: 11.5, height: 1.7, color: kMuted),
                ),
                if (_updateError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    '检查失败：$_updateError',
                    style: const TextStyle(fontSize: 11.5, height: 1.6, color: kWarn),
                  ),
                ],
                if (_release != null) ...[
                  const SizedBox(height: 10),
                  if (_release!.isNewer) ...[
                    Text(
                      '有新版本 ${_release!.version}（build ${_release!.build}）',
                      style: const TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: kAccent,
                      ),
                    ),
                    const SizedBox(height: 4),
                    for (final note in _release!.notes)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 3),
                        child: Text(
                          '· $note',
                          style: const TextStyle(fontSize: 11.5, height: 1.6),
                        ),
                      ),
                    if ((_release!.apkUrl ?? '').isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          FilledButton.icon(
                            onPressed: () => _openDownload(_release!),
                            icon: const Icon(Icons.open_in_new_rounded, size: 15),
                            label: const Text(
                              '打开下载页',
                              style: TextStyle(fontSize: 12.5),
                            ),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                          CopyButton(text: _release!.apkUrl!, label: '复制链接'),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '「打开下载页」会用系统浏览器打开 APK 地址，下载后用系统安装器覆盖安装即可（同一签名）。',
                        style: TextStyle(fontSize: 11, height: 1.6, color: kMuted),
                      ),
                    ],
                  ] else
                    const Text(
                      '已是最新版本。',
                      style: TextStyle(fontSize: 12, color: kMuted),
                    ),
                ],
                if (_checkedUpdate && _release == null && _updateError == null)
                  const Text(
                    '服务器还没有发布过 APK（releases/latest.json 不存在）。',
                    style: TextStyle(fontSize: 11.5, height: 1.6, color: kMuted),
                  ),
                const SizedBox(height: 6),
                TextButton(
                  onPressed: _showChangelog,
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('更新日志', style: TextStyle(fontSize: 12)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
