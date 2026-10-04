import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;

import '../screens/browser_screen.dart';
import '../services/android_files.dart';
import '../services/settings_controller.dart';
import 'transitions.dart';

/// Routes that reopen the last-viewed folder, with its parents stacked beneath
/// it (source → … → last) so Back walks up the folders as if navigated. Empty
/// when there's nothing to resume or it's not available (e.g. the USB drive
/// isn't plugged in / mounted yet).
List<Route<dynamic>> resumeRoutes() {
  final settings = SettingsController.instance;
  final last = settings.lastFolderPath;
  final source = settings.sourcePath;
  if (last == null || source == null) return const [];

  // Virtual MediaStore paths can't be checked on disk; real paths (desktop,
  // or Android drives read directly) must still exist. With direct drive
  // access available, a saved MediaStore source isn't resumed so the drive
  // can be picked on the source screen.
  bool isVirtual(String path) =>
      Platform.isAndroid && !AndroidFiles.isRealPath(path);
  bool exists(String path) => isVirtual(path) || Directory(path).existsSync();
  if ((AndroidFiles.granted && isVirtual(source)) ||
      !exists(last) ||
      !exists(source)) {
    return const [];
  }

  final rootIsAncestor = p.equals(last, source) || p.isWithin(source, last);
  final root = rootIsAncestor ? source : last;
  final chain = <String>[last];
  while (!p.equals(chain.first, root)) {
    chain.insert(0, p.dirname(chain.first));
  }
  return [
    for (final folder in chain)
      FadeZoomPageRoute(
        child: BrowserScreen(
          rootPath: root,
          currentPath: folder,
          rootLabel: settings.sourceLabel ??
              (Platform.isAndroid ? 'Photos & Videos' : null),
        ),
      ),
  ];
}
