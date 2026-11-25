import 'package:klabautermann_core/klabautermann_core.dart'
    show ContainerSummary;

/// One engine resource a Docker list sub-tab lists, with how many
/// containers use it. The sub-tab's own entry type adds what its row
/// shows, such as a network's built-in mark.
abstract class DockerResourceEntry<S> {
  const DockerResourceEntry(this.summary, this.containers);

  final S summary;

  /// How many containers use [summary], or null while no container list
  /// was read: the resource list itself carries no count.
  final int? containers;

  /// Whether no container uses [summary]; false while unknown.
  bool get unused => containers == 0;
}

/// Counts how many containers name each resource, by name, as [namesOf]
/// lists them. A container that names one twice counts it once, so a
/// volume mounted twice still uses it once.
Map<String, int> countContainerUse(
  List<ContainerSummary> containers,
  Iterable<String> Function(ContainerSummary container) namesOf,
) {
  final counts = <String, int>{};
  for (final container in containers) {
    for (final name in {...namesOf(container)}) {
      counts.update(name, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  return counts;
}

/// Whether every term of [terms] is in one of [fields], lower-cased.
bool matchesTerms(List<String> terms, List<String?> fields) {
  if (terms.isEmpty) return true;

  return terms.every(fields.join('\n').toLowerCase().contains);
}

/// [items] as a Docker list sub-tab lists them: those [keeps] and
/// [matches] keep, in the engine's order, each with its use counted from
/// [containers] when one was read.
List<R> dockerResourceEntries<S, R, F>(
  List<S> items, {
  required Map<String, int>? Function(List<ContainerSummary> containers)
  countUse,
  required R Function(S item, int? use) create,
  required bool Function(R entry, F filter) keeps,
  required bool Function(S item, List<String> terms) matches,
  required String Function(S item) nameOf,
  required List<ContainerSummary>? containers,
  required F filter,
  required List<String> terms,
}) {
  final counts = containers == null ? null : countUse(containers);
  return [
    for (final item in items)
      if (create(item, counts == null ? null : counts[nameOf(item)] ?? 0)
          case final entry when keeps(entry, filter) && matches(item, terms))
        entry,
  ];
}
