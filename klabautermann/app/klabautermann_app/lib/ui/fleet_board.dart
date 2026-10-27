import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_servers/ghost_servers.dart';
import 'package:ghost_theme/ghost_theme.dart' show GhostChrome;
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/fleet_controller.dart';
import '../controllers/fleet_density.dart';
import '../controllers/monitoring_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import 'chart_strings.dart';
import 'charts/charts.dart';
import 'fleet_rail.dart' show linkStatusWord;
import 'fleet_row_state.dart';
import 'fleet_rows.dart' show fleetRowAge, fleetStatusStrings;
import 'server_header.dart' show LinkDot;
import 'threshold_scope.dart';

/// The device's FL-08 layout for the widgets under it; the composition
/// root puts it above every route, and a test may leave it out, which
/// keeps the workspace's invitation.
class FleetDensityScope extends InheritedNotifier<FleetDensityController> {
  const FleetDensityScope({
    super.key,
    required FleetDensityController density,
    required super.child,
  }) : super(notifier: density);

  /// The layout controller for [context], or null when none is provided;
  /// [context] rebuilds when the layout changes.
  static FleetDensityController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FleetDensityScope>()?.notifier;
}

/// FL-08's fleet board: every server as a card or a grid tile, opened by
/// a tap, under a header that picks the layout. [invitation] stands in
/// for the tiles while the layout is [FleetDensity.rows].
class FleetBoard extends StatelessWidget {
  const FleetBoard({
    super.key,
    required this.fleet,
    required this.monitoring,
    required this.density,
    required this.invitation,
  });

  final FleetController fleet;
  final MonitoringController monitoring;
  final FleetDensityController density;
  final Widget invitation;

  /// A card's and a grid tile's width; tiles fill each line at these and
  /// the line's rest is left over.
  static const double cardWidth = 280;
  static const double gridWidth = 168;

  Future<void> _pick(BuildContext context, FleetDensity picked) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await density.setDensity(picked);
    } on FleetDensityNotSavedException catch (error) {
      debugPrint('$error');
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.fleetDensityNotSaved);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final servers = fleet.servers;
    final shown = density.value.resolve(servers.length);
    final picker = Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l10n.fleetDensityLabel,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          SegmentedButton<FleetDensity>(
            showSelectedIcon: false,
            segments: [
              for (final option in FleetDensity.values)
                ButtonSegment(
                  value: option,
                  label: Text(l10n.fleetDensity(option.name)),
                ),
            ],
            selected: {density.value},
            onSelectionChanged: (picked) =>
                unawaited(_pick(context, picked.single)),
          ),
        ],
      ),
    );
    if (shown == FleetDensity.rows) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          picker,
          Expanded(child: invitation),
        ],
      );
    }

    final compact = shown == FleetDensity.grid;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: picker),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          sliver: SliverToBoxAdapter(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final server in servers)
                  SizedBox(
                    width: compact ? gridWidth : cardWidth,
                    child: FleetTile(
                      key: ValueKey(server.id),
                      server: server,
                      fleet: fleet,
                      monitoring: monitoring,
                      compact: compact,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// One server on the [FleetBoard]: its state word and, while the app
/// holds a reading for it, the rows' pressure bar and age (03 §10.3), the
/// numbers too in a card. [compact] is the grid's tile: the name, the dot
/// and the bar. One screen-reader button, named as its row is.
class FleetTile extends StatelessWidget {
  const FleetTile({
    super.key,
    required this.server,
    required this.fleet,
    required this.monitoring,
    this.compact = false,
  });

  final FleetServer server;
  final FleetController fleet;
  final MonitoringController monitoring;
  final bool compact;

  static final Listenable _silent = Listenable.merge(const []);

  @override
  Widget build(BuildContext context) {
    final id = server.id;
    final overview = monitoring.sampleFor(id, SampleStream.overview);
    final core = monitoring.sampleFor(id, SampleStream.core);
    final fs = monitoring.sampleFor(id, SampleStream.fs);
    final onstage = TickerMode.valuesOf(context).enabled;
    return ListenableBuilder(
      listenable: Listenable.merge([overview, core, fs]),
      builder: (context, _) {
        // As a row does: only a tile with a reading keeps the clock
        // ticking for its age, and only while it shows.
        final counting = overview.value != null || core.value != null;
        return ListenableBuilder(
          listenable: counting && onstage ? monitoring.clock : _silent,
          builder: (context, _) => _build(
            context,
            overview.value,
            core.value,
            fs.value,
            counting ? monitoring.clock.value : null,
          ),
        );
      },
    );
  }

  Widget _build(
    BuildContext context,
    Sample? overview,
    Sample? core,
    Sample? fs,
    DateTime? now,
  ) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final chrome = GhostChrome.of(context, klabautermannThemeStyle);
    final link = fleet.linkStatusFor(server.id);
    final session = ghostSessionOf(link);
    final indicator = ghostServerIndicator(
      fleetStatusStrings(l10n, link),
      GhostIndicatorRule.rail,
      session: session,
      probe: ghostProbeOf(fleet.reachabilityFor(server.id)),
    );
    final reading = now == null
        ? null
        : fleetRowReading(
            overview: overview,
            core: core,
            fs: fs,
            session: session,
            now: now,
          );
    final cells = reading == null
        ? null
        : [
            PressureCell(
              label: l10n.fleetRowCpu,
              percent: reading.cpuPercent,
              thresholds: ThresholdScope.of(context, ThresholdMetric.cpu),
            ),
            PressureCell(
              label: l10n.fleetRowMemory,
              percent: reading.memoryPercent,
              thresholds: ThresholdScope.of(context, ThresholdMetric.memory),
            ),
            PressureCell(
              label: l10n.fleetRowDisk,
              percent: reading.diskPercent,
              thresholds: ThresholdScope.of(context, ThresholdMetric.disk),
            ),
          ];
    final chartStrings = klabautermannChartStrings(l10n);
    final pressure = cells == null
        ? null
        : pressureSummary(cells, chartStrings, stale: reading!.stale);
    final age = reading == null ? null : fleetRowAge(l10n, reading.age);
    final word = indicator.label ?? linkStatusWord(l10n, link);
    final secondary = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final dot = ghostStatusDot(
      indicator,
      GhostStatusColors(
        online: chrome.statusConnected,
        connecting: chrome.statusConnecting,
        offline: chrome.statusFailed,
      ),
    );

    return Semantics(
      button: true,
      label: [
        server.displayName,
        l10n.statusSemantics(word),
        ?pressure,
        if (age != null) l10n.fleetRowUpdated(age),
      ].join(l10n.fleetRowListSeparator),
      excludeSemantics: true,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => fleet.select(server.id),
          child: Padding(
            padding: EdgeInsets.all(compact ? 10 : 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              spacing: compact ? 6 : 8,
              children: [
                Row(
                  spacing: 8,
                  children: [
                    if (dot != null) LinkDot(dot),
                    Expanded(
                      child: Text(
                        server.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: compact
                            ? theme.textTheme.titleSmall
                            : theme.textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                if (!compact)
                  Text(
                    [word, ?server.address].join(l10n.fleetRowPartSeparator),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: secondary,
                  ),
                if (cells != null)
                  PressureBar(
                    cells: cells,
                    strings: chartStrings,
                    stale: reading!.stale,
                  ),
                if (cells != null && !compact)
                  Text(
                    [
                      for (final cell in cells)
                        if (cell.percent case final percent?)
                          l10n.fleetTileShare(cell.label, percent.round()),
                    ].join(l10n.fleetRowPartSeparator),
                    style: secondary,
                  ),
                if (age != null)
                  Text(
                    reading!.stale ? l10n.fleetRowStaleAge(age) : age,
                    style: secondary,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
