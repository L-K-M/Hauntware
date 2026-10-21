import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../l10n/app_localizations.dart';
import '../services/hand_off.dart';

/// Puts the hand-off launcher in reach of the surfaces that offer
/// hand-offs (X-03, X-04, X-10). Without one, none is offered.
class HandOffScope extends InheritedWidget {
  const HandOffScope({super.key, required this.launcher, required super.child});

  final HandOffLauncher launcher;

  static HandOffLauncher? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HandOffScope>()?.launcher;

  @override
  bool updateShouldNotify(HandOffScope oldWidget) =>
      !identical(launcher, oldWidget.launcher);
}

/// The server header's "Open terminal in Séance" (X-03). Hidden where
/// Séance has no intake or handler, and for a server Séance could not name
/// (an ssh_config import, whose id only this app knows).
class OpenInSeanceButton extends StatelessWidget {
  const OpenInSeanceButton({super.key, required this.serverId});

  final String serverId;

  @override
  Widget build(BuildContext context) {
    final launcher = HandOffScope.maybeOf(context);
    final link = seanceHandOff(serverId);
    if (launcher == null ||
        link == null ||
        !launcher.available(HandOffTarget.seance)) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    return TextButton.icon(
      onPressed: () => unawaited(_open(context, launcher, link)),
      icon: const Icon(Icons.terminal, size: 18),
      label: Text(l10n.handOffOpenInSeance),
    );
  }

  Future<void> _open(
    BuildContext context,
    HandOffLauncher launcher,
    Uri link,
  ) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final notOpened = AppLocalizations.of(context).handOffSeanceNotOpened;
    var opened = false;
    try {
      opened = await launcher.open(link);
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
    if (!opened && overlay.mounted) showTopToast(overlay, message: notOpened);
  }
}
