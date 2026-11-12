import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ghost_desktop/ghost_desktop.dart' show withMacosToolbarBand;

import '../l10n/app_localizations.dart';
import '../services/workspace_windows/window_titlebar.dart';
import '../services/workspace_windows/workspace_windows.dart';
import '../theme/app_appearance.dart';
import '../theme/app_theme.dart';

/// A document's navigator and theme live independently of the workspace
/// that opened it. Closing that workspace must not destroy its editor.
class EditorWindowApp extends StatelessWidget {
  const EditorWindowApp({super.key, required this.window, this.appearance});

  final WorkspaceWindow window;
  final ValueListenable<AppAppearance>? appearance;

  @override
  Widget build(BuildContext context) {
    final listenable = appearance;
    if (listenable == null) return _app(poltergeistInitialAppearance);
    return ValueListenableBuilder<AppAppearance>(
      valueListenable: listenable,
      builder: (context, value, _) => _app(value),
    );
  }

  Widget _app(AppAppearance appearance) {
    final themes = poltergeistThemesFor(appearance);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: window.navigatorKey,
      scaffoldMessengerKey: window.scaffoldMessengerKey,
      theme: themes.theme,
      darkTheme: themes.darkTheme,
      themeMode: themes.themeMode,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // Poltergeist's no-scope default is the windowed layout.
      builder: (context, child) => withMacosToolbarBand(
        defaultTargetPlatform == TargetPlatform.macOS
            ? WindowTitlebars.instance.bandFor(window.viewId)
            : null,
        windowedWithoutScope: true,
        child: child!,
      ),
      home: window.editorBuilder!(window),
    );
  }
}
