/// Tolerant reader over one decoded JSON object (03 §5.8: models target
/// 1.44, ignore unknown fields and treat a wrong type as a warning, never
/// a throw). Every model parser in this package reads daemon input
/// through this class, so the `ParseResult<T>` convention holds even when
/// the daemon sends a field in an unexpected shape.
final class JsonReader {
  JsonReader(this.raw, [List<String>? warnings])
    : warnings = warnings ?? <String>[];

  final Map<String, Object?> raw;
  final List<String> warnings;

  bool has(String key) => raw[key] != null;

  Object? operator [](String key) => raw[key];

  String? string(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is String) return v;
    warnings.add('$key is not a string (${_typeOf(v)})');
    return null;
  }

  int? integer(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is int) return v;
    if (v is double && v.isFinite && v == v.roundToDouble()) return v.toInt();
    warnings.add('$key is not an integer (${_typeOf(v)})');
    return null;
  }

  double? number(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is num) return v.toDouble();
    warnings.add('$key is not a number (${_typeOf(v)})');
    return null;
  }

  bool? boolean(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is bool) return v;
    warnings.add('$key is not a bool (${_typeOf(v)})');
    return null;
  }

  List<Object?>? list(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is List) return List<Object?>.of(v);
    warnings.add('$key is not a list (${_typeOf(v)})');
    return null;
  }

  Map<String, Object?>? map(String key) {
    final v = raw[key];
    if (v == null) return null;
    if (v is Map) return _stringKeyed(v, key);
    warnings.add('$key is not an object (${_typeOf(v)})');
    return null;
  }

  Map<String, Object?> mapOrEmpty(String key) => map(key) ?? const {};

  /// A string list; non-string entries are skipped with a warning.
  List<String> stringList(String key) {
    final v = raw[key];
    if (v == null) return const <String>[];
    if (v is! List) {
      warnings.add('$key is not a list (${_typeOf(v)})');
      return const <String>[];
    }
    final out = <String>[];
    for (final e in v) {
      if (e is String) {
        out.add(e);
      } else {
        warnings.add('$key has a non-string entry (${_typeOf(e)})');
      }
    }
    return out;
  }

  /// A string map; non-string entries are skipped with a warning.
  Map<String, String> stringMap(String key) {
    final v = raw[key];
    if (v == null) return const <String, String>{};
    if (v is! Map) {
      warnings.add('$key is not an object (${_typeOf(v)})');
      return const <String, String>{};
    }
    final out = <String, String>{};
    for (final e in v.entries) {
      final k = e.key;
      final value = e.value;
      if (k is String && value is String) {
        out[k] = value;
      } else {
        warnings.add('$key has a non-string entry');
      }
    }
    return out;
  }

  Map<String, Object?> _stringKeyed(Map<Object?, Object?> m, String key) {
    final out = <String, Object?>{};
    for (final e in m.entries) {
      final k = e.key;
      if (k is String) {
        out[k] = e.value;
      } else {
        warnings.add('$key has a non-string key (${_typeOf(k)})');
      }
    }
    return out;
  }

  static String _typeOf(Object? v) =>
      v == null ? 'null' : v.runtimeType.toString();
}

/// Copies a decoded JSON object into a `Map<String, Object?>`, dropping
/// non-string keys (JSON object keys are always strings, so this only
/// guards a hostile or hand-built map).
Map<String, Object?> asStringMap(Map<Object?, Object?> m) {
  final out = <String, Object?>{};
  for (final e in m.entries) {
    final k = e.key;
    if (k is String) out[k] = e.value;
  }
  return out;
}
