// `systemd-analyze calendar` output parser tests (03 §7.7): the original
// and normalized forms plus one elapse per `Next elapse` or `Iteration
// #N` row, and warnings for error text.
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
