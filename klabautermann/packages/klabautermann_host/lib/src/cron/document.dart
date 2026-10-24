/// A crontab as a document the jobs view edits (JOB-06, JOB-07, 03
/// §7.7): every line kept byte for byte, in order, with comments and
/// environment lines, so a write changes only the lines the person
/// changed. [CrontabDocument.text] returns the original bytes until an
/// edit.
library;

import 'package:meta/meta.dart';

/// The comment that pauses a job (JOB-07): the job line follows it on
/// the same line, after the pause time, so resuming restores it exactly.
const String kCrontabPauseMarker = '# klabautermann:paused ';

/// What one crontab line holds, as cron reads it.
enum CrontabLineKind {
  /// Empty or only blanks.
  blank,

  /// A comment, other than a paused job.
  comment,

  /// A `NAME=value` assignment, which applies to the jobs after it.
  environment,

  /// A job: an `@` macro or five fields, then the command.
  job,

  /// A job this app paused ([kCrontabPauseMarker]).
  pausedJob,
}

/// A `NAME=value` line, as cron matches one before reading a job.
final _environment = RegExp(r'^\s*[A-Za-z_][A-Za-z0-9_]*\s*=');

/// The pause marker, its UTC time and the job line it holds: `[\s\S]`
/// rather than `.`, which stops at the `\r` a CRLF line keeps.
final _paused = RegExp(
  '^${RegExp.escape(kCrontabPauseMarker)}(\\S+) ([\\s\\S]*)\$',
);

/// One line of a crontab, without its newline.
@immutable
final class CrontabLine {
  const CrontabLine._(this.text, this.kind);

  /// Classifies [text], one line without its newline.
  factory CrontabLine(String text) {
    if (text.contains('\n')) {
      throw ArgumentError.value(text, 'text', 'holds a newline');
    }
    final t = text.trim();
    final kind = switch (t) {
      '' => CrontabLineKind.blank,
      _ when _paused.hasMatch(text) => CrontabLineKind.pausedJob,
      _ when t.startsWith('#') => CrontabLineKind.comment,
      _ when _environment.hasMatch(text) => CrontabLineKind.environment,
      _ => CrontabLineKind.job,
    };
    return CrontabLine._(text, kind);
  }

  /// The line exactly as written, a `\r` included.
  final String text;

  /// What cron reads it as.
  final CrontabLineKind kind;

  /// When a paused job was paused, or null for any other line.
  DateTime? get pausedAt {
    final m = _paused.firstMatch(text);
    return m == null ? null : DateTime.tryParse(m[1]!);
  }

  /// The job line a paused job holds, or null for any other line.
  String? get pausedJob => _paused.firstMatch(text)?[2];
}

/// A crontab's lines and whether it ended in a newline (03 §7.7).
/// Immutable: each edit returns a new document.
@immutable
final class CrontabDocument {
  CrontabDocument._(List<CrontabLine> lines, this._endsWithNewline)
    : lines = List.unmodifiable(lines);

  /// Splits [text], a crontab as `crontab -l` printed it, into lines.
  factory CrontabDocument.parse(String text) {
    if (text.isEmpty) return CrontabDocument._(const [], false);
    final endsWithNewline = text.endsWith('\n');
    final body = endsWithNewline ? text.substring(0, text.length - 1) : text;
    return CrontabDocument._([
      for (final line in body.split('\n')) CrontabLine(line),
    ], endsWithNewline);
  }

  /// The lines in order.
  final List<CrontabLine> lines;

  final bool _endsWithNewline;

  /// The crontab's bytes: the parsed text until an edit. An edited
  /// document ends in a newline, which cron needs to read its last line.
  String get text {
    if (lines.isEmpty) return '';
    final joined = lines.map((l) => l.text).join('\n');
    return _endsWithNewline ? '$joined\n' : joined;
  }

  /// This document with line [index] replaced by [text].
  CrontabDocument replace(int index, String text) =>
      _edit((l) => l[index] = CrontabLine(text));

  /// This document with [text] inserted before line [index], or appended
  /// when [index] is the line count.
  CrontabDocument insert(int index, String text) =>
      _edit((l) => l.insert(index, CrontabLine(text)));

  /// This document without line [index].
  CrontabDocument remove(int index) => _edit((l) => l.removeAt(index));

  /// This document with job line [index] paused at [at] (JOB-07). A line
  /// that is already paused stays as it is; any other kind is refused.
  CrontabDocument pause(int index, {required DateTime at}) {
    final line = lines[index];
    if (line.kind == CrontabLineKind.pausedJob) return this;
    if (line.kind != CrontabLineKind.job) {
      throw ArgumentError.value(index, 'index', 'not a job line');
    }
    final stamp = at.toUtc().toIso8601String().replaceFirst('.000Z', 'Z');
    return replace(index, '$kCrontabPauseMarker$stamp ${line.text}');
  }

  /// This document with paused job [index] restored to the line it was
  /// (JOB-07). A job line that is not paused stays as it is; any other
  /// kind is refused.
  CrontabDocument resume(int index) {
    final line = lines[index];
    if (line.kind == CrontabLineKind.job) return this;
    final job = line.pausedJob;
    if (job == null) {
      throw ArgumentError.value(index, 'index', 'not a paused job');
    }
    return replace(index, job);
  }

  CrontabDocument _edit(void Function(List<CrontabLine>) change) {
    final edited = [...lines];
    change(edited);
    return CrontabDocument._(edited, true);
  }
}

/// A cron command split as cron runs it (JOB-19, crontab(5)): the text
/// before the first unescaped `%` is the command, with `\%` read as `%`;
/// the rest, with each unescaped `%` as a newline, is its standard input.
({String command, String? stdin}) splitCronCommand(String field) {
  final command = StringBuffer();
  StringBuffer? stdin;
  for (var i = 0; i < field.length; i++) {
    final c = field[i];
    final escaped = c == r'\' && i + 1 < field.length && field[i + 1] == '%';
    if (escaped) {
      (stdin ?? command).write('%');
      i++;
    } else if (c == '%') {
      if (stdin == null) {
        stdin = StringBuffer();
      } else {
        stdin.write('\n');
      }
    } else {
      (stdin ?? command).write(c);
    }
  }
  return (command: command.toString(), stdin: stdin?.toString());
}
