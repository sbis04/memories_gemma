import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';
import '../core/transitions.dart';
import '../models/media_entry.dart';
import '../screens/settings_screen.dart';
import '../services/answer_voice.dart';
import '../services/gemma_service.dart';
import '../services/settings_controller.dart';
import '../services/thumbnail_service.dart';
import 'focusable.dart';

/// Opens "Ask Gemma" full screen over the blurred photo: a centred question
/// field (focused, so the TV keyboard — with its voice button — comes straight
/// up), a preview of exactly what Gemma is shown (the zoomed-in part, if
/// zoomed), quick suggestions and the conversation. Back closes it.
/// [focus] is the zoomed-in region (normalized).
Future<void> showAskPanel(
  BuildContext context,
  MediaEntry entry, {
  Rect? focus,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: 'Ask Gemma',
    barrierColor: Colors.transparent,
    transitionDuration: AppTheme.focusAnim * 2,
    pageBuilder: (context, _, _) => _AskPanel(entry, focus: focus),
    transitionBuilder: (context, animation, _, child) =>
        FadeTransition(opacity: animation, child: child),
  );
}

class _AskPanel extends StatefulWidget {
  const _AskPanel(this.entry, {this.focus});
  final MediaEntry entry;
  final Rect? focus;

  @override
  State<_AskPanel> createState() => _AskPanelState();
}

class _Turn {
  _Turn(this.question);
  final String question;
  String? answer;
  String? error;
}

class _AskPanelState extends State<_AskPanel> {

  late final GemmaChat _chat = GemmaChat(widget.entry, focus: widget.focus)
    // Get the image(s) ready while the question is being typed/spoken.
    ..prepare().ignore();
  final _text = TextEditingController();
  final _field = FocusNode(debugLabel: 'askField');
  final _answers = FocusNode(debugLabel: 'askAnswers');
  final _scroll = ScrollController();
  final _turns = <_Turn>[];
  bool _busy = false;
  File? _backdrop; // the photo, for the blurred background

  @override
  void initState() {
    super.initState();
    _loadBackdrop();
  }

  Future<void> _loadBackdrop() async {
    final entry = widget.entry;
    final file = entry.isImage
        ? await ThumbnailService.instance.fullImage(entry)
        : await ThumbnailService.instance.thumbnail(
            entry,
            maxDim: 1024,
            quality: 85,
            urgent: true,
          );
    if (mounted && file != null) setState(() => _backdrop = file);
  }

  static const _suggestions = [
    'What is this?',
    'Where was this taken?',
    'Tell me about this place',
    'Describe this photo',
  ];

  @override
  void dispose() {
    AnswerVoice.stop();
    _text.dispose();
    _field.dispose();
    _answers.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask(String question) async {
    final q = question.trim();
    if (q.isEmpty || _busy) return;
    final turn = _Turn(q);
    AnswerVoice.stop();
    setState(() {
      _turns.add(turn);
      _busy = true;
      _text.clear();
    });
    _field.unfocus(); // put the keyboard away so the answer is visible
    _scrollToLatest();
    try {
      turn.answer = await _chat.ask(
        q,
        // Show the answer as it's written.
        onPartial: (text) {
          if (mounted) setState(() => turn.answer = text);
        },
      );
    } on GemmaException catch (e) {
      turn
        ..answer = null // drop a half-streamed answer
        ..error = e.message;
    } catch (e) {
      turn
        ..answer = null
        ..error = 'Something went wrong: $e';
    }
    if (!mounted) return;
    setState(() => _busy = false);
    _scrollToLatest();
    final answer = turn.answer;
    if (answer != null && SettingsController.instance.readAloud) {
      AnswerVoice.speak(answer);
    }
    // Ready to read/scroll with the D-pad; Up goes back to the field.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _answers.requestFocus();
    });
  }

  /// D-pad in the answers: Down/Up scroll; Up at the top returns to the field.
  KeyEventResult _onAnswersKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final down = event.logicalKey == LogicalKeyboardKey.arrowDown;
    final up = event.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!down && !up) return KeyEventResult.ignored;
    if (!_scroll.hasClients) return KeyEventResult.handled;
    final pos = _scroll.position;
    final step = pos.viewportDimension * 0.5;
    if (up && pos.pixels <= pos.minScrollExtent) {
      _field.requestFocus();
    } else {
      _scroll.animateTo(
        (pos.pixels + (down ? step : -step)).clamp(
          pos.minScrollExtent,
          pos.maxScrollExtent,
        ),
        duration: AppTheme.focusAnim * 2,
        curve: AppTheme.emphasized,
      );
    }
    return KeyEventResult.handled;
  }

  /// Newest turn is listed first (right under the field) — show it.
  void _scrollToLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: AppTheme.focusAnim * 2,
        curve: AppTheme.emphasized,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The photo behind, softly blurred and darkened. Blurred once in a
          // cached layer (not a live BackdropFilter, which re-blurs the whole
          // screen every frame anything animates — e.g. "thinking...").
          const ColoredBox(color: Colors.black),
          if (_backdrop != null)
            RepaintBoundary(
              child: ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: 18,
                  sigmaY: 18,
                  tileMode: TileMode.decal,
                ),
                child: Image.file(_backdrop!, fit: BoxFit.contain),
              ),
            ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x8C000000), Color(0xD9000000)],
              ),
            ),
          ),
          // Anchored in the top half: the TV keyboard is an overlay that
          // covers the bottom ~45% without reporting an inset, so the field
          // must already sit above it.
          LayoutBuilder(
            builder: (context, box) => Padding(
              padding: EdgeInsets.only(top: box.maxHeight * 0.07),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 980),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: FocusTraversalGroup(
                      child: GemmaChat.hasServer ? _content() : _noServer(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _content() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: _title()),
            const SizedBox(width: 24),
            _GemmaInput(entry: widget.entry, focus: widget.focus),
          ],
        ),
        const SizedBox(height: 14),
        _questionField(),
        const SizedBox(height: 18),
        if (_turns.isEmpty)
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final s in _suggestions)
                _Pill(label: s, onPressed: () => _ask(s)),
            ],
          )
        else
          Flexible(child: _conversation()),
      ],
    );
  }

  Widget _title() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.sparkles, color: Colors.white, size: 19),
            const SizedBox(width: 9),
            const Text(
              'Ask Gemma',
              style: TextStyle(
                color: Colors.white,
                fontSize: 21,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 18),
            // Read answers aloud on/off (remembered).
            ListenableBuilder(
              listenable: SettingsController.instance,
              builder: (context, _) {
                final on = SettingsController.instance.readAloud;
                return _Pill(
                  icon: on ? LucideIcons.volume2 : LucideIcons.volumeX,
                  label: on ? 'Reading aloud' : 'Read aloud',
                  onPressed: () {
                    if (on) AnswerVoice.stop();
                    SettingsController.instance.setReadAloud(!on);
                  },
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _questionField() {
    final c = context.colors;
    OutlineInputBorder border(Color color, [double width = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(22),
          borderSide: BorderSide(color: color, width: width),
        );
    // After Back hides the TV keyboard the field keeps focus, but OK on the
    // remote isn't a tap — so bring the keyboard back on OK ourselves.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        final ok =
            event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter;
        // Down (keyboard hidden) moves into the answers to scroll them, or
        // to the suggestions before anything's been asked. (The field would
        // otherwise keep Down to move its cursor.)
        if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
            _field.hasFocus) {
          if (event is KeyDownEvent) {
            if (_turns.isNotEmpty) {
              _answers.requestFocus();
            } else {
              _field.focusInDirection(TraversalDirection.down);
            }
          }
          return KeyEventResult.handled;
        }
        if (!ok || !_field.hasFocus) return KeyEventResult.ignored;
        if (event is KeyDownEvent) {
          SystemChannels.textInput.invokeMethod<void>('TextInput.show');
        }
        return KeyEventResult.handled;
      },
      child: TextField(
        controller: _text,
        focusNode: _field,
        autofocus: true,
        enabled: !_busy,
        textInputAction: TextInputAction.send,
        onSubmitted: _ask,
        cursorColor: Colors.white,
        style: const TextStyle(color: Colors.white, fontSize: 18),
        decoration: InputDecoration(
          hintText: _turns.isEmpty
              ? 'Ask anything about this photo'
              : 'Ask a follow-up…',
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 17,
          ),
          prefixIcon: Padding(
            padding: const EdgeInsets.only(left: 18, right: 10),
            child: Icon(
              LucideIcons.messageCircleQuestion,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
          filled: true,
          fillColor: Colors.white.withValues(alpha: 0.1),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 20,
            vertical: 14,
          ),
          border: border(Colors.white.withValues(alpha: 0.2)),
          enabledBorder: border(Colors.white.withValues(alpha: 0.2)),
          disabledBorder: border(Colors.white.withValues(alpha: 0.1)),
          focusedBorder: border(c.accent, 2),
        ),
      ),
    );
  }

  Widget _conversation() {
    return Focus(
      focusNode: _answers,
      onKeyEvent: _onAnswersKey,
      child: ListenableBuilder(
        listenable: _answers,
        // A scrollbar shows while the answers have focus (D-pad scrolls).
        builder: (context, child) => RawScrollbar(
          controller: _scroll,
          thumbVisibility: _answers.hasFocus,
          thumbColor: Colors.white.withValues(alpha: 0.5),
          radius: const Radius.circular(4),
          thickness: 4,
          child: child!,
        ),
        child: ListView(
          controller: _scroll,
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(16, 12, 28, 28),
          children: [
            for (final t in _turns.reversed) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 4),
                child: Text(
                  t.question,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 22),
                child: t.answer != null
                    ? Text(
                        t.answer!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          height: 1.5,
                        ),
                      )
                    : t.error != null
                    ? Text(
                        t.error!,
                        style: const TextStyle(
                          color: Color(0xFFFF8A8E),
                          fontSize: 15,
                        ),
                      )
                    : const _Thinking(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _noServer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(),
        const SizedBox(height: 22),
        Text(
          'Ask about photos with Gemma running on a computer at home — your '
          'photos never leave your network. Install Ollama there, run '
          '“ollama pull ${SettingsController.instance.gemmaModel}”, then add '
          'the computer’s address in Settings.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.8),
            fontSize: 18,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 22),
        _Pill(
          label: 'Open Settings',
          icon: LucideIcons.sliders,
          autofocus: true,
          onPressed: () {
            Navigator.of(context).pop();
            Navigator.of(
              context,
            ).push(FadeZoomPageRoute(child: const SettingsScreen()));
          },
        ),
      ],
    );
  }
}

/// What Gemma is being shown — the photo, exactly the zoomed-in part of it,
/// or a video's poster frame — as a small preview above the field.
class _GemmaInput extends StatefulWidget {
  const _GemmaInput({required this.entry, this.focus});
  final MediaEntry entry;
  final Rect? focus;

  @override
  State<_GemmaInput> createState() => _GemmaInputState();
}

class _GemmaInputState extends State<_GemmaInput> {
  File? _file;
  Size? _size; // pixel size of _file
  ImageStream? _stream;
  ImageStreamListener? _listener;

  static const double _height = 110;
  static const double _maxWidth = 200;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entry = widget.entry;
    final file = entry.isImage
        ? await ThumbnailService.instance.fullImage(entry)
        : await ThumbnailService.instance.thumbnail(
            entry,
            maxDim: 1024,
            quality: 85,
            urgent: true,
          );
    if (file == null || !mounted) return;
    final stream = _stream = FileImage(
      file,
    ).resolve(createLocalImageConfiguration(context));
    final listener = _listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      setState(() {
        _file = file;
        _size = Size(info.image.width.toDouble(), info.image.height.toDouble());
      });
    });
    stream.addListener(listener);
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final file = _file;
    final size = _size;
    if (file == null || size == null) {
      return const SizedBox(width: _maxWidth * 0.6, height: _height);
    }
    final r = widget.focus ?? const Rect.fromLTRB(0, 0, 1, 1);
    // Aspect of the visible region, in image pixels.
    final aspect = (size.width * r.width) / (size.height * r.height);
    final w = (_height * aspect).clamp(_height * 0.6, _maxWidth);
    final h = w / aspect;
    // Scale the whole image so the region fills w×h, then shift it into view.
    final fullW = w / r.width;
    final fullH = h / r.height;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          widget.focus != null ? 'Gemma sees (zoomed in)' : 'Gemma sees',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 12,
          ),
        ),
        const SizedBox(height: 6),
        Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.35)),
          ),
          clipBehavior: Clip.antiAlias,
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: fullW,
            maxWidth: fullW,
            minHeight: fullH,
            maxHeight: fullH,
            child: Transform.translate(
              offset: Offset(-r.left * fullW, -r.top * fullH),
              child: Image.file(
                file,
                width: fullW,
                height: fullH,
                fit: BoxFit.fill,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "thinking..." with a light sweeping across it while Gemma answers.
class _Thinking extends StatelessWidget {
  const _Thinking();

  @override
  Widget build(BuildContext context) {
    // Opaque grey, not translucent white: the shimmer (srcATop) keeps the
    // text's alpha and swaps in its colour, so a white sweep over
    // translucent white text would be invisible.
    return const Text(
          'thinking...',
          style: TextStyle(
            color: Color(0xFF7C7C7C),
            fontSize: 16,
            fontWeight: FontWeight.w500,
          ),
        )
        .animate(onPlay: (controller) => controller.repeat())
        .shimmer(duration: 2200.ms, color: Colors.white);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.onPressed,
    this.icon,
    this.autofocus = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onPressed;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Focusable(
      autofocus: autofocus,
      onPressed: onPressed,
      focusScale: 1.0,
      builder: (context, focused) {
        final fg = focused ? c.onAccent : Colors.white;
        return AnimatedContainer(
          duration: AppTheme.focusAnim,
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
          decoration: BoxDecoration(
            color: focused ? c.accent : Colors.white.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: focused ? 0 : 0.15),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 18, color: fg),
                const SizedBox(width: 10),
              ],
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
