import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tv_gallery/core/remote.dart';
import 'package:tv_gallery/widgets/focusable.dart';

/// Wraps a child in the SAME shortcut/action configuration the real app uses
/// (see app.dart), so these tests reproduce the integration — in particular,
/// that overriding MaterialApp.shortcuts didn't break OK/Activate.
Widget appHarness(Widget child) {
  return MaterialApp(
    shortcuts: <ShortcutActivator, Intent>{
      ...WidgetsApp.defaultShortcuts,
      ...RemoteShortcuts.map,
    },
    actions: <Type, Action<Intent>>{
      ...WidgetsApp.defaultActions,
    },
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('Focusable fires onPressed on Enter, NumpadEnter and Space',
      (tester) async {
    var count = 0;
    await tester.pumpWidget(appHarness(
      Focusable(
        autofocus: true,
        onPressed: () => count++,
        builder: (_, focused) => Container(
          width: 120,
          height: 60,
          color: focused ? Colors.amber : Colors.blueGrey,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(count, 1, reason: 'Enter should activate');

    await tester.sendKeyEvent(LogicalKeyboardKey.numpadEnter);
    await tester.pump();
    expect(count, 2, reason: 'Numpad Enter should activate');

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(count, 3, reason: 'Space should activate');
  });

  testWidgets('Focusable fires onPressed on tap', (tester) async {
    var count = 0;
    await tester.pumpWidget(appHarness(
      Focusable(
        onPressed: () => count++,
        builder: (_, _) => const SizedBox(width: 120, height: 60),
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Focusable));
    await tester.pump();
    expect(count, 1);
  });

  testWidgets('Arrow keys move focus between two Focusables', (tester) async {
    final a = FocusNode(debugLabel: 'a');
    final b = FocusNode(debugLabel: 'b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    await tester.pumpWidget(appHarness(
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Focusable(
            focusNode: a,
            autofocus: true,
            onPressed: () {},
            builder: (_, _) => const SizedBox(width: 120, height: 60),
          ),
          const SizedBox(width: 20),
          Focusable(
            focusNode: b,
            onPressed: () {},
            builder: (_, _) => const SizedBox(width: 120, height: 60),
          ),
        ],
      ),
    ));
    await tester.pumpAndSettle();
    expect(a.hasFocus, true);
    expect(b.hasFocus, false);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(b.hasFocus, true, reason: 'D-pad Right should move focus to B');
  });
}
