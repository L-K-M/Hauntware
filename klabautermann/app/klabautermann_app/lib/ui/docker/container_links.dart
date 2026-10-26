import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../l10n/app_localizations.dart';
import '../../services/hand_off.dart';
import '../hand_off_actions.dart' show HandOffScope;

/// CTR-11's links of a container, from [links]: each page its labels
/// point at, opened in the system browser where the app has a launcher,
/// and otherwise shown as text to copy.
class ContainerLinks extends StatelessWidget {
  const ContainerLinks({super.key, required this.links});

  final List<LabelLink> links;

  @override
  Widget build(BuildContext context) {
    final launcher = HandOffScope.maybeOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        for (final link in links) _LinkRow(link: link, launcher: launcher),
      ],
    );
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.link, required this.launcher});

  final LabelLink link;
  final HandOffLauncher? launcher;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final address = link.uri.toString();
    final title = link.name ?? address;
    final from = switch (link.port) {
      final port? => l10n.dockerLinksFromPort(link.source.name, port),
      null => l10n.dockerLinksFrom(link.source.name),
    };
    final launcher = this.launcher;
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (launcher == null) SelectableText(title) else Text(title),
                if (link.name != null)
                  Text(address, style: theme.textTheme.bodySmall),
                Text(
                  from,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          if (launcher != null)
            IconButton(
              tooltip: l10n.dockerLinksOpen(title),
              icon: const Icon(Icons.open_in_new),
              onPressed: () => unawaited(_open(context, launcher)),
            ),
        ],
      ),
    );
  }

  Future<void> _open(BuildContext context, HandOffLauncher launcher) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final notOpened = AppLocalizations.of(context).dockerLinksNotOpened;
    var opened = false;
    try {
      opened = await launcher.open(link.uri);
    } on Object catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
    if (!opened && overlay.mounted) showTopToast(overlay, message: notOpened);
  }
}
