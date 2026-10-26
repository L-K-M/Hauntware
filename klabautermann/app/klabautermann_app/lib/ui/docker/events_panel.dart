import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../../controllers/docker_controller.dart';
import '../../controllers/monitoring_controller.dart';
import '../../l10n/app_localizations.dart';
import 'containers_panel.dart' show DockerNotice;
import 'containers_view.dart' show searchTerms;

/// The event types the timeline filters by, each named as the engine
/// names its type.
enum DockerEventKind {
  container(Icons.view_in_ar_outlined),
  image(Icons.layers_outlined),
  volume(Icons.storage_outlined),
  network(Icons.lan_outlined);

  const DockerEventKind(this.icon);

  final IconData icon;

  static DockerEventKind? of(String type) =>
      values.where((kind) => kind.name == type).firstOrNull;
}

/// [entries] as the timeline shows them, newest first: the events of
/// [kind] (all with null) that hold every term of [terms] in their name,
/// action or image, and every gap, which stays to say what may be
/// missing.
List<DockerTimelineEntry> timelineRows(
  List<DockerTimelineEntry> entries, {
  DockerEventKind? kind,
  List<String> terms = const [],
}) => [
  for (final entry in entries.reversed)
    if (switch (entry) {
      DockerTimelineGap() => true,
      final DockerTimelineEvent event =>
        (kind == null || event.type == kind.name) &&
            terms.every(
              (term) => [
                event.name,
                event.action,
                event.image,
              ].any((field) => field?.toLowerCase().contains(term) ?? false),
            ),
    })
      entry,
];

/// The Events sub-tab (03 §7.12 DKE-03): the engine's container, image,
/// volume and network events while the app follows them, newest first,
/// filterable by type and searchable, with a marker wherever the stream
/// was lost. The engine keeps only a bounded buffer, so a gap's events
/// may be missing even where the stream resumed.
///
/// While [visible], it holds the server's events watch
/// ([DockerController.watchEvents]); hidden, it lets the watch go, and
/// the engine keeps the timeline for the next view.
class EventsPanel extends StatefulWidget {
  const EventsPanel({
    super.key,
    required this.monitoring,
    required this.serverId,
    required this.visible,
  });

  final MonitoringController monitoring;
  final String serverId;
  final bool visible;

  @override
  State<EventsPanel> createState() => _EventsPanelState();
}

class _EventsPanelState extends State<EventsPanel> {
  /// The type filter and search, which outlive sub-tab switches.
  DockerEventKind? _kind;
  final _search = TextEditingController();

  /// The server whose events watch this panel holds, if any.
  String? _held;

  DockerController get _docker => widget.monitoring.docker;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(EventsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.serverId != oldWidget.serverId) {
      _release();
      _search.clear();
    }
    _sync();
  }

  @override
  void dispose() {
    _release();
    _search.dispose();
    super.dispose();
  }

  void _sync() {
    final wanted = widget.visible ? widget.serverId : null;
    if (_held == wanted) return;
    _release();
    if (wanted == null) return;

    _docker.watchEvents(wanted);
    _held = wanted;
  }

  void _release() {
    final held = _held;
    if (held == null) return;

    _held = null;
    _docker.unwatchEvents(held);
  }

  @override
  Widget build(BuildContext context) {
    // Read on every build: a server that left the fleet and came back has
    // new listenables (SYN-08).
    final events = _docker.eventsFor(widget.serverId);
    return ValueListenableBuilder(
      valueListenable: events,
      builder: (context, list, _) => _build(context, list),
    );
  }

  Widget _build(BuildContext context, DockerEventList list) {
    final l10n = AppLocalizations.of(context);
    final entries = list.entries;
    final failure = list.failure;
    final rows = entries == null
        ? const <DockerTimelineEntry>[]
        : timelineRows(entries, kind: _kind, terms: searchTerms(_search.text));

    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 12,
        children: [
          DockerNotice(icon: Icons.info_outline, text: l10n.dockerEventsBuffer),
          if (failure != null)
            DockerNotice(
              icon: Icons.error_outline,
              text: l10n.dockerEventsFailed(failure.failure.name),
              detail: failure.detail,
              action: TextButton(
                onPressed: () => _docker.retryEvents(widget.serverId),
                child: Text(l10n.dockerRetry),
              ),
            )
          else if (entries == null)
            DockerNotice(
              icon: Icons.hourglass_empty,
              text: l10n.dockerEventsWaiting,
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ChoiceChip(
                label: Text(l10n.dockerEventsAll),
                selected: _kind == null,
                onSelected: (_) => setState(() => _kind = null),
              ),
              for (final kind in DockerEventKind.values)
                ChoiceChip(
                  label: Text(l10n.dockerEventsKind(kind.name)),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                ),
            ],
          ),
          TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: l10n.dockerEventsSearch,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
          Expanded(
            child: entries != null && rows.isEmpty
                ? Text(
                    entries.isEmpty
                        ? l10n.dockerEventsNone
                        : l10n.dockerEventsNoMatch,
                  )
                : ListView.separated(
                    itemCount: rows.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, i) => switch (rows[i]) {
                      final DockerTimelineEvent event => _EventRow(
                        event: event,
                      ),
                      final DockerTimelineGap gap => _GapRow(gap: gap),
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// One event: its time, type, what it happened to and what happened.
class _EventRow extends StatelessWidget {
  const _EventRow({required this.event});

  final DockerTimelineEvent event;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final kind = DockerEventKind.of(event.type);
    final time = DateFormat.Hms(l10n.localeName).format(event.at.toLocal());
    final details = [
      if (event.image case final image?) l10n.dockerEventsImage(image),
      if (event.exitCode case final code?) l10n.dockerEventsExitCode(code),
    ];
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Icon(
              kind?.icon ?? Icons.bolt_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Text(
                    l10n.dockerEventsLine(
                      event.name ?? event.actorId ?? l10n.systemUnknown,
                      event.action,
                    ),
                    style: theme.textTheme.bodyMedium,
                  ),
                  Text(
                    [time, ...details].join(l10n.chartListSeparator),
                    style: muted,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A span the app did not follow the events.
class _GapRow extends StatelessWidget {
  const _GapRow({required this.gap});

  final DockerTimelineGap gap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final format = DateFormat.Hms(l10n.localeName);
    return MergeSemantics(
      child: Container(
        color: theme.colorScheme.surfaceContainerHigh,
        padding: const EdgeInsets.all(8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            Icon(
              Icons.link_off,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            Expanded(
              child: Text(
                l10n.dockerEventsGap(
                  format.format(gap.at.toLocal()),
                  format.format(gap.until.toLocal()),
                  gap.resumed.toString(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
