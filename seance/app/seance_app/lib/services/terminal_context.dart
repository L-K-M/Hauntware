import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

/// What a detected piece of terminal output is.
enum ContextKind { url, path }

/// One thing the Context tab recognised in a session's output: a web link,
/// or a file path resolved against the directory the shell was in when the
/// line was read.
@immutable
class ContextItem {
  const ContextItem({
    required this.kind,
    required this.value,
    required this.label,
  });

  final ContextKind kind;

  /// The link, or the path: absolute, or `~/`-relative for a home the
  /// session has not reported yet.
  final String value;

  /// The text as the terminal showed it, `:line:column` suffix included.
  final String label;

  @override
  bool operator ==(Object other) =>
      other is ContextItem && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);

  @override
  String toString() => 'ContextItem(${kind.name}, $value)';
}

/// Finds links and file paths in [text], in reading order.
///
/// Links are found first and their spans masked, so a URL's path is never
/// read a second time as a file path. Paths take kitty's hints as the model:
/// absolute (`/etc/hosts`), home (`~/notes.md`), dot-relative (`./build/`)
/// and slash-relative names that look like files (`lib/main.dart`, `src/`).
/// A slash-relative word without an extension or trailing slash is prose
/// more often than a path (`and/or`, `MB/s`), so it is left alone. A
/// relative path needs [workingDirectory] to mean anything and is dropped
/// without one; a home path is resolved through [homeDirectory] when it is
/// known and kept as `~/…` otherwise.
List<ContextItem> detectContextItems(
  String text, {
  String? workingDirectory,
  String? homeDirectory,
}) {
  final found = <(int, ContextItem)>[];
  final masked = StringBuffer();
  var last = 0;
  for (final match in _urlPattern.allMatches(text)) {
    final raw = _trimUrl(match[0]!);
    final uri = Uri.tryParse(raw);
    if (uri != null && uri.host.isNotEmpty && uri.userInfo.isEmpty) {
      found.add((
        match.start,
        ContextItem(kind: ContextKind.url, value: raw, label: raw),
      ));
    }
    masked
      ..write(text.substring(last, match.start))
      ..write(' ' * (match.end - match.start));
    last = match.end;
  }
  masked.write(text.substring(last));

  for (final match in _pathPattern.allMatches(masked.toString())) {
    final item = _pathItem(
      match,
      workingDirectory: workingDirectory,
      homeDirectory: homeDirectory,
    );
    if (item != null) found.add((match.start, item));
  }

  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, item) in found) item];
}

/// http and https only: they are the schemes the tab can open
/// (`openWebLink`), and the only ones safe to hand the system from output
/// a server wrote.
final _urlPattern = RegExp(r'''https?://[^\s<>"'`{}|\\^]+''');

/// Characters that end a path in running text. A colon ends one too, so
/// `PATH=/a:/b` reads as two paths and `file.dart:12:5` as a location.
const _pathChars = r'''[^\s'"`<>|;:(){}\[\]]''';

/// A path starts at the start of a line or after a space, a quote, `=`, an
/// opening bracket, a comma or a colon: `--prefix=/usr`, `(/tmp/x)`.
final _pathPattern = RegExp(
  '(?<=^|[\\s\'"`=(\\[<{,:])'
  '((?:~|\\.{1,2})?/$_pathChars*|[\\w@+.-]+/$_pathChars*)'
  r'(?::(\d+))?(?::(\d+))?',
  multiLine: true,
);

/// A file extension with at least one letter: `.dart`, `.tar.gz`'s `.gz`,
/// `.mp3`, but not a version's `.2`.
final _extension = RegExp(r'\.[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*$');

final _relativeSegment = RegExp(r'^[\w@+.,-]+$');

ContextItem? _pathItem(
  RegExpMatch match, {
  String? workingDirectory,
  String? homeDirectory,
}) {
  final body = match[1]!;
  // A prompt's directory (`me@host:~/src$`, `root@host:/etc#`) is where the
  // shell is, printed again before every command, not something the output
  // pointed at.
  if (body.endsWith(r'$') || body.endsWith('#')) return null;
  final path = body.replaceFirst(_trailingPunctuation, '');
  if (path.isEmpty || path.startsWith('//')) return null;
  // The suffix belongs to the label only when nothing was trimmed between
  // it and the path.
  final label = path == body ? match[0]! : path;

  final String value;
  if (path.startsWith('/')) {
    if (path == '/') return null;
    value = _normalize(path);
  } else if (path.startsWith('~/')) {
    if (path == '~/') return null;
    final home = homeDirectory;
    value = home == null
        ? '~/${_normalize('/${path.substring(2)}').substring(1)}'
        : _normalize('$home/${path.substring(2)}');
  } else {
    final cwd = workingDirectory;
    if (cwd == null || !cwd.startsWith('/')) return null;
    if (!path.startsWith('./') && !path.startsWith('../')) {
      final segments = path.split('/');
      final named = path.endsWith('/')
          ? segments.sublist(0, segments.length - 1)
          : segments;
      if (named.any((s) => !_relativeSegment.hasMatch(s))) return null;
      // `2026/10/28`, `1/2`: numbers, not places.
      if (RegExp(r'^\d+$').hasMatch(named.first)) return null;
      if (!path.endsWith('/') && !_extension.hasMatch(named.last)) {
        return null;
      }
    }
    value = _normalize('$cwd/$path');
  }
  if (value == '/') return null;
  return ContextItem(kind: ContextKind.path, value: value, label: label);
}

/// Sentence punctuation after a path (`see /etc/hosts.`) or a link.
final _trailingPunctuation = RegExp(r'[.,!?]+$');

/// Drops sentence punctuation, and a closing bracket the link did not open:
/// `(see https://example.com/a)` keeps `https://example.com/a`, while
/// `https://en.wikipedia.org/wiki/Foo_(bar)` keeps its own.
String _trimUrl(String raw) {
  var url = raw;
  while (url.isNotEmpty) {
    final trimmed = url.replaceFirst(RegExp(r'[.,!?;:]+$'), '');
    if (trimmed != url) {
      url = trimmed;
      continue;
    }
    final close = url[url.length - 1];
    final open = switch (close) {
      ')' => '(',
      ']' => '[',
      _ => null,
    };
    if (open == null) break;
    if (open.allMatches(url).length >= close.allMatches(url).length) break;
    url = url.substring(0, url.length - 1);
  }
  return url;
}

/// Collapses `.`, `..` and repeated slashes in an absolute POSIX path,
/// keeping a trailing slash off: `/a/./b/../c/` is `/a/c`.
String _normalize(String path) {
  final out = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(segment);
  }
  return '/${out.join('/')}';
}

/// The Context tab's stack for one session: what [detectContextItems] has
/// found in the terminal's output, newest first.
///
/// ```text
/// terminal.write ─► (throttle) ─► scan finished lines ─► items
///                                   │ unchanged line? skip
///                                   └ line under the cursor? skip
/// ```
///
/// Only the main screen is read: a full-screen program (an editor, `less`)
/// draws on the alternate screen, whose contents are a view rather than
/// output. The line under the cursor is skipped too, since it is still being
/// typed or printed: a half-typed `/usr/lo` is not a path yet. Each logical
/// line is remembered with the text it had when read, so it is read again
/// only once it changes; an item seen on a new line moves back to the top.
/// Clearing the stack therefore keeps what is on screen from returning,
/// until it is printed again.
///
/// Output that scrolls more than [_scanLines] rows between two reads is not
/// seen. The throttle keeps reads at most [scanDelay] apart while output
/// streams, which bounds that to output faster than the eye can follow.
class TerminalContextStack extends ChangeNotifier {
  TerminalContextStack({
    required this._terminal,
    required this._workingDirectory,
    this._homeDirectory,
  }) {
    // Output is what arms a read, so a terminal that prints nothing (a tab
    // still connecting, a test) holds no timer.
    _terminal.addListener(_scheduleScan);
  }

  final Terminal _terminal;
  final ValueListenable<String?> _workingDirectory;
  final String? Function()? _homeDirectory;

  /// How many items the stack keeps before the oldest fall off.
  static const int capacity = 50;

  /// How far back each read looks, in rows.
  static const int _scanLines = 300;

  /// How long output may stream before the stack reads it.
  static const Duration scanDelay = Duration(milliseconds: 300);

  final List<ContextItem> _items = [];

  /// The text each logical line, keyed by its first row, had when read.
  Expando<String> _read = Expando<String>();

  Timer? _scan;
  bool _disposed = false;

  /// Newest first.
  List<ContextItem> get items => List.unmodifiable(_items);

  /// Empties the stack. What is on screen now does not come back unless it
  /// is printed again.
  void clear() {
    if (_items.isEmpty) return;
    _items.clear();
    notifyListeners();
  }

  /// Takes [item] off the stack.
  void remove(ContextItem item) {
    if (_items.remove(item)) notifyListeners();
  }

  void _scheduleScan() {
    if (_disposed || _scan != null) return;
    _scan = Timer(scanDelay, () {
      _scan = null;
      scanNow();
    });
  }

  /// Reads the finished lines now. Public for tests, which drive the
  /// terminal without waiting out the throttle.
  @visibleForTesting
  void scanNow() {
    if (_disposed) return;
    final buffer = _terminal.mainBuffer;
    final lines = buffer.lines;
    final height = lines.length;
    if (height == 0) return;

    // The logical line the cursor is on, and everything below it, is still
    // being written.
    var end = buffer.absoluteCursorY.clamp(0, height - 1);
    while (end > 0 && lines[end].isWrapped) {
      end--;
    }
    var start = height - _scanLines;
    if (start < 0) start = 0;
    while (start > 0 && lines[start].isWrapped) {
      start--;
    }

    final cwd = _workingDirectory.value;
    final home = _homeDirectory?.call();
    final fresh = <ContextItem>[];
    var row = start;
    while (row < end) {
      final first = lines[row];
      final text = StringBuffer(first.getText());
      var next = row + 1;
      while (next < end && lines[next].isWrapped) {
        text.write(lines[next].getText());
        next++;
      }
      final line = text.toString();
      if (_read[first] != line) {
        _read[first] = line;
        fresh.addAll(
          detectContextItems(line, workingDirectory: cwd, homeDirectory: home),
        );
      }
      row = next;
    }
    if (fresh.isEmpty) return;

    // Later in the output is newer, so the last one found goes on top.
    for (final item in fresh) {
      _items
        ..remove(item)
        ..insert(0, item);
    }
    if (_items.length > capacity) _items.removeRange(capacity, _items.length);
    notifyListeners();
  }

  /// Forgets which lines were read, so the next read takes in the whole
  /// window again. For tests.
  @visibleForTesting
  void forgetReadLines() => _read = Expando<String>();

  @override
  void dispose() {
    _disposed = true;
    _scan?.cancel();
    _terminal.removeListener(_scheduleScan);
    super.dispose();
  }
}
