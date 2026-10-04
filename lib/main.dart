import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';

import 'app.dart';
import 'services/android_files.dart';
import 'services/media_scanner.dart';
import 'services/settings_controller.dart';
import 'services/thumbnail_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // libmpv-backed video playback (handles HEVC/HDR on this TV).
  MediaKit.ensureInitialized();

  // Immersive fullscreen — hide system bars for a true lean-back TV experience.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  // A TV is driven by the D-pad, so always draw focus. The automatic strategy
  // treats Android as touch-first and hides focus until a key is seen (and
  // pointer input, e.g. a mouse over the emulator, hides it again).
  FocusManager.instance.highlightStrategy =
      FocusHighlightStrategy.alwaysTraditional;

  await SettingsController.instance.load();
  await AndroidFiles.init();
  // Last session's folder counts/covers, so folder cards fill in instantly.
  await MediaScanner.instance.loadSaved();

  // In-memory decoded-image cache. Kept modest: the TV has a tight heap, and a
  // large cache full of thumbnails leaves no headroom for video decode buffers
  // (which previously OOM-crashed the app when opening a video from a big
  // folder). Thumbnails are small, so this still covers a few screens.
  PaintingBinding.instance.imageCache.maximumSize = 240;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 96 * 1024 * 1024;

  // Bound the on-disk thumbnail cache (LRU) in the background.
  // ignore: discarded_futures
  ThumbnailService.instance.trimCache();

  runApp(GalleryApp());
}
