// Basic smoke test. The app reads the filesystem and spawns platform
// processes, so it isn't exercised in a pure widget test here.

import 'package:flutter_test/flutter_test.dart';

import 'package:tv_gallery/models/media_entry.dart';

void main() {
  test('MediaEntry classifies and strips extensions', () {
    final img = MediaEntry(
      path: '/some/where/IMG_1234.HEIC',
      type: EntryType.image,
      modified: DateTime(2024),
    );
    expect(img.isImage, true);
    expect(img.name, 'IMG_1234.HEIC');
    expect(img.displayName, 'IMG_1234');

    final folder = MediaEntry(
      path: '/some/where/Travel',
      type: EntryType.folder,
      modified: DateTime(2024),
    );
    expect(folder.isFolder, true);
    expect(folder.displayName, 'Travel');
  });
}
