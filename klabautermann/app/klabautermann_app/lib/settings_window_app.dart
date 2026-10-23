// The desktop settings window's whole app (D32). Its engine starts the same
// `main` as the app's with `settingsWindowArgument`, and `main` hands over
// to this instead of starting a second Klabautermann: no engine isolate
// (D18), no controllers, no stores and no sync. Everything it shows and
// changes crosses the settings link (services/settings_window/).
import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart' show AppAppearance, GhostTheme;

import 'l10n/app_localizations.dart';
import 'services/settings_window/remote_settings.dart';
import 'theme/app_theme.dart';
import 'ui/settings_page.dart';

/// Connects to the app over the link and runs the window's app, which says
/// so when no app answers.
Future<void> runSettingsWindow() async {
  RemoteSettings? remote;
  try {
    remote = await RemoteSettings.connect();
  } on Object catch (error, stackTrace) {
    // Started without the app to answer; the window says so. Reported too,
    // so a broken handshake is told apart from a window started by hand.
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stackTrace),
    );
  }
  runApp(SettingsWindowApp(remote: remote));
}

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key, required this.remote});

  /// Null when the app did not answer.
  final RemoteSettings? remote;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  /// Hands a request to quit the application to the app's isolate, which
  /// decides it: on macOS the newest engine answers the app delegate's
  /// termination question, and this one must not answer for the app.
  AppLifecycleListener? _exitRequests;

  @override
  void initState() {
    super.initState();
    final remote = widget.remote;
    if (remote != null) {
      _exitRequests = AppLifecycleListener(
        onExitRequested: remote.requestAppExit,
      );
    }
  }

  @override
  void dispose() {
    _exitRequests?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final remote = widget.remote;
    if (remote == null) {
      return _app(
        AppAppearance(palette: klabautermannThemePresets.initial),
        const _Unreachable(),
      );
    }
    // Outside the theme's builder, which then only swaps the MaterialApp's
    // themes: the screen showing is the one a change came from, and it
    // keeps its state through the re-theme.
    final home = ListenableBuilder(
      listenable: Listenable.merge([remote, remote.page]),
      builder: (context, _) {
        if (remote.lost) return const _Unreachable();
        final page = remote.page.value;
        return page == null
            // Hidden: no screen, so nothing on it outlives the window
            // being closed.
            ? const Scaffold()
            : SettingsPage(
                key: ValueKey(page.generation),
                appearance: remote.appearance,
                announcements: remote.announcements,
                appVersion: remote.appVersion,
                monitorSet: remote.monitorSet,
                safety: remote.safety,
                syncSecrets: remote.syncSecrets,
                initialTab: page.tab,
                tabRequests: remote.tabRequests,
              );
      },
    );
    // Drawn in the app's appearance, from the snapshots: the window is part
    // of the app, and the Appearance tab is judged by looking at it.
    return ListenableBuilder(
      listenable: remote.appearance,
      builder: (context, _) => _app(remote.appearance.value, home),
    );
  }

  static Widget _app(AppAppearance appearance, Widget home) {
    final themes = GhostTheme.forAppearance(
      klabautermannThemeStyle,
      appearance,
    );
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).settingsTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: themes.theme,
      darkTheme: themes.darkTheme,
      themeMode: themes.themeMode,
      home: home,
    );
  }
}

/// What the window shows when it has no app to talk to.
class _Unreachable extends StatelessWidget {
  const _Unreachable();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            AppLocalizations.of(context).settingsWindowUnreachable,
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
