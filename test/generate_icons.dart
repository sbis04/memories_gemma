// Not a test — an icon generator. Run explicitly:
//   fvm flutter test test/generate_icons.dart
// It paints the app's monochrome mark (a cream "photo" glyph on charcoal) and
// writes the master launcher icon, the Android adaptive foreground, and the
// Android TV banner. Then run `fvm dart run flutter_launcher_icons`.

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'test_fonts.dart';

const _bg = Color(0xFF161615);
const _cream = Color(0xFFEDEDEA);

/// Draws the app mark filling [r]: a TV (screen + splayed legs) showing a
/// photo, with two "slide" cards fanned behind it to depict a slideshow.
void _drawMark(Canvas canvas, Rect r) {
  final w = r.width, h = r.height;
  final stroke = w * 0.016;

  final screenW = w * 0.78;
  final screenH = screenW * 0.62;
  final screenLeft = r.left + (w - screenW) / 2;
  final screenTop = r.top + h * 0.24;
  final screenRect = Rect.fromLTWH(screenLeft, screenTop, screenW, screenH);
  final screenRRect =
      RRect.fromRectAndRadius(screenRect, Radius.circular(w * 0.05));

  // Slide cards fanned up-and-right behind the TV (the "slideshow" sequence).
  void peek(double dx, double dy, double scale) {
    final pw = screenW * scale, ph = screenH * scale;
    final rect = Rect.fromLTWH(screenLeft + dx, screenTop + dy, pw, ph);
    final rr = RRect.fromRectAndRadius(rect, Radius.circular(w * 0.045));
    canvas.drawRRect(rr, Paint()..color = _cream);
    canvas.drawRRect(
        rr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke * 1.4
          ..color = _bg);
  }

  peek(w * 0.12, -h * 0.105, 0.90);
  peek(w * 0.06, -h * 0.05, 0.95);

  // Dark gap so the front screen separates cleanly from the stack.
  canvas.drawRRect(
    RRect.fromRectAndRadius(
        screenRect.inflate(stroke * 1.3), Radius.circular(w * 0.055)),
    Paint()..color = _bg,
  );

  // TV screen.
  canvas.drawRRect(screenRRect, Paint()..color = _cream);

  // Photo on the screen (dark sun + mountains).
  canvas.save();
  canvas.clipRRect(screenRRect);
  canvas.drawCircle(
    Offset(screenLeft + screenW * 0.26, screenTop + screenH * 0.32),
    screenW * 0.075,
    Paint()..color = _bg,
  );
  final m = Path()
    ..moveTo(screenLeft, screenTop + screenH)
    ..lineTo(screenLeft + screenW * 0.34, screenTop + screenH * 0.50)
    ..lineTo(screenLeft + screenW * 0.52, screenTop + screenH * 0.72)
    ..lineTo(screenLeft + screenW * 0.68, screenTop + screenH * 0.56)
    ..lineTo(screenLeft + screenW, screenTop + screenH)
    ..close();
  canvas.drawPath(m, Paint()..color = _bg);
  canvas.restore();

  // TV legs.
  final legY = screenTop + screenH;
  final cx = screenLeft + screenW / 2;
  final legPaint = Paint()
    ..color = _cream
    ..strokeWidth = stroke * 1.7
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(Offset(cx - screenW * 0.12, legY),
      Offset(cx - screenW * 0.20, legY + h * 0.085), legPaint);
  canvas.drawLine(Offset(cx + screenW * 0.12, legY),
      Offset(cx + screenW * 0.20, legY + h * 0.085), legPaint);
}

Future<void> _writePng(String path, int w, int h,
    void Function(Canvas, Size) paint) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  paint(canvas, Size(w.toDouble(), h.toDouble()));
  final img = await recorder.endRecording().toImage(w, h);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes!.buffer.asUint8List());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('generate app icons', () async {
    await loadAppFonts();

    // 1) Master launcher icon (1024) — charcoal rounded field + mark.
    await _writePng('assets/icon/app_icon.png', 1024, 1024, (canvas, size) {
      final full = Offset.zero & size;
      canvas.drawRRect(
        RRect.fromRectAndRadius(full, const Radius.circular(225)),
        Paint()..color = _bg,
      );
      final inset = size.width * 0.24;
      _drawMark(canvas, Rect.fromLTWH(inset, inset, size.width - 2 * inset,
          size.height - 2 * inset));
    });

    // 2) Adaptive foreground (1024, transparent) — mark within the safe zone.
    await _writePng('assets/icon/app_icon_fg.png', 1024, 1024, (canvas, size) {
      final s = size.width * 0.46;
      final o = (size.width - s) / 2;
      _drawMark(canvas, Rect.fromLTWH(o, o, s, s));
    });

    // 3) Android TV banner (320x180) — mark + wordmark.
    await _writePng(
        'android/app/src/main/res/drawable/tv_banner.png', 320, 180,
        (canvas, size) {
      canvas.drawRect(Offset.zero & size, Paint()..color = _bg);
      const markSize = 96.0;
      _drawMark(canvas, const Rect.fromLTWH(28, 42, markSize, markSize));
      final tp = TextPainter(
        text: const TextSpan(
          text: 'Memories',
          style: TextStyle(
            fontFamily: 'InstrumentSerif',
            color: _cream,
            fontSize: 52,
            height: 1.0,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(150, (180 - tp.height) / 2));
    });

    expect(File('assets/icon/app_icon.png').existsSync(), true);
    expect(File('assets/icon/app_icon_fg.png').existsSync(), true);
    expect(
        File('android/app/src/main/res/drawable/tv_banner.png').existsSync(),
        true);
  });
}
