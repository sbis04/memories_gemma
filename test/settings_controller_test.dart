import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tv_gallery/services/settings_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('defaults are sensible', () async {
    final s = SettingsController.instance;
    await s.load();
    expect(s.themeMode, ThemeMode.dark);
    expect(s.gridZoom, 3);
    expect(s.sortBy, SortBy.date);
    expect(s.sortDesc, false);
    expect(s.autoplayVideos, true);
    expect(s.slideshowSeconds, 6);
  });

  test('zoom clamps within range and notifies', () async {
    final s = SettingsController.instance;
    await s.load();
    var notified = 0;
    s.addListener(() => notified++);

    await s.setGridZoom(99);
    expect(s.gridZoom, SettingsController.maxZoom);
    await s.setGridZoom(-5);
    expect(s.gridZoom, 0);
    expect(notified, greaterThanOrEqualTo(2));
    s.removeListener(() {});
  });

  test('theme change persists across reload', () async {
    final s = SettingsController.instance;
    await s.load();
    await s.setThemeMode(ThemeMode.light);
    // Re-load from the same backing store.
    await s.load();
    expect(s.themeMode, ThemeMode.light);
  });

  test('galleryRowHeight grows with zoom', () async {
    final s = SettingsController.instance;
    await s.load();
    await s.setGridZoom(0);
    final small = s.galleryRowHeight;
    await s.setGridZoom(SettingsController.maxZoom);
    expect(s.galleryRowHeight, greaterThan(small));
  });
}
