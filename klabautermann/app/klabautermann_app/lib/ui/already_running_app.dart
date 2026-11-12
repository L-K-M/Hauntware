import 'package:flutter/material.dart';
import 'package:ghost_theme/ghost_theme.dart' show AppAppearance, GhostTheme;

import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';

/// The whole app of a second desktop instance (03 §4.10): another instance
/// holds the support directory's lock, so this one opened no settings,
/// started no engine, and only says so until the user quits it.
class AlreadyRunningApp extends StatelessWidget {
  const AlreadyRunningApp({super.key, required this.onQuit});

  /// Ends this process; closing the window does too.
  final VoidCallback onQuit;

  @override
  Widget build(BuildContext context) {
    // The brand preset following the system: the stored appearance is in
    // settings.json, which only the instance holding the lock reads.
    final themes = GhostTheme.forAppearance(
      klabautermannThemeStyle,
      AppAppearance(palette: klabautermannThemePresets.initial),
    );
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: themes.theme,
      darkTheme: themes.darkTheme,
      themeMode: themes.themeMode,
      home: Builder(
        builder: (context) {
          final l10n = AppLocalizations.of(context);
          return _StartupStop(
            title: l10n.alreadyRunningTitle,
            body: l10n.alreadyRunningBody,
            quit: l10n.alreadyRunningQuit,
            onQuit: onQuit,
          );
        },
      ),
    );
  }
}

/// The whole app of a desktop launch whose engine isolate did not start
/// (03 §10.1): the window is already shown, so it says why instead of
/// staying blank, until the user quits.
class EngineFailedApp extends StatelessWidget {
  const EngineFailedApp({
    super.key,
    required this.detail,
    required this.onQuit,
  });

  /// What the engine start failed with, for a bug report.
  final String detail;

  /// Ends this process; closing the window does too.
  final VoidCallback onQuit;

  @override
  Widget build(BuildContext context) {
    // The brand preset following the system, as [AlreadyRunningApp] does:
    // the stored appearance needs controllers this launch never built.
    final themes = GhostTheme.forAppearance(
      klabautermannThemeStyle,
      AppAppearance(palette: klabautermannThemePresets.initial),
    );
    return MaterialApp(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: themes.theme,
      darkTheme: themes.darkTheme,
      themeMode: themes.themeMode,
      home: Builder(
        builder: (context) {
          final l10n = AppLocalizations.of(context);
          return _StartupStop(
            title: l10n.engineFailedTitle,
            body: l10n.engineFailedBody,
            detail: l10n.engineFailedDetail(detail),
            quit: l10n.engineFailedQuit,
            onQuit: onQuit,
          );
        },
      ),
    );
  }
}

/// A launch that goes no further: [title], [body], an optional [detail]
/// and a Quit button.
class _StartupStop extends StatelessWidget {
  const _StartupStop({
    required this.title,
    required this.body,
    this.detail,
    required this.quit,
    required this.onQuit,
  });

  final String title;
  final String body;
  final String? detail;
  final String quit;
  final VoidCallback onQuit;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Scrolls when large text outgrows a small window (A11Y-09), so the
      // Quit button stays reachable.
      body: Center(
        child: SingleChildScrollView(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(body, textAlign: TextAlign.center),
                  if (detail case final detail?) ...[
                    const SizedBox(height: 12),
                    SelectableText(
                      detail,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 24),
                  // Focused, so Enter or Space quits without a pointer.
                  FilledButton(
                    autofocus: true,
                    onPressed: onQuit,
                    child: Text(quit),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
