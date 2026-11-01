/// 时间与时长的小工具：不引 intl，够用就好（中文 + 24 小时制）。
library;

String _two(int value) => value.toString().padLeft(2, '0');

String formatClock(DateTime? time) =>
    time == null ? '—' : '${_two(time.hour)}:${_two(time.minute)}';

String formatDateTime(DateTime? time) => time == null
    ? '—'
    : '${_two(time.month)}-${_two(time.day)} ${_two(time.hour)}:${_two(time.minute)}:${_two(time.second)}';

String relativeTime(DateTime? time, {DateTime? now}) {
  if (time == null) return '—';
  final reference = now ?? DateTime.now();
  final diff = reference.difference(time);
  if (diff.isNegative || diff.inSeconds < 45) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24 && reference.day == time.day) {
    return '${diff.inHours} 小时前';
  }
  if (time.year == reference.year &&
      time.month == reference.month &&
      time.day == reference.day - 1) {
    return '昨天 ${formatClock(time)}';
  }
  if (diff.inDays < 7) return '${diff.inDays} 天前';
  if (time.year == reference.year) {
    return '${_two(time.month)}-${_two(time.day)}';
  }
  return '${time.year}-${_two(time.month)}-${_two(time.day)}';
}

String formatDuration(Duration? duration) {
  if (duration == null) return '—';
  final seconds = duration.inSeconds;
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  if (minutes < 60) return '${minutes}m${_two(seconds % 60)}s';
  final hours = minutes ~/ 60;
  if (hours < 24) return '${hours}h${_two(minutes % 60)}m';
  return '${hours ~/ 24}d${_two(hours % 24)}h';
}

String formatSpan(DateTime? start, DateTime? end) {
  if (start == null) return '—';
  final stop = end ?? DateTime.now();
  final diff = stop.difference(start);
  if (diff.isNegative) return '—';
  return '${formatClock(start)} → ${formatClock(stop)}';
}
