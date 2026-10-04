import 'package:path/path.dart' as p;

enum EntryType { folder, image, video }

/// A single item we care about: a folder, an image, or a video.
///
/// Sourced either from the filesystem (macOS — [assetId] is null and [path] is
/// a real file path) or from Android's MediaStore (via photo_manager — [assetId]
/// is set and [path] is a *virtual* tree path used only for navigation/keys).
class MediaEntry {
  MediaEntry({
    required this.path,
    required this.type,
    required this.modified,
    this.size = 0,
    this.assetId,
    this.pxWidth,
    this.pxHeight,
  }) : name = p.basename(path);

  final String path;
  final String name;
  final EntryType type;
  final DateTime modified;
  final int size;

  /// MediaStore asset id (Android). Null for filesystem entries.
  final String? assetId;

  /// Known pixel dimensions (Android MediaStore provides these for free).
  final int? pxWidth;
  final int? pxHeight;

  bool get isFolder => type == EntryType.folder;
  bool get isImage => type == EntryType.image;
  bool get isVideo => type == EntryType.video;
  bool get isMediaStore => assetId != null;

  String get displayName =>
      isFolder ? name : p.basenameWithoutExtension(name);

  @override
  bool operator ==(Object other) =>
      other is MediaEntry && other.path == path && other.type == type;

  @override
  int get hashCode => Object.hash(path, type);
}

/// Recursively-computed summary of a folder, used to render folder cards.
class FolderSummary {
  FolderSummary({
    required this.mediaCount,
    required this.subfolderCount,
    this.cover,
    this.date,
  });

  final int mediaCount;
  final int subfolderCount;

  /// Representative media item shown on the folder card (carries its own
  /// asset id / path so it loads correctly on either backend).
  final MediaEntry? cover;

  /// When the folder's photos were taken (its cover's capture date), used to
  /// sort folders by date. Null when unknown.
  final DateTime? date;

  bool get isEmpty => mediaCount == 0 && subfolderCount == 0;
}

/// The contents of a single directory, split into folders and media.
class DirectoryListing {
  DirectoryListing({required this.path, required this.entries});

  final String path;
  final List<MediaEntry> entries;

  List<MediaEntry> get folders =>
      entries.where((e) => e.isFolder).toList(growable: false);
  List<MediaEntry> get media =>
      entries.where((e) => !e.isFolder).toList(growable: false);

  bool get hasFolders => entries.any((e) => e.isFolder);
  bool get hasMedia => entries.any((e) => !e.isFolder);
}
