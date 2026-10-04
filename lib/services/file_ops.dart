import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Renames / deletes folders on a drive. On Android this goes through the
/// native side (plain java.io over the USB mount is far quicker than dart:io,
/// which stats every entry); elsewhere it's dart:io.
class FileOps {
  FileOps._();

  static const _channel = MethodChannel('tv_gallery/media_index');

  /// Renames [path] to [newName] in the same parent; returns the new path.
  /// Throws a [FileOpException] with a user-facing reason on failure.
  static Future<String> rename(String path, String newName) async {
    final name = newName.trim();
    if (name.isEmpty || name.contains('/') || name == '.' || name == '..') {
      throw const FileOpException('That name isn’t allowed');
    }
    if (Platform.isAndroid) {
      try {
        return (await _channel.invokeMethod<String>(
            'renamePath', {'path': path, 'name': name}))!;
      } on PlatformException catch (e) {
        throw FileOpException(e.message ?? 'Couldn’t rename');
      }
    }
    final dst = p.join(p.dirname(path), name);
    if (await FileSystemEntity.type(dst) != FileSystemEntityType.notFound) {
      throw FileOpException('“$name” already exists');
    }
    try {
      return (await Directory(path).rename(dst)).path;
    } on FileSystemException catch (e) {
      throw FileOpException(e.osError?.message ?? e.message);
    }
  }

  /// Permanently deletes [path] and everything inside it.
  static Future<void> delete(String path) async {
    if (Platform.isAndroid) {
      bool ok;
      try {
        ok = await _channel.invokeMethod<bool>('deletePath', {'path': path}) ??
            false;
      } on PlatformException catch (e) {
        throw FileOpException(e.message ?? 'Couldn’t delete');
      }
      if (!ok) throw const FileOpException('Some files couldn’t be deleted');
      return;
    }
    try {
      await Directory(path).delete(recursive: true);
    } on FileSystemException catch (e) {
      throw FileOpException(e.osError?.message ?? e.message);
    }
  }
}

class FileOpException implements Exception {
  const FileOpException(this.message);
  final String message;
  @override
  String toString() => message;
}
