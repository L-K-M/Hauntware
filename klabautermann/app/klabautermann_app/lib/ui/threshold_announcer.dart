import 'dart:async' show unawaited;
import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart' show ValueListenable, mapEquals;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart'
    show AccessibilityFocusBlockType, SemanticsService;
import 'package:klabautermann_core/klabautermann_core.dart';

import '../l10n/app_localizations.dart';
import 'charts/charts.dart' show ChartSeverity, ChartThresholds;
import 'system_view.dart' show shownMounts;
import 'threshold_scope.dart';

/// How long a value must stay past a level, or back under it, before its
/// band changes for A11Y-15: the threshold rules' `for` (03 §7.19), so a
/// value flapping around a level is not read out at every reading. Two
/// `core` readings even at the Cellular saver column's 10 s, and the next
/// `fs` reading in every column (03 §6.4).
const Duration kBandHold = Duration(seconds: 10);

/// What the Overview announces (D60): CPU busy and used memory from
/// `core`, and each listed mount's space and inode use from `fs`, each
/// against its OV-11 warning and critical levels, as the health card
/// judges the mounts. The careful band is shown, never announced.
enum BandMetric {
  cpu(ThresholdMetric.cpu),
  memory(ThresholdMetric.memory),
  diskSpace(ThresholdMetric.disk),
  diskInodes(ThresholdMetric.disk);

  const BandMetric(this.levels);

  /// The OV-11 metric whose levels judge this value.
  final ThresholdMetric levels;
}

/// One value's band against [levels] for A11Y-15, debounced by
/// `threshold.dart`'s hysteresis rules: one rule per level, raised once the
/// value has held at or above it for [kBandHold] and cleared once it has
/// held below it as long. The band is the highest raised level.
final class BandWatch {
  BandWatch(
    BandMetric metric, {
    ChartThresholds levels = kDefaultThresholds,
    Duration hold = kBandHold,
  }) : _levels = levels,
       _warning = _rule(metric, levels.warning, hold),
       _critical = _rule(metric, levels.critical, hold);

  final ChartThresholds _levels;
  final ThresholdRule _warning, _critical;
  ThresholdState _warned = ThresholdState.idle;
  ThresholdState _criticalled = ThresholdState.idle;

  /// Null until the first known value.
  ChartSeverity? _band;

  /// Raised at or above [level] and cleared below it: one level, no new
  /// threshold, with [hold] as the debounce on both sides. The rule's
  /// severity names an alert (v1), which this watch never raises.
  static ThresholdRule _rule(BandMetric metric, double level, Duration hold) =>
      ThresholdRule(
        metric: metric.name,
        op: ThresholdOp.greaterOrEqual,
        raise: ThresholdBound(value: level, duration: hold),
        clear: ThresholdBound(value: level, duration: hold),
      );

  /// The band [value], read [at], moves the value into, or null when it
  /// stays. The first known value only says where it starts, since the
  /// card already shows it; an unknown one holds the band. A band is
  /// taken only with a value inside it: each level's rule settles on its
  /// own, so after one reading between the levels the lower rule can
  /// still be settling when the value has gone past both.
  ChartSeverity? observe(double? value, DateTime at) {
    if (value == null || value.isNaN) return null;

    final band = _band;
    if (band == null) {
      final start = _bandOf(value);
      ThresholdState seed(bool raised) =>
          raised ? ThresholdState(RulePhase.firing, at) : ThresholdState.idle;
      _warned = seed(start.alarms);
      _criticalled = seed(start == ChartSeverity.critical);
      _band = start;
      return null;
    }

    _warned = evaluateThreshold(_warning, _warned, value: value, at: at);
    _criticalled = evaluateThreshold(
      _critical,
      _criticalled,
      value: value,
      at: at,
    );
    final now = _criticalled.raised
        ? ChartSeverity.critical
        : _warned.raised
        ? ChartSeverity.warning
        : ChartSeverity.normal;
    if (now == band || now != _bandOf(value)) return null;

    _band = now;
    return now;
  }

  /// [value]'s band, with careful counted as normal: only warning and
  /// critical are heard.
  ChartSeverity _bandOf(double value) => switch (_levels.severityOf(value)) {
    ChartSeverity.careful => ChartSeverity.normal,
    final band => band,
  };
}

/// Used memory as a share of the total, or null when either is unknown.
double? memoryPercent(MemoryUsage? memory) {
  final used = memory?.usedBytes;
  final total = memory?.totalBytes;
  if (used == null || total == null || total <= 0) return null;
  return used / total * 100;
}

/// What the Overview reads of the app's settings (D60): whether A11Y-15's
/// announcements are on, and how to open Settings, whose General tab
/// switches them. It sits above the navigator, as the macOS toolbar
/// band's scope does, because a phone pushes the server screen as a route
/// of its own; without one, as in most tests, nothing is announced and
/// the health card shows no link.
class AnnouncementScope extends InheritedNotifier<ValueListenable<bool>> {
  const AnnouncementScope({
    super.key,
    required ValueListenable<bool> announce,
    required this.openSettings,
    required super.child,
  }) : super(notifier: announce);

  /// Opens Settings from a context under the navigator.
  final void Function(BuildContext context) openSettings;

  static AnnouncementScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AnnouncementScope>();
}

typedef _WatchKey = (BandMetric metric, String? mountPoint);

/// Tells the screen reader when one of [BandMetric]'s values in [core]
/// and [fs] crosses into or out of a warning or critical band (A11Y-15),
/// while [active]: the Overview shows and the switch is on. Values that
/// refresh every few seconds are never live regions; only band changes
/// are heard, once each [BandWatch] lets them through. Going inactive
/// drops every watch, so a return starts from what then shows. The
/// changes one reading brings are one announcement.
///
/// Where the platform takes no announcements (Android), the latest
/// changes are the label of a live region, as the fleet list's link
/// announcer does.
class ThresholdAnnouncer extends StatefulWidget {
  const ThresholdAnnouncer({
    super.key,
    required this.core,
    required this.fs,
    required this.active,
    required this.child,
  });

  /// The server's latest `core` and `fs` samples, as the panel reads them
  /// on every build: a server that left the fleet and came back has new
  /// ones (SYN-08), and new ones start every watch over.
  final ValueListenable<Sample?> core, fs;
  final bool active;
  final Widget child;

  @override
  State<ThresholdAnnouncer> createState() => _ThresholdAnnouncerState();
}

class _ThresholdAnnouncerState extends State<ThresholdAnnouncer> {
  final Map<_WatchKey, BandWatch> _watches = {};

  /// The levels the watches were built with; new levels start them over.
  Map<ThresholdMetric, ChartThresholds> _levels = const {};
  ValueListenable<Sample?>? _core;
  ValueListenable<Sample?>? _fs;

  late AppLocalizations _l10n;
  late FlutterView _view;
  late TextDirection _direction;
  late bool _announces;

  /// The last changes, for the live region; null before any.
  String? _liveText;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Read here, since samples arrive outside a build.
    _l10n = AppLocalizations.of(context);
    _view = View.of(context);
    _direction = Directionality.of(context);
    _announces = MediaQuery.maybeSupportsAnnounceOf(context) ?? false;
    final levels = {
      for (final metric in ThresholdMetric.values)
        metric: ThresholdScope.of(context, metric),
    };
    if (!mapEquals(levels, _levels)) {
      _levels = levels;
      _watches.clear();
    }
    _sync();
  }

  @override
  void didUpdateWidget(ThresholdAnnouncer oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  /// Listens to the widget's samples while it is active, and starts over
  /// whenever that or the samples change.
  void _sync() {
    final active = widget.active;
    final core = active ? widget.core : null;
    final fs = active ? widget.fs : null;
    if (core == _core && fs == _fs) return;

    _detach();
    if (core == null || fs == null) return;
    _core = core..addListener(_onCore);
    _fs = fs..addListener(_onFs);
    // What shows now only sets where each value starts.
    _observeCore();
    _observeFs();
  }

  void _detach() {
    _core?.removeListener(_onCore);
    _fs?.removeListener(_onFs);
    _core = _fs = null;
    _watches.clear();
    _liveText = null;
  }

  void _onCore() => _announce(_observeCore());

  void _onFs() => _announce(_observeFs());

  List<String> _observeCore() {
    if (_core?.value case Sample(
      :final at,
      result: CoreResult(:final cpu, :final memory),
    )) {
      return [
        ?_observe((BandMetric.cpu, null), cpu?.busy, at),
        ?_observe((BandMetric.memory, null), memoryPercent(memory), at),
      ];
    }
    return const [];
  }

  /// A timed-out or failed `df` holds every mount's band; a mount no
  /// longer listed drops its watches.
  List<String> _observeFs() {
    if (_fs?.value case Sample(:final at, result: FsResult(:final fs))) {
      final mounts = shownMounts(fs, showPseudo: false);
      final listed = {for (final mount in mounts) mount.mountPoint};
      _watches.removeWhere(
        (key, _) => key.$2 != null && !listed.contains(key.$2),
      );
      return [
        for (final mount in mounts) ...[
          ?_observe(
            (BandMetric.diskSpace, mount.mountPoint),
            mount.capacityPercent?.toDouble(),
            at,
          ),
          ?_observe(
            (BandMetric.diskInodes, mount.mountPoint),
            mount.inodeUsePercent?.toDouble(),
            at,
          ),
        ],
      ];
    }
    return const [];
  }

  /// The announcement for [key]'s band change at [value], or null. The
  /// band is judged on the whole percent the announcement speaks, so a
  /// figure never contradicts its band: 79.6 % is not "80%: back to
  /// normal".
  String? _observe(_WatchKey key, double? value, DateTime at) {
    final (metric, mountPoint) = key;
    final spoken = value?.roundToDouble();
    final band = _watches
        .putIfAbsent(
          key,
          () => BandWatch(metric, levels: _levels[metric.levels]!),
        )
        .observe(spoken, at);
    if (band == null) return null;

    final name = switch (metric) {
      BandMetric.cpu => _l10n.overviewCpuTitle,
      BandMetric.memory => _l10n.overviewMemoryTitle,
      BandMetric.diskSpace => _l10n.overviewBandDisk(mountPoint!),
      BandMetric.diskInodes => _l10n.overviewBandInodes(mountPoint!),
    };
    return _l10n.overviewBandAnnouncement(
      name,
      _l10n.chartPercent(spoken! / 100),
      band.name,
    );
  }

  /// One reading's changes, as one utterance either way: iOS speaks a
  /// Flutter announcement at once, cutting off the one before it, and
  /// Windows keeps one alert text that the next announcement replaces, so
  /// changes sent one by one could leave only the last heard.
  void _announce(List<String> changes) {
    if (changes.isEmpty) return;

    final text = changes.join(_l10n.chartListSeparator);
    if (!_announces) {
      setState(() => _liveText = text);
      return;
    }
    unawaited(SemanticsService.sendAnnouncement(_view, text, _direction));
  }

  @override
  Widget build(BuildContext context) {
    final live = widget.active && !_announces;
    // As the fleet list's announcer: the node takes no accessibility focus
    // of its own, and the cards stay nodes of their own.
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
