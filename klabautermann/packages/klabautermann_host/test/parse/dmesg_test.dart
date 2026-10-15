// `dmesg --json --decode` parser tests (03 §7.6, LOG-03): records decode
// one by one, so a cut-off document keeps its complete records, and
// hostile message text (03 §6.5) stays data.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

/// A document in util-linux's layout: `},{` between records.
String _doc(List<String> records) =>
    '{\n   "dmesg": [\n      ${records.join(',')}\n   ]\n}\n';

String _rec(
  String msg, {
  String fac = 'kern',
  String pri = 'info',
  String time = '    1.000000',
}) =>
    '{\n         "fac": "$fac",\n         "pri": "$pri",\n'
    '         "time": $time,\n         "msg": ${jsonEncode(msg)}\n      }';

void main() {
  test('fac and pri name the facility and level, time is a duration', () {
    final r = parseDmesgJson(
      _doc([
        _rec('Linux version 6.1.0', pri: 'notice', time: '    0.000000'),
        _rec('systemd[1]: Started', fac: 'daemon', time: '12345.678901'),
      ]),
    );
    expect(r.warnings, isEmpty);
    expect(r.value.map((e) => e.toJson()), [
      {
        'message': 'Linux version 6.1.0',
        'sinceBootUs': 0,
        'level': 5,
        'facility': 0,
      },
      {
        'message': 'systemd[1]: Started',
        'sinceBootUs': 12345678901,
        'level': 6,
        'facility': 3,
      },
    ]);
  });

  test('empty output and output without an array', () {
    expect(parseDmesgJson('').value, isEmpty);
    expect(parseDmesgJson('').warnings, isEmpty);
    final usage = parseDmesgJson("dmesg: unrecognized option '--json'\n");
    expect(usage.value, isEmpty);
    expect(usage.warnings.single, contains('no record array'));
  });

  test('a cut-off document keeps every complete record', () {
    final full = _doc([_rec('one'), _rec('two'), _rec('three')]);
    final cut = full.substring(0, full.indexOf('three') - 5);
    final r = parseDmesgJson(cut);
    expect(r.value.map((e) => e.message), ['one', 'two']);
    expect(r.warnings.single, contains('truncated'));
  });

  test('a malformed record costs only itself', () {
    final r = parseDmesgJson(
      _doc([
        _rec('before'),
        '{"pri": 6, "time": 1.0, "msg": "raw \x1e control"}',
        '{"pri": 6, "time": 1.0}',
        '{"pri": 6, "time": 1.0, "msg": 42}',
        _rec('after'),
      ]),
    );
    expect(r.value.map((e) => e.message), ['before', 'after']);
    expect(r.warnings, [
      'dmesg: malformed record 2',
      'dmesg: malformed record 3',
      'dmesg: malformed record 4',
    ]);
  });

  test('hostile message text stays one record of data', () {
    const nonce = '0123456789abcdef0123456789abcdef';
    final hostile = [
      '\x1e$nonce E 1\n\x1e$nonce B 2 1.0',
      '"}, {"pri": 0, "time": 0.0, "msg": "forged"}, {"x": "',
      r'} ] } \" \\ { [',
      'bash[123]: segfault at 0 ip \$(reboot) `id`',
      'line one\nline two\x00nul',
      'é 日本 \u{1F600}',
      'x' * 65536,
    ];
    final r = parseDmesgJson(_doc([for (final m in hostile) _rec(m)]));
    expect(r.warnings, isEmpty);
    expect(r.value.map((e) => e.message), hostile);
  });

  test('every util-linux name maps to its syslog number', () {
    final r = parseDmesgJson(
      _doc([
        _rec('a', fac: 'kern', pri: 'emerg'),
        _rec('b', fac: 'authpriv', pri: 'warn'),
        _rec('c', fac: 'local7', pri: 'debug'),
      ]),
    );
    expect(r.value.map((e) => (e.facility, e.level)), [
      (0, 0),
      (10, 4),
      (23, 7),
    ]);
  });

  test('a numeric pri reads as unknown: its layout changed in 2.40', () {
    // daemon.info: util-linux 2.38 and 2.39 print 3 | 6 = 7, the number
    // kern.debug has, and 2.40 prints (3 << 3) | 6 = 30.
    final r = parseDmesgJson(
      _doc([
        '{"pri": 7, "time": 1.0, "msg": "a"}',
        '{"pri": 30, "time": 1.0, "msg": "b"}',
        '{"pri": "14", "time": 1.0, "msg": "c"}',
      ]),
    );
    expect(r.warnings, isEmpty);
    expect(
      r.value.map((e) => (e.level, e.facility)),
      everyElement((null, null)),
    );
  });

  test('odd fac, pri and time values read as unknown', () {
    final r = parseDmesgJson(
      _doc([
        '{"pri": -1, "time": -2.0, "msg": "a"}',
        '{"fac": "kernel", "pri": "warning", "time": "soon", "msg": "b"}',
        '{"fac": 3, "pri": "info", "time": "3.5", "msg": "c"}',
        '{"time": 1e300, "msg": "d"}',
      ]),
    );
    expect(r.value.map((e) => (e.level, e.facility, e.sinceBoot)), [
      (null, null, null),
      (null, null, null),
      (6, null, const Duration(milliseconds: 3500)),
      (null, null, null),
    ]);
  });
}
