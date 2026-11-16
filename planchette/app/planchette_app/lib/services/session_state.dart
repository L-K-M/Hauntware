import 'package:planchette_editor/planchette_editor.dart';

/// One document of a window the hot-exit journal keeps (A2): a local file
/// by [path], or an untitled buffer by [untitledName], with its unsaved
/// [text] while it has any.
///
/// The text is kept only until the document is saved or discarded: a clean
/// file is remembered by its path alone, so a session restores it from disk.
final class SessionTab {
  const SessionTab({
    this.path,
    this.untitledName,
    this.text,
    this.baselineSha256,
    this.metadata = const TextDocumentMetadata(),
    this.line = 1,
    this.column = 1,
  }) : assert(
         (path == null) != (untitledName == null),
         'a tab is either a file or an untitled buffer',
       );

  /// The local file, absolute; null for an untitled buffer.
  final String? path;

  /// The untitled buffer's name, or the name of a server document whose
  /// unsaved text comes back as an untitled buffer.
  final String? untitledName;

  /// The unsaved text, or null when the document had none.
  final String? text;

  /// The digest of the file [text] was edited from, so a restore can tell
  /// whether the file changed on disk in the meantime.
  final String? baselineSha256;

  /// What the next save would write: line ending, encoding and byte order
  /// mark, as chosen in the buffer.
  final TextDocumentMetadata metadata;

  /// Where the caret was, one-based.
  final int line;
  final int column;

  bool get isFile => path != null;

  Map<String, Object?> toJson() => {
    'path': ?path,
    'untitledName': ?untitledName,
    'text': ?text,
    'baselineSha256': ?baselineSha256,
    'lineEnding': metadata.lineEnding.name,
    'encoding': metadata.encoding.name,
    if (metadata.utf8Bom == Utf8Bom.present) 'utf8Bom': true,
    'line': line,
    'column': column,
  };

  /// Null for an entry this version cannot use, which a restore skips
  /// rather than failing the whole window.
  static SessionTab? fromJson(Object? json) {
    if (json is! Map) return null;
    final path = json['path'];
    final untitledName = json['untitledName'];
    final text = json['text'];
    final baseline = json['baselineSha256'];
    final validPath = path is String && path.isNotEmpty;
    final validName = untitledName is String && untitledName.isNotEmpty;
    if (validPath == validName) return null;
    final encoding = _byName(TextEncoding.values, json['encoding']);
    return SessionTab(
      path: validPath ? path : null,
      untitledName: validName ? untitledName : null,
      text: text is String ? text : null,
      baselineSha256: baseline is String ? baseline : null,
      metadata: TextDocumentMetadata(
        lineEnding:
            _byName(LineEnding.values, json['lineEnding']) ?? LineEnding.lf,
        encoding: encoding ?? TextEncoding.utf8,
        utf8Bom:
            json['utf8Bom'] == true &&
                (encoding ?? TextEncoding.utf8) == TextEncoding.utf8
            ? Utf8Bom.present
            : Utf8Bom.absent,
      ),
      line: _positive(json['line']),
      column: _positive(json['column']),
    );
  }

  static T? _byName<T extends Enum>(List<T> values, Object? name) {
    for (final value in values) {
      if (value.name == name) return value;
    }
    return null;
  }

  static int _positive(Object? value) => value is int && value > 0 ? value : 1;
}

/// One window of the kept session: its documents in tab order and which
/// one was active.
final class SessionWindow {
  const SessionWindow({this.tabs = const [], this.active});

  final List<SessionTab> tabs;

  /// Index into [tabs], or null when none was active (or the active tab
  /// was not kept, such as an empty scratch tab).
  final int? active;

  /// The journal's format, bumped when an older reader could misread it.
  static const int version = 1;

  Map<String, Object?> toJson() => {
    'version': version,
    'tabs': [for (final tab in tabs) tab.toJson()],
    'active': ?active,
  };

  /// Null for a file of another version or shape.
  static SessionWindow? fromJson(Object? json) {
    if (json is! Map || json['version'] != version) return null;
    final stored = json['tabs'];
    if (stored is! List) return null;
    // The stored index counts every entry, skipped ones included.
    final storedActive = json['active'];
    final tabs = <SessionTab>[];
    int? active;
    for (final (index, entry) in stored.indexed) {
      final tab = SessionTab.fromJson(entry);
      if (tab == null) continue;
      if (index == storedActive) active = tabs.length;
      tabs.add(tab);
    }
    return SessionWindow(tabs: List.unmodifiable(tabs), active: active);
  }
}
