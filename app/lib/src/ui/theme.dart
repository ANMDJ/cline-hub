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
  'done' || 'completed' => kAccent,
  'failed' || 'cancelled' || 'canceled' => kDanger,
  _ => ok ? kAccent : kMuted,
};

String statusLabel(String? status) => switch (status) {
  'pending' => '排队中',
  'delivered' => '已送达',
  'running' => '执行中',
  'done' => '已完成',
  'completed' => '已完成',
  'failed' => '失败',
  'cancelled' || 'canceled' => '已取消',
  null => '未知',
  _ => status,
};

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
