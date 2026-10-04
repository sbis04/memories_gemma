import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tv_gallery/core/remote.dart';

void main() {
  group('RemoteShortcuts', () {
    // SingleActivator is not value-equal as a map key, so match by trigger.
    Intent? lookup(LogicalKeyboardKey key) {
      for (final entry in RemoteShortcuts.map.entries) {
        final activator = entry.key;
        if (activator is SingleActivator && activator.trigger == key) {
          return entry.value;
        }
      }
      return null;
    }

    test('Back keys map to BackIntent', () {
      for (final key in [
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.delete,
        LogicalKeyboardKey.goBack,
        LogicalKeyboardKey.browserBack,
      ]) {
        expect(lookup(key), isA<BackIntent>(), reason: '$key should go Back');
      }
    });

    test('OK / Activate keys map to ActivateIntent', () {
      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.gameButtonA,
      ]) {
        expect(lookup(key), isA<ActivateIntent>(),
            reason: '$key should Activate');
      }
    });
  });
}
