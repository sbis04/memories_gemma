import 'dart:async';
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

/// A conversation with Gemma about one photo (or a video's poster frame).
///
/// Gemma, Google's open-weight model, runs on a computer at home through
/// Ollama (Settings → Gemma server); the TV talks to it over the local
/// network, so photos never leave the house and there's no API key or bill.
/// The image is sent downscaled (~1024px) along with what the app already
/// knows — date, place, folder — so questions like "where was this?" get
/// grounded answers. Follow-ups keep the history, so "and that building on
/// the left?" works.
class GemmaChat {
  GemmaChat(this.entry, {Rect? focus})
      : focus = focus == null || focus == const Rect.fromLTRB(0, 0, 1, 1)
            ? null
            : focus;

  final MediaEntry entry;

  /// The zoomed-in region (normalized 0–1), or null for the whole photo.
  final Rect? focus;

  bool get zoomed => focus != null;

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

  static bool get hasServer => SettingsController.instance.gemmaServer != null;

  /// Asks [question] about the photo; returns the answer text. The answer
  /// streams in: [onPartial] gets the text so far as each piece arrives, so
  /// it can be shown while Gemma is still writing. Throws a [GemmaException]
  /// with a user-facing message on failure.
  Future<String> ask(
    String question, {
    void Function(String partial)? onPartial,
  }) async {
    final settings = SettingsController.instance;
    final server = settings.gemmaServer;
    if (server == null) {
      throw const GemmaException('Add your Gemma server in Settings.');
    }
    final model = settings.gemmaModel;

    final Map<String, Object> turn;
    if (_history.isEmpty) {
      await prepare();
      final crop = _cropData;
      turn = {
        'role': 'user',
        'content': [
          await _context(),
          if (crop != null)
            'The viewer has zoomed in: the second image is the part of the '
                'photo on screen. Focus on it; the first image is the whole '
                'photo for context.',
          question,
        ].join('\n\n'),
        'images': [await _image(), ?crop],
      };
    } else {
      turn = {'role': 'user', 'content': question};
    }

    final body = jsonEncode({
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': 'You help someone look through their own photos and '
              'videos on a TV. Answer about the attached picture in plain '
              'text (no markdown), concisely: usually 2–5 sentences, readable '
              'from a couch. Use the date, place and folder given as context '
              'when relevant. If you are unsure, say so briefly.',
        },
        ..._history,
        turn,
      ],
      'stream': true,
      // Answer straight away: with thinking on, Gemma 4 reasons for ~500
      // tokens first (10–30 s), and describing a photo doesn't need it.
      'think': false,
      // Keep the model loaded between questions while browsing (loading it
      // takes several seconds; Ollama's default unloads after 5 minutes).
      'keep_alive': '30m',
    });

    final answer = (await _chat(server, model, body, onPartial)).trim();
    if (answer.isEmpty) {
      throw const GemmaException('Gemma didn’t return an answer.');
    }
    _history
      ..add(turn)
      ..add({'role': 'assistant', 'content': answer});
    return answer;
  }

  /// One streaming /api/chat call; returns the whole answer. Ollama sends a
  /// JSON object per line, each with the next piece of the message.
  Future<String> _chat(
    String server,
    String model,
    String body,
    void Function(String partial)? onPartial,
  ) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    const unreachable = GemmaException(
        'Couldn’t reach the Gemma server — is the computer on, with Ollama '
        'running and listening on the network (OLLAMA_HOST=0.0.0.0)?');
    try {
      final req = await client.postUrl(Uri.parse('$server/api/chat'));
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(body));
      // Generous: the first question may wait for the model to load.
      final res = await req.close().timeout(const Duration(seconds: 180));
      final lines = res
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .where((l) => l.trim().isNotEmpty)
          .timeout(const Duration(seconds: 60));
      final answer = StringBuffer();
      await for (final line in lines) {
        final json = jsonDecode(line) as Map<String, dynamic>;
        final error = json['error'] as String?;
        if (res.statusCode != 200 || error != null) {
          throw GemmaException(switch (res.statusCode) {
            404 => 'The model “$model” isn’t on the Gemma server yet — run '
                '“ollama pull $model” there, or pick another model in '
                'Settings.',
            _ => 'Gemma error ${res.statusCode}'
                '${error == null ? '' : ': $error'}',
          });
        }
        final piece = (json['message'] as Map?)?['content'] as String?;
        if (piece != null && piece.isNotEmpty) {
          answer.write(piece);
          onPartial?.call(answer.toString().trimLeft());
        }
        if (json['done'] == true) break;
      }
      return answer.toString();
    } on SocketException {
      throw unreachable;
    } on HttpException {
      throw unreachable;
    } on TimeoutException {
      throw const GemmaException(
          'Gemma took too long to answer — try a smaller model in Settings.');
    } on FormatException {
      throw const GemmaException(
          'Unexpected reply — is that address an Ollama server?');
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
      throw const GemmaException('Couldn’t prepare this picture.');
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

class GemmaException implements Exception {
  const GemmaException(this.message);
  final String message;
  @override
  String toString() => message;
}
