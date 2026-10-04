import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'package:path/path.dart' as p;

import '../models/media_entry.dart';
import '../widgets/media_caption.dart';
import 'location_service.dart';
import 'settings_controller.dart';
import 'thumbnail_service.dart';

/// A conversation with Gemini about one photo (or a video's poster frame).
///
/// Uses the Gemini API directly over HTTPS with the user's API key from
/// Settings. The image is sent downscaled (~1024px) along with what the app
/// already knows — date, place, folder — so questions like "where was this?"
/// get grounded answers. Follow-ups keep the history, so "and that building
/// on the left?" works.
class GeminiChat {
  GeminiChat(this.entry, {Rect? focus})
      : focus = focus == null || focus == const Rect.fromLTRB(0, 0, 1, 1)
            ? null
            : focus;

  final MediaEntry entry;

  /// The zoomed-in region (normalized 0–1), or null for the whole photo.
  final Rect? focus;

  bool get zoomed => focus != null;

  /// Newest Flash model (Google keeps this alias pointing at it).
  static const model = 'gemini-flash-latest';

  final List<Map<String, Object>> _history = [];
  String? _imageData;
  String? _cropData;
  Future<void>? _prepared;

  /// Prepares the image(s) to send — called as soon as the Ask screen opens,
  /// so they're ready by the time a question has been typed or spoken.
  Future<void> prepare() => _prepared ??= () async {
        final crop = focus;
        final results = await Future.wait([
          _image(),
          crop == null ? Future<String?>.value() : _crop(crop),
        ]);
        _cropData = results[1];
      }();

  static bool get hasKey =>
      (SettingsController.instance.geminiApiKey ?? '').trim().isNotEmpty;

  /// Asks [question] about the photo; returns the answer text. Throws a
  /// [GeminiException] with a user-facing message on failure.
  Future<String> ask(String question) async {
    final key = SettingsController.instance.geminiApiKey?.trim() ?? '';
    if (key.isEmpty) {
      throw const GeminiException('Add your Gemini API key in Settings.');
    }

    final parts = <Map<String, Object>>[];
    if (_history.isEmpty) {
      await prepare();
      parts.add({
        'inline_data': {'mime_type': 'image/jpeg', 'data': await _image()},
      });
      final crop = _cropData;
      if (crop != null) {
        parts.add({
          'inline_data': {'mime_type': 'image/png', 'data': crop},
        });
      }
      parts.add({
        'text': [
          await _context(),
          if (crop != null)
            'The viewer has zoomed in: the second image is the part of the '
                'photo on screen. Focus on it; the first image is the whole '
                'photo for context.',
        ].join(' '),
      });
    }
    parts.add({'text': question});
    final turn = {'role': 'user', 'parts': parts};

    final body = jsonEncode({
      'system_instruction': {
        'parts': [
          {
            'text': 'You help someone look through their own photos and videos '
                'on a TV. Answer about the attached picture in plain text (no '
                'markdown), concisely: usually 2–5 sentences, readable from a '
                'couch. Use the date, place and folder given as context when '
                'relevant. If you are unsure, say so briefly.',
          },
        ],
      },
      'contents': [..._history, turn],
      // Quick, conversational answers: low thinking (Gemini 3 defaults to
      // high, which adds seconds; naming what's in a photo doesn't need it).
      'generationConfig': {
        'thinkingConfig': {'thinkingLevel': 'LOW'},
      },
    });

    // Temporary failures (overloaded 503, 500, rate-limited 429) are retried
    // twice with a short backoff before giving up.
    const backoff = [Duration(seconds: 1), Duration(seconds: 3)];
    for (var attempt = 0;; attempt++) {
      final (status, json) = await _post(key, body);
      if (status == 200) {
        final answer = [
          for (final part
              in ((json['candidates'] as List?)?.firstOrNull?['content']
                      ?['parts'] as List?) ??
                  const [])
            if (part is Map && part['text'] is String) part['text'] as String,
        ].join().trim();
        if (answer.isEmpty) {
          throw const GeminiException('Gemini didn’t return an answer.');
        }
        _history
          ..add(turn)
          ..add({
            'role': 'model',
            'parts': [
              {'text': answer},
            ],
          });
        return answer;
      }
      final transient = status == 429 || status == 500 || status == 503;
      if (transient && attempt < backoff.length) {
        await Future<void>.delayed(backoff[attempt]);
        continue;
      }
      final msg = (json['error'] as Map?)?['message'] as String?;
      throw GeminiException(switch (status) {
        400 || 403 =>
          'Gemini rejected the request — check the API key in Settings.'
              '${msg == null ? '' : '\n($msg)'}',
        429 || 500 || 503 =>
          'Gemini is busy right now — try again in a moment.',
        _ => 'Gemini error $status${msg == null ? '' : ': $msg'}',
      });
    }
  }

  /// One generateContent call: (HTTP status, decoded JSON body).
  Future<(int, Map<String, dynamic>)> _post(String key, String body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      final req = await client.postUrl(Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/'
          '$model:generateContent'));
      req.headers
        ..contentType = ContentType.json
        ..set('x-goog-api-key', key);
      req.add(utf8.encode(body));
      final res = await req.close().timeout(const Duration(seconds: 60));
      final text = await res.transform(utf8.decoder).join();
      return (res.statusCode, jsonDecode(text) as Map<String, dynamic>);
    } on SocketException {
      throw const GeminiException('Couldn’t reach Gemini — is the TV online?');
    } on HandshakeException {
      throw const GeminiException('Couldn’t reach Gemini — is the TV online?');
    } on FormatException {
      throw const GeminiException('Unexpected reply from Gemini.');
    } finally {
      client.close();
    }
  }

  /// The photo (or video poster) as a ~1024px JPEG, base64-encoded.
  Future<String> _image() async {
    if (_imageData != null) return _imageData!;
    final file = await ThumbnailService.instance
        .thumbnail(entry, maxDim: 1024, quality: 85, urgent: true);
    if (file == null) {
      throw const GeminiException('Couldn’t prepare this picture.');
    }
    return _imageData = base64Encode(await file.readAsBytes());
  }

  /// The zoomed-in region cut from the screen-sized image (sharper than the
  /// 1024px copy), up to 768px, as base64 PNG. Null if it can't be made.
  Future<String?> _crop(Rect r) async {
    try {
      final file = await ThumbnailService.instance.fullImage(entry);
      if (file == null) return null;
      final codec = await ui.instantiateImageCodec(await file.readAsBytes());
      final image = (await codec.getNextFrame()).image;
      final src = Rect.fromLTRB(r.left * image.width, r.top * image.height,
          r.right * image.width, r.bottom * image.height);
      final k = math.min(1.0, 768 / math.max(src.width, src.height));
      final w = math.max(1, (src.width * k).round());
      final h = math.max(1, (src.height * k).round());
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawImageRect(
        image,
        src,
        Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
        ui.Paint()..filterQuality = ui.FilterQuality.high,
      );
      final out = await recorder.endRecording().toImage(w, h);
      final png = await out.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      out.dispose();
      codec.dispose();
      return png == null ? null : base64Encode(png.buffer.asUint8List());
    } catch (_) {
      return null;
    }
  }

  Future<String> _context() async {
    final place = await LocationService.instance.placeName(entry);
    final folder = p.basename(p.dirname(entry.path));
    return [
      if (entry.isVideo) 'This is a frame from a video.',
      if (entry.modified.millisecondsSinceEpoch > 0)
        'Taken: ${MediaCaption.formatDate(entry.modified)}.',
      if (place != null) 'Place: $place.',
      if (folder.isNotEmpty && folder != '/') 'Album/folder: $folder.',
      'File: ${entry.name}.',
    ].join(' ');
  }
}

class GeminiException implements Exception {
  const GeminiException(this.message);
  final String message;
  @override
  String toString() => message;
}
