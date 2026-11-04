import 'package:flutter/material.dart';

/// 和落地页（site/styles.css）同一套色板，避免「官网和 App 不是一家人」。
const Color kBg = Color(0xFF0A0E13);
const Color kBgSoft = Color(0xFF0E1621);
const Color kPanel = Color(0xFF111B26);
const Color kLine = Color(0xFF1E2C3B);
const Color kText = Color(0xFFE7EEF6);
const Color kMuted = Color(0xFF8EA2B6);
const Color kAccent = Color(0xFF34D399);
const Color kWarn = Color(0xFFFBBF24);
const Color kDanger = Color(0xFFF87171);
const Color kInfo = Color(0xFF60A5FA);

const double kRadius = 14;

/// 会话 / 命令状态 → 颜色。未知状态一律灰色，不要让 UI 猜。
Color statusColor(String? status, {bool ok = false}) => switch (status) {
  'pending' => kWarn,
  'delivered' || 'running' => kInfo,
  'cancelling' => kWarn,
  'done' || 'completed' => kAccent,
  'failed' || 'cancelled' || 'canceled' => kDanger,
  _ => ok ? kAccent : kMuted,
};

String statusLabel(String? status) => switch (status) {
  'pending' => '排队中',
  'delivered' => '已送达',
  'running' => '执行中',
  'cancelling' => '取消中',
  'done' => '已完成',
  'completed' => '已完成',
  'failed' => '失败',
  'cancelled' || 'canceled' => '已取消',
  null => '未知',
  _ => status,
};

/// 命令状态文案：执行前被拒（P49）不是「跑完失败」，要说「未执行」。
///
/// 单独的 [statusLabel] 还要给会话用，所以不改它的语义；这里只给命令加一层。
String commandStatusLabel(String? status, {bool rejectedBeforeStart = false}) =>
    rejectedBeforeStart && status == 'failed' ? '未执行' : statusLabel(status);

/// 执行前被拒的颜色：警示色（配置 / 路径问题），不是执行失败的红色。
Color commandStatusColor(
  String? status, {
  bool rejectedBeforeStart = false,
}) => rejectedBeforeStart && status == 'failed'
    ? kWarn
    : statusColor(status);

/// 模式色：PLAN 用信息色，ACT 用警示色。
///
/// 别把 PLAN 画成灰色 —— 会和「未知状态」撞色，用户分不清是只读还是没数据。
const Color kPlan = kInfo;
const Color kAct = kDanger;

Color modeColor(String? mode) => mode == 'act' ? kAct : kPlan;

/// SegmentedButton 的统一样式。
///
/// 只设 `foregroundColor` 是不够的：M3 选中段的背景取 `secondaryContainer`，
/// 本项目没定义，派生出来是一块浅蓝，浅底配 kInfo/kDanger 的字直接糊成一片
/// （2026-11-02 手机端反馈「PLAN 状态看不清」）。这里把背景、边框、文字一起钉死。
ButtonStyle modeSegmentStyle(Color color) {
  return ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    textStyle: const WidgetStatePropertyAll<TextStyle>(
      TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
    ),
    backgroundColor: WidgetStateProperty.resolveWith<Color>(
      (states) => states.contains(WidgetState.selected)
          ? color.withValues(alpha: 0.18)
          : Colors.transparent,
    ),
    foregroundColor: WidgetStateProperty.resolveWith<Color>(
      (states) => states.contains(WidgetState.selected) ? color : kMuted,
    ),
    side: WidgetStateProperty.resolveWith<BorderSide>(
      (states) => BorderSide(
        color: states.contains(WidgetState.selected)
            ? color.withValues(alpha: 0.55)
            : kLine,
      ),
    ),
  );
}

ThemeData buildTheme() {
  const scheme = ColorScheme.dark(
    primary: kAccent,
    onPrimary: Color(0xFF04140D),
    secondary: kInfo,
    onSecondary: Color(0xFF05121F),
    surface: kPanel,
    onSurface: kText,
    error: kDanger,
    onError: Color(0xFF1A0505),
  );

  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: kBg,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: kText, displayColor: kText),
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: kText,
      ),
      iconTheme: IconThemeData(color: kMuted, size: 22),
    ),
    cardTheme: CardThemeData(
      color: kPanel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadius),
        side: const BorderSide(color: kLine),
      ),
    ),
    dividerTheme: const DividerThemeData(color: kLine, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: kPanel,
      surfaceTintColor: Colors.transparent,
      indicatorColor: kAccent.withValues(alpha: 0.18),
      elevation: 0,
      height: 62,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11.5,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w500,
          color: states.contains(WidgetState.selected) ? kText : kMuted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 22,
          color: states.contains(WidgetState.selected) ? kAccent : kMuted,
        ),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: kBgSoft,
      isDense: true,
      hintStyle: const TextStyle(color: kMuted, fontSize: 13.5),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kLine),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kLine),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kAccent),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: kDanger),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: Color(0xFF1B2836),
      contentTextStyle: TextStyle(color: kText, fontSize: 13),
      behavior: SnackBarBehavior.floating,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: kAccent,
        foregroundColor: const Color(0xFF04140D),
        minimumSize: const Size(0, 44),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: kText,
        minimumSize: const Size(0, 44),
        side: const BorderSide(color: kLine),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: kAccent),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: kAccent),
    listTileTheme: const ListTileThemeData(iconColor: kMuted, textColor: kText),
  );
}

/// 等宽字体：命令、id、token 这些都要能对齐着看。
const List<String> kMonoFallback = <String>[
  'Cascadia Code',
  'Consolas',
  'Menlo',
  'monospace',
];

const TextStyle kMono = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: kMonoFallback,
  fontSize: 12.5,
  height: 1.45,
  color: kText,
);
