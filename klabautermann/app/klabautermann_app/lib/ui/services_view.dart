import 'package:klabautermann_core/klabautermann_core.dart';

import '../controllers/log_reads.dart';
import '../controllers/log_streams.dart';
import '../l10n/app_localizations.dart';

/// How many recent journal records a unit's page reads (SVC-04, 03 §7.5:
/// `journalctl -u <unit> -o json -n 50`).
const int kUnitLogWindow = 50;

/// systemd's unit types, which a unit's name ends in (`unit_type_table`
/// in systemd's `src/basic/unit-def.c`).
enum UnitType {
  service,
  mount,
  swap,
  socket,
  target,
  device,
  automount,
  timer,
  path,
  slice,
  scope,
}

/// systemd's active states (`unit_active_state_table`).
enum UnitActiveState {
  active,
  reloading,
  inactive,
  failed,
  activating,
  deactivating,
  maintenance,
  refreshing,
}

/// systemd's load states (`unit_load_state_table`), whose names it joins
/// with a hyphen where these change case.
enum _UnitLoadState {
  stub,
  loaded,
  notFound,
  badSetting,
  error,
  merged,
  masked,
}

final Map<String, UnitType> _types = UnitType.values.asNameMap();
final Map<String, UnitActiveState> _activeStates = UnitActiveState.values
    .asNameMap();
final Set<String> _loadStates = {
  for (final state in _UnitLoadState.values)
    state.name.replaceAllMapped(
      RegExp('[A-Z]'),
      (capital) => '-${capital[0]!.toLowerCase()}',
    ),
};

/// How systemd spells a sub state: lowercase words joined by hyphens.
final _subState = RegExp(r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$');

/// A unit's type and states as the Services panel shows them; null is
/// unknown.
typedef UnitStates = ({
  UnitType? type,
  String? load,
  UnitActiveState? active,
  String? sub,
});

/// [unit]'s type and states, each unknown (null) unless it is a value
/// systemd uses in that column (CN-10). Below systemd 246 the host reads
/// `systemctl` text by position, so a row it misread, such as one led by
/// a status bullet, shifts every column; its name then ends in no unit
/// type, and all its states read as unknown rather than as a guess.
UnitStates unitStatesOf(SystemdUnit unit) {
  final name = unit.unit;
  final dot = name.lastIndexOf('.');
  final type = dot > 0 ? _types[name.substring(dot + 1)] : null;
  if (type == null) return (type: null, load: null, active: null, sub: null);

  final sub = unit.sub;
  return (
    type: type,
    load: _loadStates.contains(unit.load) ? unit.load : null,
    active: _activeStates[unit.active],
    sub: sub != null && _subState.hasMatch(sub) ? sub : null,
  );
}

/// [unit]'s description, unknown (null) with the states of a row whose
/// name ends in no unit type: a text row the host misread by position
/// holds its sub state and more there, never the description (CN-10).
String? unitDescriptionOf(SystemdUnit unit) =>
    unitStatesOf(unit).type == null ? null : unit.description;

/// What a filter over one unit column keeps: every unit when [any], else
/// the units whose value is [value], null meaning unknown.
typedef UnitFilter<T extends Enum> = ({bool any, T? value});

/// The units of [units] that [type] and [state] keep, in their order.
List<SystemdUnit> filterUnits(
  List<SystemdUnit> units, {
  required UnitFilter<UnitType> type,
  required UnitFilter<UnitActiveState> state,
}) => [
  for (final unit in units)
    if (unitStatesOf(unit) case final states
        when (type.any || type.value == states.type) &&
            (state.any || state.value == states.active))
      unit,
];

/// A filter's choices over the [present] values: every unit, each present
/// value in [all]'s order, unknown when a unit's value is, and [selected]
/// whatever the units hold, so a refresh never takes the user's choice
/// away.
List<UnitFilter<T>> filterChoices<T extends Enum>(
  Iterable<T?> present,
  List<T> all,
  UnitFilter<T> selected,
) {
  final shown = {...present, if (!selected.any) selected.value};
  return [
    (any: true, value: null),
    for (final value in all)
      if (shown.contains(value)) (any: false, value: value),
    if (shown.contains(null)) (any: false, value: null),
  ];
}

/// What a unit's page says about its log [read] in place of, or above,
/// its lines; null once lines show and there is nothing to add.
String? unitLogsNotice(AppLocalizations l10n, LogRead read) {
  final empty = read.records.isEmpty;
  return switch (read.state) {
    LogReadRequested() => l10n.servicesLogsRequested,
    LogReadRefused(rejection: LogRejection.refused) => l10n.servicesLogsRefused,
    LogReadRefused(rejection: LogRejection.engineStopped) =>
      l10n.servicesLogsEngineStopped,
    LogReadReported(:final status) => switch (status) {
      LogStreamWaiting(:final reason) => switch (reason) {
        LogStreamWaitReason.link => l10n.servicesLogsWaitingLink,
        LogStreamWaitReason.channel => l10n.servicesLogsWaitingChannel,
        LogStreamWaitReason.background => l10n.servicesLogsWaitingBackground,
      },
      LogStreamRunning() => empty ? l10n.servicesLogsReading : null,
      LogStreamEnded(:final reason) => switch (reason) {
        LogStreamEndReason.windowFilled ||
        LogStreamEndReason.oldestReached ||
        LogStreamEndReason.closed => empty ? l10n.servicesLogsEmpty : null,
        LogStreamEndReason.invalid => l10n.servicesLogsInvalid,
        LogStreamEndReason.missing => l10n.servicesLogsMissing,
        LogStreamEndReason.denied => l10n.servicesLogsDenied,
        // A container's logs, which a unit's page never opens.
        LogStreamEndReason.failed ||
        LogStreamEndReason.logDriverUnreadable => l10n.servicesLogsFailed,
      },
    },
  };
}
