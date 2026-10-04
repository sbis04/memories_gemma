import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Intent fired by the remote's Back button (and keyboard equivalents).
class BackIntent extends Intent {
  const BackIntent();
}

/// Intent to toggle play/pause in the viewer (remote OK / space on a video).
class PlayPauseIntent extends Intent {
  const PlayPauseIntent();
}

/// Maps keyboard keys to TV-remote semantics.
///
/// Sony Bravia / Google TV remote -> keyboard mapping used while testing on
/// macOS:
///   D-pad Up/Down/Left/Right -> Arrow keys (built-in directional focus)
///   OK / Select              -> Enter / Space  (built-in ActivateIntent)
///   Back                     -> Esc / Backspace / Delete
class RemoteShortcuts {
  RemoteShortcuts._();

  static final Map<ShortcutActivator, Intent> map =
      <ShortcutActivator, Intent>{
    // Back navigation.
    const SingleActivator(LogicalKeyboardKey.escape): const BackIntent(),
    const SingleActivator(LogicalKeyboardKey.backspace): const BackIntent(),
    const SingleActivator(LogicalKeyboardKey.delete): const BackIntent(),
    // Not the remote's Back key (goBack): Android already turns it into a
    // single route pop (onBackPressed → popRoute, honouring PopScope). Also
    // mapping it here popped twice per press — once on key-down via this
    // shortcut, and again when the unhandled key-up was redispatched to the
    // activity (FlutterView tracks the key, so onKeyUp → onBackPressed).
    // Activation (OK / Select). Bound explicitly so it works even when the
    // app's custom shortcut map replaces the framework defaults.
    const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.space): const ActivateIntent(),
    // TV remote OK button also reports as `select` on some platforms.
    const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
    const SingleActivator(LogicalKeyboardKey.gameButtonA):
        const ActivateIntent(),
  };
}
