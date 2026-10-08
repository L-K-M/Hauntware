/// Validation for the fields of a configured external editor, shared by the
/// hosts' editor registries and their settings forms so a stored registry
/// and a typed one obey the same rules.
library;

const _maximumExtensionLength = 32;
const _maximumExtensionCount = 64;
const _maximumDisplayNameLength = 100;

/// [values] as a sorted, de-duplicated list of bare lower-case extensions:
/// ` .DART `, `*.dart` and `dart` all become `dart`; `tar.gz` stays
/// compound. Blank entries are dropped.
///
/// Throws a [FormatException] for an entry that could name a path or a
/// pattern rather than an extension, or for too many extensions.
List<String> normalizeEditorExtensions(Iterable<String> values) {
  final result = <String>{};
  for (var value in values) {
    value = value.trim().toLowerCase();
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    if (value.startsWith('*')) value = value.substring(1);
    while (value.startsWith('.')) {
      value = value.substring(1);
    }
    if (value.isEmpty) continue;
    if (value.length > _maximumExtensionLength ||
        RegExp(r'[/\\*?\x00-\x1f\x7f]').hasMatch(value)) {
      throw FormatException('Invalid file extension: $value');
    }
    result.add(value);
    if (result.length > _maximumExtensionCount) {
      throw const FormatException(
        'At most $_maximumExtensionCount extensions can be configured.',
      );
    }
  }
  return result.toList()..sort();
}

/// [value] trimmed, when it is a non-empty string of at most 100 characters
/// without control characters; otherwise throws a [FormatException].
String validateEditorDisplayName(Object? value) {
  if (value is! String) throw const FormatException('Invalid editor name');
  final name = value.trim();
  if (name.isEmpty ||
      name.length > _maximumDisplayNameLength ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
    throw const FormatException('Invalid editor name');
  }
  return name;
}
