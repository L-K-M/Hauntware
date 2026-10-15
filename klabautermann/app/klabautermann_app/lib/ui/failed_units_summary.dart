import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart' show SystemdUnit;

import '../l10n/app_localizations.dart';
import 'services_view.dart' show unitStatesOf;

/// SVC-02's failed units: how many, then each one's name with its sub
/// state, the closest the unit list comes to systemd's result (the
/// `Result` property needs `systemctl show`, SVC-08, v1). The Services
/// panel shows it over `UnitsSnapshot.failed`; the Overview's health card
/// (OV-02) is to show it over the `failedUnits` stream's list.
///
/// An icon of its own marks failure and its absence, beside the count in
/// words, so colour is never the only cue (A11Y-01).
class FailedUnitsSummary extends StatelessWidget {
  const FailedUnitsSummary({
    super.key,
    required this.failed,
    this.onUnitSelected,
    this.maxShown = 5,
  });

  final List<SystemdUnit> failed;

  /// Opens a unit; null lists the units as plain text.
  final ValueChanged<SystemdUnit>? onUnitSelected;

  /// How many units it names before "and N more".
  final int maxShown;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final none = failed.isEmpty;
    final color = none
        ? theme.colorScheme.onSurfaceVariant
        : theme.colorScheme.error;
    final hidden = failed.length - maxShown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          header: true,
          child: Row(
            children: [
              Icon(
                none ? Icons.check_circle_outline : Icons.error_outline,
                color: color,
                size: 20,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l10n.servicesFailedCount(failed.length),
                  style: theme.textTheme.titleSmall?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
        for (final unit in failed.take(maxShown))
          _FailedUnit(unit: unit, onSelected: onUnitSelected),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: 28, top: 4),
            child: Text(
              l10n.servicesFailedMore(hidden),
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

class _FailedUnit extends StatelessWidget {
  const _FailedUnit({required this.unit, required this.onSelected});

  final SystemdUnit unit;
  final ValueChanged<SystemdUnit>? onSelected;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final label = l10n.servicesFailedUnit(
      unit.unit,
      unitStatesOf(unit).sub ?? l10n.chartUnknownValue,
    );
    final onSelected = this.onSelected;
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 20),
      child: onSelected == null
          ? Padding(
              padding: const EdgeInsetsDirectional.only(start: 8, top: 4),
              child: Text(label),
            )
          : TextButton(
              onPressed: () => onSelected(unit),
              style: TextButton.styleFrom(
                alignment: AlignmentDirectional.centerStart,
              ),
              child: Text(label),
            ),
    );
  }
}
