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
  Widget build(BuildContext context) => HandOffButton(
    target: HandOffTarget.seance,
    link: seanceHandOff(serverId),
    icon: Icons.terminal,
    label: (l10n) => l10n.handOffOpenInSeance,
  );
}

/// Whether [FolderHandOffs] for [folder] on [serverId] shows anything,
/// so a layout that spaces its children leaves no gap where it would not.
bool folderHandOffsShown(
  BuildContext context, {
  required String serverId,
  required String folder,
}) {
  final launcher = HandOffScope.maybeOf(context);
  if (launcher == null) return false;
  return launcher.available(HandOffTarget.seance) &&
          seanceHandOff(serverId, folder: folder) != null ||
      launcher.available(HandOffTarget.poltergeist) &&
          poltergeistHandOff(serverId, path: folder) != null;
}

/// A folder's hand-offs (X-04, X-10): "Open terminal here" in Séance and
/// "Open in Poltergeist", each hidden where its app has no intake or
/// handler or could not name [folder] on [serverId]. Stack folders show
/// it beside the folder they name.
class FolderHandOffs extends StatelessWidget {
  const FolderHandOffs({
    super.key,
    required this.serverId,
    required this.folder,
  });

  final String serverId;
  final String folder;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      children: [
        HandOffButton(
          target: HandOffTarget.seance,
          link: seanceHandOff(serverId, folder: folder),
          icon: Icons.terminal,
          label: (l10n) => l10n.handOffOpenTerminalHere,
        ),
        HandOffButton(
          target: HandOffTarget.poltergeist,
          link: poltergeistHandOff(serverId, path: folder),
          icon: Icons.folder_open_outlined,
          label: (l10n) => l10n.handOffOpenInPoltergeist,
        ),
      ],
    );
  }
}

/// Opens [link] in [target]'s app. Hidden without a launcher in scope,
/// where [target] has no intake or handler, or when [link] is null: the
/// app could not name what it would open. A link the OS refuses says so
/// in a toast.
class HandOffButton extends StatelessWidget {
  const HandOffButton({
    super.key,
    required this.target,
    required this.link,
    required this.icon,
    required this.label,
  });

  final HandOffTarget target;
  final Uri? link;
  final IconData icon;

  /// The button's words, read only once it shows.
  final String Function(AppLocalizations l10n) label;

  @override
  Widget build(BuildContext context) {
    final launcher = HandOffScope.maybeOf(context);
    final link = this.link;
    if (launcher == null || link == null || !launcher.available(target)) {
      return const SizedBox.shrink();
    }
    return TextButton.icon(
      onPressed: () => unawaited(_open(context, launcher, link)),
      icon: Icon(icon, size: 18),
      label: Text(label(AppLocalizations.of(context))),
    );
  }

  Future<void> _open(
    BuildContext context,
    HandOffLauncher launcher,
    Uri link,
  ) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    final notOpened = switch (target) {
      HandOffTarget.seance => l10n.handOffSeanceNotOpened,
      HandOffTarget.poltergeist => l10n.handOffPoltergeistNotOpened,
    };
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
