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
      home: _AlreadyRunning(onQuit: onQuit),
    );
  }
}

class _AlreadyRunning extends StatelessWidget {
  const _AlreadyRunning({required this.onQuit});

  final VoidCallback onQuit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
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
                      l10n.alreadyRunningTitle,
                      style: Theme.of(context).textTheme.headlineSmall,
                      textAlign: TextAlign.center,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(l10n.alreadyRunningBody, textAlign: TextAlign.center),
                  const SizedBox(height: 24),
                  // Focused, so Enter or Space quits without a pointer.
                  FilledButton(
                    autofocus: true,
                    onPressed: onQuit,
                    child: Text(l10n.alreadyRunningQuit),
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
