// `systemd-analyze calendar` output parser tests (03 §7.7): the original
// and normalized forms plus one elapse per `Next elapse`, `Iter. #N`
// or `Iteration #N` row, and warnings for error text.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  test('next elapse and iterations parse with their UTC detail', () {
    const raw = '''
  Original form: daily
Normalized form: *-*-* 00:00:00
    Next elapse: Tue 2026-10-13 00:00:00 UTC
       (in UTC): Tue 2026-10-13 00:00:00 UTC
       From now: 3h 12min left
       Iteration #2: Wed 2026-10-14 00:00:00 UTC
          (in UTC): Wed 2026-10-14 00:00:00 UTC
''';
    final r = parseOnCalendar(raw);
    expect(r.value.originalForm, 'daily');
    expect(r.value.normalizedForm, '*-*-* 00:00:00');
    expect(r.value.elapses, hasLength(2));
    expect(r.value.elapses.first.atUtc, DateTime.parse('2026-10-13T00:00:00Z'));
    expect(r.value.elapses.first.fromNow, '3h 12min left');
    expect(r.value.elapses.first.text, 'Tue 2026-10-13 00:00:00 UTC');
    expect(r.value.elapses.last.atUtc, DateTime.parse('2026-10-14T00:00:00Z'));
  });

  test('systemd 242 to 252 label later runs Iter. #N', () {
    // analyze.c v242 to v249 and analyze-calendar.c v252 print
    // `Iter. #%u:`; v253 renamed the row to `Iteration #%u`.
    const utc = '''
Normalized form: *-*-* 00:00:00
    Next elapse: Fri 2026-10-16 00:00:00 UTC
       From now: 11h left
       Iter. #2: Sat 2026-10-17 00:00:00 UTC
       From now: 1 day 11h left
       Iter. #3: Sun 2026-10-18 00:00:00 UTC
       From now: 2 days 11h left
''';
    final r = parseOnCalendar(utc);
    expect(r.warnings, isEmpty);
    expect(r.value.elapses.map((e) => e.text), [
      'Fri 2026-10-16 00:00:00 UTC',
      'Sat 2026-10-17 00:00:00 UTC',
      'Sun 2026-10-18 00:00:00 UTC',
    ]);
    expect(r.value.elapses.map((e) => e.atUtc), [
      DateTime.parse('2026-10-16T00:00:00Z'),
      DateTime.parse('2026-10-17T00:00:00Z'),
      DateTime.parse('2026-10-18T00:00:00Z'),
    ]);
    expect(r.value.elapses.last.fromNow, '2 days 11h left');

    const berlin = '''
Normalized form: *-*-* 00:00:00
    Next elapse: Fri 2026-10-16 00:00:00 CEST
       (in UTC): Thu 2026-10-15 22:00:00 UTC
       From now: 9h left
       Iter. #2: Sat 2026-10-17 00:00:00 CEST
       (in UTC): Fri 2026-10-16 22:00:00 UTC
       From now: 1 day 9h left
''';
    final b = parseOnCalendar(berlin).value.elapses;
    expect(b.map((e) => e.text), [
      'Fri 2026-10-16 00:00:00 CEST',
      'Sat 2026-10-17 00:00:00 CEST',
    ]);
    expect(b.last.atUtc, DateTime.parse('2026-10-16T22:00:00Z'));
  });

  test('in a UTC server zone the elapse itself is the instant', () {
    // systemd-analyze prints no `(in UTC)` line when the zone is UTC.
    const raw = '''
  Original form: daily
Normalized form: *-*-* 00:00:00
    Next elapse: Tue 2026-10-13 00:00:00 UTC
       From now: 3h left
''';
    expect(
      parseOnCalendar(raw).value.elapses.single.atUtc,
      DateTime.parse('2026-10-13T00:00:00Z'),
    );
  });

  test('in a zero-offset GMT zone the elapse is the instant too', () {
    // systemd 255 under TZ=Etc/GMT, Atlantic/Reykjavik or Africa/Abidjan:
    // no `(in UTC)` line, since the offset is zero all year.
    const raw = '''
  Original form: daily
Normalized form: *-*-* 00:00:00
    Next elapse: Fri 2026-10-16 00:00:00 GMT
       From now: 11h left
''';
    expect(
      parseOnCalendar(raw).value.elapses.single.atUtc,
      DateTime.parse('2026-10-16T00:00:00Z'),
    );
  });

  test('a non-UTC zone keeps the text but leaves atUtc unknown', () {
    const raw = '''
Original form: daily
Normalized form: *-*-* 00:00:00
Next elapse: Tue 2026-10-13 00:00:00 CEST
''';
    final r = parseOnCalendar(raw);
    expect(r.value.elapses.single.atUtc, isNull);
    expect(r.value.elapses.single.text, 'Tue 2026-10-13 00:00:00 CEST');
  });

  test('error text before a failure collects as warnings', () {
    const raw = 'Failed to parse calendar specification: nope\n';
    final r = parseOnCalendar(raw);
    expect(r.value.elapses, isEmpty);
    expect(r.warnings, isNotEmpty);
  });
}
