import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerBulkVerb, ContainerPort, ContainerSummary, HealthStatus;

/// The Containers sub-tab's columns, whose names key them in the table,
/// its sort and the stored choice (03 §7.12 CTR-01, CTR-04, CTR-08,
/// CST-01).
enum ContainerColumn {
  name,
  state,
  health,
  status,
  image,
  ports,
  stack,
  cpu,
  memory,
  network,
  blockIo,
  pids,
  ip,
  started;

  /// Every column but the name, which always leads: the ones CTR-08's
  /// chooser shows, hides and orders.
  static final chooseable = [
    for (final column in values)
      if (column != name) column,
  ];
}

/// The columns shown after the name until the user chooses (CTR-08).
const kDefaultContainerColumns = [
  ContainerColumn.state,
  ContainerColumn.health,
  ContainerColumn.status,
  ContainerColumn.image,
  ContainerColumn.ports,
  ContainerColumn.stack,
  ContainerColumn.cpu,
  ContainerColumn.memory,
];

/// The columns [names] choose, in their order: the default for none, and
/// a name the tab does not know, the name column's, or a repeat skipped,
/// so a choice stored by another version still reads.
List<ContainerColumn> chosenContainerColumns(List<String>? names) {
  if (names == null) return kDefaultContainerColumns;

  final byName = ContainerColumn.values.asNameMap();
  final chosen = <ContainerColumn>[];
  for (final name in names) {
    final column = byName[name];
    if (column == null ||
        column == ContainerColumn.name ||
        chosen.contains(column)) {
      continue;
    }
    chosen.add(column);
  }
  return chosen;
}

/// [container]'s first address on a network, in the order the list gave
/// them, or null when it has none (host networking, or stopped).
String? containerIpOf(ContainerSummary container) {
  for (final ip in container.networks.values) {
    if (ip.isNotEmpty) return ip;
  }
  return null;
}

/// The label that names a container's compose project (compose's
/// `pkg/api/labels.go`), which groups the list (03 §7.16 STK-01).
const kComposeProjectLabel = 'com.docker.compose.project';

/// [container]'s compose project, read as the engine's stack grouping
/// reads it: the label's text, unless it is empty or masked. The
/// Containers tab does not watch the stacks list, whose source checks run
/// compose commands on the host (03 §7.16), for the name alone.
String? composeProjectOf(ContainerSummary container) {
  final label = container.labels[kComposeProjectLabel];
  if (label == null || label.isMasked || label.display.isEmpty) return null;
  return label.display;
}

/// The Engine API's container states, which the tab names in words, in
/// the state column's order: the running first, the dead last.
enum EngineContainerState {
  running,
  restarting,
  paused,
  created,
  removing,
  exited,
  dead;

  /// [state] as the engine named it, or null for a state outside the
  /// API's list, which the tab shows as the engine gave it.
  static EngineContainerState? of(String? state) =>
      _byName[state?.toLowerCase()];

  static final _byName = values.asNameMap();

  /// Whether a container in this state runs as `docker ps` without `-a`
  /// lists it: running, paused or restarting.
  bool get up => switch (this) {
    running || restarting || paused => true,
    created || removing || exited || dead => false,
  };
}

/// Whether [container] runs as `docker ps` without `-a` lists it.
bool containerIsUp(ContainerSummary container) =>
    EngineContainerState.of(container.state)?.up ?? false;

/// [id] as `docker ps` shortens it.
String shortContainerId(String id) => id.length > 12 ? id.substring(0, 12) : id;

/// [container]'s name, or its short id where it has none.
String containerNameOf(ContainerSummary container) =>
    container.name ?? shortContainerId(container.id);

/// The service a Swarm task belongs to, from its name (03 §7.12 CTR-01:
/// parsed defensively), for a container outside any compose project.
String? swarmServiceOf(ContainerSummary container) =>
    composeProjectOf(container) == null ? container.swarmServiceName : null;

/// The terms of a search query: lower-case words.
List<String> searchTerms(String query) => [
  for (final term in query.toLowerCase().split(RegExp(r'\s+')))
    if (term.isNotEmpty) term,
];

/// Whether every term of [terms] is in [container]'s name, image or id.
bool containerMatches(ContainerSummary container, List<String> terms) {
  if (terms.isEmpty) return true;

  final haystack = [
    ...container.names,
    container.image ?? '',
    container.id,
  ].join('\n').toLowerCase();
  return terms.every(haystack.contains);
}

/// The daemon's Status text without the health marker the health column
/// shows: "Up 3 hours", "Exited (0) 2 days ago".
String? containerStatusText(ContainerSummary container) {
  final status = container.status;
  if (status == null) return null;
  final text = status.replaceAll(_healthMarker, '').trim();
  return text.isEmpty ? null : text;
}

final _healthMarker = RegExp(
  r'\s*\((healthy|unhealthy|health: starting)\)',
  caseSensitive: false,
);

/// The exit code in a stopped or restarting container's Status text:
/// "Exited (137) 2 hours ago", "Restarting (1) 3 seconds ago", as
/// Docker's `State.String` and Podman print it. Null for any other.
int? containerExitCode(ContainerSummary container) {
  final match = _exitStatus.firstMatch(container.status ?? '');
  // A digit run past int's range reads as no code, not a thrown build.
  return match == null ? null : int.tryParse(match.group(1)!);
}

final _exitStatus = RegExp(r'^(?:Exited|Restarting) \((-?\d+)\)');

/// The exit codes a stop leaves, which the list cannot tell from a
/// failure: 128 plus SIGINT, SIGQUIT or SIGTERM, the usual stop signals,
/// or SIGKILL, which follows when the stop times out. An OOM kill also
/// leaves 137; the details say so from `State.OOMKilled`.
const _stopExitCodes = {130, 131, 137, 143};

/// A list row's CTR-09 flag.
enum ContainerFlag {
  /// The daemon is waiting to start it again after it exited, as a
  /// restart policy does in a loop.
  restartLoop,

  /// It exited with a code a stop does not leave.
  failed,
}

/// [container]'s flag, from what the list carries: its state and the
/// exit code in its Status text. The list has no `RestartCount` or
/// `State.OOMKilled`, which the details show from the inspect.
ContainerFlag? containerFlagOf(ContainerSummary container) {
  switch (EngineContainerState.of(container.state)) {
    case EngineContainerState.restarting:
      return ContainerFlag.restartLoop;
    case EngineContainerState.exited:
      final code = containerExitCode(container);
      if (code == null || code == 0 || _stopExitCodes.contains(code)) {
        return null;
      }
      return ContainerFlag.failed;
    default:
      return null;
  }
}

/// How long a container that is up has been, from its Status text: the
/// list carries no start time, and its "Up 3 hours" is go-units'
/// `HumanDuration`, which Docker and Podman both print, Podman with
/// " ago" after it. Null for a container that is not up, or a status in
/// other words.
Duration? containerUptime(ContainerSummary container) {
  final match = _upStatus.firstMatch(container.status ?? '');
  if (match == null) return null;

  final words = match.group(1)!.toLowerCase();
  switch (words) {
    case 'less than a second':
      return Duration.zero;
    case 'about a minute':
      return const Duration(minutes: 1);
    case 'about an hour':
      return const Duration(hours: 1);
  }
  final counted = _countedUnit.firstMatch(words);
  if (counted == null) return null;

  final unit = _UptimeUnit.values.byName(counted.group(2)!);
  return unit.length * int.parse(counted.group(1)!);
}

final _upStatus = RegExp(r'^Up (.+?)(?: ago)?(?: \(.*\))?$');
final _countedUnit = RegExp(
  r'^(\d+) (second|minute|hour|day|week|month|year)s?$',
);

/// The units `HumanDuration` counts in, a month as 30 days and a year as
/// 365, as it reckons them.
enum _UptimeUnit {
  second(Duration(seconds: 1)),
  minute(Duration(minutes: 1)),
  hour(Duration(hours: 1)),
  day(Duration(days: 1)),
  week(Duration(days: 7)),
  month(Duration(days: 30)),
  year(Duration(days: 365));

  const _UptimeUnit(this.length);

  final Duration length;
}

/// [container]'s ports as `docker ps` shows them: a wildcard address
/// left out, so IPv4's and IPv6's binding of one port read once.
String containerPortsText(ContainerSummary container) =>
    containerPortLabels(container).join(', ');

/// [container]'s ports one by one, as [containerPortsText] lists them.
List<String> containerPortLabels(ContainerSummary container) =>
    {for (final port in container.ports) _portLabel(port)}.toList();

String _portLabel(ContainerPort port) => switch (port.ip) {
  '0.0.0.0' || '::' => ContainerPort(
    privatePort: port.privatePort,
    publicPort: port.publicPort,
    type: port.type,
  ).label,
  _ => port.label,
};

/// The health column's order: trouble first.
int healthRank(HealthStatus? health) => switch (health) {
  HealthStatus.unhealthy => 0,
  HealthStatus.starting => 1,
  HealthStatus.healthy => 2,
  HealthStatus.none || null => 3,
};

/// How the Containers sub-tab lists its rows.
enum ContainerGrouping {
  /// Under a heading per compose project.
  byProject,

  /// In one list, as the Top view (CST-05) ranks them.
  flat,
}

/// [containers] that [runningOnly] and [terms] keep, in their order: the
/// containers the tab shows, folded headings or not.
List<ContainerSummary> containersShown(
  List<ContainerSummary> containers, {
  required bool runningOnly,
  required List<String> terms,
}) => [
  for (final container in containers)
    if ((!runningOnly || containerIsUp(container)) &&
        containerMatches(container, terms))
      container,
];

/// The ids of [selected] that [verb] takes (CTR-07), in their order.
List<String> bulkTargets(
  Iterable<ContainerSummary> selected,
  ContainerBulkVerb verb,
) => [
  for (final container in selected)
    if (verb.appliesTo(container.state)) container.id,
];

/// One row of the grouped list: a compose project's heading or a
/// container.
sealed class ContainerListEntry {
  const ContainerListEntry();
}

/// A group's heading: a compose project, or with a null [project] the
/// containers in none. [shown] and [up] count its containers that the
/// filters keep.
final class ContainerGroupEntry extends ContainerListEntry {
  const ContainerGroupEntry({
    required this.project,
    required this.shown,
    required this.up,
    required this.collapsed,
  });

  final String? project;
  final int shown;
  final int up;
  final bool collapsed;
}

/// A container's row.
final class ContainerEntry extends ContainerListEntry {
  const ContainerEntry(this.container);

  final ContainerSummary container;
}

/// [containers] as the tab lists them: those [runningOnly] and [terms]
/// keep, grouped by compose project in name order, the containers in no
/// project last. Each group's rows come in [order]'s order, and a group
/// in [collapsed] shows only its heading, unless [terms] search, which
/// shows every match. Where no container is in a compose project, or
/// [grouping] is [ContainerGrouping.flat], there are no headings.
List<ContainerListEntry> containerListEntries(
  List<ContainerSummary> containers, {
  required bool runningOnly,
  required List<String> terms,
  required Set<String?> collapsed,
  required List<ContainerEntry> Function(List<ContainerEntry> rows) order,
  ContainerGrouping grouping = ContainerGrouping.byProject,
}) {
  if (grouping == ContainerGrouping.flat) {
    return order([
      for (final container in containersShown(
        containers,
        runningOnly: runningOnly,
        terms: terms,
      ))
        ContainerEntry(container),
    ]);
  }

  final groups = <String?, List<ContainerEntry>>{};
  for (final container in containersShown(
    containers,
    runningOnly: runningOnly,
    terms: terms,
  )) {
    groups
        .putIfAbsent(composeProjectOf(container), () => [])
        .add(ContainerEntry(container));
  }
  if (!containers.any((container) => composeProjectOf(container) != null)) {
    return order(groups[null] ?? const []);
  }

  final projects = groups.keys.toList()
    ..sort((a, b) {
      if (a == null || b == null) {
        return (a == null ? 1 : 0) - (b == null ? 1 : 0);
      }
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  final folded = terms.isEmpty ? collapsed : const <String?>{};
  return [
    for (final project in projects) ...[
      ContainerGroupEntry(
        project: project,
        shown: groups[project]!.length,
        up: groups[project]!
            .where((entry) => containerIsUp(entry.container))
            .length,
        collapsed: folded.contains(project),
      ),
      if (!folded.contains(project)) ...order(groups[project]!),
    ],
  ];
}
