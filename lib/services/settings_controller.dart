import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum SortBy { name, date }

enum SlideshowTransition { fade, kenBurns, slide, none }

/// App-wide, user-adjustable settings, persisted with shared_preferences and
/// exposed as a [ChangeNotifier] so the UI rebuilds when they change.
class SettingsController extends ChangeNotifier {
  SettingsController._();
  static final SettingsController instance = SettingsController._();

  late SharedPreferences _prefs;

  // ---- Keys ----
  static const _kTheme = 'themeMode';
  static const _kZoom = 'gridZoom';
  static const _kSortBy = 'sortBy';
  static const _kSortDesc = 'sortDesc';
  static const _kShowTitles = 'showTitles';
  static const _kShowCaption = 'showCaption';
  static const _kAutoplay = 'autoplayVideos';
  static const _kMuteVideo = 'muteVideo';
  static const _kSlideshow = 'slideshowSeconds';
  static const _kSlideTransition = 'slideshowTransition';
  static const _kSlideLoop = 'slideshowLoop';
  static const _kSlideShuffle = 'slideshowShuffle';
  static const _kSource = 'sourcePath';
  static const _kSourceLabel = 'sourceLabel';
  static const _kLastFolder = 'lastFolderPath';
  static const _kSlideLastFolder = 'slideshowLastFolder';
  static const _kSlideLastItem = 'slideshowLastItem';
  static const _kFolderCounts = 'folderMediaCounts';
  static const _kListView = 'listView';
  static const _kPinned = 'pinnedFolders';
  static const _kGeminiKey = 'geminiApiKey';
  static const _kReadAloud = 'readAnswersAloud';
  static const _kAnswerVoice = 'answerVoice'; // "name|locale"

  // ---- State (defaults) ----
  ThemeMode _themeMode = ThemeMode.dark;
  int _gridZoom = 2; // 0..maxZoom (2 = default, one step below "Medium")
  // Media defaults to chronological order, oldest first.
  SortBy _sortBy = SortBy.date;
  bool _sortDesc = false;
  bool _showTitles = false;
  bool _showCaption = true;
  bool _autoplayVideos = true;
  bool _muteVideo = false;
  int _slideshowSeconds = 6;
  SlideshowTransition _slideshowTransition = SlideshowTransition.kenBurns;
  bool _slideshowLoop = true;
  bool _slideshowShuffle = false;
  String? _sourcePath;
  String? _sourceLabel;
  String? _lastFolderPath;
  String? _slideshowLastFolder;
  String? _slideshowLastItem;
  Map<String, int> _folderCounts = {};
  bool _listView = false;
  List<String> _pinned = [];
  String? _geminiApiKey;
  bool _readAloud = true;
  String? _answerVoice;

  // ---- Getters ----
  ThemeMode get themeMode => _themeMode;
  int get gridZoom => _gridZoom;
  SortBy get sortBy => _sortBy;
  bool get sortDesc => _sortDesc;
  bool get showTitles => _showTitles;
  bool get showCaption => _showCaption;
  bool get autoplayVideos => _autoplayVideos;
  bool get muteVideo => _muteVideo;
  int get slideshowSeconds => _slideshowSeconds;
  SlideshowTransition get slideshowTransition => _slideshowTransition;
  bool get slideshowLoop => _slideshowLoop;
  bool get slideshowShuffle => _slideshowShuffle;
  String? get sourcePath => _sourcePath;

  /// Display name of the source (e.g. the USB drive's label).
  String? get sourceLabel => _sourceLabel;
  String? get lastFolderPath => _lastFolderPath;

  /// The folder a slideshow was last running in, and the item it stopped on, so
  /// that folder can offer to resume it. Only the most recent slideshow is kept.
  String? get slideshowLastFolder => _slideshowLastFolder;
  String? get slideshowLastItem => _slideshowLastItem;

  /// The base height (in logical px) of a row in the justified gallery for the
  /// current zoom level. Higher zoom = fewer, larger items.
  double get galleryRowHeight =>
      const [100.0, 140.0, 190.0, 260.0, 330.0, 410.0, 500.0][_gridZoom];

  /// Target width of a folder card for the current zoom level, so zooming
  /// resizes folder pages too (the default level keeps the original ~250px).
  double get folderCardWidth =>
      const [160.0, 190.0, 220.0, 250.0, 310.0, 380.0, 470.0][_gridZoom];

  /// Row height (logical px) of the list view for the current zoom level.
  double get listRowHeight =>
      const [52.0, 60.0, 70.0, 84.0, 100.0, 120.0, 144.0][_gridZoom];

  /// Gemini API key (from aistudio.google.com) for asking about photos.
  /// Stored only on this device.
  String? get geminiApiKey => _geminiApiKey;

  Future<void> setGeminiApiKey(String? key) async {
    final k = key?.trim();
    _geminiApiKey = (k == null || k.isEmpty) ? null : k;
    if (_geminiApiKey == null) {
      await _prefs.remove(_kGeminiKey);
    } else {
      await _prefs.setString(_kGeminiKey, _geminiApiKey!);
    }
    notifyListeners();
  }

  /// Read Gemini's answers aloud (Android text-to-speech).
  bool get readAloud => _readAloud;

  Future<void> setReadAloud(bool v) async {
    _readAloud = v;
    await _prefs.setBool(_kReadAloud, v);
    notifyListeners();
  }

  /// The text-to-speech voice for answers, as "name|locale"; null = automatic.
  String? get answerVoice => _answerVoice;

  Future<void> setAnswerVoice(String? v) async {
    _answerVoice = v;
    if (v == null) {
      await _prefs.remove(_kAnswerVoice);
    } else {
      await _prefs.setString(_kAnswerVoice, v);
    }
    notifyListeners();
  }

  /// Browse folders as a list instead of a grid.
  bool get listView => _listView;

  static const int maxZoom = 6;

  Future<void> load() async {
    _prefs = await SharedPreferences.getInstance();
    final t = _prefs.getString(_kTheme);
    _themeMode = switch (t) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    _gridZoom = (_prefs.getInt(_kZoom) ?? 3).clamp(0, maxZoom);
    _sortBy = _prefs.getString(_kSortBy) == 'name' ? SortBy.name : SortBy.date;
    _sortDesc = _prefs.getBool(_kSortDesc) ?? false;
    _showTitles = _prefs.getBool(_kShowTitles) ?? false;
    _showCaption = _prefs.getBool(_kShowCaption) ?? true;
    _autoplayVideos = _prefs.getBool(_kAutoplay) ?? true;
    _muteVideo = _prefs.getBool(_kMuteVideo) ?? false;
    _slideshowSeconds = _prefs.getInt(_kSlideshow) ?? 6;
    _slideshowTransition = SlideshowTransition.values.firstWhere(
      (t) => t.name == _prefs.getString(_kSlideTransition),
      orElse: () => SlideshowTransition.kenBurns,
    );
    _slideshowLoop = _prefs.getBool(_kSlideLoop) ?? true;
    _slideshowShuffle = _prefs.getBool(_kSlideShuffle) ?? false;
    _sourcePath = _prefs.getString(_kSource);
    _sourceLabel = _prefs.getString(_kSourceLabel);
    _lastFolderPath = _prefs.getString(_kLastFolder);
    _slideshowLastFolder = _prefs.getString(_kSlideLastFolder);
    _slideshowLastItem = _prefs.getString(_kSlideLastItem);
    _listView = _prefs.getBool(_kListView) ?? false;
    _pinned = _prefs.getStringList(_kPinned) ?? [];
    _geminiApiKey = _prefs.getString(_kGeminiKey);
    _readAloud = _prefs.getBool(_kReadAloud) ?? true;
    _answerVoice = _prefs.getString(_kAnswerVoice);
    final countsRaw = _prefs.getString(_kFolderCounts);
    if (countsRaw != null) {
      try {
        final m = jsonDecode(countsRaw) as Map<String, dynamic>;
        _folderCounts = m.map((k, v) => MapEntry(k, (v as num).toInt()));
      } catch (_) {
        _folderCounts = {};
      }
    }
  }

  // ---- Setters (persist + notify) ----
  Future<void> setThemeMode(ThemeMode mode) async {
    _themeMode = mode;
    await _prefs.setString(
        _kTheme,
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.system => 'system',
          ThemeMode.dark => 'dark',
        });
    notifyListeners();
  }

  Future<void> setGridZoom(int zoom) async {
    _gridZoom = zoom.clamp(0, maxZoom);
    await _prefs.setInt(_kZoom, _gridZoom);
    notifyListeners();
  }

  Future<void> zoomIn() => setGridZoom(_gridZoom + 1);
  Future<void> zoomOut() => setGridZoom(_gridZoom - 1);

  Future<void> setListView(bool v) async {
    _listView = v;
    await _prefs.setBool(_kListView, v);
    notifyListeners();
  }

  Future<void> setSortBy(SortBy by) async {
    _sortBy = by;
    await _prefs.setString(_kSortBy, by == SortBy.date ? 'date' : 'name');
    notifyListeners();
  }

  Future<void> setSortDesc(bool desc) async {
    _sortDesc = desc;
    await _prefs.setBool(_kSortDesc, desc);
    notifyListeners();
  }

  Future<void> setShowTitles(bool v) async {
    _showTitles = v;
    await _prefs.setBool(_kShowTitles, v);
    notifyListeners();
  }

  Future<void> setShowCaption(bool v) async {
    _showCaption = v;
    await _prefs.setBool(_kShowCaption, v);
    notifyListeners();
  }

  Future<void> setAutoplayVideos(bool v) async {
    _autoplayVideos = v;
    await _prefs.setBool(_kAutoplay, v);
    notifyListeners();
  }

  Future<void> setMuteVideo(bool v) async {
    _muteVideo = v;
    await _prefs.setBool(_kMuteVideo, v);
    notifyListeners();
  }

  Future<void> setSlideshowSeconds(int s) async {
    _slideshowSeconds = s.clamp(2, 30);
    await _prefs.setInt(_kSlideshow, _slideshowSeconds);
    notifyListeners();
  }

  Future<void> setSlideshowTransition(SlideshowTransition t) async {
    _slideshowTransition = t;
    await _prefs.setString(_kSlideTransition, t.name);
    notifyListeners();
  }

  Future<void> setSlideshowLoop(bool v) async {
    _slideshowLoop = v;
    await _prefs.setBool(_kSlideLoop, v);
    notifyListeners();
  }

  Future<void> setSlideshowShuffle(bool v) async {
    _slideshowShuffle = v;
    await _prefs.setBool(_kSlideShuffle, v);
    notifyListeners();
  }

  Future<void> setSource(String? path, {String? label}) async {
    _sourcePath = path;
    _sourceLabel = label;
    if (path == null) {
      await _prefs.remove(_kSource);
    } else {
      await _prefs.setString(_kSource, path);
    }
    if (label == null) {
      await _prefs.remove(_kSourceLabel);
    } else {
      await _prefs.setString(_kSourceLabel, label);
    }
    notifyListeners();
  }

  /// Remembers the most recently opened folder (no notify — purely persisted).
  Future<void> setLastFolder(String? path) async {
    _lastFolderPath = path;
    if (path == null) {
      await _prefs.remove(_kLastFolder);
    } else {
      await _prefs.setString(_kLastFolder, path);
    }
  }

  /// Records the folder + item a slideshow stopped on so that folder can offer
  /// to resume it. Notifies so an open browser updates its Resume button. Pass
  /// nulls to clear.
  /// [notify] is false for the slideshow's per-slide saves: listeners include
  /// the app root, and rebuilding everything every few seconds isn't needed
  /// just to persist a resume point.
  Future<void> setLastSlideshow(
      {String? folder, String? item, bool notify = true}) async {
    _slideshowLastFolder = folder;
    _slideshowLastItem = item;
    if (folder == null) {
      await _prefs.remove(_kSlideLastFolder);
    } else {
      await _prefs.setString(_kSlideLastFolder, folder);
    }
    if (item == null) {
      await _prefs.remove(_kSlideLastItem);
    } else {
      await _prefs.setString(_kSlideLastItem, item);
    }
    if (notify) notifyListeners();
  }

  /// The last-known media count for [path] from a previous, settled scan — used
  /// as the "total" estimate while a folder is still being indexed. Null if the
  /// folder has never been fully loaded before.
  int? folderCount(String path) => _folderCounts[path];

  /// Whether [path] is pinned to the top of its parent folder.
  bool isPinned(String path) => _pinned.contains(path);

  /// Pinned subfolders of [parent], in the order they were pinned.
  List<String> pinnedIn(String parent) =>
      _pinned.where((p) => _parentOf(p) == parent).toList();

  static String _parentOf(String path) {
    final i = path.lastIndexOf('/');
    return i <= 0 ? '/' : path.substring(0, i);
  }

  /// Keeps pins pointing at a folder (and anything inside it) after it was
  /// renamed from [from] to [to]; drops them if [to] is null (deleted).
  Future<void> movePinned(String from, String? to) async {
    if (!_pinned.any((p) => p == from || p.startsWith('$from/'))) return;
    _pinned = [
      for (final path in _pinned)
        if (path == from || path.startsWith('$from/')) ...[
          if (to != null) to + path.substring(from.length),
        ] else
          path,
    ];
    await _prefs.setStringList(_kPinned, _pinned);
    notifyListeners();
  }

  /// Pins or unpins [path]; returns whether it is now pinned.
  Future<bool> togglePin(String path) async {
    final pinned = !_pinned.remove(path);
    if (pinned) _pinned.add(path);
    await _prefs.setStringList(_kPinned, _pinned);
    notifyListeners();
    return pinned;
  }

  /// Remembers a folder's settled media count so the next scan can show
  /// progress against it. Purely persisted (no notify). No-op if unchanged.
  Future<void> setFolderCount(String path, int count) async {
    if (count <= 0 || _folderCounts[path] == count) return;
    _folderCounts[path] = count;
    await _prefs.setString(_kFolderCounts, jsonEncode(_folderCounts));
  }
}
