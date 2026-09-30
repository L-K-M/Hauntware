import 'package:flutter/foundation.dart';
import 'package:planchette_core/planchette_core.dart';

/// One recorded run: the tool and the options it ran with, resolved —
/// defaults included — so re-running it reproduces the run exactly.
final class TextToolRunRecord {
  const TextToolRunRecord(this.toolId, this.options);

  final String toolId;
  final Map<String, Object?> options;

  @override
  bool operator ==(Object other) =>
      other is TextToolRunRecord &&
      other.toolId == toolId &&
      _optionsEqual(other.options, options);

  @override
  int get hashCode => Object.hash(toolId, Object.hashAll(options.entries));

  static bool _optionsEqual(Map<String, Object?> a, Map<String, Object?> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }
}

/// The text tools a user ran, most recent first. A host may create one and
/// hand it to every controller — the app's menus then offer Repeat and a
/// Recent submenu across documents; without one a controller keeps its own.
///
/// Records that only restate a tool's defaults would make every Repeat label
/// identical to "run it again", so they still count: a repeat of the same
/// tool and options collapses into one entry rather than stacking.
final class TextToolHistory extends ChangeNotifier {
  TextToolHistory({Iterable<TextToolRunRecord> restored = const []}) {
    for (final record in restored) {
      if (_recent.length >= keep) break;
      if (textToolById(record.toolId) != null) _recent.add(_normalized(record));
    }
  }

  /// The record with its declared defaults filled in. Callers record the
  /// resolved set; a hand-built or stale record still reads complete.
  static TextToolRunRecord _normalized(TextToolRunRecord record) {
    final options = <String, Object?>{...record.options};
    for (final option
        in textToolById(record.toolId)?.options ?? const <TextToolOption>[]) {
      options.putIfAbsent(option.id, () => option.defaultValue);
    }
    return TextToolRunRecord(record.toolId, options);
  }

  /// How many runs Recent keeps.
  static const keep = 5;

  final _recent = <TextToolRunRecord>[];

  /// The newest run, for the Repeat row, or null before the first one.
  TextToolRunRecord? get last => _recent.firstOrNull;

  /// The newest [keep] runs, most recent first.
  List<TextToolRunRecord> get recent => List.unmodifiable(_recent);

  /// The options [toolId] last ran with, for a tool bar that pre-fills the
  /// last-used values, or the declared defaults when it never ran.
  Map<String, Object?> lastOptionsFor(String toolId) {
    for (final record in _recent) {
      if (record.toolId == toolId) return Map.of(record.options);
    }
    final tool = textToolById(toolId);
    return {
      for (final option in tool?.options ?? const <TextToolOption>[])
        option.id: option.defaultValue,
    };
  }

  /// Records a run of [toolId] with [options]. Missing declared options are
  /// filled with their defaults so a record always holds the resolved set,
  /// and an identical repeat moves to the front rather than duplicating.
  void record(String toolId, Map<String, Object?> options) {
    final record = _normalized(TextToolRunRecord(toolId, options));
    _recent.remove(record);
    _recent.insert(0, record);
    if (_recent.length > keep) _recent.removeRange(keep, _recent.length);
    notifyListeners();
  }

  /// The entries safe to keep across a restart. Text options can hold
  /// secrets, so like search history a record only persists when every
  /// declared text option still holds its default.
  List<TextToolRunRecord> get persistable => [
    for (final record in _recent)
      if (_isPersistable(record)) record,
  ];

  static bool _isPersistable(TextToolRunRecord record) {
    final tool = textToolById(record.toolId);
    if (tool == null) return false;
    for (final option in tool.options) {
      if (option is TextOption &&
          record.options[option.id] != option.defaultValue) {
        return false;
      }
    }
    return true;
  }

  /// [persistable] as JSON-ready maps: unknown or mistyped values are
  /// dropped, so the file's write/read round-trip never carries junk.
  List<Object?> encode() => [
    for (final record in persistable)
      {
        'id': record.toolId,
        'options': {
          for (final entry in record.options.entries)
            if (_isEncodable(record.toolId, entry.key, entry.value))
              entry.key: entry.value,
        },
      },
  ];

  static bool _isEncodable(String toolId, String optionId, Object? value) {
    final tool = textToolById(toolId);
    if (tool == null) return false;
    for (final option in tool.options) {
      if (option.id != optionId) continue;
      return switch (option) {
        ToggleOption() => value is bool,
        IntegerOption() => value is int,
        ChoiceOption() => value is String && option.choices.contains(value),
        TextOption() => value is String,
      };
    }
    return false;
  }

  /// Rebuilds a history from [encode]'s output. Anything unreadable —
  /// unknown tools, mistyped options — is skipped, never fatal.
  static TextToolHistory decode(Object? json) {
    final records = <TextToolRunRecord>[];
    if (json is List) {
      for (final entry in json) {
        if (entry is! Map) continue;
        final toolId = entry['id'];
        if (toolId is! String) continue;
        final options = <String, Object?>{};
        if (entry['options'] case Map optionsMap) {
          for (final option in optionsMap.entries) {
            if (option.key is! String) continue;
            if (_isEncodable(toolId, option.key as String, option.value)) {
              options[option.key as String] = option.value;
            }
          }
        }
        records.add(TextToolRunRecord(toolId, options));
      }
    }
    return TextToolHistory(restored: records);
  }
}
