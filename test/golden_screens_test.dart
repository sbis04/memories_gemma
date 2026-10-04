import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tv_gallery/core/app_theme.dart';
import 'package:tv_gallery/models/media_entry.dart';
import 'package:tv_gallery/screens/browser_screen.dart';
import 'package:tv_gallery/services/media_scanner.dart';
import 'package:tv_gallery/services/settings_controller.dart';
import 'package:tv_gallery/services/thumbnail_service.dart' as tsvc;
import 'package:tv_gallery/widgets/icon_focus_button.dart';

import 'test_fonts.dart';

const _root = '/demo/Trip';
late File _placeholder;

Widget wrap(Widget child, {required bool dark}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: dark ? AppTheme.dark() : AppTheme.light(),
      home: child,
    );

MediaEntry _entry(String parent, String name) => MediaEntry(
      path: '$parent/$name',
      type: name.endsWith('.mov')
          ? EntryType.video
          : (name.contains('.') ? EntryType.image : EntryType.folder),
      modified: DateTime(2025, 1, 1),
    );

/// In-memory directory tree so the browser renders without touching disk.
final Map<String, DirectoryListing> _tree = {
  _root: DirectoryListing(path: _root, entries: [
    _entry(_root, 'Mumbai'),
    _entry(_root, 'Goa'),
    for (final n in [
      'IMG_a.heic', 'IMG_b.heic', 'VID_c.mov', 'IMG_d.heic', 'IMG_e.heic',
      'IMG_f.heic', 'VID_g.mov', 'IMG_h.heic', 'IMG_i.heic', 'IMG_j.heic',
    ])
      _entry(_root, n),
  ]),
  '$_root/Mumbai': DirectoryListing(path: '$_root/Mumbai', entries: [
    for (final n in [
      'IMG_1.heic', 'IMG_2.heic', 'VID_3.mov', 'IMG_4.heic',
      'IMG_5.heic', 'IMG_6.heic', 'IMG_7.heic', 'VID_8.mov', 'IMG_9.heic',
    ])
      _entry('$_root/Mumbai', n),
  ]),
};

final Map<String, FolderSummary> _summaries = {
  '$_root/Mumbai': FolderSummary(
      mediaCount: 134,
      subfolderCount: 0,
      cover: _entry('$_root/Mumbai', 'IMG_1.heic')),
  '$_root/Goa': FolderSummary(
      mediaCount: 76,
      subfolderCount: 2,
      cover: _entry('$_root/Goa', 'IMG_x.heic')),
};

tsvc.Size _fakeSize(MediaEntry e) {
  final sum = e.name.codeUnits.fold<int>(0, (a, b) => a + b);
  switch (sum % 3) {
    case 0:
      return const tsvc.Size(1600, 1066);
    case 1:
      return const tsvc.Size(1066, 1600);
    default:
      return const tsvc.Size(1280, 1280);
  }
}

Future<File> _makePlaceholderImage(String path) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const size = 400.0;
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, size, size),
    Paint()
      ..shader = ui.Gradient.linear(Offset.zero, const Offset(size, size),
          const [Color(0xFF6B7480), Color(0xFF2C313A)]),
  );
  final img = await recorder.endRecording().toImage(400, 400);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  final file = File(path)..writeAsBytesSync(bytes!.buffer.asUint8List());
  return file;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await loadAppFonts();
    _placeholder = await _makePlaceholderImage(
        '${Directory.systemTemp.createTempSync('tvg_ph').path}/ph.png');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await SettingsController.instance.load();
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;

    MediaScanner.instance.scanOverride = (path) =>
        _tree[path] ?? DirectoryListing(path: path, entries: const []);
    MediaScanner.instance.summarizeOverride = (path) =>
        _summaries[path] ??
        FolderSummary(mediaCount: 0, subfolderCount: 0);

    final ts = tsvc.ThumbnailService.instance;
    ts.thumbnailOverride = (e, _) async => _placeholder;
    ts.fullImageOverride = (e) async => _placeholder;
    ts.dimensionsOverride = (e) async => _fakeSize(e);
  });

  tearDown(() {
    MediaScanner.instance.scanOverride = null;
    MediaScanner.instance.summarizeOverride = null;
    final ts = tsvc.ThumbnailService.instance;
    ts.thumbnailOverride = null;
    ts.fullImageOverride = null;
    ts.dimensionsOverride = null;
  });

  Future<void> pumpBrowser(WidgetTester tester, String path,
      {required bool dark}) async {
    await tester.binding.setSurfaceSize(const Size(1320, 880));
    await tester.pumpWidget(wrap(
      BrowserScreen(rootPath: _root, currentPath: path),
      dark: dark,
    ));
    await tester.pumpAndSettle();
    // Let the real image files decode, then settle the fade-in.
    await tester.runAsync(() => Future<void>.delayed(
        const Duration(milliseconds: 60)));
    await tester.pumpAndSettle();
  }

  testWidgets('Browser: folders + media (dark)', (tester) async {
    await pumpBrowser(tester, _root, dark: true);
    await expectLater(find.byType(BrowserScreen),
        matchesGoldenFile('goldens/browser_dark.png'));
  });

  testWidgets('Browser: folders + media (light)', (tester) async {
    await pumpBrowser(tester, _root, dark: false);
    await expectLater(find.byType(BrowserScreen),
        matchesGoldenFile('goldens/browser_light.png'));
  });

  testWidgets('Browser: media-only justified gallery (dark)', (tester) async {
    await pumpBrowser(tester, '$_root/Mumbai', dark: true);
    await expectLater(find.byType(BrowserScreen),
        matchesGoldenFile('goldens/gallery_dark.png'));
  });

  testWidgets('IconFocusButton focused vs idle (dark)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 120));
    await tester.pumpWidget(wrap(
      Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconFocusButton(
                icon: Icons.arrow_back, autofocus: true, onPressed: () {}),
            const SizedBox(width: 24),
            IconFocusButton(icon: Icons.add, onPressed: () {}),
          ],
        ),
      ),
      dark: true,
    ));
    await tester.pumpAndSettle();
    await expectLater(find.byType(Row).first,
        matchesGoldenFile('goldens/icon_button_dark.png'));
  });
}
