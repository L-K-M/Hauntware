import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show FlutterView;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart'
    show AccessibilityFocusBlockType, SemanticsService;
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'fleet_rail.dart' show FleetEmptyState, linkFailureText, linkStatusWord;
import 'fleet_row_state.dart';
import 'monitor_set_feedback.dart';
import 'server_editing.dart';
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

/// The collapse key of the imports' section. A leading space keeps it
/// apart from every group key, as `ghost_servers`' own section keys are.
const String _importedKey = ' imported';

/// The key of the section or group header whose collapse key is [key]
/// (`ghost_servers`' [kPinnedKey], [kServersKey] or a group's key, or the
/// imports' section), for tests to find it by.
@visibleForTesting
Key fleetSectionHeaderKey(String key) => ValueKey('fleet.section.$key');

/// What `ghost_servers`' sectioning reads from a row.
GhostServerEntry _entryOf(FleetServer server) =>
    GhostServerEntry(id: server.id, group: server.group);

/// The fleet's rows under the shared filter field (FL-05, 03 §10.3), for
/// the desktop rail and the phone's home list alike, with the screen
/// reader told of link changes (A11Y-15).
///
/// The rows are sectioned by `ghost_servers` as Séance's are (FL-06):
/// PINNED with the synced servers pinned on this device, then SERVERS
/// with the other synced servers, ungrouped first and then one nested
/// disclosure row per group. Imports carry no group and are never pinned,
/// so they list in a section of their own after these. Each section and
/// group folds away under its header for as long as the list lives.
///
/// The field shows while the fleet has servers. Esc clears a query, then
/// leaves the field; Enter opens the first match as the list orders it
/// through [onOpen]. A live query shows its matches in every folded
/// section and group, so the count under the field never describes rows
/// nobody can see.
class FleetServerList extends StatefulWidget {
  const FleetServerList({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.onOpen,
    this.showSelection = false,
    this.header,
  });

  final FleetController fleet;

  /// Feeds the rows' readings and their freshness clock (03 §10.1).
  final MonitoringController monitoring;

  final void Function(FleetServer server) onOpen;

  /// Draws the selected server's pill: the desktop workspace shows it,
  /// while a phone's pushed screen covers the list.
  final bool showSelection;

  /// Scrolls with the rows above the first, so a notice there never
  /// takes the rows' room on a short screen at large text (A11Y-09).
  final Widget? header;

  @override
  State<FleetServerList> createState() => _FleetServerListState();
}

class _FleetServerListState extends State<FleetServerList> {
  String _query = '';
  final _filterFocus = FocusNode(debugLabel: 'Fleet filter');

  /// The folded sections and groups, by key.
  final Set<String> _collapsed = {};

  @override
  void dispose() {
    _filterFocus.dispose();
    super.dispose();
  }

  void _setQuery(String query) => setState(() => _query = query);

  /// Folds or unfolds [key]. A search draws every header open, so a tap
  /// during one changes nothing rather than a fold the user cannot see.
  void _toggle(String key) {
    if (_query.isNotEmpty) return;
    setState(() {
      if (!_collapsed.remove(key)) _collapsed.add(key);
    });
  }

  /// The lines drawn for [servers]: `ghost_servers`' sections of the
  /// synced ones, then the imports' section. One definition, so "the first
  /// match" means the row the eye reads first, which pinning and group
  /// order make differ from the fleet's.
  List<GhostServerListRow<FleetServer>> _rows(
    AppLocalizations l10n,
    List<FleetServer> servers,
    Set<String> collapsed,
  ) {
    final synced = <FleetServer>[];
    final imported = <FleetServer>[];
    for (final server in servers) {
      switch (server.origin) {
        case FleetEntryOrigin.synced:
          synced.add(server);
        case FleetEntryOrigin.sshConfig:
          imported.add(server);
      }
    }

    final rows = serverListRows(
      sections: groupServerEntries(
        synced,
        _entryOf,
        pinnedIds: widget.fleet.pinnedServerIds,
      ),
      collapsedKeys: collapsed,
      labels: GhostServerSectionLabels(
        pinned: l10n.fleetSectionPinned,
        servers: l10n.fleetSectionServers,
      ),
    );
    if (imported.isEmpty) return rows;

    final folded = collapsed.contains(_importedKey);
    return [
      ...rows,
      GhostServerSectionRow(
        title: l10n.fleetSectionImported,
        key: _importedKey,
        count: imported.length,
        collapsed: folded,
      ),
      if (!folded)
        for (final server in imported) GhostServerRow(server),
    ];
  }

  /// A row's verbs: a synced row pins to the top or comes off (an import
  /// is never pinned), and every row joins FL-21's monitor set or leaves
  /// it. Monitor is disabled for a server that cannot join; Settings >
  /// Servers says why. While an account is enrolled, a synced row is also
  /// edited and deleted from here (FL-03, P16).
  List<SidebarMenuEntry> Function() _menuFor(FleetServer server) => () {
    final l10n = AppLocalizations.of(context);
    final fleet = widget.fleet;
    final pinned = fleet.pinnedServerIds.contains(server.id);
    final monitored = fleet.monitoredServerIds.contains(server.id);
    final editing = ServerEditingScope.maybeOf(context);
    return [
      if (server.origin == FleetEntryOrigin.synced)
        SidebarMenuAction(
          label: pinned ? l10n.fleetRowUnpin : l10n.fleetRowPin,
          onSelected: () => unawaited(
            _savingPins(pinned ? fleet.unpin(server.id) : fleet.pin(server.id)),
          ),
        ),
      SidebarMenuAction(
        label: monitored ? l10n.fleetRowStopMonitoring : l10n.fleetRowMonitor,
        onSelected: server.monitorEligibility == MonitorEligibility.eligible
            ? () => unawaited(
                changeMonitorSetWithFeedback(
                  context,
                  () => fleet.setMonitored(server.id, monitored: !monitored),
                ),
              )
            : null,
      ),
      if (editing != null && editing.canEdit(server)) ...[
        SidebarMenuAction(
          label: l10n.fleetRowEdit,
          onSelected: () => unawaited(
            openServerEditor(context, editing, serverId: server.id),
          ),
        ),
        SidebarMenuAction(
          label: l10n.fleetRowDuplicate,
          onSelected: () =>
              unawaited(duplicateServer(context, editing, server)),
        ),
        SidebarMenuAction(
          label: l10n.fleetRowDelete,
          onSelected: () =>
              unawaited(confirmAndDeleteServer(context, editing, server)),
        ),
      ],
    ];
  };

  /// Waits for a pin change to save, and says so when it could not: the
  /// change lasts until the app quits.
  Future<void> _savingPins(Future<void> change) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final notSaved = AppLocalizations.of(context).fleetPinNotSaved;
    try {
      await change;
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) showTopToast(overlay, message: notSaved);
    }
  }

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
    final matches = [
      for (final server in widget.fleet.servers)
        if (fleetServerMatches(server, _query)) server,
    ];
    final first = _rows(
      AppLocalizations.of(context),
      matches,
      const {},
    ).whereType<GhostServerRow<FleetServer>>().firstOrNull;
    if (first == null) return;
    _filterFocus.unfocus();
    widget.onOpen(first.server);
  }

  /// The widget for one of [_rows]' lines.
  Widget _line(GhostServerListRow<FleetServer> row) => switch (row) {
    GhostServerSectionRow(
      :final title,
      :final key,
      :final count,
      :final collapsed,
    ) =>
      SidebarSectionHeader(
        key: fleetSectionHeaderKey(key),
        title: title,
        count: count,
        collapsed: collapsed,
        onToggle: () => _toggle(key),
      ),
    GhostServerGroupHeaderRow(
      :final name,
      :final key,
      :final count,
      :final collapsed,
    ) =>
      SidebarSectionHeader(
        key: fleetSectionHeaderKey(key),
        nested: true,
        title: name,
        count: count,
        collapsed: collapsed,
        onToggle: () => _toggle(key),
      ),
    GhostServerRow(:final server, :final depth) => FleetServerRow(
      key: ValueKey(server.id),
      server: server,
      fleet: widget.fleet,
      monitoring: widget.monitoring,
      depth: depth,
      menuEntries: _menuFor(server),
      selected:
          widget.showSelection && widget.fleet.selectedServerId == server.id,
      onActivate: () => widget.onOpen(server),
    ),
  };

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
                          ?widget.header,
                          for (final row in _rows(
                            l10n,
                            matches,
                            _query.isEmpty ? _collapsed : const {},
                          ))
                            _line(row),
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
/// A server shows the bar while the app holds an `overview` or `core`
/// reading for it ([fleetRowReading]). Rows subscribe nothing themselves:
/// the engine samples `overview` for FL-21's monitor set, and the
/// surfaces that show a server's panels read the rest.
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
    this.depth = 0,
    this.menuEntries,
  });

  final FleetServer server;
  final FleetController fleet;
  final MonitoringController monitoring;
  final VoidCallback onActivate;
  final bool selected;

  /// 1 under a group's disclosure row (FL-06), 0 elsewhere.
  final int depth;

  /// The row's verbs, from a right-click, Shift+F10, the Menu key or a
  /// long-press, or null for none. The row draws no "⋮" for them: the
  /// bar's room is measured for a row without one ([_kitRowChrome]).
  final List<SidebarMenuEntry> Function()? menuEntries;

  /// The locator warning's target: 24 px square, WCAG 2.5.8's smallest,
  /// and no taller than a compact row.
  static const double _warningExtent = 24;

  /// [PressureBar]'s width: its 46 px bar, a 4 px gap and the 14 px slot
  /// of the severity icon, which the rows' thresholds always draw.
  static const double _barWidth = 64;

  /// The history icon before a stale age, and the gap after it.
  static const double _staleIconSize = 14;
  static const double _staleIconGap = 2;

  /// Between the warning and the bar, and after the last of them.
  static const double _extrasGap = 6;
  static const double _extrasEndPadding = 8;

  /// The width `SidebarRow` keeps beside its label in [layout] at
  /// [density], on touch or desktop: its two margins, the start inset, the
  /// mark and the gap after it, the trailing icon with its gap (counted
  /// even for a row with nothing known, which has none), and the end
  /// padding of a row with no menu button, in that order. ghost_ui keeps
  /// these metrics private, so they are mirrored here; the tests that
  /// find the narrowest row showing the bar fail when they drift.
  static double _kitRowChrome(
    SidebarKitLayout layout,
    SidebarKitDensity density, {
    required bool touch,
  }) => switch ((layout, density, touch)) {
    (SidebarKitLayout.list, _, _) => 2 * 8.0 + 8 + 40 + 16 + 6 + 16 + 4,
    (_, SidebarKitDensity.comfortable, false) =>
      2 * 6.0 + 12 + 32 + 10 + 6 + 14 + 4,
    (_, SidebarKitDensity.comfortable, true) =>
      2 * 6.0 + 12 + 32 + 12 + 6 + 14 + 4,
    (_, SidebarKitDensity.compact, false) => 2 * 6.0 + 8 + 18 + 6 + 6 + 12 + 4,
    (_, SidebarKitDensity.compact, true) => 2 * 6.0 + 8 + 24 + 12 + 6 + 12 + 4,
  };

  /// The kit's indent for one nesting level in [layout] at [density],
  /// mirrored like [_kitRowChrome].
  static double _kitDepthIndent(
    SidebarKitLayout layout,
    SidebarKitDensity density,
  ) => switch ((layout, density)) {
    (SidebarKitLayout.list, _) => 16,
    (_, SidebarKitDensity.comfortable) => 16,
    (_, SidebarKitDensity.compact) => 8,
  };

  /// What a row with no age to count listens to instead of the clock: it
  /// never notifies, so the clock stops once no row shows an age.
  static final Listenable _silent = Listenable.merge(const []);

  @override
  Widget build(BuildContext context) {
    final id = server.id;
    final overview = monitoring.sampleFor(id, SampleStream.overview);
    final core = monitoring.sampleFor(id, SampleStream.core);
    final fs = monitoring.sampleFor(id, SampleStream.fs);
    // False while the row is offstage, as under a phone's pushed server
    // screen; the row rebuilds when it changes.
    final onstage = TickerMode.valuesOf(context).enabled;
    return ListenableBuilder(
      listenable: Listenable.merge([overview, core, fs]),
      builder: (context, _) {
        final samples = (
          overview: overview.value,
          core: core.value,
          fs: fs.value,
        );
        // Only a row with a reading has an age to keep counting, so only
        // such a row keeps the clock ticking, and only while it is on
        // screen; back on stage it rebuilds with the clock's current time.
        // The builder is the same either way: a subtree that changed shape
        // when the first reading lands would remount the kit's row and drop
        // its keyboard focus.
        final counting = samples.overview != null || samples.core != null;
        return ListenableBuilder(
          listenable: counting && onstage ? monitoring.clock : _silent,
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
    // Why the link failed takes a sentence, more than a fixed-height row
    // has room for, so only the tooltip and the label carry it.
    final failure = linkFailureText(l10n, link);
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
      ?failure,
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
      depth: depth,
      menuEntries: menuEntries,
      showMenuButton: false,
      onActivate: (_) => onActivate(),
      tooltip: tooltip.isEmpty ? null : tooltip,
      semanticLabel: [
        server.displayName,
        ?server.address,
        l10n.statusSemantics(label ?? linkStatusWord(l10n, link)),
        ?failure,
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
    final ageText = reading == null
        ? null
        : switch (fleetRowAge(l10n, reading.age)) {
            final age when reading.stale && !linkWordSaysStale =>
              l10n.fleetRowStaleAge(age),
            final age => age,
          };
    final ageStyle = Theme.of(context).textTheme.labelMedium?.copyWith(
      color: secondaryText,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final warning = conflict == null
        ? null
        : Tooltip(
            message: conflict,
            excludeFromSemantics: true,
            // A touch on the warning shows its words, since on a phone the
            // row's tooltip never shows (it opens on hover only). Tap mode
            // ignores mice: a click opens the server and hover shows these.
            triggerMode: TooltipTriggerMode.tap,
            child: SizedBox.square(
              dimension: _warningExtent,
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
                  spacing: _staleIconGap,
                  children: [
                    if (reading.stale)
                      Icon(
                        Icons.history,
                        size: _staleIconSize,
                        color: secondaryText,
                      ),
                    Flexible(
                      child: Text(
                        ageText!,
                        key: kFleetRowAgeKey,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: ageStyle,
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
    //
    // The bar and age sit there only where the row keeps the server's name
    // and state word in full and the age fits too, each measured as drawn
    // at this text scale (03 §10.10); elsewhere they give way, and the
    // tooltip and the label still say what they show. The warning stays:
    // on touch it is the only way to its words.
    final barExtrasWidth = ageText == null
        ? null
        : (warning == null ? 0 : _warningExtent + _extrasGap) +
              math.max(
                _barWidth,
                (reading!.stale ? _staleIconSize + _staleIconGap : 0) +
                    _textWidth(context, ageText, ageStyle),
              ) +
              _extrasEndPadding;
    final barRowWidth = barExtrasWidth == null
        ? null
        : barExtrasWidth.ceilToDouble() + _rowNeed(context, label);
    return LayoutBuilder(
      builder: (context, constraints) {
        final showsBar =
            barRowWidth != null && constraints.maxWidth >= barRowWidth;
        final extras = [?warning, if (showsBar) ?bar];
        return Row(
          children: [
            Expanded(child: row),
            if (extras.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: showsBar
                      ? barExtrasWidth!.ceilToDouble()
                      : _warningExtent + _extrasEndPadding,
                ),
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  // The row's node has the tap already; the detector's own
                  // would merge into the list item as a second, unnamed stop.
                  excludeFromSemantics: true,
                  onTap: onActivate,
                  child: ExcludeSemantics(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(
                        end: _extrasEndPadding,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        spacing: _extrasGap,
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

  /// The width the kit's row needs to show the server's name and
  /// [stateWord] in full: its label's widest line, styled as `SidebarRow`
  /// styles it, and the kit's room around the label.
  double _rowNeed(BuildContext context, String? stateWord) {
    final theme = Theme.of(context);
    final scope = context.dependOnInheritedWidgetOfExactType<SidebarKitScope>();
    // The kit's defaults outside a scope; a list is always comfortable.
    final layout = scope?.layout ?? SidebarKitLayout.rail;
    final density = scope?.density ?? SidebarKitDensity.comfortable;
    final comfortable = density == SidebarKitDensity.comfortable;
    final titleStyle =
        (comfortable ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)
            ?.copyWith(
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            );
    final label = math.max(
      _textWidth(context, server.displayName, titleStyle),
      // Only a comfortable row draws the second line.
      comfortable && stateWord != null
          ? _textWidth(context, stateWord, theme.textTheme.bodySmall)
          : 0.0,
    );
    final touch = switch (theme.platform) {
      TargetPlatform.macOS ||
      TargetPlatform.linux ||
      TargetPlatform.windows => false,
      _ => true,
    };
    return _kitRowChrome(layout, density, touch: touch) +
        depth * _kitDepthIndent(layout, density) +
        label.ceilToDouble();
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

/// How wide [text] lays out on one line in [style] over the ambient text
/// style and scale: what a [Text] there takes to show it in full.
double _textWidth(BuildContext context, String text, TextStyle? style) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: DefaultTextStyle.of(context).style.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: 1,
  )..layout();
  final width = painter.width;
  // A painter holds a native paragraph until disposed.
  painter.dispose();
  return width;
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
