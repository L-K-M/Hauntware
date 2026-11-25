import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show ghostIsDesktopPlatform;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import 'actions/action_entry.dart' show ActionEntryPoint, actionsAllowedAt;
import 'actions/host_actions.dart';
import 'freshness.dart';
import 'latest_read.dart';
import 'panel_kit.dart';
import 'process_detail_view.dart';
import 'processes_view.dart';
import 'sortable_table.dart';
import 'timed_reveal.dart';

/// How old a `procs` reading grows before it reads as stale: twice the
/// stream's slowest cadence in 03 §6.4 (10 s, Cellular saver), the rule
/// `kFleetRowStaleAfter` keeps for the fleet's streams.
const Duration _staleAfter = Duration(seconds: 20);

/// The freshness of a `procs` reading at [now], as the panel and its
/// process sheet word it.
Freshness processesFreshnessAt(
  DateTime now,
  Sample? reading,
  SamplingStatus? sampling,
) => freshnessOf(
  now: now,
  staleAfter: _staleAfter,
  lastSampleAt: reading?.at,
  // No monitor set watches a server yet (FL-21): the panel samples it
  // while it shows.
  watched: false,
  sampling: sampling,
);

/// [row]'s details in a sheet, as read: its figures in [columns]' words,
/// its parent and state, and each argument, a masked one revealed only on
/// a tap there (03 §8.9). The sheet keeps that [reading], so it says the
/// reading's freshness by [clock] and the server's [sampling] as it
/// changes, and greys its figures once stale.
void showProcess(
  BuildContext context,
  ProcessRow row,
  List<SortableTableColumn<ProcessRow>> columns, {
  required MonitoringController monitoring,
  required String serverId,
  required Sample reading,
  required ValueListenable<DateTime> clock,
  required ValueListenable<SamplingStatus?> sampling,
}) {
  final l10n = AppLocalizations.of(context);
  final unknown = l10n.chartUnknownValue;
  unawaited(
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ProcessSheet(
        monitoring: monitoring,
        serverId: serverId,
        row: row,
        reading: reading,
        clock: clock,
        sampling: sampling,
        facts: [
          for (final column in columns.skip(1))
            (column.label, column.text(row)),
          (l10n.processesParentPid, row.parentPid?.toString() ?? unknown),
          (l10n.processesState, row.state ?? unknown),
        ],
      ),
    ),
  );
}

/// A process's details: the reading's facts, then PRC-04 and PRC-05's
/// read of the process itself, which the sheet asks for when it opens and
/// on request, then its arguments and environment. Revealed arguments and
/// variables live in this sheet only: each is masked again after
/// [kRevealDuration], when the app turns inactive, and when the sheet
/// closes, and nothing sends, stores or logs them (SAF-07). Inactive
/// precedes hidden on the way to the background, while a frame can still
/// draw the mask before an app switcher's snapshot.
class _ProcessSheet extends StatefulWidget {
  const _ProcessSheet({
    required this.monitoring,
    required this.serverId,
    required this.row,
    required this.facts,
    required this.reading,
    required this.clock,
    required this.sampling,
  });

  final MonitoringController monitoring;
  final String serverId;
  final ProcessRow row;
  final List<(String, String)> facts;
  final Sample reading;
  final ValueListenable<DateTime> clock;
  final ValueListenable<SamplingStatus?> sampling;

  @override
  State<_ProcessSheet> createState() => _ProcessSheetState();
}

class _ProcessSheetState extends State<_ProcessSheet> {
  /// The revealed arguments and variables by kind and index.
  late final TimedReveals<_Revealed> _revealed;

  /// The process read's answer, null while it reads.
  late final LatestRead<HostPayload> _latest = LatestRead(
    setState: setState,
    mounted: () => mounted,
  );

  @override
  void initState() {
    super.initState();
    _revealed = TimedReveals(onChanged: () => setState(() {}));
    if (widget.row.startTicks != null) unawaited(_read());
  }

  Future<void> _read() async {
    final ticks = widget.row.startTicks;
    if (ticks == null) return;

    await _latest.run(() async {
      final result = await widget.monitoring.hostReads.queryHost(
        widget.serverId,
        ProcessDetailQuery(pid: widget.row.pid, startTicks: ticks),
      );
      // A new read can list other variables at the same places.
      if (mounted) {
        _revealed.discard(where: (key) => key.$1 == _MaskedKind.variable);
      }
      return result.payload;
    });
  }

  @override
  void dispose() {
    _revealed.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final row = widget.row;
    final arguments = row.arguments ?? const <MaskedValue>[];
    final header = <Widget>[
      Semantics(
        header: true,
        child: Text(
          row.name ?? row.pid.toString(),
          style: theme.textTheme.titleMedium,
        ),
      ),
      // Only where actions show, so the sheet keeps its layout otherwise.
      if (actionsAllowedAt(
        context,
        widget.serverId,
        ActionEntryPoint.processSignal,
      ))
        ProcessActionButtons(serverId: widget.serverId, row: row),
      ListenableBuilder(
        listenable: Listenable.merge([widget.clock, widget.sampling]),
        builder: (context, _) {
          final freshness = processesFreshnessAt(
            widget.clock.value,
            widget.reading,
            widget.sampling.value,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 12,
            children: [
              PanelNotice.state(
                icon: freshness.stale ? Icons.history : Icons.schedule,
                text: freshnessText(l10n, freshness),
              ),
              // Grey once stale (03 §9.5 item 4).
              _Facts(facts: widget.facts, muted: freshness.stale),
            ],
          );
        },
      ),
      ..._detailLines(l10n),
      Semantics(
        header: true,
        child: Text(
          l10n.processesCommandLineTitle,
          style: theme.textTheme.titleSmall,
        ),
      ),
      if (arguments.isEmpty)
        PanelNotice.state(
          icon: Icons.info_outline,
          text: l10n.processesCommandUnavailable,
        )
      else if (arguments.any((argument) => argument.isMasked))
        Text(
          l10n.processesRevealNote(kRevealDuration.inSeconds),
          style: theme.textTheme.bodySmall,
        ),
      if (arguments.isNotEmpty && row.argumentsTruncated)
        Text(l10n.processesCommandTruncated, style: theme.textTheme.bodySmall),
    ];
    final details = _latest.value;
    final variables = details is ProcessDetails
        ? details.environment ?? const <EnvVar>[]
        : const <EnvVar>[];
    final environment = <Widget>[
      if (details case ProcessDetails(:final detail, :final environment)) ...[
        Semantics(
          header: true,
          child: Text(
            l10n.processesEnvironmentTitle,
            style: theme.textTheme.titleSmall,
          ),
        ),
        if (detail.environmentDenied)
          PanelNotice.state(
            icon: Icons.lock_outline,
            text: l10n.processesEnvironmentDenied,
          )
        else if (environment == null || environment.isEmpty)
          PanelNotice.state(
            icon: Icons.info_outline,
            text: l10n.processesEnvironmentNone,
          )
        else if (environment.length >= kProcessEnvironLimit)
          Text(
            l10n.processesEnvironmentCapped(kProcessEnvironLimit),
            style: theme.textTheme.bodySmall,
          ),
      ],
    ];
    final variablesAt = header.length + arguments.length + environment.length;
    // Built lazily: a command line can hold thousands of arguments.
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView.builder(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        itemCount: variablesAt + variables.length,
        itemBuilder: (context, index) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: index < header.length
              ? header[index]
              : index < header.length + arguments.length
              ? _masked(l10n, (
                  _MaskedKind.argument,
                  index - header.length,
                ), arguments[index - header.length])
              : index < variablesAt
              ? environment[index - header.length - arguments.length]
              : _variable(l10n, index - variablesAt, variables),
        ),
      ),
    );
  }

  /// PRC-04 and PRC-05's lines: what the process read found, or why it
  /// found nothing, and the way to read it again.
  List<Widget> _detailLines(AppLocalizations l10n) {
    final theme = Theme.of(context);
    final canRead = widget.row.startTicks != null;
    final status = switch (_latest.value) {
      _ when !canRead => PanelNotice.state(
        icon: Icons.info_outline,
        text: l10n.processesDetailNoStart,
      ),
      null => PanelNotice.state(
        icon: Icons.hourglass_empty,
        text: l10n.processesDetailReading,
      ),
      ProcessDetails(:final detail) => _Facts(
        facts: processDetailFacts(
          l10n,
          detail,
          unknown: l10n.chartUnknownValue,
        ),
      ),
      ProcessEnded(:final end) => PanelNotice.state(
        icon: Icons.history,
        text: l10n.processesDetailEnded(end.name),
      ),
      HostQueryFailed(:final failure, :final detail) => PanelNotice.state(
        icon: Icons.error_outline,
        text: l10n.processesDetailFailed(failure.name),
        detail: detail,
      ),
      _ => PanelNotice.state(
        icon: Icons.error_outline,
        text: l10n.processesDetailFailed(HostQueryFailure.failed.name),
      ),
    };
    return [
      Semantics(
        header: true,
        child: Text(
          l10n.processesDetailTitle,
          style: theme.textTheme.titleSmall,
        ),
      ),
      status,
      if (canRead)
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton(
            onPressed: _latest.reading ? null : () => unawaited(_read()),
            child: Text(l10n.processesDetailReadAgain),
          ),
        ),
    ];
  }

  /// One environment variable, its name above its value, which is masked
  /// by key (03 §8.9) until revealed.
  Widget _variable(AppLocalizations l10n, int index, List<EnvVar> variables) {
    final variable = variables[index];
    return _masked(
      l10n,
      (_MaskedKind.variable, index),
      variable.value,
      name: variable.name,
    );
  }

  /// [value] under its [name], if any, shown as is or, when masked,
  /// revealed for a while on a tap.
  Widget _masked(
    AppLocalizations l10n,
    _Revealed key,
    MaskedValue value, {
    String? name,
  }) {
    final theme = Theme.of(context);
    Widget named(Widget value) => name == null
        ? value
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                name,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              value,
            ],
          );
    if (!value.isMasked) {
      return MergeSemantics(child: named(Text(clipProcessText(value.display))));
    }

    final revealed = _revealed.isRevealed(key);
    final shown = clipProcessText(revealed ? value.reveal()! : value.display);
    // A masked value is read as masked, never as eight asterisks.
    final spoken = revealed
        ? shown
        : clipProcessText(argumentText(value, maskWord: l10n.processesMasked));
    return Semantics(
      button: true,
      // A masked value is read as masked, never as eight asterisks.
      label: name == null
          ? spoken
          : l10n.processesEnvironmentEntry(name, spoken),
      hint: revealed ? l10n.processesHideHint : l10n.processesRevealHint,
      excludeSemantics: true,
      onTap: () => _revealed.toggle(key),
      child: InkWell(
        onTap: () => _revealed.toggle(key),
        child: ConstrainedBox(
          // A touch needs a 48 dp target (A11Y-01); a pointer, the line.
          constraints: BoxConstraints(
            minHeight: ghostIsDesktopPlatform(Theme.of(context).platform)
                ? 0
                : kMinInteractiveDimension,
          ),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                Icon(
                  revealed
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                Expanded(child: named(Text(shown))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What a revealed value is in a process's details.
enum _MaskedKind { argument, variable }

/// A revealed value's key: its kind and its index among that kind.
typedef _Revealed = (_MaskedKind, int);

/// Labelled values in a wrapping row, each label and value read as one
/// node; [muted] greys the values, as for a stale reading.
class _Facts extends StatelessWidget {
  const _Facts({required this.facts, this.muted = false});

  final List<(String, String)> facts;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 24,
      runSpacing: 12,
      children: [
        for (final (label, value) in facts)
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  value,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: muted ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
