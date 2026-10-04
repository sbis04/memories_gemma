import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import 'focusable.dart';

/// A pill / circular icon button that works with both the remote and a mouse.
class IconFocusButton extends StatelessWidget {
  const IconFocusButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.label,
    this.autofocus = false,
    this.enabled = true,
    this.focusNode,
  });

  final IconData icon;
  final String? label;
  final VoidCallback onPressed;
  final bool autofocus;
  final bool enabled;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    if (!enabled) {
      return Opacity(
        opacity: 0.35,
        child: _pill(c, false, focusedAllowed: false),
      );
    }
    return Focusable(
      autofocus: autofocus,
      focusNode: focusNode,
      onPressed: onPressed,
      builder: (context, focused) => _pill(c, focused),
    );
  }

  Widget _pill(GalleryColors c, bool focused, {bool focusedAllowed = true}) {
    final hasLabel = label != null;
    final fg = focused ? c.onAccent : c.textPrimary;
    return AnimatedContainer(
      duration: AppTheme.focusAnim,
      curve: AppTheme.emphasized,
      height: 40,
      padding: EdgeInsets.symmetric(horizontal: hasLabel ? 15 : 0),
      width: hasLabel ? null : 40,
      decoration: BoxDecoration(
        color: focused ? c.accent : c.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: focused ? c.accent : c.hairline,
          width: 1.5,
        ),
        boxShadow: focused ? c.focusGlow(intensity: 0.6) : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: fg),
          if (hasLabel) ...[
            const SizedBox(width: 9),
            Text(
              label!,
              style: TextStyle(
                color: fg,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
