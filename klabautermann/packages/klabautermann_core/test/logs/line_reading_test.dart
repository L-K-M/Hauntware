// CTX-05: a container line's severity from what it says of itself, a
// stack trace's continuation lines, and a JSON line's keys.
import 'dart:math';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

/// The level-word pattern as it stood before SMP-01, which backtracked
/// quadratically: what [linePriority] must still read from a line that
/// is no JSON object and has no logfmt level.
final _levelWordBefore = RegExp(
  r'^(?:(?:\S*\d\S*|[A-Z]{2,5})\s+){0,4}?\[?'
  r'(FATAL|PANIC|CRITICAL|CRIT|ERROR|ERR|WARNING|WARN|NOTICE|INFO|DEBUG|TRACE)'
  r'\]?:?(?=\s|$)',
);

const _priorityOfLevelWord = {
  'FATAL': LogPriority.critical,
  'PANIC': LogPriority.critical,
  'CRITICAL': LogPriority.critical,
  'CRIT': LogPriority.critical,
  'ERROR': LogPriority.error,
  'ERR': LogPriority.error,
  'WARNING': LogPriority.warning,
  'WARN': LogPriority.warning,
  'NOTICE': LogPriority.notice,
  'INFO': LogPriority.info,
  'DEBUG': LogPriority.debug,
  'TRACE': LogPriority.debug,
};

/// Lines of the shapes containers log, none a JSON object, a logfmt
/// level or an exception's own line, so the level word alone decides.
const _levelWordCorpus = [
  '2026-10-15 14:30:01.123 UTC [1] FATAL:  password authentication failed',
  '2026-10-15 14:30:01.123 UTC [1] LOG:  database system is ready',
  '[ERROR] could not bind',
  '[DEBUG] cache miss',
  'WARNING:  checkpoints are occurring too frequently',
  'ERROR request failed',
  'an ERROR deep in a long message here',
  'the error count is 0',
  'GET /health 200',
  '2026/10/26 12:00:00 [error] 31#31: *1 connect() failed',
  '2026/10/26 12:00:00 [NOTICE] 31#31: start worker processes',
  '2026-10-26T12:00:00Z INFO starting',
  '2026-10-26T12:00:00.123456789Z  WARN  slow request',
  '2026-10-26 12:00:00,123 ERROR [main] boom',
  '12:00:00 CEST PANIC: out of memory',
  '1 2 3 4 ERROR four prefix words',
  '1 2 3 4 5 ERROR five prefix words',
  'UTC GMT CET EST ERROR',
  'ABCDEF ERROR six capitals is no time zone',
  'ab ERROR lower case is no prefix',
  ' ERROR after a space',
  '\tERROR after a tab',
  'ERROR',
  'ERROR:',
  '[ERROR]:',
  '[ERROR',
  'ERROR]',
  'ERRORS in the plural',
  'ERR: short',
  'WARNING',
  'WARNINGS',
  'CRIT CRITICAL',
  'INFO:x',
  'INFO: x',
  '1ERROR x',
  '1 [TRACE] x',
  'a1b2 c3 TRACE x',
  '10.0.0.1 - - [20/Oct/2026:12:00:00 +0000] "GET / HTTP/1.1" 200 5',
  'I1026 12:00:00.000000       1 server.go:1] INFO',
  '2026-10-26T12:00:00Z\u00a0ERROR after a no-break space',
  '2026-10-26T12:00:00Z\u2003ERROR after an em space',
  'x\u0661 ERROR an Arabic digit is no digit',
  'ERROR\u2028after a line separator',
  '',
  '7',
  '7 ',
  'UTC',
  'UTC ',
];

/// A line of [words] random pieces that prefix words, level words and
/// their near misses are built from.
String _randomLine(Random random, int words) {
  const pieces = [
    'ERROR',
    'WARN',
    'WARNING',
    'INFO',
    '[FATAL]',
    'DEBUG:',
    '[ERR]:',
    'CRIT',
    'UTC',
    'AB',
    'ABCDEF',
    'A',
    '2026-10-26',
    '12:00:00',
    'x1',
    '1',
    'abc',
    '[1]',
    '[',
    ']',
    ':',
    'ERRORx',
    'aERROR',
    '',
    ' ',
    '\t',
    '\u00a0',
    '.',
  ];
  final line = StringBuffer();
  for (var i = 0; i < words; i++) {
    line.write(pieces[random.nextInt(pieces.length)]);
    if (random.nextInt(4) > 0) line.write(' ');
  }
  return line.toString();
}

void main() {
  test('a level word reads as the pattern before SMP-01 read it', () {
    final random = Random(1);
    final lines = [
      ..._levelWordCorpus,
      for (var i = 0; i < 20000; i++) _randomLine(random, 1 + i % 8),
    ];
    var levels = 0;
    for (final line in lines) {
      final word = _levelWordBefore.firstMatch(line)?.group(1);
      if (word != null) levels++;
      expect(linePriority(line), _priorityOfLevelWord[word], reason: line);
    }
    // The corpus exercises both answers.
    expect(levels, inInclusiveRange(1000, lines.length - 1000));
  });

  test('a long line without spaces is read in linear time (SMP-01)', () {
    const length = 64 * 1024;
    String filled(String piece) =>
        (piece * (length ~/ piece.length + 1)).substring(0, length);
    final lines = [
      filled('7'),
      filled('aGVsbG8gd29ybGQh0'),
      '2026-10-15T14:30:01Z ${filled('aGVsbG8gd29ybGQh0')}',
      '2026-10-15 14:30:01.123 UTC [1] ${filled('1.')}',
      filled('255.255.255.255:'),
      filled('UTC '),
      filled('1 '),
      '1${filled(' ')}x',
      filled('a.'),
      filled('Error'),
      filled(' level='),
      filled(' '),
    ];

    // Before the fix the first line alone took over a minute here; all
    // of them take a few milliseconds now.
    final watch = Stopwatch()..start();
    for (final line in lines) {
      linePriority(line);
      continuesLine(line);
    }
    expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
  });

  test('severity keeps fatal, notice and pino numbers apart', () {
    expect(linePriority('{"level":"fatal"}'), LogPriority.critical);
    expect(linePriority('{"level":60}'), LogPriority.critical);
    expect(linePriority('{"level":50}'), LogPriority.error);
    expect(linePriority('{"@l":"Warning","@mt":"x"}'), LogPriority.warning);
    expect(linePriority('level=notice msg=x'), LogPriority.notice);
    expect(linePriority('[DEBUG] cache miss'), LogPriority.debug);
    expect(linePriority('{"msg":"no level"}'), isNull);
    expect(linePriority('an ERROR deep in a long message here'), isNull);
  });

  test('continuation lines are indented frames and Caused by', () {
    expect(continuesLine('    at a.b(C.java:1)'), isTrue);
    expect(continuesLine('  File "app.py", line 3'), isTrue);
    expect(continuesLine('Caused by: x'), isTrue);
    expect(continuesLine('ValueError: x'), isFalse);
  });

  test('a JSON object line flattens its keys; anything else has none', () {
    expect(jsonLineFields('{"a":{"b":1,"c":null},"d":"e"}'), [
      ('a.b', '1'),
      ('a.c', 'null'),
      ('d', 'e'),
    ]);
    expect(jsonLineFields('{"a":1'), isNull);
    expect(jsonLineFields('[1]'), isNull);
  });
}
