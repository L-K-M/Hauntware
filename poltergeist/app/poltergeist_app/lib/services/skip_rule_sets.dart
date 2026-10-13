import 'package:flutter/foundation.dart';

/// A named list of skip patterns (05 §3's rule sets): a template kept on
/// this device whose lines a sync pair copies into its own excludes.
/// Pairs keep the copy, so a later edit to the set changes no pair and
/// the saved-sync record carries no reference to it.
@immutable
final class SkipRuleSet {
  SkipRuleSet({required String name, required Iterable<String> patterns})
    : name = name.trim(),
      patterns = List.unmodifiable(patterns);

  /// Trimmed and unique on this device, ignoring case.
  final String name;

  /// gitignore-style lines, trimmed, with no blank lines.
  final List<String> patterns;

  Map<String, Object> toJson() => {'name': name, 'patterns': patterns};

  /// The set [json] holds, or null when it holds none: a non-map, a
  /// missing or blank name, patterns that are not a list, or patterns
  /// with no line the editor would accept ([hasSkipPattern]). Non-string
  /// pattern entries are dropped and the rest read as [skipRuleLines]
  /// reads an editor's lines.
  static SkipRuleSet? fromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    final patterns = json['patterns'];
    if (name is! String || name.trim().isEmpty || patterns is! List) {
      return null;
    }
    final lines = skipRuleLines(patterns.whereType<String>().join('\n'));
    if (!hasSkipPattern(lines)) return null;
    return SkipRuleSet(name: name, patterns: lines);
  }

  @override
  bool operator ==(Object other) =>
      other is SkipRuleSet &&
      other.name == name &&
      listEquals(other.patterns, patterns);

  @override
  int get hashCode => Object.hash(name, Object.hashAll(patterns));
}

/// Thrown when a save would take a name another set already holds:
/// the stored list can hold a set the list on screen missed (a launch
/// whose read failed), and saving must never replace it.
final class SkipRuleSetNameTaken implements Exception {
  const SkipRuleSetNameTaken(this.name);

  /// The name as the existing set spells it.
  final String name;
}

/// The stored sets in [stored], in order. Entries that do not decode are
/// dropped, as is any set whose name an earlier one already holds, so a
/// damaged value keeps every set it still can.
List<SkipRuleSet> decodeSkipRuleSets(Object? stored) {
  final sets = <SkipRuleSet>[];
  if (stored is List) {
    for (final entry in stored) {
      final set = SkipRuleSet.fromJson(entry);
      if (set == null || skipRuleSetNamed(sets, set.name) != null) continue;
      sets.add(set);
    }
  }
  return List.unmodifiable(sets);
}

/// An editor's text as excludes lines: each line trimmed and blank lines
/// dropped, as the Skip Rules dialog and the pair editor save them.
List<String> skipRuleLines(String text) => [
  for (final line in text.split('\n'))
    if (line.trim().isNotEmpty) line.trim(),
];

/// [existing] followed by each line of [patterns] it lacks, in order.
///
/// Rules match last-wins, so a line is never moved: a pair that already
/// holds `*.log` before its own `!debug.log` keeps debug.log included
/// rather than having a set's `*.log` exclude it again below.
List<String> appendSkipRules(List<String> existing, Iterable<String> patterns) {
  final lines = skipRuleLines(existing.join('\n'));
  final seen = lines.toSet();
  for (final line in skipRuleLines(patterns.join('\n'))) {
    if (seen.add(line)) lines.add(line);
  }
  return lines;
}

/// Whether [lines] hold at least one pattern rather than only comments.
bool hasSkipPattern(Iterable<String> lines) =>
    lines.any((line) => line.trim().isNotEmpty && !line.trim().startsWith('#'));

/// The set in [sets] named [name], ignoring case and surrounding space.
SkipRuleSet? skipRuleSetNamed(List<SkipRuleSet> sets, String name) {
  final key = _nameKey(name);
  for (final set in sets) {
    if (_nameKey(set.name) == key) return set;
  }
  return null;
}

/// [sets] with [set] saved in place of the set named [replacing] (an
/// edit or rename), else at the end. Throws [SkipRuleSetNameTaken] when
/// any other set already holds [set]'s name.
List<SkipRuleSet> putSkipRuleSetInto(
  List<SkipRuleSet> sets,
  SkipRuleSet set, {
  String? replacing,
}) {
  final replaced = replacing == null ? null : _nameKey(replacing);
  for (final existing in sets) {
    final key = _nameKey(existing.name);
    if (key == _nameKey(set.name) && key != replaced) {
      throw SkipRuleSetNameTaken(existing.name);
    }
  }

  final next = <SkipRuleSet>[];
  var placed = false;
  for (final existing in sets) {
    if (!placed && _nameKey(existing.name) == replaced) {
      next.add(set);
      placed = true;
    } else {
      next.add(existing);
    }
  }
  if (!placed) next.add(set);
  return List.unmodifiable(next);
}

/// [sets] without the set named [name].
List<SkipRuleSet> removeSkipRuleSetFrom(List<SkipRuleSet> sets, String name) =>
    List.unmodifiable([
      for (final set in sets)
        if (_nameKey(set.name) != _nameKey(name)) set,
    ]);

String _nameKey(String name) => name.trim().toLowerCase();
