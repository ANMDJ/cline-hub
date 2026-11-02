/// App 自身的版本与更新日志（手工维护，发版时和 `pubspec.yaml` 一起改）。
///
/// 为什么不引 `package_info_plus`：这个客户端刻意只保留 http / shared_preferences
/// 两个依赖，版本号一年也就改几次，手工同步比多一个插件更划算。
/// 发版脚本 `scripts/release-apk.mjs` 会读 `pubspec.yaml` 并校验这里是否一致。
const String kAppVersion = '1.1.4';
const int kAppBuild = 6;

class ChangelogEntry {
  const ChangelogEntry(this.version, this.date, this.items);

  final String version;
  final String date;
  final List<String> items;
}

const List<ChangelogEntry> kChangelog = <ChangelogEntry>[
  ChangelogEntry('1.1.4', '2026-11-02', <String>[
    '新增：命令详情可以「取消命令」——排队中的立即取消，执行中的由 bridge 停掉进程',
    '新增：会话正文与结果按 Markdown 渲染（标题 / 列表 / 代码块 / 表格），命令输出仍保持终端原文',
    '新增：Windows 端支持命令并发执行（不同工作目录并行，同一目录仍串行）',
    '优化：命令状态多一档「取消中」，取消后不会又变回「已完成」',
  ]),
  ChangelogEntry('1.1.3', '2026-11-02', <String>[
    '新增：有新版本时可以直接「打开下载页」，用系统浏览器下载 APK，不用再复制链接',
    '修复：命令一直显示「执行中」——bridge 主动重启前会先把执行中的命令标记为中断并说明原因',
  ]),
  ChangelogEntry('1.1.2', '2026-11-02', <String>[
    '新增：远程命令完成 / 失败时弹系统通知（可在设置里关掉，Android 13+ 需授权）',
    '新增：会话结束 / 失败时弹系统通知',
    '修复：命令一直显示「执行中」——bridge 重启后会把没有进程接管的命令标记为失败并说明原因',
    '优化：命令详情显示 pid / runner / 启动时间，可复制排查命令',
  ]),
  ChangelogEntry('1.1.1', '2026-11-02', <String>[
    '修复：会话列表预览显示成 Markdown 源码（## / 代码围栏 / 表格竖线）',
    '修复：命令输出带终端颜色码，卡片和详情看起来像乱码；现在展示与复制都是纯文本',
  ]),
  ChangelogEntry('1.1.0', '2026-11-02', <String>[
    '修复：手机发 ACT 却按 PLAN 执行（bridge 用 CLINE_GLOBAL_SETTINGS_PATH 钉死模式）',
    '修复：PLAN / ACT 选中态配色看不清',
    '会话消息上限 2000 → 20000 字，长回复不再被截断；支持最近 60 个会话回填',
    '长文本折叠 + 「展开全文」二级页',
    '新增：消息级复制、整段对话复制',
    '新增：会话里的「选择题」可直接点选（作为新命令下发）',
    '新增：版本与更新日志、检查更新',
  ]),
  ChangelogEntry('1.0.0', '2026-10-31', <String>[
    '会话 / 命令 / 动态三页 + SSE',
    '会话详情逐条消息流、概览弹层、继续对话',
  ]),
];

/// 语义化版本比较：`1.2.0` > `1.1.9`。解析失败时按 0 处理，不抛异常。
int compareVersions(String a, String b) {
  List<int> parse(String value) => value
      .split(RegExp(r'[.+-]'))
      .map((part) => int.tryParse(part) ?? 0)
      .toList(growable: false);

  final left = parse(a);
  final right = parse(b);
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final x = i < left.length ? left[i] : 0;
    final y = i < right.length ? right[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}
