import 'dart:ui' show PlatformDispatcher;

import 'package:flutter_tts/flutter_tts.dart';

import 'settings_controller.dart';

/// A text-to-speech voice offered by the TV's speech engine.
class VoiceOption {
  const VoiceOption(this.name, this.locale, {this.network = false});
  final String name;
  final String locale;

  /// Google's higher-quality voices streamed from the network (still free).
  final bool network;

  String get id => '$name|$locale';

  /// e.g. "en-US · iob · Higher quality" from "en-us-x-iob-network".
  String get label {
    final parts = name.split('-');
    final code = parts.length >= 4 ? parts[3] : name;
    return '$locale · $code${network ? ' · Higher quality' : ''}';
  }
}

/// Reads Gemini's answers aloud with Android's built-in text-to-speech (the
/// TV's Google speech engine) — free, nothing extra to install. Uses the
/// voice chosen in Settings, else the best one for the device language
/// (preferring Google's higher-quality network voices).
class AnswerVoice {
  AnswerVoice._();

  static final FlutterTts _tts = FlutterTts();
  static Future<List<VoiceOption>>? _voices;
  static String? _applied;

  /// Voices for the device's language, best first.
  static Future<List<VoiceOption>> voices() => _voices ??= () async {
        final locale = PlatformDispatcher.instance.locale;
        try {
          final raw = ((await _tts.getVoices) as List).cast<Map>();
          final options = [
            for (final v in raw)
              if ('${v['locale']}'.startsWith(locale.languageCode) &&
                  !'${v['features']}'.contains('notInstalled'))
                VoiceOption('${v['name']}', '${v['locale']}',
                    network: '${v['network_required']}' == '1'),
          ];
          int score(VoiceOption o) =>
              (o.locale == locale.toLanguageTag() ? 2 : 0) +
              (o.network ? 1 : 0);
          options.sort((a, b) {
            final c = score(b) - score(a);
            return c != 0 ? c : a.label.compareTo(b.label);
          });
          return options;
        } catch (_) {
          return <VoiceOption>[];
        }
      }();

  static Future<void> _use(VoiceOption? voice) async {
    voice ??= await _chosen();
    if (voice == null || voice.id == _applied) return;
    await _tts.setVoice({'name': voice.name, 'locale': voice.locale});
    _applied = voice.id;
  }

  static Future<VoiceOption?> _chosen() async {
    final all = await voices();
    final saved = SettingsController.instance.answerVoice;
    for (final v in all) {
      if (v.id == saved) return v;
    }
    return all.isEmpty ? null : all.first;
  }

  /// Speaks [text] in the chosen voice, replacing anything being read.
  static Future<void> speak(String text, {VoiceOption? voice}) async {
    await _tts.stop();
    await _use(voice);
    await _tts.speak(text);
  }

  static Future<void> stop() => _tts.stop();
}
