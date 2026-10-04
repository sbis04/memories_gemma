import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:tv_gallery/core/app_theme.dart';
import 'package:tv_gallery/models/media_entry.dart';
import 'package:tv_gallery/screens/settings_screen.dart';
import 'package:tv_gallery/services/settings_controller.dart';
import 'package:tv_gallery/widgets/polaroid_folder_card.dart';

import 'test_fonts.dart';

Widget wrap(Widget child, {required bool dark}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: dark ? AppTheme.dark() : AppTheme.light(),
    home: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => loadAppFonts());
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('SettingsScreen golden (dark)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1180));
    await SettingsController.instance.load();
    await tester.pumpWidget(wrap(const SettingsScreen(), dark: true));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SettingsScreen),
      matchesGoldenFile('goldens/settings_dark.png'),
    );
  });

  testWidgets('SettingsScreen golden (light)', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1024, 1180));
    await SettingsController.instance.load();
    await tester.pumpWidget(wrap(const SettingsScreen(), dark: false));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(SettingsScreen),
      matchesGoldenFile('goldens/settings_light.png'),
    );
  });

  testWidgets('Empty folder card golden', (tester) async {
    await tester.binding.setSurfaceSize(
        const Size(PolaroidFolderCard.defaultWidth + 40, 320));
    final folder = MediaEntry(
      path: '/nonexistent/Holiday Trip',
      type: EntryType.folder,
      modified: DateTime(2024),
    );
    await tester.pumpWidget(wrap(
      Center(child: PolaroidFolderCard(folder: folder, onOpen: () {})),
      dark: true,
    ));
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(PolaroidFolderCard),
      matchesGoldenFile('goldens/folder_card_empty.png'),
    );
  });

}
