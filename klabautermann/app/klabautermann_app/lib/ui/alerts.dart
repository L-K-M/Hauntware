import 'dart:async';

import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/alert_center.dart';
import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';
import 'alert_rules.dart';
import 'charts/charts.dart';

/// Hands the [AlertCenter] to the fleet rows' badges and the fleet list's
/// notice; without one, as in tests that leave alerts out, neither shows.
class AlertScope extends InheritedNotifier<AlertCenter> {
  const AlertScope({
    super.key,
    required AlertCenter alerts,
    required super.child,
  }) : super(notifier: alerts);

  static AlertCenter? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AlertScope>()?.notifier;
}

/// The words for a rule's [metric] id; one this version does not know
/// shows its id.
String alertMetricName(AppLocalizations l10n, String metric) =>
    switch (AlertMetric.byId(metric)) {
      AlertMetric.cpuBusy => l10n.alertMetricCpuBusy,
      AlertMetric.memoryUsed => l10n.alertMetricMemoryUsed,
      AlertMetric.loadPerCore => l10n.alertMetricLoadPerCore,
      AlertMetric.diskUsed => l10n.alertMetricDiskUsed,
      AlertMetric.diskInodes => l10n.alertMetricDiskInodes,
      null => metric,
    };

/// [value] of [metric] in the UI locale: a percentage, or a load per core
/// with two decimals; null for a metric this version does not know.
String? alertValueText(AppLocalizations l10n, String metric, double value) =>
    switch (AlertMetric.byId(metric)) {
      AlertMetric.loadPerCore => l10n.overviewLoadValue(value),
      null => null,
      _ => l10n.chartPercent(value / 100),
    };

/// The icon of [severity]: a shape apiece, so the badge and the rows never
/// rely on colour alone (A11Y-01).
IconData alertSeverityIcon(AlertSeverity severity) => switch (severity) {
  AlertSeverity.critical => Icons.error_outline,
  AlertSeverity.warning => Icons.warning_amber_rounded,
  AlertSeverity.info => Icons.info_outline,
};

/// The tint of [severity], the charts' warning and critical colours.
Color alertSeverityColor(BuildContext context, AlertSeverity severity) {
  final palette = ChartPalette.of(context);
  return switch (severity) {
    AlertSeverity.critical => palette.critical,
    AlertSeverity.warning => palette.warning,
    AlertSeverity.info => Theme.of(context).colorScheme.onSurfaceVariant,
  };
}

/// A fleet row's alert badge (ALR-02): the icon of the server's highest
/// raised severity and how many alerts are raised. The row's label and
/// tooltip say the count, so the badge stays out of the semantics tree.
class AlertBadge extends StatelessWidget {
  const AlertBadge({super.key, required this.count, required this.severity});

  final int count;
  final AlertSeverity severity;

  static const double iconSize = 14;
  static const double gap = 2;

  /// The count's style, which the row measures the badge with.
  static TextStyle? textStyle(BuildContext context) =>
      Theme.of(context).textTheme.labelMedium?.copyWith(
        fontWeight: FontWeight.w600,
        fontFeatures: const [FontFeature.tabularFigures()],
      );

  @override
  Widget build(BuildContext context) {
    final color = alertSeverityColor(context, severity);
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: gap,
      children: [
        Icon(alertSeverityIcon(severity), size: iconSize, color: color),
        Text(
          AppLocalizations.of(context).alertsBadgeCount(count),
          maxLines: 1,
          softWrap: false,
          style: textStyle(context)?.copyWith(color: color),
        ),
      ],
    );
  }
}

/// The fleet list's alert notice: shown while an alert is raised, or when
/// alerts came and went since the user last opened the alert center. It
/// states the coverage limit (Y3) and opens the alert center.
class AlertsNotice extends StatelessWidget {
  const AlertsNotice({super.key, required this.fleet, this.onOpenServer});

  final FleetController fleet;

  /// Opens a server from the alert center's rows; null leaves them inert.
  final void Function(FleetServer server)? onOpenServer;

  @override
  Widget build(BuildContext context) {
    final alerts = AlertScope.maybeOf(context);
    if (alerts == null) return const SizedBox.shrink();
    final active = alerts.active;
    if (active.isEmpty && alerts.unseen == 0) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final severity = active.isEmpty ? null : active.first.severity;
    return Material(
      color: colors.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 8, 8, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 12,
              children: [
                Icon(
                  severity == null
                      ? Icons.check_circle_outline
                      : alertSeverityIcon(severity),
                  color: severity == null
                      ? colors.onSurfaceVariant
                      : alertSeverityColor(context, severity),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 2,
                    children: [
                      // A state change, which screen readers hear
                      // (A11Y-15).
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          active.isEmpty
                              ? l10n.alertsNoticeCleared
                              : l10n.alertsNoticeActive(active.length),
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      Text(
                        l10n.alertsCoverage,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: () => unawaited(
                  showAlertCenter(
                    context,
                    alerts: alerts,
                    fleet: fleet,
                    onOpenServer: onOpenServer,
                  ),
                ),
                child: Text(l10n.alertsShow),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The widest the alert center grows on a wide window.
const double _dialogMaxWidth = 560;

/// Opens the alert center over [context] and marks its history seen.
Future<void> showAlertCenter(
  BuildContext context, {
  required AlertCenter alerts,
  required FleetController fleet,
  void Function(FleetServer server)? onOpenServer,
}) {
  alerts.markSeen();
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
        child: AlertCenterView(
          alerts: alerts,
          fleet: fleet,
          onOpenServer: onOpenServer == null
              ? null
              : (server) {
                  Navigator.of(dialogContext).pop();
                  onOpenServer(server);
                },
        ),
      ),
    ),
  );
}

/// The alert center (ALR-01): the raised alerts, then the latest raises
/// and clears, under the coverage limit (Y3). It follows [alerts] while
/// open, keeping new transitions seen.
class AlertCenterView extends StatelessWidget {
  const AlertCenterView({
    super.key,
    required this.alerts,
    required this.fleet,
    this.onOpenServer,
  });

  final AlertCenter alerts;
  final FleetController fleet;
  final void Function(FleetServer server)? onOpenServer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([alerts, fleet]),
      builder: (context, _) {
        // Whatever arrives while the center is open, the user sees here.
        if (alerts.unseen > 0) {
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => alerts.markSeen(),
          );
        }
        final active = alerts.active;
        final history = alerts.history;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(24, 24, 24, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 4,
                children: [
                  Semantics(
                    header: true,
                    child: Text(
                      l10n.alertsTitle,
                      style: theme.textTheme.headlineSmall,
                    ),
                  ),
                  Text(
                    l10n.alertsCoverage,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  _Heading(l10n.alertsActiveHeading),
                  if (active.isEmpty)
                    ListTile(title: Text(l10n.alertsNoneActive))
                  else
                    for (final alert in active) _activeRow(context, alert),
                  if (history.isNotEmpty) ...[
                    _Heading(l10n.alertsHistoryHeading),
                    for (final transition in history)
                      _historyRow(context, transition),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: OverflowBar(
                alignment: MainAxisAlignment.end,
                spacing: 8,
                children: [
                  if (AlertRulesScope.maybeOf(context) != null)
                    TextButton(
                      onPressed: () =>
                          unawaited(openAlertRules(context, fleet: fleet)),
                      child: Text(l10n.alertRulesTitle),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      MaterialLocalizations.of(context).closeButtonLabel,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  FleetServer? _server(String id) =>
      fleet.servers.where((server) => server.id == id).firstOrNull;

  Widget _activeRow(BuildContext context, ActiveAlert alert) {
    final l10n = AppLocalizations.of(context);
    final server = _server(alert.serverId);
    final value = alert.value;
    final detail = [
      l10n.alertSeverity(alert.severity.name),
      if (value != null) ?alertValueText(l10n, alert.metric, value),
      l10n.alertSince(_time(context, alert.since ?? alert.raisedAt)),
    ].join(l10n.fleetRowPartSeparator);
    return ListTile(
      leading: Icon(
        alertSeverityIcon(alert.severity),
        color: alertSeverityColor(context, alert.severity),
      ),
      title: Text(
        l10n.alertRowTitle(
          server?.displayName ?? alert.serverId,
          alertMetricName(l10n, alert.metric),
        ),
      ),
      subtitle: Text(detail),
      onTap: _opener(server),
    );
  }

  Widget _historyRow(BuildContext context, AlertTransition transition) {
    final l10n = AppLocalizations.of(context);
    final server = _server(transition.serverId);
    final time = _time(context, transition.at);
    final value = transition.value;
    final detail = [
      transition.raised ? l10n.alertRaisedAt(time) : l10n.alertClearedAt(time),
      if (value != null) ?alertValueText(l10n, transition.metric, value),
    ].join(l10n.fleetRowPartSeparator);
    return ListTile(
      leading: transition.raised
          ? Icon(
              alertSeverityIcon(transition.severity),
              color: alertSeverityColor(context, transition.severity),
            )
          : Icon(
              Icons.check_circle_outline,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
      title: Text(
        l10n.alertRowTitle(
          server?.displayName ?? transition.serverId,
          alertMetricName(l10n, transition.metric),
        ),
      ),
      subtitle: Text(detail),
      onTap: _opener(server),
    );
  }

  VoidCallback? _opener(FleetServer? server) {
    final open = onOpenServer;
    if (open == null || server == null) return null;
    return () => open(server);
  }

  static String _time(BuildContext context, DateTime at) =>
      MaterialLocalizations.of(
        context,
      ).formatTimeOfDay(TimeOfDay.fromDateTime(at.toLocal()));
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(24, 12, 24, 4),
      child: Semantics(
        header: true,
        child: Text(
          text,
          style: theme.textTheme.titleSmall?.copyWith(
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }
}
