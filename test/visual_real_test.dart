import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tv_gallery/core/app_theme.dart';
import 'package:tv_gallery/models/media_entry.dart';
import 'package:tv_gallery/screens/browser_screen.dart';
import 'package:tv_gallery/screens/viewer_screen.dart';
import 'package:tv_gallery/services/media_scanner.dart';
import 'package:tv_gallery/services/settings_controller.dart';
import 'package:tv_gallery/services/thumbnail_service.dart' as tsvc;

import 'test_fonts.dart';

/// Renders screens with REAL converted photos from the HDD so the design can
/// be judged faithfully. Skips automatically when the drive isn't mounted, so
/// it's safe to keep in the suite.
const _srcDir = '/Volumes/Seagate/Travel/Mumbai';
const _fakeDir = '/demo/Mumbai';

bool _have = false;
final Map<String, File> _jpeg = {}; // original path -> converted jpeg
final Map<String, tsvc.Size> _dims = {};
List<MediaEntry> _media = const [];

Widget wrap(Widget child, {required bool dark}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: child,
    );

tsvc.Size? _sips(String jpg) {
  final r = Process.runSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', jpg]);
  final out = r.stdout.toString();
  final w = RegExp(r'pixelWidth:\s*(\d+)').firstMatch(out);
  final h = RegExp(r'pixelHeight:\s*(\d+)').firstMatch(out);
  if (w == null || h == null) return null;
  return tsvc.Size(double.parse(w.group(1)!), double.parse(h.group(1)!));
}

Future<void> _pumpLoad(WidgetTester tester) async {
  await tester.pump();
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 90)));
    await tester.pump(const Duration(milliseconds: 140));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadAppFonts();
    final dir = Directory(_srcDir);
    if (!dir.existsSync()) return;
    final tmp = Directory.systemTemp.createTempSync('tvg_real');
    final originals = dir
        .listSync()
        .whereType<File>()
        .where((f) {
          final n = f.uri.pathSegments.last.toLowerCase();
          return !n.startsWith('.') &&
              (n.endsWith('.heic') || n.endsWith('.jpg') || n.endsWith('.jpeg'));
        })
        .take(9)
        .toList();
    if (originals.length < 6) return;
    final entries = <MediaEntry>[];
    var i = 0;
    for (final o in originals) {
      final jpg = '${tmp.path}/img_$i.jpg';
      final r = Process.runSync(
          'sips', ['-s', 'format', 'jpeg', '-Z', '1400', o.path, '--out', jpg]);
      if (r.exitCode != 0 || !File(jpg).existsSync()) continue;
      final fake = '$_fakeDir/IMG_$i.heic';
      _jpeg[fake] = File(jpg);
      _dims[fake] = _sips(jpg) ?? const tsvc.Size(1600, 1066);
      entries.add(MediaEntry(
          path: fake, type: EntryType.image, modified: DateTime(2025, 1, i + 1)));
      i++;
    }
    _media = entries;
    _have = entries.length >= 6;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsController.instance.load();
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    MediaScanner.instance.scanOverride =
        (path) => DirectoryListing(path: path, entries: _media);
    final ts = tsvc.ThumbnailService.instance;
    ts.thumbnailOverride = (e, _) async => _jpeg[e.path] ?? _jpeg.values.first;
    ts.fullImageOverride = (e) async => _jpeg[e.path] ?? _jpeg.values.first;
    ts.dimensionsOverride = (e) async => _dims[e.path];
  });

  tearDown(() {
    MediaScanner.instance.scanOverride = null;
    final ts = tsvc.ThumbnailService.instance;
    ts.thumbnailOverride = null;
    ts.fullImageOverride = null;
    ts.dimensionsOverride = null;
  });

  testWidgets('REAL gallery dark', (tester) async {
    if (!_have) return;
    await tester.binding.setSurfaceSize(const Size(1320, 880));
    await tester.pumpWidget(wrap(
        const BrowserScreen(rootPath: _fakeDir, currentPath: _fakeDir),
        dark: true));
    await _pumpLoad(tester);
    await expectLater(find.byType(BrowserScreen),
        matchesGoldenFile('goldens/real_gallery_dark.png'));
  });

  testWidgets('REAL gallery light', (tester) async {
    if (!_have) return;
    await tester.binding.setSurfaceSize(const Size(1320, 880));
    await tester.pumpWidget(wrap(
        const BrowserScreen(rootPath: _fakeDir, currentPath: _fakeDir),
        dark: false));
    await _pumpLoad(tester);
    await expectLater(find.byType(BrowserScreen),
        matchesGoldenFile('goldens/real_gallery_light.png'));
  });

  testWidgets('REAL photo preview', (tester) async {
    if (!_have) return;
    await tester.binding.setSurfaceSize(const Size(1320, 860));
    await tester.pumpWidget(wrap(
        ViewerScreen(media: _media, initialIndex: 0),
        dark: true));
    await _pumpLoad(tester);
    await expectLater(find.byType(ViewerScreen),
        matchesGoldenFile('goldens/real_viewer.png'));
  });
}
