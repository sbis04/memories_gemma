import 'dart:io';

import 'package:photo_manager/photo_manager.dart';

import 'android_files.dart';

/// Handles media access and storage-volume discovery.
///
/// - macOS: filesystem; no permission needed; lists `/Volumes` + home.
/// - Android: media is read through MediaStore (photo_manager), which reaches
///   USB drives that raw file access can't under scoped storage. Permission is
///   the photos/videos grant; the single "source" is the media library.
class StorageAccess {
  StorageAccess._();

  static const String androidLibraryRoot = '/';

  static Future<bool> hasAccess() async {
    if (!Platform.isAndroid) return true;
    final ps = await PhotoManager.getPermissionState(
        requestOption: const PermissionRequestOption());
    return ps.hasAccess;
  }

  static Future<bool> request() async {
    if (!Platform.isAndroid) return true;
    final ps = await PhotoManager.requestPermissionExtend();
    return ps.hasAccess;
  }

  /// photo_manager opens the system settings page when permanently denied.
  static Future<void> openSettings() => PhotoManager.openSetting();

  static Future<bool> isPermanentlyDenied() async => false;

  static Future<List<StorageVolume>> volumes() async {
    if (Platform.isAndroid) {
      final library =
          StorageVolume(androidLibraryRoot, 'Photos & Videos', isPrimary: true);
      if (!AndroidFiles.granted) return [library];
      // With All files access, offer the drives themselves (read directly,
      // complete immediately) ahead of the MediaStore library.
      final drives = await AndroidFiles.volumes();
      return [
        for (final (path, name, removable) in drives)
          StorageVolume(path, name, isPrimary: !removable),
        library,
      ];
    }
    if (Platform.isMacOS) return _macVolumes();
    final home = Platform.environment['HOME'];
    return [if (home != null) StorageVolume(home, 'Home', isPrimary: true)];
  }

  static Future<List<StorageVolume>> _macVolumes() async {
    final out = <StorageVolume>[];
    try {
      final dir = Directory('/Volumes');
      if (await dir.exists()) {
        await for (final e in dir.list(followLinks: false)) {
          final name = e.path.split('/').last;
          if (e is Directory && !name.startsWith('.')) {
            out.add(StorageVolume(e.path, name));
          }
        }
      }
    } catch (_) {}
    final home = Platform.environment['HOME'];
    if (home != null) out.add(StorageVolume(home, 'Home Folder', isHome: true));
    out.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }
}

class StorageVolume {
  StorageVolume(this.path, this.name, {this.isPrimary = false, this.isHome = false});
  final String path;
  final String name;
  final bool isPrimary;
  final bool isHome;
}
