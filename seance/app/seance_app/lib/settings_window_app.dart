import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'services/settings_window.dart';
import 'theme.dart';
import 'theme/app_appearance.dart';
import 'ui/settings_screen.dart';

/// The settings window's whole app. Its engine starts the same `main` as the
/// app's with [settingsWindowArgument], and `main` hands over to this instead
/// of starting a second Séance: no services, no window-state tracking, no
/// menus — only the Settings screen over the app's state, reached through
/// the link.
Future<void> runSettingsWindow() async {
  RemoteSettingsBackend? backend;
  Object? error;
  try {
    backend = await RemoteSettingsBackend.connect();
  } catch (e) {
    error = e;
  }
  runApp(SettingsWindowApp(backend: backend, error: error));
}

class SettingsWindowApp extends StatefulWidget {
  const SettingsWindowApp({super.key, required this.backend, this.error});

  /// Null when the app did not answer, in which case [error] says why.
  final RemoteSettingsBackend? backend;
  final Object? error;

  @override
  State<SettingsWindowApp> createState() => _SettingsWindowAppState();
}

/// The macOS window's pane toolbar (SettingsPaneToolbar in the runner):
/// it asks for a pane with `select` and hears the one shown as `shown`.
const MethodChannel _paneChannel = MethodChannel('seance/settings_pane');

class _SettingsWindowAppState extends State<SettingsWindowApp> {
  /// Hands a request to quit the application to the app's isolate, which
  /// decides it: see [RemoteSettingsBackend.requestAppExit].
  AppLifecycleListener? _exitRequests;

  /// The tabs the screen is asked to show: the app's requests, and on
  /// macOS the toolbar's.
  final StreamController<SettingsTab> _tabRequests =
      StreamController.broadcast();
  StreamSubscription<SettingsTab>? _appRequests;

  bool get _nativePanes => Platform.isMacOS;

  @override
  void initState() {
    super.initState();
    final backend = widget.backend;
    if (backend != null) {
      _exitRequests = AppLifecycleListener(
        onExitRequested: backend.requestAppExit,
      );
      _appRequests = backend.tabRequests.listen(_tabRequests.add);
    }
    if (_nativePanes) {
      _paneChannel.setMethodCallHandler((call) async {
        final tab = SettingsTab.values.asNameMap()[call.arguments];
        if (call.method == 'select' && tab != null) _tabRequests.add(tab);
        return null;
      });
    }
  }

  @override
  void dispose() {
    _exitRequests?.dispose();
    unawaited(_appRequests?.cancel());
    unawaited(_tabRequests.close());
    if (_nativePanes) _paneChannel.setMethodCallHandler(null);
    super.dispose();
  }

  void _tabShown(SettingsTab tab) {
    if (!_nativePanes) return;
    unawaited(
      _paneChannel.invokeMethod<void>('shown', tab.name).catchError((_) {}),
    );
  }

  @override
  Widget build(BuildContext context) {
    final backend = widget.backend;
    final error = widget.error;
    if (backend == null) {
      return _app(
        seanceInitialAppearance,
        Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Settings could not reach Séance:\n$error'),
            ),
          ),
        ),
      );
    }
    // Outside the theme's builder, which then only swaps the MaterialApp's
    // themes: the screen showing is the one the edit came from, and it
    // keeps its state through the change.
    final home = ValueListenableBuilder<SettingsWindowPage?>(
      valueListenable: backend.page,
      builder: (context, page, _) => page == null
          // Hidden: no screen, so nothing typed into it outlives the
          // window being closed.
          ? const Scaffold()
          : SettingsScreen(
              key: ValueKey(page.generation),
              backend: backend,
              initialTab: page.tab,
              tabRequests: _tabRequests.stream,
              onTabShown: _tabShown,
              presentation: _nativePanes
                  ? SettingsPresentation.toolbarWindow
                  : SettingsPresentation.window,
            ),
    );
    // Drawn in the app's theme, from the snapshots: the window is part of
    // the app, and the Appearance tab is judged by looking at it.
    return ValueListenableBuilder<AppAppearance>(
      valueListenable: backend.appearance,
      builder: (context, appearance, _) => _app(appearance, home),
    );
  }

  static Widget _app(AppAppearance appearance, Widget home) {
    final themes = SeanceTheme.forAppearance(appearance);
    return MaterialApp(
      title: 'Séance Settings',
      theme: themes.theme,
      darkTheme: themes.darkTheme,
      themeMode: themes.themeMode,
      home: home,
    );
  }
}
