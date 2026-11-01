import 'package:flutter/material.dart';

import '../data/hub_api.dart';
import '../data/settings_store.dart';
import 'theme.dart';

/// 首次启动 / 换服务器时的向导：填地址 + token，顺手探一次 /health。
class SetupPage extends StatefulWidget {
  const SetupPage({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<SetupPage> createState() => _SetupPageState();
}

class _SetupPageState extends State<SetupPage> {
  late final TextEditingController _baseCtrl;
  late final TextEditingController _tokenCtrl;
  bool _busy = false;
  String? _error;
  String? _probe;

  @override
  void initState() {
    super.initState();
    _baseCtrl = TextEditingController(text: widget.settings.baseUrl);
    _tokenCtrl = TextEditingController(text: widget.settings.token);
  }

  @override
  void dispose() {
    _baseCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  String? _validate() {
    final base = _baseCtrl.text.trim();
    final token = _tokenCtrl.text.trim();
    if (base.isEmpty) return '先填 Hub 地址';
    if (!base.startsWith('http://') && !base.startsWith('https://')) {
      return '地址要以 http:// 或 https:// 开头';
    }
    final uri = Uri.tryParse(base);
    if (uri == null || uri.host.isEmpty) return '地址看起来不像一个 URL';
    if (token.isEmpty) return 'token 不能为空';
    if (token.length < 10) return 'token 太短了，应该是 clh_ 开头的一整串';
    return null;
  }

  Future<void> _test() async {
    final invalid = _validate();
    if (invalid != null) {
      setState(() {
        _error = invalid;
        _probe = null;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _probe = null;
    });
    final api = HttpHubApi(
      baseUrl: _baseCtrl.text,
      token: _tokenCtrl.text,
      timeout: const Duration(seconds: 10),
    );
    try {
      // health 是 auth: 'none'，只能证明地址通；token 得靠一个需要鉴权的接口来验。
      final health = await api.health();
      await api.sessions(limit: 1);
      if (!mounted) return;
      setState(() {
        _probe = health.dbOk
            ? '连通 ${health.service} v${health.version} · DB ${health.dbLatencyMs ?? '?'}ms · token 有效'
            : '服务在线，但数据库不可用（${health.service} v${health.version}）';
      });
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.friendly);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      await api.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enter() async {
    final invalid = _validate();
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    await widget.settings.saveConnection(
      baseUrl: _baseCtrl.text,
      token: _tokenCtrl.text,
    );
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(
                      colors: [kAccent, Color(0xFF38BDF8)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: const Icon(
                    Icons.terminal_rounded,
                    color: Color(0xFF04140D),
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Cline Console',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 26),
            const Text(
              '把 Cline 的每一次执行\n装进口袋',
              style: TextStyle(
                fontSize: 24,
                height: 1.35,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '填上你自己的 Hub 地址和 App token。数据只在你自己的服务器上，不经过任何第三方。',
              style: TextStyle(fontSize: 13, height: 1.7, color: kMuted),
            ),
            const SizedBox(height: 24),
            const Text('Hub 地址', style: TextStyle(fontSize: 12, color: kMuted)),
            const SizedBox(height: 8),
            TextField(
              controller: _baseCtrl,
              keyboardType: TextInputType.url,
              autocorrect: false,
              style: kMono,
              decoration: const InputDecoration(
                hintText: 'http://82.157.153.22/_h/<前缀>',
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'App token',
              style: TextStyle(fontSize: 12, color: kMuted),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _tokenCtrl,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              style: kMono,
              decoration: const InputDecoration(hintText: 'clh_...'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              _Notice(
                text: _error!,
                color: kDanger,
                icon: Icons.error_outline_rounded,
              ),
            ],
            if (_probe != null) ...[
              const SizedBox(height: 14),
              _Notice(
                text: _probe!,
                color: kAccent,
                icon: Icons.check_circle_outline_rounded,
              ),
            ],
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _busy ? null : _enter,
              child: Text(_busy ? '处理中…' : '保存并进入'),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: _busy ? null : _test,
              icon: const Icon(Icons.wifi_tethering_rounded, size: 16),
              label: const Text('测试连接'),
            ),
            const SizedBox(height: 26),
            const _SetupHelp(),
          ],
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text, required this.color, required this.icon});

  final String text;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 12.5, height: 1.6, color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _SetupHelp extends StatelessWidget {
  const _SetupHelp();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kBgSoft,
        borderRadius: BorderRadius.circular(kRadius),
        border: Border.all(color: kLine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '这两个值从哪来',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: kText,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '地址：备案前是 http://<服务器IP>/_h/<前缀>（前缀存仓库 .secrets/hub-http-prefix.txt）；'
            '备案通过后换成 https://hub.littlewish.top。',
            style: TextStyle(fontSize: 12, height: 1.65, color: kMuted),
          ),
          const SizedBox(height: 12),
          const Text(
            'token：在仓库里签发一次，只打印一次',
            style: TextStyle(fontSize: 12, height: 1.65, color: kMuted),
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: kBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kLine),
            ),
            child: const Text(
              'npm run create-device -- --id phone --role app --name Pixel',
              style: kMono,
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '同一个 token 只给一台设备用；丢了就重新签一个，旧的删掉即可。',
            style: TextStyle(fontSize: 12, height: 1.65, color: kMuted),
          ),
        ],
      ),
    );
  }
}
