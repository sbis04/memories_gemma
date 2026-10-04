import 'package:flutter/material.dart';

/// A lower-left overlay caption: the reverse-geocoded place (when available)
/// above the capture date. Drawn at 60% opacity with soft shadows so it stays
/// legible over any photo. It's anchored by its bottom edge, so the date line
/// stays put when the place resolves and appears above it.
class MediaCaption extends StatelessWidget {
  const MediaCaption({super.key, required this.date, this.place});

  final DateTime date;
  final String? place;

  static const List<String> _months = [
    'January', 'February', 'March', 'April', 'May', 'June',
    'July', 'August', 'September', 'October', 'November', 'December',
  ];

  /// Compact form for small tiles: "Sep 12, 2026".
  static String formatShortDate(DateTime d) =>
      '${_months[d.month - 1].substring(0, 3)} ${d.day}, ${d.year}';

  /// Compact date + time for small tiles: "Sep 12, 2026 · 4:25 AM".
  static String formatShortDateTime(DateTime d) =>
      '${formatShortDate(d)} · ${formatTime(d)}';

  /// "4:25 AM".
  static String formatTime(DateTime d) {
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour < 12 ? 'AM' : 'PM';
    return '$h12:$mm $ampm';
  }

  static String formatDate(DateTime d) =>
      '${_months[d.month - 1]} ${d.day}, ${d.year}  ·  ${formatTime(d)}';

  static const _shadow = [Shadow(blurRadius: 8, color: Colors.black54)];

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (place != null && place!.isNotEmpty) ...[
            Text(
              place!,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w500,
                shadows: _shadow,
              ),
            ),
            const SizedBox(height: 3),
          ],
          Text(
            formatDate(date),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              shadows: _shadow,
            ),
          ),
        ],
      ),
    );
  }
}
