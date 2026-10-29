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

/// The longest line [detectContextItems] reads; the rest of a longer one
/// (a minified bundle, one line of JSON) is skipped. It bounds the cost of a
/// read whatever a server prints.
const contextLineLimit = 4096;

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
///
/// Also left alone, since none of them names a file here: a prompt's own
/// directory, another host's path (`git@host:org/repo.git`, `host:/srv`),
/// a value a column cut short (`/docker-entrypoint.…`), and anything
/// carrying bidi or invisible characters, which could show one name and
/// act on another. A diff header's `a/` and `b/` are dropped.
List<ContextItem> detectContextItems(
  String text, {
  String? workingDirectory,
  String? homeDirectory,
}) {
  // Where the line was cut, if it was: a value reaching the cut may go on
  // past it (`https://github.c…`), so it is not offered.
  int? cut;
  if (text.length > contextLineLimit) {
    // Never between the halves of a surrogate pair.
    cut = contextLineLimit;
    if (_isHighSurrogate(text.codeUnitAt(cut - 1))) cut--;
    text = text.substring(0, cut);
  }
  final found = <(int, ContextItem)>[];
  final masked = StringBuffer();
  var last = 0;
  for (final match in _urlPattern.allMatches(text)) {
    // A Markdown link whose text is the link: `[https://x](https://x)`.
    var span = match[0]!;
    final markdown = span.indexOf('](');
    if (markdown >= 0) span = span.substring(0, markdown);
    final raw = _trimUrl(span);
    final uri = Uri.tryParse(raw);
    if ((cut == null || match.end < cut) &&
        uri != null &&
        _namedHost.hasMatch(uri.host) &&
        uri.userInfo.isEmpty &&
        !_cutShort(text, match.end) &&
        !_invisible.hasMatch(raw)) {
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

  final scanned = masked.toString();
  final diffHeader = _diffHeader.hasMatch(text);
  final farSides = _FarSides(scanned);
  var position = 0;
  while (position < scanned.length) {
    final match = _firstFrom(_pathPattern, scanned, position);
    if (match == null) break;
    // A path cut short (at a closing quote, at CJK prose) leaves its text's
    // tail to read again: `「/etc/hosts」と「/etc/resolv.conf」`.
    final (_, end) = _pathBody(match, scanned);
    position = end > match.start ? end : match.end;
    if (cut != null && match.end >= cut) continue;
    final item = _pathItem(
      match,
      scanned,
      workingDirectory: workingDirectory,
      homeDirectory: homeDirectory,
      diffHeader: diffHeader,
      farSides: farSides,
    );
    if (item != null) found.add((match.start, item));
  }

  found.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final (_, item) in found) item];
}

RegExpMatch? _firstFrom(RegExp pattern, String text, int start) {
  for (final match in pattern.allMatches(text, start)) {
    return match;
  }
  return null;
}

/// http and https only: they are the schemes the tab can open
/// (`openWebLink`), and the only ones safe to hand the system from output
/// a server wrote.
final _urlPattern = RegExp(r'''https?://[^\s<>"'`{}|\\^‘’“”…，。；！？、（）「」『』]+''');

/// The punctuation a sentence or a quote puts after a path.
const _pathTrailing = '.,!?’';

/// Characters that end a path in running text. A colon ends one too, so
/// `PATH=/a:/b` reads as two paths and `file.dart:12:5` as a location, and
/// so does a comma, so a list of files reads as its files, CJK's list
/// marks (`/etc/hosts、/etc/passwd`) included. Other CJK punctuation is in
/// names as often as after them (`旅行（京都）/`, `報告書（1）.pdf`), so
/// [_cutAtProse] decides where it ends a path. A closing curly single quote
/// does not: it is an apostrophe in a name too (`Dad’s_taxes.pdf`), and
/// ends a path only one an opening quote started, or the path's end.
const _pathChars = r'''[^\s'"`<>|;:,(){}\[\]‘“”…、，；]''';

/// CJK punctuation that is in a name or after one: `。：！？「」『』（）`.
final _cjkPunctuation = RegExp('[。：！？「」『』（）]');

/// [body] cut at the first CJK punctuation that prose follows rather than
/// the rest of a name. What a name's mark leads into must look like a name:
/// a `/` (`旅行（京都）/IMG.jpg`, `君の名は。/夢灯籠.m4a`) or an extension
/// (`報告書（案）（修正）.docx`). Otherwise the sentence goes on, which CJK
/// writes without a space (`/etc/hosts（設定ファイル）を編集しました`).
///
/// Brackets pair up as well. An opener (`「『（`) is a name's only when its
/// closer follows within the same segment. A closer (`」』）`) is a name's
/// when it closes such an opener; one the path opened outside of, as in
/// `「/etc/hosts」と「/etc/resolv.conf」`, ends the path when a new opener
/// follows it in the segment, so that line reads as two paths. `。：！？`
/// right after a file's name end it too (`config.yml。代わりに…`), while a
/// folder's name may hold them (`けいおん！！/01.mp3`, `仕事：2024/`).
String _cutAtProse(String body) {
  final open = <String>[];
  var from = 0;
  while (true) {
    final found = _cjkPunctuation.firstMatch(body.substring(from));
    if (found == null) return body;
    final at = from + found.start;
    final mark = body[at];
    final rest = body.substring(at + 1);
    final slash = rest.indexOf('/');
    final segment = slash < 0 ? rest : rest.substring(0, slash);
    final leadsOn = slash >= 0 || _hasExtension(rest);
    final closer = _openers[mark];
    final bool named;
    if (closer != null) {
      named = leadsOn && segment.contains(closer);
      if (named) open.add(mark);
    } else if (open.isNotEmpty && _openers[open.last] == mark) {
      open.removeLast();
      named = true;
    } else if (_openers.containsValue(mark)) {
      named = leadsOn && !segment.contains(_anyOpener);
    } else {
      // `：` right before a `/` labels the path that starts there
      // (`工作目录：/srv/app。配置：/srv/app/config.yml`). After a file's
      // name (`config.yml。`) the sentence goes on, but marks right before
      // a `/` are a folder's (`Dr.STONE！/`).
      final labels = (mark == '：' && slash == 0) || segment.endsWith('：');
      final endsFolder = slash >= 0 && _foldersMarks.hasMatch(segment);
      final name = body.substring(body.lastIndexOf('/', at) + 1, at);
      named = leadsOn && !labels && (endsFolder || !_hasExtension(name));
    }
    if (!named) return body.substring(0, at);
    from = at + 1;
  }
}

/// What may sit between one of `。！？` and the `/` that ends its folder's
/// name: more of them (`けいおん！！/`).
final _foldersMarks = RegExp('^[。！？]*\$');

/// The CJK brackets a name may hold, opener to closer.
const _openers = {'「': '」', '『': '』', '（': '）'};

final _anyOpener = RegExp('[「『（]');

/// The curly quote that closes a path each opening one started.
const _closingQuote = {'‘': '’', '“': '”'};

/// A path starts at the start of a line or after a space, a quote, `=`, an
/// opening bracket, a comma or a colon: `--prefix=/usr`, `(/tmp/x)`,
/// `‘/tmp/x’`, `保存先：/tmp/a.txt`. Not after `<`, which opens a tag
/// (`</title>`).
final _pathPattern = RegExp(
  '(?<=^|[\\s\'"`=(\\[{,:‘“：「『（，、。；])'
  '((?:~|\\.{1,2})?/$_pathChars*|[\\w@+.-]+/$_pathChars*)'
  r'(?::(\d+))?(?::(\d+))?',
  multiLine: true,
);

/// A host with a name in it: not the `...` of a placeholder `https://...`.
/// An IPv6 literal (`http://[::]:8000/`) names its host with colons.
final _namedHost = RegExp(r'[A-Za-z0-9:]');

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

/// The lines of a diff whose paths start `a/` and `b/`.
final _diffHeader = RegExp(r'^(?:diff --git |--- a/|\+\+\+ b/|Binary files )');

/// Bidi controls and zero-width characters: drawn as nothing, or as
/// reordered text, so the row would not show what the action opens.
final _invisible = RegExp(
  '[\u00AD\u061C\u180E\u200B-\u200F\u202A-\u202E\u2060-\u2064'
  '\u2066-\u2069\uFEFF]',
);

/// A prompt's last character, after the directory it shows:
/// `me@host ~/src $`, `[me@host ~/src]$`, `[root@host /etc]#`, `~/src ❯`.
/// A `#` after a space is a comment (`source ~/.cargo/env # rust`), so it
/// counts only after the bracket that closes a prompt.
final _promptAfter = RegExp(r'^(?:[\])]+\s*[$#%❯»]|\s*[$%❯»])(?:\s|$)');

/// A root prompt's `#` after a space: `myhost /etc/portage # `.
final _rootPromptAfter = RegExp(r'^\s+#(?:\s|$)');

/// fish's prompt puts `>` straight after the directory: `~/s/project> `.
final _fishPromptAfter = RegExp(r'^>(?:\s|$)');

/// Whether [name] ends in a file extension with at least one letter:
/// `.dart`, `.tar.gz`'s `.gz`, `.mp3`, but not a version's `.2`. Read from
/// the last dot in one pass: a backtracking pattern takes quadratic time on
/// a long name a server printed.
bool _hasExtension(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return false;
  var letter = false;
  for (var i = dot + 1; i < name.length; i++) {
    final unit = name.codeUnitAt(i);
    final isLetter =
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
    if (!isLetter && !(unit >= 0x30 && unit <= 0x39)) return false;
    letter = letter || isLetter;
  }
  return letter;
}

final _relativeSegment = RegExp(r'^[\w@+.-]+$');

/// A number, perhaps with a unit: `28`, `2.23G`, `1.34k`, `512MiB`.
final _quantity = RegExp(r'^\d[\d.]*[A-Za-z]{0,3}$');

/// `...`, which `git diff --stat` and columns put where they cut a path.
final _elision = RegExp(r'(?:^|/)\.{3,}(?:/|$)');

/// What an absolute path's first name may start with: not `*` (`/*`) or
/// other punctuation that only looks like a path.
final _absoluteStart = RegExp(r'^/[\w.~@+-]');

/// The path [match] names, and where it ends in [text]: cut at the curly
/// quote that closes the one it opened after, and at CJK prose
/// ([_cutAtProse]). Text past a cut may hold another path, which the scan
/// reads from there.
(String, int) _pathBody(RegExpMatch match, String text) {
  var body = match[1]!;
  final opener = match.start == 0 ? null : text[match.start - 1];
  final closer = _closingQuote[opener];
  if (closer != null) {
    final close = body.indexOf(closer);
    if (close >= 0) body = body.substring(0, close);
  }
  body = _cutAtProse(body);
  if (body.length == match[1]!.length) return (body, match.end);
  return (body, match.start + body.length);
}

ContextItem? _pathItem(
  RegExpMatch match,
  String text, {
  String? workingDirectory,
  String? homeDirectory,
  required bool diffHeader,
  required _FarSides farSides,
}) {
  final (body, end) = _pathBody(match, text);
  final after = text.substring(end);
  // A prompt's directory (`me@host:~/src$`, `root@host:/etc#`) is where the
  // shell is, printed again before every command, not something the output
  // pointed at.
  if (body.endsWith(r'$') ||
      body.endsWith('#') ||
      _promptAfter.hasMatch(after) ||
      _fishPromptAfter.hasMatch(after)) {
    return null;
  }
  if (_cutShort(text, end)) return null;
  if (farSides.contains(match.start)) return null;
  if (_invisible.hasMatch(body)) return null;
  // A query string (`/api/users?id=1`) belongs to a route, not a file.
  if (body.contains('?') && body.indexOf('?') < body.length - 1) return null;
  // `java.base/java.lang.Thread.run(Thread.java:1583)`, Go's
  // `net/http.serverHandler.ServeHTTP({0xc000…})`: a stack frame's
  // function, not a file. A location in parentheses (`app.py(12)`,
  // `Program.cs(12,5)`) keeps its file.
  if (end < text.length &&
      text.codeUnitAt(end) == 0x28 &&
      _parenLocation.matchAsPrefix(text, end) == null &&
      _frameOffset.matchAsPrefix(text, end) == null) {
    return null;
  }
  if (body.startsWith('/') && _isWebRoute(text, match.start)) return null;
  if (_afterClosingQuote(text, match.start)) return null;
  // A mount's container side, by name in its key list
  // (`--mount type=bind,src=/srv/conf,dst=/etc/nginx/conf.d`); a lone
  // `--target=/opt/libs` is a local directory.
  if (_mountTargetBefore.hasMatch(
        text.substring(match.start < 12 ? 0 : match.start - 12, match.start),
      ) &&
      _inKeyList(text, match.start)) {
    return null;
  }

  // A sanitizer frame's module offset: `(/lib/libc.so.6+0x29d8f)`.
  var path = _trimEnd(body, _pathTrailing).replaceFirst(_moduleOffset, '');
  // Three dots after a name with an extension close a sentence
  // (`Writing /etc/nginx/nginx.conf...`); after any other name they are
  // where a column cut it (`/var/log/app...`).
  if (body.endsWith('...') && !_hasExtension(path)) return null;
  if (path.isEmpty || path.startsWith('//') || _elision.hasMatch(path)) {
    return null;
  }
  // The suffix belongs to the label only when nothing was trimmed between
  // it and the path.
  final label = path == match[1] ? match[0]! : path;

  final String? value;
  if (path.startsWith('/')) {
    if (!_absoluteStart.hasMatch(path)) return null;
    value = _normalize(path);
  } else if (path.startsWith('~/')) {
    if (path == '~/') return null;
    final home = homeDirectory;
    if (home == null) {
      // Kept relative to a home not known yet, so it may not climb out.
      final inHome = _normalize('/${path.substring(2)}', climbOut: false);
      value = inHome == null ? null : '~$inHome';
    } else {
      value = _normalize('$home/${path.substring(2)}');
    }
  } else {
    final cwd = workingDirectory;
    if (cwd == null || !cwd.startsWith('/')) return null;
    if (diffHeader && (path.startsWith('a/') || path.startsWith('b/'))) {
      path = path.substring(2);
    }
    if (!path.startsWith('./') && !path.startsWith('../')) {
      final segments = path.split('/');
      final named = path.endsWith('/')
          ? segments.sublist(0, segments.length - 1)
          : segments;
      if (named.isEmpty || named.any((s) => !_relativeSegment.hasMatch(s))) {
        return null;
      }
      // `2026/10/28`, `1/2`, a progress bar's `2.23G/4.94G`: numbers, not
      // places.
      if (_quantity.hasMatch(named.first)) return null;
      if (!path.endsWith('/') && !_hasExtension(named.last)) {
        return null;
      }
    }
    value = _normalize('$cwd/$path');
  }
  if (value == null || value == '/' || value == '~/') return null;
  // A root prompt with a space before its `#` (`/etc # `) reads like a
  // comment after a path (`source ~/.cargo/env # rust`); it is the prompt
  // when the path is where the shell is.
  if (value == workingDirectory && _rootPromptAfter.hasMatch(after)) {
    return null;
  }
  return ContextItem(kind: ContextKind.path, value: value, label: label);
}

/// Whether the value ending at [end] was cut short with an ellipsis.
bool _cutShort(String text, int end) =>
    end < text.length && text.codeUnitAt(end) == 0x2026;

/// Reads, for each path that follows a `:`, whether it is the far side of
/// a `before:path` token: another machine's (`prod:/var/backups`,
/// `192.168.1.10:/srv`, `git@github.com:org/repo.git`, `sftp:nas:/repo`,
/// `[2001:db8::5]:/x`), a container's (`-v ./nginx.conf:/etc/nginx/x.conf`,
/// `kubectl cp ns/pod:/var/log/app.log`) or a drive's (`C:/Users`).
/// Offering a same-named file on this machine would act on the wrong one,
/// so the far side is left out unless the token is a path list:
///
/// * an assignment's value whose entry before the path is itself a path
///   (`PATH=/usr/bin:/bin`, `CLASSPATH=.:/x.jar`), not a host
///   (`url=git@github.com:org/x.git`, `BORG_REPO=nas:/volume1`);
/// * three or more entries that all look like paths, as `echo $PATH`
///   prints them.
///
/// `Error:/x`, a two-entry `/usr/bin:/bin` and `PATH=bin:/usr/bin` miss
/// their far side for it. A token is read once for all the paths in it, so
/// a long list costs one pass.
class _FarSides {
  _FarSides(this._text);

  final String _text;

  /// The token last read, `[_start, _end)`, its first `=` (or -1), and
  /// whether it is a list of three or more paths.
  int _start = 0;
  int _end = -1;
  int _equals = -1;
  bool _isList = false;

  bool contains(int start) {
    if (start == 0 || _text.codeUnitAt(start - 1) != 0x3A) return false;
    if (start < _start || start >= _end) _read(start);
    final colon = start - 1;
    var entryStart = colon;
    while (entryStart > _start) {
      final unit = _text.codeUnitAt(entryStart - 1);
      if (unit == 0x3A || unit == 0x3D) break;
      entryStart--;
    }
    final before = _text.substring(entryStart, colon);
    if (_namesHost(before)) return true;
    if (_equals >= 0 && _equals < colon) return !_isPathEntry(before);
    return !_isList;
  }

  void _read(int start) {
    var tokenStart = start - 1;
    while (tokenStart > 0 && !_tokenBreak(_text.codeUnitAt(tokenStart - 1))) {
      tokenStart--;
    }
    var tokenEnd = start;
    while (tokenEnd < _text.length &&
        !_tokenBreak(_text.codeUnitAt(tokenEnd))) {
      tokenEnd++;
    }
    _start = tokenStart;
    _end = tokenEnd;
    final token = _text.substring(tokenStart, tokenEnd);
    final equals = token.indexOf('=');
    // An option's value (`--volume=./conf:/etc/nginx`, `--bind=/a:/b`) is
    // read like its spaced form (`-v ./conf:/etc/nginx`), not as a list.
    final assignment = equals >= 0 && !token.startsWith('-');
    _equals = assignment ? tokenStart + equals : -1;
    final entries = token.substring(equals + 1).split(':');
    _isList = entries.length >= 3 && entries.every(_isPathEntry);
  }
}

/// An entry of a path list: absolute, home- or dot-relative, with a `/`,
/// or empty (the current directory, in `PATH=:/usr/bin`).
bool _isPathEntry(String entry) =>
    entry.isEmpty || _listedPath.hasMatch(entry) || entry.contains('/');

/// A `user@` login, a bracketed IPv6 address, a dotted host name or an
/// IPv4 address.
bool _namesHost(String entry) =>
    entry.contains('@') ||
    entry.contains(']') ||
    _hostName.hasMatch(entry) ||
    _ipv4.hasMatch(entry);

final _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

/// `example.com`, `db-1.internal`: dotted labels, the last one a name.
final _hostName = RegExp(r'^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$');

/// An entry of a path list: absolute, home- or dot-relative.
final _listedPath = RegExp(r'^(?:/|~|\.)');

/// Whitespace or a quote: where a `before:path` token ends.
bool _tokenBreak(int unit) =>
    unit == 0x20 ||
    unit == 0x09 ||
    unit == 0x22 ||
    unit == 0x27 ||
    unit == 0x60;

/// A line, or a line and column, in parentheses after a file:
/// `app.py(12)main()`, `Program.cs(12,5):`. A `(1)` that a name goes on
/// after (`report(1).pdf`, `dir(1)/x`) is not one.
final _parenLocation = RegExp(r'\(\d+(?:,\d+)?\)(?![./])');

/// A glibc backtrace frame's offset after its file: `./app(+0x1149)`.
final _frameOffset = RegExp(r'\(\+0x[0-9A-Fa-f]+\)');

final _mountTargetBefore = RegExp(r'\b(?:dst|target|destination)=$');

/// Whether the word around [start] is a comma-separated key list.
bool _inKeyList(String text, int start) {
  var from = start;
  while (from > 0 && !_tokenBreak(text.codeUnitAt(from - 1))) {
    from--;
  }
  var to = start;
  while (to < text.length && !_tokenBreak(text.codeUnitAt(to))) {
    to++;
  }
  return text.substring(from, to).contains(',');
}

final _moduleOffset = RegExp(r'\+0x[0-9A-Fa-f]+$');

/// Whether the path at [start] follows a quote that closes a word rather
/// than opening one: `"$HOME"/bin` is the variable's path, not `/bin`.
bool _afterClosingQuote(String text, int start) {
  if (start < 2) return false;
  final quote = text.codeUnitAt(start - 1);
  if (quote != 0x22 && quote != 0x27 && quote != 0x60) return false;
  return !_opensWord(text.codeUnitAt(start - 2));
}

/// Space and the characters after which a quote opens a word: `= ( [ { , :`.
bool _opensWord(int unit) =>
    unit == 0x20 ||
    unit == 0x09 ||
    unit == 0x3D ||
    unit == 0x28 ||
    unit == 0x5B ||
    unit == 0x7B ||
    unit == 0x2C ||
    unit == 0x3A;

/// Whether the absolute path at [start] is a web route rather than a file:
/// after an HTTP method (`"GET /wp-login.php HTTP/1.1"`, `Started GET
/// "/users/1"`), an HTML attribute (`href="/about"`), or a redirect header
/// as `curl -v` marks it (`< Location: /login`). An unmarked `Location:`
/// reads the same in `pip show` (`Location: /usr/lib/python3/dist-packages`)
/// and in `curl -i`'s raw headers, and the files `pip show` names matter
/// more than a route that names nothing.
bool _isWebRoute(String text, int start) {
  final window = text.substring(start < 24 ? 0 : start - 24, start);
  if (_requestBefore.hasMatch(window)) return true;
  // An attribute's quoted value is a route wherever it stands (JSX puts
  // one per line); an unquoted one only inside a tag, so Docker's
  // `--mount …,src=/srv/conf` is a file.
  if (_quotedAttributeBefore.hasMatch(window)) return true;
  if (_attributeBefore.hasMatch(window)) {
    return text.lastIndexOf('<', start) > text.lastIndexOf('>', start);
  }
  if (!_locationBefore.hasMatch(window)) return false;
  return _redirectHeader.hasMatch(text.substring(0, start));
}

final _requestBefore = RegExp(
  r'\b(?:GET|POST|PUT|DELETE|HEAD|PATCH|OPTIONS|CONNECT|TRACE)\s+"?$',
);

final _quotedAttributeBefore = RegExp(
  r'\b(?:[Hh][Rr][Ee][Ff]|[Ss][Rr][Cc]|[Aa]ction)=["\x27]$',
);

final _attributeBefore = RegExp(
  r'\b(?:[Hh][Rr][Ee][Ff]|[Ss][Rr][Cc]|[Aa]ction)=["\x27]?$',
);

final _locationBefore = RegExp(r'[Ll]ocation:\s*$');

/// A redirect header as `curl -v` prints it.
final _redirectHeader = RegExp(r'^\s*[<>]\s*[Ll]ocation:\s*$');

/// [value] without any run of [chars] at its end, in one pass: a
/// backtracking `[…]+$` would take quadratic time on a long run of dots a
/// server printed.
String _trimEnd(String value, String chars) {
  var end = value.length;
  while (end > 0 && chars.contains(value[end - 1])) {
    end--;
  }
  return value.substring(0, end);
}

/// Drops sentence punctuation, and a closing bracket the link did not open:
/// `(see https://example.com/a)` keeps `https://example.com/a`, while
/// `https://en.wikipedia.org/wiki/Foo_(bar)` keeps its own. One pass from
/// the end, with the brackets counted once.
String _trimUrl(String raw) {
  var parens = 0;
  var brackets = 0;
  for (final unit in raw.codeUnits) {
    switch (unit) {
      case 0x28:
        parens--;
      case 0x29:
        parens++;
      case 0x5B:
        brackets--;
      case 0x5D:
        brackets++;
    }
  }
  var end = raw.length;
  while (end > 0) {
    final unit = raw.codeUnitAt(end - 1);
    if (_urlTrailing.contains(unit)) {
      end--;
    } else if (unit == 0x29 && parens > 0) {
      parens--;
      end--;
    } else if (unit == 0x5D && brackets > 0) {
      brackets--;
      end--;
    } else {
      break;
    }
  }
  return raw.substring(0, end);
}

/// `.`, `,`, `!`, `?`, `;` and `:`: sentence punctuation after a link, and
/// `*`, Markdown's emphasis (`**https://example.com/docs**`).
const _urlTrailing = {0x2E, 0x2C, 0x21, 0x3F, 0x3B, 0x3A, 0x2A};

/// Collapses `.`, `..` and repeated slashes in an absolute POSIX path,
/// keeping a trailing slash off: `/a/./b/../c/` is `/a/c`. A `..` at the
/// root stays there, as the kernel reads it, unless [climbOut] is false:
/// then the path is refused (null).
String? _normalize(String path, {bool climbOut = true}) {
  final out = <String>[];
  for (final segment in path.split('/')) {
    if (segment.isEmpty || segment == '.') continue;
    if (segment == '..') {
      if (out.isEmpty && !climbOut) return null;
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
/// until it is printed again. (`clear` erases rows in place: a line printed
/// into the same row with the same text before the next read is taken for
/// the one already read.)
///
/// A relative path resolves against the shell's directory when the line is
/// read. The shell reports a `cd` inside a running command
/// (`cd build && make`) only at its next prompt, so that command's relative
/// paths resolve against the directory it started in.
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
  final Expando<String> _read = Expando<String>();

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
  ///
  /// A failure reading the buffer itself is reported and ends that read
  /// only: the vendored xterm can leave a row unset (CSI 3J and then a
  /// resize), and the timer this runs from must not throw.
  @visibleForTesting
  void scanNow() {
    if (_disposed) return;
    try {
      _readBuffer();
    } catch (error, stack) {
      _report(error, stack, 'while reading the terminal buffer');
    }
  }

  void _readBuffer() {
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
    // The window starts on a whole line: forward past the tail of one that
    // began above it, since walking back could cross the whole scrollback.
    var start = height - _scanLines;
    if (start < 0) start = 0;
    while (start < end && lines[start].isWrapped) {
      start++;
    }

    final cwd = _workingDirectory.value;
    final home = _homeDirectory?.call();
    final fresh = <ContextItem>[];
    var row = start;
    while (row < end) {
      final first = lines[row];
      final text = StringBuffer();
      var next = row + 1;
      var carried = _writeRow(
        first,
        text,
        wideNext: next < end && _startsWide(lines[next]),
      );
      while (next < end && lines[next].isWrapped) {
        final wideNext = next + 1 < end && _startsWide(lines[next + 1]);
        if (text.length <= contextLineLimit) {
          carried = _writeRow(
            lines[next],
            text,
            wideNext: wideNext,
            behindWide: carried,
          );
        }
        next++;
      }
      final line = text.toString().trimRight();
      if (_read[first] != line) {
        _read[first] = line;
        fresh.addAll(_detect(line, cwd, home));
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

  /// [detectContextItems] on one line a server wrote. A defect it meets on
  /// some unforeseen output is reported, and costs that line only: the
  /// rest of the read, and later reads, still happen.
  static List<ContextItem> _detect(String line, String? cwd, String? home) {
    try {
      return detectContextItems(
        line,
        workingDirectory: cwd,
        homeDirectory: home,
      );
    } catch (error, stack) {
      _report(error, stack, 'while reading a terminal line');
      return const [];
    }
  }

  static void _report(Object error, StackTrace stack, String context) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'seance terminal context',
        context: ErrorDescription(context),
      ),
    );
  }

  static bool _startsWide(BufferLine row) =>
      row.isWrapped && row.length > 0 && row.getWidth(0) == 2;

  /// Writes [row]'s cells as text. A cell nothing was written to (the gap
  /// a tab stop leaves, `ls`'s and `git diff --name-status`'s columns)
  /// reads as a space, where xterm's own `getText` drops it and glues the
  /// columns together; the cell behind a wide character is skipped.
  ///
  /// When the next row is this line's wrap and opens with a wide
  /// character ([wideNext]), one empty cell at this row's edge is where
  /// that character did not fit, and is skipped; any other empty cells are
  /// a gap and stay spaces. A wide character in the last column leaves its
  /// second cell at the start of the next row; the return says so, for
  /// [behindWide].
  static bool _writeRow(
    BufferLine row,
    StringBuffer out, {
    required bool wideNext,
    bool behindWide = false,
  }) {
    var end = row.length;
    if (wideNext && end > 0 && row.getCodePoint(end - 1) == 0) end--;
    var skip = behindWide;
    for (var i = 0; i < end; i++) {
      final codePoint = row.getCodePoint(i);
      if (skip) {
        skip = false;
        if (codePoint == 0) continue;
      }
      if (codePoint == 0) {
        out.write(' ');
        continue;
      }
      out.writeCharCode(codePoint);
      if (row.getWidth(i) != 2) continue;
      if (i == row.length - 1) return true;
      skip = true;
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    _scan?.cancel();
    _terminal.removeListener(_scheduleScan);
    super.dispose();
  }
}
