import 'dart:async';
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart'
    show AccessibilityFocusBlockType, SemanticsService;
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'fleet_rail.dart' show FleetEmptyState, linkStatusWord;
import 'fleet_row_state.dart';
import 'sidebar_kit.dart';

/// `ghost_servers`' words for a row whose link is [link] (03 §10.10's
/// adapter convention). Every session state takes the word for the status
/// at hand, as the bag allows, so a backoff that the shared glyph draws
/// as connecting still reads "Waiting to reconnect"; the probe answers
/// take FL-04's words. A block carries no detail: its reasons are worded
/// where the user resolves them. The section header's words for hidden
/// live servers keep the bag's defaults and go unused: a collapsed or
/// filtered rail does hide live servers, and saying so in the header
/// (`ghostHiddenLiveIndicator`) is deferred to a follow-up on the header.
GhostServerStatusStrings fleetStatusStrings(
  AppLocalizations l10n,
  LinkStatus link,
) {
  final word = linkStatusWord(l10n, link);
  return GhostServerStatusStrings(
    connected: word,
    connecting: word,
    failed: word,
    blocked: word,
    notConnected: l10n.statusDisconnected,
    probeOnline: l10n.fleetRowProbeOnline,
    probeOffline: l10n.fleetRowProbeOffline,
    probeUnknown: l10n.fleetRowProbeUnknown,
    blockedDetail: null,
  );
}

/// The icon beside a row's state word (A11Y-01): its shape tells the
/// states apart where the dot's colour would. Only "nothing known" has
/// none, as it has no dot and no word.
IconData? fleetStatusIcon(GhostServerGlyph glyph) => switch (glyph) {
  GhostServerGlyph.connected => Icons.link,
  GhostServerGlyph.connecting => Icons.sync,
  GhostServerGlyph.failed => Icons.error_outline,
  GhostServerGlyph.blocked => Icons.block,
  GhostServerGlyph.idle => Icons.link_off,
  GhostServerGlyph.reachable => Icons.cloud_done_outlined,
  GhostServerGlyph.unreachable => Icons.cloud_off_outlined,
  GhostServerGlyph.reachabilityUnknown => Icons.help_outline,
  GhostServerGlyph.none => null,
};

/// [age] in whole seconds under a minute, whole minutes under an hour and
/// whole hours beyond (03 §9.5 item 4's "updated 4 s ago").
String fleetRowAge(AppLocalizations l10n, Duration age) {
  if (age < const Duration(minutes: 1)) {
    return l10n.fleetRowAgeSeconds(age.inSeconds);
  }
  if (age < const Duration(hours: 1)) {
    return l10n.fleetRowAgeMinutes(age.inMinutes);
  }
  return l10n.fleetRowAgeHours(age.inHours);
}

/// The fleet's rows under the shared filter field (FL-05, 03 §10.3), for
/// the desktop rail and the phone's home list alike, with the screen
/// reader told of link changes (A11Y-15).
///
/// The field shows while the fleet has servers. Esc clears a query, then
/// leaves the field; Enter opens the first match through [onOpen]. A live
/// query shows its matches even while [collapsed] folds the rows away
/// behind the section header, so the count under the field never
/// describes rows nobody can see.
class FleetServerList extends StatefulWidget {
  const FleetServerList({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.onOpen,
    this.collapsed = false,
    this.showSelection = false,
  });

  final FleetController fleet;

  /// Feeds the rows' readings and their freshness clock (03 §10.1).
  final MonitoringController monitoring;

  final void Function(FleetServer server) onOpen;
  final bool collapsed;

  /// Draws the selected server's pill: the desktop workspace shows it,
  /// while a phone's pushed screen covers the list.
  final bool showSelection;

  @override
  State<FleetServerList> createState() => _FleetServerListState();
}

class _FleetServerListState extends State<FleetServerList> {
  String _query = '';
  final _filterFocus = FocusNode(debugLabel: 'Fleet filter');

  @override
  void dispose() {
    _filterFocus.dispose();
    super.dispose();
  }

  void _setQuery(String query) => setState(() => _query = query);

  void _dismissFilter() {
    if (_query.isNotEmpty) {
      _setQuery('');
      return;
    }
    _filterFocus.unfocus();
  }

  /// Matches are recomputed here rather than captured from the last build:
  /// typing and submitting within one frame would act on a stale list.
  void _openFirstMatch() {
    if (_query.isEmpty) return;
    final first = widget.fleet.servers
        .where((server) => fleetServerMatches(server, _query))
        .firstOrNull;
    if (first == null) return;
    _filterFocus.unfocus();
    widget.onOpen(first);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _LinkAnnouncer(
      fleet: widget.fleet,
      child: ListenableBuilder(
        listenable: widget.fleet,
        builder: (context, _) {
          final servers = widget.fleet.servers;
          if (servers.isEmpty) return const FleetEmptyState();

          final matches = [
            for (final server in servers)
              if (fleetServerMatches(server, _query)) server,
          ];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SidebarFilterField(
                query: _query,
                focusNode: _filterFocus,
                onChanged: _setQuery,
                onDismiss: _dismissFilter,
                onSubmitted: _openFirstMatch,
                countText: matches.isEmpty
                    ? l10n.fleetFilterCount(0, servers.length)
                    : l10n.fleetFilterCountOpensFirst(
                        matches.length,
                        servers.length,
                      ),
              ),
              Expanded(
                child: matches.isEmpty
                    ? _NoMatches(onClear: () => _setQuery(''))
                    : ListView(
                        children: [
                          if (!widget.collapsed || _query.isNotEmpty)
                            for (final server in matches)
                              FleetServerRow(
                                key: ValueKey(server.id),
                                server: server,
                                fleet: widget.fleet,
                                monitoring: widget.monitoring,
                                selected:
                                    widget.showSelection &&
                                    widget.fleet.selectedServerId == server.id,
                                onActivate: () => widget.onOpen(server),
                              ),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // A list, so large text in a short rail scrolls instead of clipping.
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          l10n.fleetFilterNoMatches,
          style: Theme.of(context).textTheme.bodyMedium,
          textAlign: TextAlign.center,
        ),
        Center(
          child: TextButton(
            onPressed: onClear,
            child: Text(l10n.sidebarFilterClear),
          ),
        ),
      ],
    );
  }
}

/// The key of the age a [FleetServerRow] shows under its pressure bar.
const Key kFleetRowAgeKey = ValueKey('fleetRowAge');

/// One server row of 03 §10.3 over the sidebar kit's [SidebarRow]: the
/// mark with `ghost_servers`' dot, the state word on the second line and
/// its icon at the row's end (A11Y-01), and, beside the row, the locator
/// warning (03 §4.6) and a monitored server's pressure bar (FL-07) over
/// the reading's age.
///
/// A server is monitored while the app holds an `overview` or `core`
/// reading for it ([fleetRowReading]). Rows subscribe nothing themselves:
/// FL-21 samples the fleet only for the monitor set, which does not exist
/// yet, so readings come from the surfaces that show a server's panels.
///
/// The row is one screen-reader node whose label says everything it
/// shows; its values refresh with every sample, so it is no live region
/// (A11Y-15). Its height is the kit's fixed extent whatever it shows, so
/// a host turning unreachable never reflows the list.
class FleetServerRow extends StatelessWidget {
  const FleetServerRow({
    super.key,
    required this.server,
    required this.fleet,
    required this.monitoring,
    required this.onActivate,
    this.selected = false,
  });

  final FleetServer server;
  final FleetController fleet;
  final MonitoringController monitoring;
  final VoidCallback onActivate;
  final bool selected;

  /// The widest the warning, pressure bar and age beside the row grow:
  /// the warning's target (24 px), the bar with its severity icon (64),
  /// the gaps, and room for an age wider than the bar, so the kit's row
  /// keeps room for its mark, icon and a title on a 260 px rail.
  static const double _extrasMaxWidth = 120;

  /// How wide a row must be, per 100 % of text, for the pressure bar and
  /// age to sit beside it: the 260 px rail keeps them up to about 140 %
  /// text, a 360 dp phone up to 200 %. A narrower row would cut the
  /// server's name and state word to an ellipsis, so they give way there;
  /// the tooltip and the label still say what they show.
  static const double _barRowWidthPerText = 180;

  /// The text size whose growth [_barRowWidthPerText] follows: body text,
  /// as on the row's second line.
  static const double _bodyTextSize = 14;

  /// What a row with no age to count listens to instead of the clock: it
  /// never notifies, so the clock stops once no row shows an age.
  static final Listenable _silent = Listenable.merge(const []);

  @override
  Widget build(BuildContext context) {
    final id = server.id;
    final overview = monitoring.sampleFor(id, SampleStream.overview);
    final core = monitoring.sampleFor(id, SampleStream.core);
    final fs = monitoring.sampleFor(id, SampleStream.fs);
    return ListenableBuilder(
      listenable: Listenable.merge([overview, core, fs]),
      builder: (context, _) {
        final samples = (
          overview: overview.value,
          core: core.value,
          fs: fs.value,
        );
        // Only a row with a reading has an age to keep counting, so only
        // such a row keeps the clock ticking. The builder is the same
        // either way: a subtree that changed shape when the first reading
        // lands would remount the kit's row and drop its keyboard focus.
        final counting = samples.overview != null || samples.core != null;
        return ListenableBuilder(
          listenable: counting ? monitoring.clock : _silent,
          builder: (context, _) => _build(
            context,
            samples,
            counting ? monitoring.clock.value : null,
          ),
        );
      },
    );
  }

  Widget _build(
    BuildContext context,
    ({Sample? overview, Sample? core, Sample? fs}) samples,
    DateTime? now,
  ) {
    final l10n = AppLocalizations.of(context);
    // The status colours live on ghost_theme's chrome beside the tokens
    // they are held to the same contrast floor with.
    final chrome = GhostChrome.of(context, klabautermannThemeStyle);
    final link = fleet.linkStatusFor(server.id);
    final session = ghostSessionOf(link);
    // The rail rule: live truth beyond idle outranks the probe, so a
    // connected server never reads as merely reachable.
    final indicator = ghostServerIndicator(
      fleetStatusStrings(l10n, link),
      GhostIndicatorRule.rail,
      session: session,
      probe: ghostProbeOf(fleet.reachabilityFor(server.id)),
    );
    final reading = now == null
        ? null
        : fleetRowReading(
            overview: samples.overview,
            core: samples.core,
            fs: samples.fs,
            session: session,
            now: now,
          );

    final chartStrings = klabautermannChartStrings(l10n);
    final cells = reading == null
        ? null
        : [
            PressureCell(
              label: l10n.fleetRowCpu,
              percent: reading.cpuPercent,
              thresholds: kFleetRowThresholds,
            ),
            PressureCell(
              label: l10n.fleetRowMemory,
              percent: reading.memoryPercent,
              thresholds: kFleetRowThresholds,
            ),
            PressureCell(
              label: l10n.fleetRowDisk,
              percent: reading.diskPercent,
              thresholds: kFleetRowThresholds,
            ),
          ];
    final freshness = reading == null
        ? null
        : l10n.fleetRowUpdated(fleetRowAge(l10n, reading.age));
    final pressure = cells == null
        ? null
        : pressureSummary(cells, chartStrings, stale: reading!.stale);
    final conflict = _conflictWarning(l10n);
    // Nothing known paints no dot and shows no word, as in Séance; a
    // screen reader still hears the link's word.
    final label = indicator.label;

    final subtitle = [?label, ?server.address].join(l10n.fleetRowPartSeparator);
    // The bar's values too: where it gives way to the name, hover still
    // shows them on desktop.
    final tooltip = [
      ?server.address,
      ?label,
      ?indicator.detail,
      ?freshness,
      ?pressure,
      ?conflict,
    ].join('\n');
    final row = SidebarRow(
      mark: const Icon(Icons.dns_outlined),
      title: server.displayName,
      subtitle: subtitle.isEmpty ? null : subtitle,
      status: ghostStatusDot(
        indicator,
        GhostStatusColors(
          online: chrome.statusConnected,
          connecting: chrome.statusConnecting,
          offline: chrome.statusFailed,
        ),
      ),
      // A framed mark means connected, a silhouette the eye tells apart
      // without the dot's colour (Séance's rail does the same).
      markRing: indicator.glyph == GhostServerGlyph.connected
          ? chrome.statusConnected
          : null,
      trailingIcon: fleetStatusIcon(indicator.glyph),
      selected: selected,
      onActivate: (_) => onActivate(),
      tooltip: tooltip.isEmpty ? null : tooltip,
      semanticLabel: [
        server.displayName,
        ?server.address,
        l10n.statusSemantics(label ?? linkStatusWord(l10n, link)),
        ?freshness,
        ?pressure,
        ?conflict,
      ].join(l10n.fleetRowListSeparator),
    );

    // The age, short, under the pressure bar, level with the second line;
    // the tooltip and the label say it in full. It shows whatever the link
    // says: a lost link's word does not say how old the values are, and
    // after a clean close the probe's word says nothing of them. Stale
    // values add an icon to the bar's grey, and the word "Stale" unless
    // the state word already says the link is down (03 §9.5 item 4,
    // A11Y-01), which keeps that word's room on a 260 px rail. Not the
    // kit's trailing text: beside the bar it would crowd the state word
    // out, and it never gives way, so 200 % text would overflow the row.
    final secondaryText = SidebarThemeTokens.of(context).secondaryText;
    final linkWordSaysStale = switch (indicator.glyph) {
      GhostServerGlyph.connecting ||
      GhostServerGlyph.failed ||
      GhostServerGlyph.blocked => true,
      _ => false,
    };
    final warning = conflict == null
        ? null
        : Tooltip(
            message: conflict,
            excludeFromSemantics: true,
            // A touch on the warning shows its words, since on a phone the
            // row's tooltip never shows (it opens on hover only). Tap mode
            // ignores mice: a click opens the server and hover shows these.
            triggerMode: TooltipTriggerMode.tap,
            // 24 px square, WCAG 2.5.8's smallest target, and no taller
            // than a compact row.
            child: SizedBox.square(
              dimension: 24,
              child: Icon(
                Icons.warning_amber_rounded,
                size: 16,
                color: ChartPalette.of(context).warning,
              ),
            ),
          );
    final bar = cells == null
        ? null
        : Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              spacing: 4,
              children: [
                PressureBar(
                  cells: cells,
                  strings: chartStrings,
                  stale: reading!.stale,
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 2,
                  children: [
                    if (reading.stale)
                      Icon(Icons.history, size: 14, color: secondaryText),
                    Flexible(
                      child: Text(
                        switch (fleetRowAge(l10n, reading.age)) {
                          final age when reading.stale && !linkWordSaysStale =>
                            l10n.fleetRowStaleAge(age),
                          final age => age,
                        },
                        key: kFleetRowAgeKey,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: secondaryText,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
    // Beside the row rather than in it: the kit's row takes no trailing
    // widget, and ghost_ui is a shared package outside this change. The
    // row's label already says what these show, so they stay out of the
    // semantics tree, and a tap on them opens the server like the row.
    // The kit's row stays this Row's first child with or without them, so
    // it keeps its state (focus, hover) when they come and go.
    return LayoutBuilder(
      builder: (context, constraints) {
        final textGrowth =
            MediaQuery.textScalerOf(context).scale(_bodyTextSize) /
            _bodyTextSize;
        final extras = [
          ?warning,
          if (constraints.maxWidth >= _barRowWidthPerText * textGrowth) ?bar,
        ];
        return Row(
          children: [
            Expanded(child: row),
            if (extras.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: _extrasMaxWidth),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // The row's node has the tap already; the detector's own
                  // would merge into the list item as a second, unnamed stop.
                  excludeFromSemantics: true,
                  onTap: onActivate,
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(end: 8),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: 6,
                        children: extras,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// The locator warning K14's import flags (03 §4.6), naming the other
  /// servers by their labels; null when nothing collides.
  String? _conflictWarning(AppLocalizations l10n) {
    final ids = server.locatorConflict;
    if (ids == null || ids.isEmpty) return null;

    final names = [
      for (final id in ids)
        fleet.servers
                .where((other) => other.id == id)
                .firstOrNull
                ?.displayName ??
            id,
    ];
    return l10n.fleetRowLocatorConflict(names.join(l10n.fleetRowListSeparator));
  }
}

/// Tells the screen reader when a server's link changes state (A11Y-15),
/// worded with the link's word: once per change of that word, except that
/// connecting, authenticating and waiting to reconnect are one attempt in
/// flight, as `ghost_servers` draws them, so a connect or a retry loop is
/// not read out step by step. "Needs your input" to "Blocked" and
/// "Connected" to "Connected with limits" are news. Samples and probe
/// answers are never announced; a server that joins or leaves the fleet
/// is not a link change.
///
/// Where the platform takes no announcements, as on Android, which
/// deprecated them and where Flutter reports them unsupported, the latest
/// changes go to a live region instead, as Flutter's date picker does.
class _LinkAnnouncer extends StatefulWidget {
  const _LinkAnnouncer({required this.fleet, required this.child});

  final FleetController fleet;
  final Widget child;

  @override
  State<_LinkAnnouncer> createState() => _LinkAnnouncerState();
}

/// What [_LinkAnnouncer] tells a link change by: the session state the
/// shared dot draws and, past an attempt in flight, the link's word.
typedef _HeardLink = (GhostSessionState session, String? word);

class _LinkAnnouncerState extends State<_LinkAnnouncer> {
  /// Each listed server's link as last heard.
  late Map<String, _HeardLink> _heard;
  late AppLocalizations _l10n;
  late FlutterView _view;
  late TextDirection _direction;
  late bool _announces;

  /// The last link changes, for the live region; null before any.
  String? _liveText;

  @override
  void initState() {
    super.initState();
    widget.fleet.addListener(_onFleetChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read here, since the fleet's notifications arrive outside a build.
    _l10n = AppLocalizations.of(context);
    _view = View.of(context);
    _direction = Directionality.of(context);
    _announces = MediaQuery.maybeSupportsAnnounceOf(context) ?? false;
    // Heard afresh, so a new language rewords the states without
    // announcing them.
    _heard = _current();
  }

  @override
  void didUpdateWidget(_LinkAnnouncer oldWidget) {
    super.didUpdateWidget(oldWidget);
    assert(
      widget.fleet == oldWidget.fleet,
      'new controllers come with a new tree (KlabautermannApp, D44)',
    );
  }

  @override
  void dispose() {
    widget.fleet.removeListener(_onFleetChanged);
    super.dispose();
  }

  Map<String, _HeardLink> _current() => {
    for (final server in widget.fleet.servers)
      server.id: _hear(widget.fleet.linkStatusFor(server.id)),
  };

  _HeardLink _hear(LinkStatus link) {
    final session = ghostSessionOf(link);
    return (
      session,
      session == GhostSessionState.connecting
          ? null
          : linkStatusWord(_l10n, link),
    );
  }

  void _onFleetChanged() {
    final current = _current();
    final changes = [
      for (final server in widget.fleet.servers)
        if (_heard[server.id] case final before?
            when before != current[server.id])
          _l10n.fleetRowLinkAnnouncement(
            server.displayName,
            linkStatusWord(_l10n, widget.fleet.linkStatusFor(server.id)),
          ),
    ];
    _heard = current;
    if (changes.isEmpty) return;

    if (!_announces) {
      setState(() => _liveText = changes.join(_l10n.fleetRowListSeparator));
      return;
    }
    for (final change in changes) {
      unawaited(SemanticsService.sendAnnouncement(_view, change, _direction));
    }
  }

  @override
  Widget build(BuildContext context) {
    final live = !_announces;
    // The node takes no accessibility focus of its own: its label is read
    // out when it changes, and the rows stay nodes of their own.
    return Semantics(
      container: live,
      explicitChildNodes: live,
      liveRegion: live ? true : null,
      accessibilityFocusBlockType: live
          ? AccessibilityFocusBlockType.blockNode
          : null,
      label: live ? _liveText : null,
      child: widget.child,
    );
  }
}
