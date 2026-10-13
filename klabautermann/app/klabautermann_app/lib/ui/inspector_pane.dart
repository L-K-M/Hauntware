import 'package:flutter/material.dart';

import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';

/// The desktop inspector of 03 §10.2: Details, Alerts (v1), Operations,
/// Coverage and Audit sections, empty until a server is selected.
class InspectorPane extends StatelessWidget {
  const InspectorPane({super.key, required this.fleet});

  final FleetController fleet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.inspectorTitle, style: theme.textTheme.titleSmall),
            const SizedBox(height: 12),
            // The inspector fills in as link phases and operations arrive;
            // it listens for its own concern only (03 §10.1).
            Expanded(
              child: ListenableBuilder(
                listenable: fleet,
                builder: (context, _) => const InspectorEmptyBody(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The inspector's empty body, also the panels' placeholder until their
/// subsystems land.
class InspectorEmptyBody extends StatelessWidget {
  const InspectorEmptyBody({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Text(
      l10n.inspectorEmptyBody,
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}

/// The generic placeholder for surfaces whose milestone has not landed.
class PlaceholderPaneBody extends StatelessWidget {
  const PlaceholderPaneBody({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Center(
      child: Text(
        l10n.placeholderMilestone,
        style: Theme.of(context).textTheme.bodyMedium,
      ),
    );
  }
}
