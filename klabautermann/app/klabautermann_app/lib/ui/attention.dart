import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/alert_center.dart';
import '../controllers/attention.dart';
import '../controllers/docker_controller.dart' show DockerContainerList;
import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'alerts.dart' show AlertScope, alertMetricName;

/// The widest the attention queue grows on a wide window.
const double _dialogMaxWidth = 560;

/// The window width below which the queue opens as a bottom sheet.
const double _phoneMaxWidth = 600;

/// TRI-03's queue over the fleet as this device reads it: each server's
/// link, its raised alerts (from [AlertScope], when there is one) and the
/// mount, unit and container lists this run holds. [builder] gets the
/// scan and rebuilds as any of them changes; problems that cleared lose
/// their acknowledgements after the frame.
class _AttentionWatch extends StatelessWidget {
  const _AttentionWatch({
    required this.fleet,
    required this.monitoring,
    required this.builder,
  });

  final FleetController fleet;
  final MonitoringController monitoring;
  final Widget Function(BuildContext context, AttentionScan scan) builder;

  @override
  Widget build(BuildContext context) {
    final alerts = AlertScope.maybeOf(context);
    final acks = monitoring.attentionAcks;
    return ListenableBuilder(
      listenable: Listenable.merge([fleet, ?alerts, acks]),
      builder: (context, _) {
        final servers = fleet.servers;
        // Read on every build: a server that left the fleet and came back
        // has new listenables (SYN-08).
        final readings = {
          for (final server in servers)
            server.id: _Readings(monitoring, server.id),
        };
        return ListenableBuilder(
          listenable: Listenable.merge([
            for (final reading in readings.values) ...reading.all,
          ]),
          builder: (context, _) {
            final active = alerts?.active ?? const <ActiveAlert>[];
            final scan = scanAttention([
              for (final server in servers)
                readings[server.id]!.source(
                  link: fleet.linkStatusFor(server.id),
                  alerts: [
                    for (final alert in active)
                      if (alert.serverId == server.id) alert,
                  ],
                ),
            ]);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              acks.prune(scan);
            });
            return builder(context, scan);
          },
        );
      },
    );
  }
}

/// What the queue reads of one server from [MonitoringController].
final class _Readings {
  _Readings(MonitoringController monitoring, this.serverId)
    : fsLatest = monitoring.sampleFor(serverId, SampleStream.fs),
      fsListed = monitoring.lastReadingFor(serverId, SampleStream.fs),
      units = monitoring.lastReadingFor(serverId, SampleStream.failedUnits),
      containers = monitoring.docker.containersFor(serverId);

  final String serverId;
  final ValueListenable<Sample?> fsLatest, fsListed, units;
  final ValueListenable<DockerContainerList> containers;

  List<Listenable> get all => [fsLatest, fsListed, units, containers];

  AttentionSource source({
    required LinkStatus link,
    required List<ActiveAlert> alerts,
  }) => AttentionSource(
    serverId: serverId,
    link: link,
    alerts: alerts,
    // A failed latest `df` leaves every mount's use unknown.
    fs: fsLatest.value?.result is CollectorUnavailable
        ? null
        : switch (fsListed.value?.result) {
            FsResult(:final fs) => fs,
            _ => null,
          },
    failedUnits: switch (units.value?.result) {
      FailedUnitsResult(:final failed) => failed,
      _ => null,
    },
    containers: containers.value.containers,
  );
}

/// The fleet list's attention notice (TRI-03): shown while a problem asks
/// for attention, it counts them and opens the queue.
class AttentionNotice extends StatelessWidget {
  const AttentionNotice({
    super.key,
    required this.fleet,
    required this.monitoring,
    this.onOpenServer,
  });

  final FleetController fleet;
  final MonitoringController monitoring;

  /// Opens a server from the queue's rows; null leaves them inert.
  final void Function(FleetServer server)? onOpenServer;

  @override
  Widget build(BuildContext context) => _AttentionWatch(
    fleet: fleet,
    monitoring: monitoring,
    builder: (context, scan) {
      final acks = monitoring.attentionAcks;
      final open = scan.items.where((item) => acks.ackFor(item) == null);
      if (open.isEmpty) return const SizedBox.shrink();

      final l10n = AppLocalizations.of(context);
      final theme = Theme.of(context);
      final colors = theme.colorScheme;
      return Material(
        color: colors.surfaceContainerHigh,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 8, 4),
          child: Row(
            spacing: 12,
            children: [
              Icon(Icons.flag_outlined, color: colors.error),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    l10n.attentionNotice(open.length),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
              ),
              TextButton(
                onPressed: () => unawaited(
                  showAttention(
                    context,
                    fleet: fleet,
                    monitoring: monitoring,
                    onOpenServer: onOpenServer,
                  ),
                ),
                child: Text(l10n.attentionShow),
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Opens TRI-03's queue over [context]: a bottom sheet on phones, a
/// dialog on wider windows.
Future<void> showAttention(
  BuildContext context, {
  required FleetController fleet,
  required MonitoringController monitoring,
  void Function(FleetServer server)? onOpenServer,
}) {
  final style = MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null;
  Widget view(BuildContext sheetContext) => AttentionView(
    fleet: fleet,
    monitoring: monitoring,
    onOpenServer: onOpenServer == null
        ? null
        : (server) {
            Navigator.of(sheetContext).pop();
            onOpenServer(server);
          },
  );

  if (MediaQuery.sizeOf(context).width < _phoneMaxWidth) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      sheetAnimationStyle: style,
      builder: view,
    );
  }
  return showDialog<void>(
    context: context,
    animationStyle: style,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
        child: view(dialogContext),
      ),
    ),
  );
}

/// TRI-03's queue: the problems that ask for attention, then those
/// acknowledged, with when and the note. Acknowledging hides a problem
/// until it clears; acknowledgements stay on this device.
class AttentionView extends StatelessWidget {
  const AttentionView({
    super.key,
    required this.fleet,
    required this.monitoring,
    this.onOpenServer,
  });

  final FleetController fleet;
  final MonitoringController monitoring;
  final void Function(FleetServer server)? onOpenServer;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final acks = monitoring.attentionAcks;
    return _AttentionWatch(
      fleet: fleet,
      monitoring: monitoring,
      builder: (context, scan) {
        final open = [
          for (final item in scan.items)
            if (acks.ackFor(item) == null) item,
        ];
        final acknowledged = [
          for (final item in scan.items)
            if (acks.ackFor(item) case final ack?) (item, ack),
        ];
        FleetServer? serverOf(AttentionItem item) =>
            fleet.servers.where((s) => s.id == item.serverId).firstOrNull;

        return SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              Semantics(
                header: true,
                child: Text(
                  l10n.attentionTitle,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              Text(
                l10n.attentionIntro,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (open.isEmpty)
                Text(l10n.attentionNone)
              else
                for (final item in open)
                  _AttentionRow(
                    item: item,
                    server: serverOf(item),
                    onOpenServer: onOpenServer,
                    onAcknowledge: () =>
                        unawaited(_acknowledge(context, acks, item)),
                  ),
              if (acknowledged.isNotEmpty) ...[
                Semantics(
                  header: true,
                  child: Text(
                    l10n.attentionAcknowledgedHeading(acknowledged.length),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                for (final (item, ack) in acknowledged)
                  _AttentionRow(
                    item: item,
                    server: serverOf(item),
                    ack: ack,
                    onOpenServer: onOpenServer,
                    onReopen: () => unawaited(acks.reopen(item)),
                  ),
              ],
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(l10n.attentionClose),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Asks for an optional note, then acknowledges [item] with it.
  static Future<void> _acknowledge(
    BuildContext context,
    AttentionAcks acks,
    AttentionItem item,
  ) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => const _NoteDialog(),
    );
    if (note == null) return;
    await acks.acknowledge(item, note: note);
  }
}

class _AttentionRow extends StatelessWidget {
  const _AttentionRow({
    required this.item,
    required this.server,
    this.ack,
    this.onOpenServer,
    this.onAcknowledge,
    this.onReopen,
  });

  final AttentionItem item;
  final FleetServer? server;
  final AttentionAck? ack;
  final void Function(FleetServer server)? onOpenServer;
  final VoidCallback? onAcknowledge;
  final VoidCallback? onReopen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final server = this.server;
    final ack = this.ack;
    final open = onOpenServer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 2,
      children: [
        MergeSemantics(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 2,
            children: [
              Text(
                server?.displayName ?? item.serverId,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(_sentence(l10n), style: theme.textTheme.bodyMedium),
              if (ack != null) ...[
                Text(
                  l10n.attentionAcknowledgedAt(ack.at.toLocal()),
                  style: muted,
                ),
                if (ack.note.isNotEmpty) SelectableText(ack.note, style: muted),
              ],
            ],
          ),
        ),
        Wrap(
          spacing: 8,
          children: [
            if (onAcknowledge case final acknowledge?)
              TextButton(
                onPressed: acknowledge,
                child: Text(l10n.attentionAcknowledge),
              ),
            if (onReopen case final reopen?)
              TextButton(onPressed: reopen, child: Text(l10n.attentionReopen)),
            if (server != null && open != null)
              TextButton(
                onPressed: () => open(server),
                child: Text(l10n.attentionOpenServer),
              ),
          ],
        ),
      ],
    );
  }

  String _sentence(AppLocalizations l10n) {
    final subject = item.subject;
    return switch (item.kind) {
      AttentionKind.blocked => l10n.attentionBlocked,
      AttentionKind.unreachable => l10n.attentionUnreachable,
      AttentionKind.alert => l10n.attentionAlert(
        alertMetricName(l10n, item.alert!.metric),
      ),
      AttentionKind.failedUnit => l10n.attentionFailedUnit(subject!),
      AttentionKind.diskFull => l10n.attentionDiskFull(
        subject!,
        l10n.chartPercent((item.percent ?? 0) / 100),
      ),
      AttentionKind.inodesFull => l10n.attentionInodesFull(
        subject!,
        l10n.chartPercent((item.percent ?? 0) / 100),
      ),
      AttentionKind.unhealthyContainer => l10n.attentionUnhealthy(subject!),
    };
  }
}

/// Asks for an acknowledgement's note; pops it, possibly empty, or null
/// when cancelled.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog();

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  final _note = TextEditingController();

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l10n.attentionNoteTitle),
      content: TextField(
        controller: _note,
        autofocus: true,
        maxLength: kAttentionNoteMax,
        maxLines: 3,
        minLines: 1,
        decoration: InputDecoration(labelText: l10n.attentionNoteLabel),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.attentionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_note.text),
          child: Text(l10n.attentionAcknowledge),
        ),
      ],
    );
  }
}
