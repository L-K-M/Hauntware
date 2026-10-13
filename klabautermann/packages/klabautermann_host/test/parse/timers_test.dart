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

  test('an empty payload yields no timers and a warning', () {
    final r = parseTimers('', _ctx);
    expect(r.value.format, TimerListFormat.none);
    expect(r.warnings, isNotEmpty);
  });
}
