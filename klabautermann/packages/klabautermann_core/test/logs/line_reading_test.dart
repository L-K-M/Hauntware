// CTX-05: a container line's severity from what it says of itself, a
// stack trace's continuation lines, and a JSON line's keys.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

void main() {
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
