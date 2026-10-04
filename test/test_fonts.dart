import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Loads every font declared in the bundled FontManifest (Inter, Instrument
/// Serif, the Lucide icon font, Material Icons…) into the test engine so golden
/// images render with real glyphs instead of placeholder boxes — letting us
/// actually judge the visual design from a golden.
Future<void> loadAppFonts() async {
  final manifest = json.decode(
    await rootBundle.loadString('FontManifest.json'),
  ) as List<dynamic>;

  for (final entry in manifest) {
    final family = entry['family'] as String;
    final loader = FontLoader(family);
    for (final font in (entry['fonts'] as List<dynamic>)) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}
