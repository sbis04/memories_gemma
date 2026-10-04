import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_theme.dart';

typedef FocusedBuilder = Widget Function(BuildContext context, bool focused);

/// A D-pad / keyboard focusable element that reports its focus state to a
/// builder so each call site can render its own focus treatment. Hovering with
/// a mouse also moves focus, so the app is fully usable with a trackpad while
/// testing on macOS.
class Focusable extends StatefulWidget {
  const Focusable({
    super.key,
    required this.builder,
    required this.onPressed,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
    this.requestFocusOnHover = true,
    this.scrollAlignment = 0.5,
    this.focusScale = 1.06,
    this.onLongPress,
  });

  final FocusedBuilder builder;
  final VoidCallback onPressed;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;
  final bool requestFocusOnHover;

  /// When focused inside a scroll view, scroll so the item sits at this
  /// fraction of the viewport (0.5 = centred). Keeps the focus ring/glow off
  /// the viewport edges so it's never clipped. Ignored when not scrollable.
  final double scrollAlignment;

  /// Scale applied while focused (1.0 for full-width rows that can't grow).
  final double focusScale;

  /// Fired when OK is held (the remote sends key repeats) or on a long tap.
  /// When set, a short OK press activates on key-up instead of key-down, so
  /// the two can be told apart.
  final VoidCallback? onLongPress;

  @override
  State<Focusable> createState() => _FocusableState();
}

class _FocusableState extends State<Focusable> {
  FocusNode? _internal;
  bool _focused = false;

  FocusNode get _node => widget.focusNode ?? (_internal ??= FocusNode());

  // OK-key state for telling a press from a hold (see [Focusable.onLongPress]).
  bool _okHeld = false;
  bool _longFired = false;

  static final _okKeys = {
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.space,
    LogicalKeyboardKey.gameButtonA,
  };

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (!_okKeys.contains(event.logicalKey)) return KeyEventResult.ignored;
    final onLongPress = widget.onLongPress;
    if (onLongPress == null) {
      // A held OK never re-activates: e.g. the menu opened by a long press
      // must not take the still-held key as a choice.
      return event is KeyRepeatEvent
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }
    switch (event) {
      case KeyDownEvent():
        _okHeld = true;
        _longFired = false;
      case KeyRepeatEvent():
        if (_okHeld && !_longFired) {
          _longFired = true;
          onLongPress();
        }
      case KeyUpEvent():
        // A key-up without our key-down (focus arrived mid-press) is ignored.
        if (_okHeld && !_longFired) widget.onPressed();
        _okHeld = false;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _internal?.dispose();
    super.dispose();
  }

  void _setFocused(bool v) {
    if (_focused == v) return;
    setState(() => _focused = v);
    widget.onFocusChange?.call(v);
    if (v) _scrollIntoView();
  }

  void _scrollIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Only scroll if we're actually inside a scroll view.
      if (Scrollable.maybeOf(context) == null) return;
      Scrollable.ensureVisible(
        context,
        alignment: widget.scrollAlignment,
        alignmentPolicy: ScrollPositionAlignmentPolicy.explicit,
        duration: AppTheme.focusAnim,
        curve: AppTheme.emphasized,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    // An ancestor Focus sees the focused node's key events before the app's
    // shortcuts (which would activate on key-down) and splits press vs hold.
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: _detector(),
    );
  }

  Widget _detector() {
    return FocusableActionDetector(
      focusNode: _node,
      autofocus: widget.autofocus,
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: _setFocused,
      onShowHoverHighlight: (hovering) {
        if (hovering && widget.requestFocusOnHover && !_node.hasFocus) {
          _node.requestFocus();
        }
      },
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed();
            return null;
          },
        ),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          _node.requestFocus();
          widget.onPressed();
        },
        onLongPress: widget.onLongPress,
        child: AnimatedScale(
          scale: _focused ? widget.focusScale : 1.0,
          duration: AppTheme.focusAnim,
          curve: AppTheme.emphasized,
          child: widget.builder(context, _focused),
        ),
      ),
    );
  }
}
