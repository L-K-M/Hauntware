// `timers` parser tests (03 §6.4, §7.7): the systemd 246+ JSON shape and
// the columnar `list-timers --all` table, sliced at the header's column
// offsets, with n/a and timespan cells.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

const _widths = [30, 14, 30, 12, 30];

String _pad(String s, int width) =>
    s.length >= width ? s : s + ' ' * (width - s.length);

/// The `list-timers` header and a row, both padded to the same widths so
/// the parser's header offsets and the row cells agree.
String _header() =>
    '${_pad('NEXT', _widths[0])}${_pad('LEFT', _widths[1])}'
    '${_pad('LAST', _widths[2])}${_pad('PASSED', _widths[3])}'
    '${_pad('UNIT', _widths[4])}ACTIVATES';

String _row(
  String next,
  String left,
  String last,
  String passed,
  String unit,
  String activates,
) =>
    '${_pad(next, _widths[0])}${_pad(left, _widths[1])}'
    '${_pad(last, _widths[2])}${_pad(passed, _widths[3])}'
    '${_pad(unit, _widths[4])}$activates';

void main() {
  test('JSON rows carry microsecond instants and the activated unit', () {
    final raw = [
      '== timers_json ==',
      '[{"next":1750000000000000,"left":3600000000,'
          '"last":1749990000000000,"passed":10000000000,'
          '"unit":"logrotate.timer","activates":"logrotate.service"},'
          '{"next":null,"left":null,"last":null,"passed":null,'
          '"unit":"fstrim.timer","activates":"fstrim.service"}]',
    ].join('\n');

    final r = parseTimers(raw, _ctx);
    expect(r.value.format, TimerListFormat.json);
    expect(r.value.timers, hasLength(2));
    final t = r.value.timers.first;
    expect(t.unit, 'logrotate.timer');
    expect(t.activates, 'logrotate.service');
    expect(t.nextUs, 1750000000000000);
    expect(t.leftUs, 3600000000);
    expect(
      t.nextUtc,
      DateTime.fromMicrosecondsSinceEpoch(1750000000000000, isUtc: true),
    );
    expect(r.value.timers.last.nextUs, isNull);
  });

  test('JSON instants beyond the DateTime range read as unknown', () {
    final raw = [
      '== timers_json ==',
      '[{"next":9000000000000000000,"last":-9000000000000000000,'
          '"unit":"a.timer"},'
          '{"next":-9223372036854775808,"unit":"b.timer"}]',
    ].join('\n');

    final r = parseTimers(raw, _ctx);
    for (final t in r.value.timers) {
      expect(t.nextUs, isNull, reason: t.unit);
      expect(t.lastUs, isNull, reason: t.unit);
      expect(t.nextUtc, isNull, reason: t.unit);
      expect(t.lastUtc, isNull, reason: t.unit);
    }
    expect(r.warnings, hasLength(3));
  });

  test('JSON instants at the DateTime bounds are kept', () {
    const maxUs = 8640000000000000000;
    final raw = [
      '== timers_json ==',
      '[{"next":$maxUs,"last":-$maxUs,"unit":"edge.timer"}]',
    ].join('\n');

    final r = parseTimers(raw, _ctx);
    final t = r.value.timers.single;
    expect(t.nextUs, maxUs);
    expect(t.lastUs, -maxUs);
    expect(t.nextUtc, isNotNull);
    expect(t.lastUtc, isNotNull);
    expect(r.warnings, isEmpty);
  });

  test('text rows are sliced at the header columns', () {
    final raw = [
      '== timers_text ==',
      _header(),
      _row(
        'Mon 2023-11-13 21:45:58 UTC',
        '2h 15min left',
        'Mon 2023-11-13 19:30:00 UTC',
        '10min ago',
        'logrotate.timer',
        'logrotate.service',
      ),
      _row('n/a', 'n/a', 'n/a', 'n/a', 'fstrim.timer', 'fstrim.service'),
      '2 timers listed.',
    ].join('\n');

    final r = parseTimers(raw, _ctx);
    expect(r.value.format, TimerListFormat.text);
    expect(r.value.timers, hasLength(2));
    final t = r.value.timers.first;
    expect(t.unit, 'logrotate.timer');
    expect(t.activates, 'logrotate.service');
    expect(
      t.nextUs,
      DateTime.parse('2023-11-13T21:45:58Z').microsecondsSinceEpoch,
    );
    expect(t.leftUs, ((2 * 60 + 15) * 60) * 1000000);
    expect(t.passedUs, 10 * 60 * 1000000);
    expect(t.nextText, 'Mon 2023-11-13 21:45:58 UTC');
    final never = r.value.timers.last;
    expect(never.nextUs, isNull);
    expect(never.activates, 'fstrim.service');
  });

  test('a non-UTC timestamp stays unconverted text', () {
    final raw = [
      '== timers_text ==',
      _header(),
      _row(
        'Mon 2023-11-13 21:45:58 CET',
        '1h left',
        'Mon 2023-11-13 19:00:00 CET',
        '2h ago',
        'x.timer',
        'x.service',
      ),
    ].join('\n');
    final r = parseTimers(raw, _ctx);
    expect(r.value.timers.single.nextUs, isNull);
    expect(r.value.timers.single.nextText, 'Mon 2023-11-13 21:45:58 CET');
  });

  test('spans with unit words read as microseconds', () {
    final raw = [
      '== timers_text ==',
      _header(),
      _row('n/a', '1 day 3h left', 'n/a', '2 weeks ago', 'x.timer', 'x'),
    ].join('\n');
    final t = parseTimers(raw, _ctx).value.timers.single;
    expect(t.leftUs, const Duration(hours: 27).inMicroseconds);
    expect(t.passedUs, const Duration(days: 14).inMicroseconds);
  });

  test('an empty payload yields no timers and a warning', () {
    final r = parseTimers('', _ctx);
    expect(r.value.format, TimerListFormat.none);
    expect(r.warnings, isNotEmpty);
  });

  group('timer_detail (D57)', () {
    test('calendar and monotonic triggers and the randomized delay', () {
      final r = parseTimerDetail(
        'hw_timeout=absent\n'
        'TimersMonotonic={ OnBootUSec=15min ; next_elapse=15min }\n'
        'TimersMonotonic={ OnUnitInactiveUSec=1h 30.500000s ; '
        'next_elapse=0 }\n'
        'TimersCalendar={ OnCalendar=*-*-* 06,18:00:00 ; '
        'next_elapse=Thu 2026-10-15 18:00:00 UTC }\n'
        'TimersCalendar={ OnCalendar=Mon..Fri *-*-* 09:00:00 Europe/Berlin '
        '; next_elapse=n/a }\n'
        'RandomizedDelayUSec=12h\n',
        _ctx,
      );
      expect(r.warnings, isEmpty);
      expect(r.value.toJson(), {
        'calendar': [
          '*-*-* 06,18:00:00',
          'Mon..Fri *-*-* 09:00:00 Europe/Berlin',
        ],
        'monotonic': [
          {'type': 'monotonic', 'base': 'boot', 'spanUs': 900000000},
          {'type': 'monotonic', 'base': 'unitInactive', 'spanUs': 3630500000},
        ],
        'randomizedDelayUs': 43200000000,
        'timeoutAbsent': true,
      });
    });

    test('every monotonic base maps from its bus property name', () {
      for (final b in MonotonicBase.values) {
        final property = b.setting.replaceFirst(RegExp(r'Sec$'), 'USec');
        final r = parseTimerDetail(
          'TimersMonotonic={ $property=1d ; next_elapse=1d }',
          _ctx,
        );
        expect(r.value.monotonic.single.base, b, reason: property);
      }
    });

    test('zero and absent delays differ; empty values are skipped', () {
      final zero = parseTimerDetail('RandomizedDelayUSec=0\n', _ctx);
      expect(zero.value.randomizedDelay, Duration.zero);
      final old = parseTimerDetail('TimersCalendar=\nTimersMonotonic=\n', _ctx);
      expect(old.value.randomizedDelay, isNull);
      expect(old.value.calendar, isEmpty);
      expect(old.warnings, isEmpty);
    });

    test('spans systemd prints parse, others warn instead of throwing', () {
      Duration? delay(String span) => parseTimerDetail(
        'RandomizedDelayUSec=$span',
        _ctx,
      ).value.randomizedDelay;
      expect(delay('1y 2month'), const Duration(microseconds: 36817200000000));
      expect(delay('2w 3d 4h 5min 6s 7ms 8us'), isNotNull);
      expect(delay('1.5ms'), const Duration(microseconds: 1500));
      for (final bad in [
        'infinity',
        '5 parsecs',
        '1.2.3s',
        '-1s',
        '99999999999999999999y',
        '9223372036854775807us 9223372036854775807us',
      ]) {
        final r = parseTimerDetail('RandomizedDelayUSec=$bad', _ctx);
        expect(r.value.randomizedDelay, isNull, reason: bad);
        expect(r.warnings, hasLength(1), reason: bad);
      }
    });

    test('error text and broken triggers warn', () {
      final r = parseTimerDetail(
        'Failed to get properties: Access denied\n'
        'TimersCalendar=OnCalendar=daily\n'
        'TimersCalendar={ OnBootUSec=1h ; next_elapse=1h }\n'
        'TimersMonotonic={ OnWhenever=1h ; next_elapse=1h }\n'
        'Unexpected=1\n',
        _ctx,
      );
      expect(r.value.calendar, isEmpty);
      expect(r.value.monotonic, isEmpty);
      expect(r.warnings, hasLength(5));
    });
  });
}
