import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';
import '../services/answer_voice.dart';
import '../services/settings_controller.dart';
import '../widgets/focusable.dart';
import '../widgets/folder_actions.dart';
import '../widgets/icon_focus_button.dart';

/// All user-adjustable preferences, fully navigable with the remote.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = SettingsController.instance;

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: c.backgroundDecoration,
        child: SafeArea(
          child: ListenableBuilder(
            listenable: s,
            builder: (context, _) {
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 880),
                  child: ListView(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 40, vertical: 28),
                    children: [
                      Row(
                        children: [
                          IconFocusButton(
                            icon: LucideIcons.arrowLeft,
                            autofocus: true,
                            onPressed: () => Navigator.of(context).maybePop(),
                          ),
                          const SizedBox(width: 18),
                          Text(
                            'Settings',
                            style: TextStyle(
                              fontFamily: AppTheme.displayFont,
                              color: c.textPrimary,
                              fontSize: 46,
                              height: 1.0,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      _SectionHeader('Appearance'),
                      _SettingTile(
                        title: 'Theme',
                        subtitle: 'Light, dark or follow the system',
                        trailing: _ChoiceChips<ThemeMode>(
                          value: s.themeMode,
                          options: const {
                            ThemeMode.light: 'Light',
                            ThemeMode.dark: 'Dark',
                            ThemeMode.system: 'System',
                          },
                          onSelect: s.setThemeMode,
                        ),
                      ),
                      _SettingTile(
                        title: 'Default thumbnail size',
                        subtitle: 'How large items appear in the gallery',
                        trailing: _Stepper(
                          label: _zoomLabel(s.gridZoom),
                          onDec:
                              s.gridZoom > 0 ? () => s.zoomOut() : null,
                          onInc: s.gridZoom < SettingsController.maxZoom
                              ? () => s.zoomIn()
                              : null,
                        ),
                      ),
                      _SettingTile(
                        title: 'Show file names',
                        subtitle: 'Label photos and videos in the gallery',
                        trailing: _Toggle(
                            value: s.showTitles, onChanged: s.setShowTitles),
                      ),
                      _SettingTile(
                        title: 'Date & location caption',
                        subtitle:
                            'Show the date and place over photos and slideshows',
                        trailing: _Toggle(
                            value: s.showCaption, onChanged: s.setShowCaption),
                      ),
                      const SizedBox(height: 20),
                      _SectionHeader('Sorting'),
                      _SettingTile(
                        title: 'Sort items by',
                        trailing: _ChoiceChips<SortBy>(
                          value: s.sortBy,
                          options: const {
                            SortBy.name: 'Name',
                            SortBy.date: 'Date',
                          },
                          onSelect: s.setSortBy,
                        ),
                      ),
                      _SettingTile(
                        title: 'Order',
                        trailing: _ChoiceChips<bool>(
                          value: s.sortDesc,
                          options: const {
                            false: 'Ascending',
                            true: 'Descending',
                          },
                          onSelect: s.setSortDesc,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _SectionHeader('Playback'),
                      _SettingTile(
                        title: 'Autoplay videos',
                        subtitle: 'Start playing as soon as a video opens',
                        trailing: _Toggle(
                            value: s.autoplayVideos,
                            onChanged: s.setAutoplayVideos),
                      ),
                      _SettingTile(
                        title: 'Mute video sound',
                        trailing: _Toggle(
                            value: s.muteVideo, onChanged: s.setMuteVideo),
                      ),
                      const SizedBox(height: 20),
                      _SectionHeader('Slideshow'),
                      _SettingTile(
                        title: 'Transition',
                        subtitle: 'How photos change during a slideshow',
                        trailing: _ChoiceChips<SlideshowTransition>(
                          value: s.slideshowTransition,
                          options: const {
                            SlideshowTransition.fade: 'Fade',
                            SlideshowTransition.kenBurns: 'Ken Burns',
                            SlideshowTransition.slide: 'Slide',
                            SlideshowTransition.none: 'None',
                          },
                          onSelect: s.setSlideshowTransition,
                        ),
                      ),
                      _SettingTile(
                        title: 'Interval',
                        subtitle: 'Seconds each photo is shown',
                        trailing: _Stepper(
                          label: '${s.slideshowSeconds}s',
                          onDec: s.slideshowSeconds > 2
                              ? () =>
                                  s.setSlideshowSeconds(s.slideshowSeconds - 1)
                              : null,
                          onInc: s.slideshowSeconds < 30
                              ? () =>
                                  s.setSlideshowSeconds(s.slideshowSeconds + 1)
                              : null,
                        ),
                      ),
                      _SettingTile(
                        title: 'Loop',
                        subtitle: 'Restart after the last item',
                        trailing: _Toggle(
                            value: s.slideshowLoop,
                            onChanged: s.setSlideshowLoop),
                      ),
                      _SettingTile(
                        title: 'Shuffle',
                        subtitle: 'Play in random order',
                        trailing: _Toggle(
                            value: s.slideshowShuffle,
                            onChanged: s.setSlideshowShuffle),
                      ),
                      _SectionHeader('Gemini'),
                      _SettingTile(
                        title: 'Gemini API key',
                        subtitle: s.geminiApiKey == null
                            ? 'Needed to ask about photos — get one free at '
                                'aistudio.google.com'
                            : 'Set (…${_tail(s.geminiApiKey!)}) — stored only '
                                'on this TV',
                        trailing: IconFocusButton(
                          icon: LucideIcons.keyRound,
                          label: s.geminiApiKey == null ? 'Add' : 'Change',
                          onPressed: () => _editGeminiKey(context),
                        ),
                      ),
                      _SettingTile(
                        title: 'Read answers aloud',
                        subtitle: 'Speak Gemini’s answers with the TV voice',
                        trailing: _Toggle(
                            value: s.readAloud, onChanged: s.setReadAloud),
                      ),
                      _SettingTile(
                        title: 'Answer voice',
                        subtitle: s.answerVoice == null
                            ? 'Automatic — best voice for your language'
                            : s.answerVoice!.split('|').first,
                        trailing: IconFocusButton(
                          icon: LucideIcons.audioLines,
                          label: 'Choose',
                          onPressed: () => showDialog<void>(
                            context: context,
                            builder: (_) => const _VoicePicker(),
                          ),
                        ),
                      ),
                      const SizedBox(height: 28),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  static String _tail(String key) =>
      key.length <= 4 ? key : key.substring(key.length - 4);

  Future<void> _editGeminiKey(BuildContext context) async {
    final settings = SettingsController.instance;
    final key = await showTextInputDialog(
      context,
      title: 'Gemini API key',
      initial: settings.geminiApiKey ?? '',
      hint: 'Paste or type your key',
      allowSlash: true,
    );
    if (key != null) await settings.setGeminiApiKey(key);
  }

  String _zoomLabel(int z) => const [
        'Tiny',
        'Smaller',
        'Small',
        'Medium',
        'Large',
        'Larger',
        'Largest',
      ][z];
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 10),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: c.accent,
          fontSize: 13,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.8,
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({required this.title, this.subtitle, required this.trailing});
  final String title;
  final String? subtitle;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
      decoration: BoxDecoration(
        color: c.surface.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.surfaceHigh),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600),
                ),
                if (subtitle != null) ...[
                  const SizedBox(height: 3),
                  Text(subtitle!,
                      style: TextStyle(color: c.textFaint, fontSize: 14)),
                ],
              ],
            ),
          ),
          const SizedBox(width: 20),
          trailing,
        ],
      ),
    );
  }
}

class _ChoiceChips<T> extends StatelessWidget {
  const _ChoiceChips({
    required this.value,
    required this.options,
    required this.onSelect,
  });
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onSelect;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in options.entries)
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Focusable(
              onPressed: () => onSelect(entry.key),
              builder: (context, focused) {
                final selected = entry.key == value;
                return AnimatedContainer(
                  duration: AppTheme.focusAnim,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                  decoration: BoxDecoration(
                    color: selected
                        ? c.accent
                        : focused
                            ? c.surfaceHigh
                            : Colors.transparent,
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(
                      color: focused && !selected ? c.accent : c.hairline,
                      width: 1.5,
                    ),
                    boxShadow: focused ? c.focusGlow(intensity: 0.5) : null,
                  ),
                  child: Text(
                    entry.value,
                    style: TextStyle(
                      color: selected ? c.onAccent : c.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Focusable(
      onPressed: () => onChanged(!value),
      builder: (context, focused) {
        return AnimatedContainer(
          duration: AppTheme.focusAnim,
          width: 62,
          height: 36,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: value ? c.accent : c.surfaceHigh,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: focused ? c.accent : Colors.transparent,
              width: 2,
            ),
            boxShadow: focused ? c.focusGlow(intensity: 0.5) : null,
          ),
          child: AnimatedAlign(
            duration: AppTheme.focusAnim,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: 26,
              height: 26,
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({required this.label, this.onDec, this.onInc});
  final String label;
  final VoidCallback? onDec;
  final VoidCallback? onInc;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconFocusButton(
            icon: LucideIcons.minus,
            onPressed: onDec ?? () {},
            enabled: onDec != null),
        Container(
          width: 104,
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
                color: c.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600),
          ),
        ),
        IconFocusButton(
            icon: LucideIcons.plus,
            onPressed: onInc ?? () {},
            enabled: onInc != null),
      ],
    );
  }
}

/// Lists the TV speech engine's voices for the device language. Moving onto
/// one plays a short sample (after a moment, so scrolling past doesn't
/// chatter); OK picks it for reading answers.
class _VoicePicker extends StatefulWidget {
  const _VoicePicker();

  @override
  State<_VoicePicker> createState() => _VoicePickerState();
}

class _VoicePickerState extends State<_VoicePicker> {
  List<VoiceOption>? _voices;
  Timer? _preview;

  static const _sample = 'Hi! This is how Gemini’s answers will sound.';

  @override
  void initState() {
    super.initState();
    AnswerVoice.voices().then((v) {
      if (mounted) setState(() => _voices = v);
    });
  }

  @override
  void dispose() {
    _preview?.cancel();
    AnswerVoice.stop();
    super.dispose();
  }

  void _onFocus(VoiceOption? voice) {
    _preview?.cancel();
    _preview = Timer(const Duration(milliseconds: 450), () {
      AnswerVoice.speak(_sample, voice: voice);
    });
  }

  Future<void> _pick(VoiceOption? voice) async {
    await SettingsController.instance.setAnswerVoice(voice?.id);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final voices = _voices;
    final saved = SettingsController.instance.answerVoice;
    Widget row(String label, VoiceOption? voice, {bool autofocus = false}) {
      final current = voice?.id == saved;
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Focusable(
          autofocus: autofocus,
          focusScale: 1.0,
          onFocusChange: (f) {
            if (f) _onFocus(voice);
          },
          onPressed: () => _pick(voice),
          builder: (context, focused) => AnimatedContainer(
            duration: AppTheme.focusAnim,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: focused ? c.accent : Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: focused ? c.onAccent : c.textPrimary,
                      fontSize: 16,
                      fontWeight: current ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
                if (current)
                  Icon(LucideIcons.check,
                      size: 18, color: focused ? c.onAccent : c.accent),
              ],
            ),
          ),
        ),
      );
    }

    return Center(
      child: Material(
        type: MaterialType.transparency,
        child: Container(
          width: 520,
          constraints: const BoxConstraints(maxHeight: 460),
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Answer voice',
                  style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text('Move through the list to hear each voice; OK to choose.',
                  style: TextStyle(color: c.textFaint, fontSize: 14)),
              const SizedBox(height: 14),
              if (voices == null)
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      row('Automatic', null, autofocus: saved == null),
                      for (final v in voices)
                        row(v.label, v, autofocus: v.id == saved),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
