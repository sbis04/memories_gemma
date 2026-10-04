import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Tracks whether this widget's screen is the one being shown. Screens covered
/// by another route stay mounted but have their tickers disabled — that's the
/// signal used to pause background loading (folder counts, thumbnails) so the
/// folder on screen gets the drive to itself, and to resume on return.
mixin VisibilityGate<T extends StatefulWidget> on State<T> {
  ValueListenable<TickerModeData>? _ticker;

  bool get isVisible => _ticker?.value.enabled ?? true;

  /// Called when the screen is covered (false) or shown again (true).
  void onVisibilityChanged(bool visible);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final notifier = TickerMode.getValuesNotifier(context);
    if (!identical(notifier, _ticker)) {
      _ticker?.removeListener(_changed);
      _ticker = notifier..addListener(_changed);
      _changed();
    }
  }

  void _changed() => onVisibilityChanged(isVisible);

  @override
  void dispose() {
    _ticker?.removeListener(_changed);
    super.dispose();
  }
}
