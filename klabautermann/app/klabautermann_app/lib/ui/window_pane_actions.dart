import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToastIn;

import '../controllers/window_panes.dart';
import '../l10n/app_localizations.dart';

/// The suite's pane-toggle chords (common.md): ⌃⌘S and ⌥⌘I on Apple
/// platforms, Ctrl+Alt+S and Ctrl+Alt+I elsewhere. The command registry
/// binds the same activators, and the toggle buttons show them in their
/// tooltips, so menu, key and hint cannot drift.
ShortcutActivator windowPaneChord(WindowPane pane, TargetPlatform platform) =>
    switch (platform) {
      TargetPlatform.macOS || TargetPlatform.iOS => switch (pane) {
        WindowPane.sidebar => const SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
          meta: true,
        ),
        WindowPane.inspector => const SingleActivator(
          LogicalKeyboardKey.keyI,
          alt: true,
          meta: true,
        ),
      },
      _ => switch (pane) {
        WindowPane.sidebar => const SingleActivator(
          LogicalKeyboardKey.keyS,
          control: true,
          alt: true,
        ),
        WindowPane.inspector => const SingleActivator(
          LogicalKeyboardKey.keyI,
          control: true,
          alt: true,
        ),
      },
    };

/// Shows or hides [pane] through [panes] the way the buttons and the
/// commands do: a change that applied but was not saved shows the same
/// toast fleet density's failed save does.
Future<void> toggleWindowPane(
  BuildContext context,
  WindowPanesController panes,
  WindowPane pane,
) async {
  try {
    await panes.toggle(pane);
  } on WindowPanesNotSavedException {
    if (context.mounted) {
      showTopToastIn(
        context,
        message: AppLocalizations.of(context).windowPanesNotSaved,
      );
    }
  }
}
