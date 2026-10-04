import 'package:flutter/material.dart';

import 'app_theme.dart';

/// A page route that fades and gently zooms the incoming page in, while the
/// outgoing page fades and zooms slightly away — giving every screen change a
/// soft, cinematic feel suited to a TV.
class FadeZoomPageRoute<T> extends PageRouteBuilder<T> {
  FadeZoomPageRoute({required this.child, super.settings})
      : super(
          transitionDuration: AppTheme.pageTransition,
          reverseTransitionDuration: AppTheme.pageTransition,
          opaque: false,
          pageBuilder: (context, animation, secondaryAnimation) => child,
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: AppTheme.emphasized,
              reverseCurve: Curves.easeInCubic,
            );
            final secondary = CurvedAnimation(
              parent: secondaryAnimation,
              curve: AppTheme.emphasized,
              reverseCurve: Curves.easeInCubic,
            );

            // Incoming: fade 0->1, scale 0.92->1.
            final inScale = Tween<double>(begin: 0.92, end: 1.0).animate(curved);
            // Outgoing: fade 1->0, scale 1->1.06 (recedes).
            final outScale =
                Tween<double>(begin: 1.0, end: 1.06).animate(secondary);
            final outFade =
                Tween<double>(begin: 1.0, end: 0.0).animate(secondary);

            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: inScale,
                child: FadeTransition(
                  opacity: outFade,
                  child: ScaleTransition(scale: outScale, child: child),
                ),
              ),
            );
          },
        );

  final Widget child;
}
