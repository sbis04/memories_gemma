import 'package:geocoding/geocoding.dart';
import 'package:permission_handler/permission_handler.dart';

import '../models/media_entry.dart';
import 'media_store_index.dart';

/// Resolves a human-readable place name ("City, Country") for a photo from its
/// embedded GPS coordinates, reverse-geocoded via the platform geocoder.
/// Results (including "no place") are cached per item so it isn't re-fetched.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  final Map<String, String?> _cache = {};

  // ACCESS_MEDIA_LOCATION is a separate grant from the media-read permissions;
  // without it Android redacts GPS from MediaStore so latlngAsync() returns
  // null. Request it once, lazily, the first time a place is resolved.
  Future<void>? _mediaLocationGrant;
  Future<void> _ensureMediaLocation() {
    return _mediaLocationGrant ??= () async {
      try {
        if (!await Permission.accessMediaLocation.isGranted) {
          await Permission.accessMediaLocation.request();
        }
      } catch (_) {/* not Android, or unsupported — ignore */}
    }();
  }

  Future<String?> placeName(MediaEntry entry) async {
    final key = entry.assetId ?? entry.path;
    if (_cache.containsKey(key)) return _cache[key];
    String? result;
    try {
      final coords = await _coords(entry);
      if (coords != null) {
        result = await _geocode(coords.$1, coords.$2);
      }
    } catch (_) {
      // No geocoder backend / no network — leave it blank (don't cache so a
      // transient failure can be retried later).
      return null;
    }
    _cache[key] = result;
    return result;
  }

  /// Reads the photo's GPS via photo_manager (which transparently fetches the
  /// original when Android has redacted location from the MediaStore copy).
  Future<(double, double)?> _coords(MediaEntry entry) async {
    final id = entry.assetId;
    if (id == null) return null; // non-Android (filesystem) — skip for now
    final asset = MediaStoreIndex.instance.assetFor(entry);
    if (asset == null) return null;
    await _ensureMediaLocation();
    final ll = await asset.latlngAsync(); // null when the photo has no GPS
    if (ll == null) return null;
    return (ll.latitude, ll.longitude);
  }

  Future<String?> _geocode(double lat, double lng) async {
    final marks = await placemarkFromCoordinates(lat, lng);
    if (marks.isEmpty) return null;
    final m = marks.first;
    final city = _firstNonEmpty([
      m.locality,
      m.subAdministrativeArea,
      m.administrativeArea,
    ]);
    final parts = <String>[
      ?city,
      if (m.country != null && m.country!.isNotEmpty) m.country!,
    ];
    return parts.isEmpty ? null : parts.join(', ');
  }

  String? _firstNonEmpty(List<String?> values) {
    for (final v in values) {
      if (v != null && v.isNotEmpty) return v;
    }
    return null;
  }
}
