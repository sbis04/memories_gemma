import 'package:flutter/material.dart';

/// Custom design tokens carried on [ThemeData] so widgets adapt to light/dark
/// automatically. Read with `context.colors`.
///
/// The palette is deliberately monochromatic (Notion-like): neutral greys with
/// a single high-contrast "ink" used for focus/selection. Focus is shown by
/// *inverting* — light ink on dark, dark ink on light — rather than colour.
@immutable
class GalleryColors extends ThemeExtension<GalleryColors> {
  const GalleryColors({
    required this.bgTop,
    required this.bgMid,
    required this.bgBottom,
    required this.surface,
    required this.surfaceHigh,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.textPrimary,
    required this.textSecondary,
    required this.textFaint,
    required this.polaroid,
    required this.galleryBg,
    required this.tile,
    required this.shadow,
    required this.hairline,
  });

  final Color bgTop, bgMid, bgBottom;
  final Color surface, surfaceHigh;

  /// The single high-contrast "ink" used for focus/selection fills and rings.
  final Color accent;

  /// Colour for content (text/icons) drawn on top of [accent].
  final Color onAccent;
  final Color accentSoft;
  final Color textPrimary, textSecondary, textFaint;
  final Color polaroid;
  final Color galleryBg;
  final Color tile;
  final Color shadow;

  /// Subtle separator / border colour.
  final Color hairline;

  BoxDecoration get backgroundDecoration => BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [bgTop, bgMid, bgBottom],
          stops: const [0.0, 0.55, 1.0],
        ),
      );

  /// A soft neutral halo around the focused element.
  List<BoxShadow> focusGlow({double intensity = 1}) => [
        BoxShadow(
          color: accent.withValues(alpha: 0.28 * intensity),
          blurRadius: 30 * intensity,
          spreadRadius: 0.5 * intensity,
        ),
      ];

  // ---- Dark (default) — charcoal greys, light ink ----
  static const GalleryColors dark = GalleryColors(
    bgTop: Color(0xFF1B1B1A),
    bgMid: Color(0xFF141413),
    bgBottom: Color(0xFF0D0D0C),
    surface: Color(0xFF1D1D1C),
    surfaceHigh: Color(0xFF2A2A28),
    accent: Color(0xFFEDEDEA),
    onAccent: Color(0xFF161615),
    accentSoft: Color(0xFFBFBFBB),
    textPrimary: Color(0xFFF3F3F0),
    textSecondary: Color(0xFFAEAEA8),
    textFaint: Color(0xFF73736E),
    // Folder "card" surface — dark in dark mode (not a white polaroid).
    polaroid: Color(0xFF222220),
    galleryBg: Color(0xFF0D0D0C),
    tile: Color(0xFF1D1D1C),
    shadow: Color(0xCC000000),
    hairline: Color(0xFF333331),
  );

  // ---- Light — warm paper, dark ink (Notion) ----
  static const GalleryColors light = GalleryColors(
    bgTop: Color(0xFFFFFFFF),
    bgMid: Color(0xFFFBFBFA),
    bgBottom: Color(0xFFF3F2EF),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFF0EFEB),
    accent: Color(0xFF1F1E1C),
    onAccent: Color(0xFFFAFAF8),
    accentSoft: Color(0xFF55534E),
    textPrimary: Color(0xFF2B2A26),
    textSecondary: Color(0xFF6A6862),
    textFaint: Color(0xFF9C9A93),
    polaroid: Color(0xFFFFFFFF),
    galleryBg: Color(0xFFEFEEEA),
    tile: Color(0xFFFFFFFF),
    shadow: Color(0x26404038),
    hairline: Color(0xFFE3E1DB),
  );

  @override
  GalleryColors copyWith({
    Color? bgTop,
    Color? bgMid,
    Color? bgBottom,
    Color? surface,
    Color? surfaceHigh,
    Color? accent,
    Color? onAccent,
    Color? accentSoft,
    Color? textPrimary,
    Color? textSecondary,
    Color? textFaint,
    Color? polaroid,
    Color? galleryBg,
    Color? tile,
    Color? shadow,
    Color? hairline,
  }) {
    return GalleryColors(
      bgTop: bgTop ?? this.bgTop,
      bgMid: bgMid ?? this.bgMid,
      bgBottom: bgBottom ?? this.bgBottom,
      surface: surface ?? this.surface,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      accent: accent ?? this.accent,
      onAccent: onAccent ?? this.onAccent,
      accentSoft: accentSoft ?? this.accentSoft,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textFaint: textFaint ?? this.textFaint,
      polaroid: polaroid ?? this.polaroid,
      galleryBg: galleryBg ?? this.galleryBg,
      tile: tile ?? this.tile,
      shadow: shadow ?? this.shadow,
      hairline: hairline ?? this.hairline,
    );
  }

  @override
  GalleryColors lerp(ThemeExtension<GalleryColors>? other, double t) {
    if (other is! GalleryColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return GalleryColors(
      bgTop: l(bgTop, other.bgTop),
      bgMid: l(bgMid, other.bgMid),
      bgBottom: l(bgBottom, other.bgBottom),
      surface: l(surface, other.surface),
      surfaceHigh: l(surfaceHigh, other.surfaceHigh),
      accent: l(accent, other.accent),
      onAccent: l(onAccent, other.onAccent),
      accentSoft: l(accentSoft, other.accentSoft),
      textPrimary: l(textPrimary, other.textPrimary),
      textSecondary: l(textSecondary, other.textSecondary),
      textFaint: l(textFaint, other.textFaint),
      polaroid: l(polaroid, other.polaroid),
      galleryBg: l(galleryBg, other.galleryBg),
      tile: l(tile, other.tile),
      shadow: l(shadow, other.shadow),
      hairline: l(hairline, other.hairline),
    );
  }
}

extension GalleryColorsX on BuildContext {
  GalleryColors get colors => Theme.of(this).extension<GalleryColors>()!;
}

/// Shared tokens (brightness-independent).
class AppTheme {
  AppTheme._();

  /// Editorial serif used for hero / screen titles.
  static const String displayFont = 'InstrumentSerif';

  /// Clean grotesque used for everything else.
  static const String uiFont = 'Inter';

  static const Duration pageTransition = Duration(milliseconds: 460);
  static const Duration focusAnim = Duration(milliseconds: 170);
  static const Duration fade = Duration(milliseconds: 520);
  static const Curve emphasized = Curves.easeOutCubic;

  static ThemeData _build(Brightness brightness, GalleryColors c) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: c.bgBottom,
      colorScheme: base.colorScheme.copyWith(
        brightness: brightness,
        primary: c.accent,
        secondary: c.accentSoft,
        surface: c.surface,
      ),
      textTheme: base.textTheme
          .apply(
            bodyColor: c.textPrimary,
            displayColor: c.textPrimary,
            fontFamily: uiFont,
          ),
      iconTheme: IconThemeData(color: c.textPrimary),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      // Neutral, slim progress indicator (no Material accent).
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: c.textSecondary,
        linearTrackColor: c.hairline,
        circularTrackColor: Colors.transparent,
      ),
      extensions: [c],
    );
  }

  static ThemeData dark() => _build(Brightness.dark, GalleryColors.dark);
  static ThemeData light() => _build(Brightness.light, GalleryColors.light);
}
