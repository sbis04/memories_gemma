import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../core/app_theme.dart';
import '../core/resume.dart';
import '../core/transitions.dart';
import '../services/android_files.dart';
import '../services/media_scanner.dart';
import '../services/media_store_index.dart';
import '../services/settings_controller.dart';
import '../services/storage_access.dart';
import '../widgets/focusable.dart';
import 'browser_screen.dart';

/// First screen: pick the media source. Requests storage access gracefully on
/// Android (so testing on a TV isn't blocked) and lists available volumes.
/// Content fades and gently zooms in on entry.
class SourceScreen extends StatefulWidget {
  const SourceScreen({super.key, this.debugVolumePaths});

  /// Test seam: when provided, these paths are used instead of discovering
  /// volumes, so the screen renders deterministically in golden tests.
  final List<String>? debugVolumePaths;

  @override
  State<SourceScreen> createState() => _SourceScreenState();
}

class _SourceScreenState extends State<SourceScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(
    vsync: this,
    duration: AppTheme.fade,
  )..forward();

  List<StorageVolume> _volumes = const [];
  bool _loading = true;
  bool _needsPermission = false;
  bool _permanentlyDenied = false;
  Timer? _driveWait;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _driveWait?.cancel();
    _intro.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    if (widget.debugVolumePaths != null) {
      setState(() {
        _volumes = widget.debugVolumePaths!
            .map((p) => StorageVolume(p, p.split('/').last))
            .toList();
        _loading = false;
      });
      return;
    }
    if (!await StorageAccess.hasAccess()) {
      if (mounted) {
        setState(() {
          _needsPermission = true;
          _loading = false;
        });
      }
      return;
    }
    await _loadVolumes();
  }

  Future<void> _loadVolumes() async {
    // Start building the media index now (access is already granted) so the
    // folder tree is ready by the time a source is picked.
    // (Not needed when the drives are read directly.)
    if (Platform.isAndroid && !AndroidFiles.granted) {
      unawaited(MediaStoreIndex.instance.build());
    }
    final vols = await StorageAccess.volumes();
    if (!mounted) return;
    setState(() {
      _volumes = vols;
      _needsPermission = false;
      _loading = false;
    });
    _waitForSavedDrive();
  }

  /// Opened by plugging the SSD in (or before it finished mounting): the drive
  /// shows up a second or two later. Keep checking for a short while, then
  /// resume straight into the last folder on it.
  void _waitForSavedDrive() {
    final source = SettingsController.instance.sourcePath;
    if (!Platform.isAndroid ||
        !AndroidFiles.granted ||
        source == null ||
        !AndroidFiles.isRealPath(source) ||
        _volumes.any((v) => v.path == source)) {
      return;
    }
    var ticks = 0;
    _driveWait?.cancel();
    _driveWait = Timer.periodic(const Duration(seconds: 1), (timer) async {
      if (!mounted || ++ticks > 20) {
        timer.cancel();
        return;
      }
      final vols = await StorageAccess.volumes();
      if (!mounted || !timer.isActive) return;
      setState(() => _volumes = vols);
      if (!vols.any((v) => v.path == source)) return;
      timer.cancel();
      // Only if nothing's been picked meanwhile (this screen still showing).
      if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
      final navigator = Navigator.of(context);
      for (final route in resumeRoutes()) {
        unawaited(navigator.push(route));
      }
    });
  }

  Future<void> _grant() async {
    final granted = await StorageAccess.request();
    if (!mounted) return;
    if (granted) {
      setState(() => _loading = true);
      await _loadVolumes();
    } else {
      final denied = await StorageAccess.isPermanentlyDenied();
      if (mounted) setState(() => _permanentlyDenied = denied);
    }
  }

  Future<void> _select(StorageVolume vol) async {
    _driveWait?.cancel();
    // On Android, browsing is backed by the MediaStore index — build it first.
    if (MediaScanner.instance.usesIndex(vol.path) &&
        !MediaStoreIndex.instance.isBuilt) {
      setState(() => _loading = true);
      final ok = await MediaStoreIndex.instance.build();
      if (!mounted) return;
      if (!ok) {
        setState(() {
          _loading = false;
          _needsPermission = true;
        });
        return;
      }
    }
    await SettingsController.instance.setSource(vol.path, label: vol.name);
    await _intro.reverse();
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      FadeZoomPageRoute(
        child: BrowserScreen(
            rootPath: vol.path, currentPath: vol.path, rootLabel: vol.name),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Container(
        decoration: c.backgroundDecoration,
        child: SafeArea(
          child: AnimatedBuilder(
            animation: _intro,
            builder: (context, child) {
              final t = Curves.easeOutCubic.transform(_intro.value);
              return Opacity(
                opacity: t,
                child: Transform.scale(scale: 0.96 + 0.04 * t, child: child),
              );
            },
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(LucideIcons.image, size: 38, color: c.textSecondary),
                    const SizedBox(height: 22),
                    Text(
                      'Your Memories',
                      style: TextStyle(
                        fontFamily: AppTheme.displayFont,
                        color: c.textPrimary,
                        fontSize: 68,
                        height: 1.0,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _needsPermission
                          ? 'Allow access to browse your photos and videos'
                          : 'Choose where your photos and videos live',
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 18,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 48),
                    if (_loading)
                      const CircularProgressIndicator()
                    else if (_needsPermission)
                      _PermissionPanel(
                        permanentlyDenied: _permanentlyDenied,
                        onGrant: _grant,
                        onOpenSettings: StorageAccess.openSettings,
                      )
                    else
                      _buildVolumeGrid(c),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVolumeGrid(GalleryColors c) {
    if (_volumes.isEmpty) {
      return Column(
        children: [
          Text('No storage volumes found',
              style: TextStyle(color: c.textFaint, fontSize: 16)),
          const SizedBox(height: 16),
          _RetryButton(onTap: _loadVolumes),
        ],
      );
    }
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 22,
      runSpacing: 22,
      children: [
        for (var i = 0; i < _volumes.length; i++)
          _SourceCard(
            volume: _volumes[i],
            autofocus: i == 0,
            onOpen: () => _select(_volumes[i]),
          ),
      ],
    );
  }
}

class _SourceCard extends StatelessWidget {
  const _SourceCard({
    required this.volume,
    required this.onOpen,
    this.autofocus = false,
  });

  final StorageVolume volume;
  final VoidCallback onOpen;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isLibrary = volume.path == StorageAccess.androidLibraryRoot;
    final icon = isLibrary
        ? LucideIcons.images
        : volume.isHome
            ? LucideIcons.house
            : volume.isPrimary
                ? LucideIcons.hardDrive
                : LucideIcons.usb;
    final subtitle = isLibrary
        ? (AndroidFiles.granted
            ? 'Android media library'
            : 'Everything on this TV & USB')
        : volume.isHome
            ? 'On this Mac'
            : volume.isPrimary
                ? 'Internal storage'
                : 'Removable drive';
    return Focusable(
      autofocus: autofocus,
      onPressed: onOpen,
      builder: (context, focused) {
        return AnimatedContainer(
          duration: AppTheme.focusAnim,
          curve: AppTheme.emphasized,
          width: 220,
          height: 158,
          padding: const EdgeInsets.all(22),
          decoration: BoxDecoration(
            color: focused ? c.accent : c.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: focused ? c.accent : c.hairline,
              width: 1.5,
            ),
            boxShadow: focused ? c.focusGlow() : null,
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 32, color: focused ? c.onAccent : c.textSecondary),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    volume.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: focused ? c.onAccent : c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: focused
                          ? c.onAccent.withValues(alpha: 0.75)
                          : c.textFaint,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PermissionPanel extends StatelessWidget {
  const _PermissionPanel({
    required this.permanentlyDenied,
    required this.onGrant,
    required this.onOpenSettings,
  });

  final bool permanentlyDenied;
  final VoidCallback onGrant;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Column(
      children: [
        Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
          decoration: BoxDecoration(
            color: c.surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: c.hairline),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.lockKeyhole, color: c.textSecondary, size: 22),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  permanentlyDenied
                      ? 'Storage access was denied. Enable “All files access” '
                          'for this app in Settings, then come back.'
                      : 'This app needs permission to read photos and videos '
                          'from your storage and connected drives.',
                  style: TextStyle(
                      color: c.textSecondary, fontSize: 15, height: 1.4),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        Focusable(
          autofocus: true,
          onPressed: permanentlyDenied ? onOpenSettings : onGrant,
          builder: (context, focused) => AnimatedContainer(
            duration: AppTheme.focusAnim,
            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 16),
            decoration: BoxDecoration(
              color: focused ? c.accent : c.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: focused ? c.accent : c.hairline, width: 1.5),
              boxShadow: focused ? c.focusGlow() : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  permanentlyDenied ? LucideIcons.settings : LucideIcons.check,
                  size: 20,
                  color: focused ? c.onAccent : c.textPrimary,
                ),
                const SizedBox(width: 10),
                Text(
                  permanentlyDenied ? 'Open Settings' : 'Grant access',
                  style: TextStyle(
                    color: focused ? c.onAccent : c.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Focusable(
      autofocus: true,
      onPressed: onTap,
      builder: (context, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 13),
        decoration: BoxDecoration(
          color: focused ? c.accent : c.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: focused ? c.accent : c.hairline, width: 1.5),
        ),
        child: Text('Retry',
            style: TextStyle(
                color: focused ? c.onAccent : c.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
      ),
    );
  }
}
