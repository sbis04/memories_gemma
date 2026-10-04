import 'package:flutter/material.dart';

import 'core/app_theme.dart';
import 'core/remote.dart';
import 'core/resume.dart';
import 'core/transitions.dart';
import 'screens/source_screen.dart';
import 'services/settings_controller.dart';

class GalleryApp extends StatelessWidget {
  GalleryApp({super.key});

  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();
  final SettingsController _settings = SettingsController.instance;

  List<Route<dynamic>> _initialRoutes() => [
        FadeZoomPageRoute(child: const SourceScreen()),
        ...resumeRoutes(),
      ];

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) {
        return MaterialApp(
          title: 'Memories',
          debugShowCheckedModeBanner: false,
          navigatorKey: _navKey,
          theme: AppTheme.light(),
          darkTheme: AppTheme.dark(),
          themeMode: _settings.themeMode,
          shortcuts: <ShortcutActivator, Intent>{
            ...WidgetsApp.defaultShortcuts,
            ...RemoteShortcuts.map,
          },
          actions: <Type, Action<Intent>>{
            ...WidgetsApp.defaultActions,
            BackIntent: CallbackAction<BackIntent>(
              onInvoke: (_) {
                _navKey.currentState?.maybePop();
                return null;
              },
            ),
          },
          onGenerateInitialRoutes: (_) => _initialRoutes(),
          onGenerateRoute: (settings) =>
              FadeZoomPageRoute(child: const SourceScreen(), settings: settings),
          // TVs report a small logical resolution, so default text reads large.
          // Scale all text down for a denser, more refined look.
          builder: (context, child) {
            final mq = MediaQuery.of(context);
            return MediaQuery(
              data: mq.copyWith(textScaler: const TextScaler.linear(0.82)),
              child: child!,
            );
          },
        );
      },
    );
  }
}
