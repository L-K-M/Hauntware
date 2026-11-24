// UIB-1: a regular expression is matched by a worker isolate, so no
// pattern can hold the UI isolate, a new query stops the one before it
// in the middle of a match, and a pattern that does not finish ends the
// search with a reason.
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/logs/log_search.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_core/planchette_core.dart' show TextMatch;

/// A controller and a pattern search over it, disposed after the test.
(LogViewController, LogSearch) _logs({
  int? maxLines,
  Duration patternLimit = const Duration(seconds: 30),
}) {
  final logs = LogViewController(
    buffer: maxLines == null ? null : LogBuffer(maxLines: maxLines),
  );
  final search = LogSearch(logs, patternLimit: patternLimit)..setRegex(true);
  addTearDown(() {
    search.dispose();
    logs.dispose();
  });
  return (logs, search);
}

/// Waits until the worker has answered everything [search] asked it.
Future<void> _answered(LogSearch search) async {
  while (search.searching || search.working) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

/// [line]'s matches once the worker sent their places.
Future<List<TextMatch>> _matchesIn(LogSearch search, LogEntry line) async {
  search.matchesIn(line as LogLine);
  await _answered(search);
  return search.matchesIn(line);
}

/// An access log's line, about 150 characters.
String _accessLine(int i) =>
    '10.0.0.${i % 250} - - [20/Oct/2026:12:00:00 +0000] "GET /api/items/$i '
    'HTTP/1.1" 200 5123 "-" "curl/8.5.0" upstream=10.1.0.7:8080 '
    'request_time=0.012';

/// A pattern whose nested quantifier backtracks without end on a row of
/// words that does not end in one.
const _endless = r'(\w+\s?)+$';
final _endlessLine = '${'word ' * 12}${'a' * 50}!';

void main() {
  test('a slow pattern over a full buffer returns control at once and a new '
      'query stops it', () async {
    final (logs, search) = _logs();
    logs.add([for (var i = 0; i < 50000; i++) _accessLine(i)]);
    var notified = 0;
    search.addListener(() => notified++);

    // 13.9 s on the UI isolate before UIB-1.
    final watch = Stopwatch()..start();
    search.setQuery('.*items.*upstream.*zzz');
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(search.searching, isTrue);
    expect(notified, 1);

    watch.reset();
    search.setQuery(r'items/4999\d ');
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    await _answered(search);
    expect(watch.elapsed, lessThan(const Duration(seconds: 8)));
    expect(search.searching, isFalse);
    expect(search.tooCostly, isFalse);
    expect(search.total, 10);
    expect(notified, greaterThan(2));

    search.next();
    expect(search.current, (seq: 49990, index: 0));
    final start = _accessLine(49990).indexOf('items/49990 ');
    expect(await _matchesIn(search, logs[49990]), [
      TextMatch(start: start, end: start + 12),
    ]);
  });

  test('a pattern that does not finish ends the search and says so', () async {
    final (logs, search) = _logs(
      patternLimit: const Duration(milliseconds: 300),
    );
    logs.add(['GET /a 200', _endlessLine, 'GET /b 502']);

    final watch = Stopwatch()..start();
    search.setQuery(_endless);
    expect(search.tooCostly, isFalse);
    await _answered(search);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(search.tooCostly, isTrue);
    expect(search.total, 0);
    expect(search.matchesIn(logs[0] as LogLine), isEmpty);

    // New lines are not searched either, and nothing is left running.
    logs.add(['GET /c 200']);
    expect(search.working, isFalse);
    expect(search.total, 0);

    // The next query starts a new worker.
    search.setQuery(r'GET \S+ [45]\d\d');
    expect(search.tooCostly, isFalse);
    await _answered(search);
    expect(search.total, 1);
  });

  test('a query set while a pattern never finishes is answered', () async {
    final (logs, search) = _logs();
    logs.add([_endlessLine, 'GET /b 502']);

    search.setQuery(_endless);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(search.working, isTrue);

    final watch = Stopwatch()..start();
    search.setQuery('GET');
    await _answered(search);
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(search.total, 1);

    // Plain text needs no worker and is searched at once.
    search.setQuery(_endless);
    search.setRegex(false);
    expect(search.working, isFalse);
    expect(search.total, 0);
  });

  test('counts and places are those of the pattern itself', () async {
    final (logs, search) = _logs();
    final lines = [
      for (var i = 0; i < 700; i++) _accessLine(i),
      'Disk full on /dev/sda1',
      '\x1b[31mERROR\x1b[0m disk DISK disk',
      'Ärger mit ärger',
      '\u{1f600} smile \u{1f600}',
      '',
      'aaa',
    ];
    logs.add(lines);

    for (final (query, caseSensitive) in [
      (r'items/\d*7 ', false),
      ('disk', false),
      ('disk', true),
      (r'\p{Lu}rger', true),
      ('a*', false),
      ('.', false),
      (r'a\-b|sm.le', false),
      ('zzz', false),
    ]) {
      search
        ..setCaseSensitive(caseSensitive)
        ..setQuery(query);
      await _answered(search);

      final pattern = RegExp(
        query,
        caseSensitive: caseSensitive,
        unicode: !query.contains(r'\-'),
      );
      var total = 0;
      for (var i = 0; i < logs.length; i++) {
        final line = logs[i] as LogLine;
        final expected = [
          for (final match in pattern.allMatches(logs.rowText(line)))
            if (match.end > match.start)
              TextMatch(start: match.start, end: match.end),
        ];
        total += expected.length;
        // Every row's places for the short patterns, a sample otherwise.
        if (i % 97 == 0 || i >= 700) {
          expect(await _matchesIn(search, line), expected, reason: query);
        }
      }
      expect(search.total, total, reason: query);
    }
  });

  test('keeps up as lines arrive and leave while it searches', () async {
    final (logs, search) = _logs(maxLines: 1000);
    logs.add([for (var i = 0; i < 1000; i++) 'line $i x']);
    search.setQuery(r'x$');

    // Half the lines leave before the worker answered for any of them.
    logs.add([for (var i = 1000; i < 1500; i++) 'line $i x']);
    expect(logs.firstSeq, 500);
    await _answered(search);
    expect(search.total, 1000);

    search.next();
    expect(search.current, (seq: 500, index: 0));
    expect(await _matchesIn(search, logs[0]), const [
      TextMatch(start: 9, end: 10),
    ]);

    logs.add([for (var i = 0; i < 10; i++) 'no match', 'one more x']);
    expect(search.searching, isFalse, reason: 'only the first pass says so');
    await _answered(search);
    expect(search.total, 990);
    expect(search.current, isNull, reason: 'its line left');
    expect(search.matchesIn(logs[0] as LogLine), isEmpty);

    // A new zone changes every row's text: the search starts over.
    logs.setZoneOffset(const Duration(hours: 2));
    expect(search.searching, isTrue);
    await _answered(search);
    expect(search.total, 990);
  });
}
