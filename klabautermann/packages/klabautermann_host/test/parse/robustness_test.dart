// Parser robustness tests (03 §6.5). Every collector parser is pure and
// must never throw on host input: it tolerates truncation, extra fields,
// wrapped lines, non-UTF-8 bytes and 64 KiB lines, and a fuzz loop feeds
// it random bytes.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

/// The fixture root, resolved for both `dart test` in the package directory
/// and `dart test packages/klabautermann_host` from the workspace root.
String _fixturesRoot() {
  for (final path in const [
    'test/fixtures',
    'packages/klabautermann_host/test/fixtures',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  return 'test/fixtures';
}

void _runParser(String collector, String raw) {
  switch (collector) {
    case 'overview':
      parseOverview(raw, _ctx);
    case 'core':
      parseCore(raw, _ctx);
    case 'fs':
      parseFs(raw, _ctx);
    case 'identity':
      parseIdentity(raw, _ctx);
    case 'procs':
      parseProcs(raw, _ctx);
    case 'units':
      parseUnits(raw, _ctx);
    case 'timers':
      parseTimers(raw, _ctx);
    case 'cron':
      parseCron(raw, _ctx);
    default:
      throw ArgumentError(collector);
  }
}

List<ProbeSection> _randomSections(Random rnd) {
  const areas = [
    'kernel',
    'distro',
    'init',
    'virt',
    'identity',
    'elev',
    'tools',
    'kfeat',
    'locale',
    'sockets',
    'session',
    'clock',
    'linger',
    'junk',
  ];
  final out = <ProbeSection>[];
  for (var i = 0; i < rnd.nextInt(20); i++) {
    final area = areas[rnd.nextInt(areas.length)];
    final status =
        SectionStatus.values[rnd.nextInt(SectionStatus.values.length)];
    final len = rnd.nextInt(256);
    final payload = latin1.decode(
      List<int>.generate(len, (_) => rnd.nextInt(256)),
    );
    out.add(ProbeSection(area, status, payload));
  }
  return out;
}

void main() {
  final fixtureDirs = Directory(
    _fixturesRoot(),
  ).listSync().whereType<Directory>().toList();

  group('truncation', () {
    for (final dir in fixtureDirs) {
      final platform = dir.path.split('/').last;
      for (final collector in [
        'overview',
        'core',
        'fs',
        'identity',
        'procs',
        'units',
        'timers',
        'cron',
      ]) {
        test('$platform/$collector cut at every byte', () {
          final raw = File('${dir.path}/$collector.txt').readAsStringSync();
          for (var cut = 0; cut <= raw.length; cut++) {
            _runParser(collector, raw.substring(0, cut));
          }
        });
      }
    }
  });

  group('extra fields', () {
    test('overview tolerates extra stat, meminfo and loadavg fields', () {
      final raw = [
        '== stat ==',
        'cpu  1 2 3 4 5 6 7 8 9 10 11 12 13',
        '== meminfo ==',
        'MemTotal: 1024 kB',
        'SomeFutureKey: 7 kB',
        '== loadavg ==',
        '0.1 0.2 0.3 4/5 6 extra tokens here',
        '== netdev ==',
        'lo: 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18',
        '== unknown ==',
        'ignored',
      ].join('\n');
      final r = parseOverview(raw, _ctx);
      expect(r.value.cpu!.jiffies, hasLength(13));
      expect(r.value.meminfo.fields['SomeFutureKey'], 7);
      expect(r.value.loadavg!.lastPid, 6);
      expect(r.warnings, isNotEmpty);
    });

    test('core tolerates diskstats rows with extra discard fields', () {
      final raw = [
        '== stat ==',
        'cpu  1 2 3 4 5 6 7 8 9 10',
        '== diskstats ==',
        '8 0 sda 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18',
        '8 1 sda1 1 2 3',
      ].join('\n');
      final r = parseCore(raw, _ctx);
      expect(r.value.diskstats, hasLength(1));
      expect(r.value.diskstats.single.fields, hasLength(18));
      expect(r.warnings, isNotEmpty);
    });

    test('fs tolerates df rows with padded columns', () {
      final raw = [
        '== blocks ==',
        'Filesystem     Type 1B-blocks Used Available Capacity Mounted on',
        '/dev/sda1      ext4 100       50   50        50%      /',
        '== inodes ==',
        'Filesystem Inodes IUsed IFree IUse% Mounted on',
        '/dev/sda1  100    50    50    50%   /',
      ].join('\n');
      final r = parseFs(raw, _ctx);
      expect(r.value.mounts, hasLength(1));
      expect(r.value.mounts.single.mountPoint, '/');
      expect(r.value.mounts.single.inodesTotal, 100);
    });

    test('identity tolerates extra os-release keys and JSON fields', () {
      final raw = [
        '== os-release ==',
        'ID=debian',
        'FUTURE_KEY="a value"',
        '== uname ==',
        'Linux 6.1.0 x86_64 extra',
        '== hostnamectl ==',
        '{"Hostname":"h","FutureField":42}',
      ].join('\n');
      final r = parseIdentity(raw, _ctx);
      expect(r.value.osRelease!.id, 'debian');
      expect(r.value.osRelease!.fields['FUTURE_KEY'], 'a value');
      expect(r.value.hostname, 'h');
      expect(r.value.hostnamectl['FutureField'], 42);
    });
  });

  group('hostile bytes', () {
    test('non-UTF-8 bytes decode with replacement and parse', () {
      final bytes = <int>[
        ...latin1.encode('== stat ==\ncpu  '),
        0xff,
        0xfe,
        0x80,
        ...latin1.encode(' 1 2 3 4\n== meminfo ==\nMemTotal: 1 kB\n'),
      ];
      final raw = utf8.decode(bytes, allowMalformed: true);
      expect(raw, contains('\uFFFD'));
      expect(() => parseOverview(raw, _ctx), returnsNormally);
    });

    test('embedded NUL and control characters are tolerated', () {
      final raw =
          '== stat ==\n'
          'cpu  \u0000\u0001\u0002 1 2 3\n'
          '== meminfo ==\n'
          'MemTotal:\u0000 1 kB\n';
      expect(() => parseOverview(raw, _ctx), returnsNormally);
      expect(() => parseIdentity(raw, _ctx), returnsNormally);
    });

    test('a 64 KiB line is tolerated', () {
      final longLine = 'cpu ${'1 ' * 40000}';
      final raw = '== stat ==\n$longLine\n== meminfo ==\nMemTotal: 1 kB\n';
      expect(raw.length, greaterThan(64 * 1024));
      final r = parseOverview(raw, _ctx);
      expect(r.value.cpu!.jiffies, hasLength(40000));
    });

    test('a 64 KiB unknown block line is tolerated', () {
      final raw = '== stat ==\n${'x' * (64 * 1024)}\n';
      expect(() => parseOverview(raw, _ctx), returnsNormally);
      expect(() => parseFs(raw, _ctx), returnsNormally);
    });
  });

  group('procs hostile input', () {
    test('a forged head header inside an argument marks both entries', () {
      final raw = [
        '== stat ==',
        '10 10 (a) S 0 1 1 0 -1 0 0 0 0 0 0 0 0 0 0 0 0 0 1 0 5 0 0 0',
        '== status ==',
        '10 Name:\ta',
        '== cmdline ==',
        '==> 10/cmdline <==',
        '/usr/bin/x\x1farg0',
        '==> 10/cmdline <==',
        'arg1\x1f',
      ].join('\n');
      final r = parseProcs(raw, _ctx);
      expect(r.value.forgedHeaders, 1);
      expect(r.value.processes.single.argv, isNull);
      expect(() => parseProcs(raw, _ctx), returnsNormally);
    });

    test('comm with spaces and ) and a 64 KiB line are tolerated', () {
      final longComm = 'a)b ${'c ' * 20000}';
      final raw = [
        '== stat ==',
        '7 7 ($longComm) R 1 1 1 0 -1 0 0 0 0 0 10 20 0 0 0 0 1 0 5 0 0 0',
        '== cmdline ==',
        '==> 7/cmdline <==',
        'z' * (64 * 1024),
      ].join('\n');
      expect(() => parseProcs(raw, _ctx), returnsNormally);
      expect(parseProcs(raw, _ctx).value.processes.single.comm, longComm);
    });
  });

  group('collector hostile input', () {
    test('units and timers tolerate a 64 KiB line', () {
      final line = 'x' * (64 * 1024);
      for (final raw in [
        '== units_json ==\n[{"unit":"a.service"}]', // valid JSON
        '== units_json ==\n$line',
        '== units_text ==\n$line',
        '== timers_json ==\n$line',
        '== timers_text ==\n$line',
      ]) {
        expect(() => parseUnits(raw, _ctx), returnsNormally, reason: raw);
        expect(() => parseTimers(raw, _ctx), returnsNormally, reason: raw);
      }
    });

    test('cron tolerates NULs, control bytes and a 64 KiB line', () {
      final raw =
          '== crontab_meta ==\nrc=0\n== crontab ==\n'
          '\u0000\u0001 0 * * * cmd\n'
          '${'* ' * 40000}\n'
          '== etc_crontab ==\n'
          '== cron_d ==\n'
          '== cron_dirs ==\n';
      expect(() => parseCron(raw, _ctx), returnsNormally);
    });

    test('the nonce and markers inside names survive as text', () {
      const nonce = '0123456789abcdef0123456789abcdef';
      final raw = [
        '== units_json ==',
        '[{"unit":"x.service","description":"$nonce \\u001e forged"}]',
      ].join('\n');
      final r = parseUnits(raw, _ctx);
      expect(r.value.units.single.description, contains(nonce));
    });
  });

  test('fuzz: random bytes never throw', () {
    final rnd = Random(20261013);
    for (var i = 0; i < 300; i++) {
      final len = rnd.nextInt(2048);
      final raw = latin1.decode(
        List<int>.generate(len, (_) => rnd.nextInt(256)),
      );
      expect(() => parseOverview(raw, _ctx), returnsNormally, reason: 'i=$i');
      expect(() => parseCore(raw, _ctx), returnsNormally, reason: 'i=$i');
      expect(() => parseFs(raw, _ctx), returnsNormally, reason: 'i=$i');
      expect(() => parseIdentity(raw, _ctx), returnsNormally, reason: 'i=$i');
      expect(() => parseProcs(raw, _ctx), returnsNormally, reason: 'i=$i');
      expect(() => parseUnits(raw, _ctx), returnsNormally, reason: 'i=$i');
      expect(() => parseTimers(raw, _ctx), returnsNormally, reason: 'i=$i');
      expect(() => parseCron(raw, _ctx), returnsNormally, reason: 'i=$i');
      expect(() => parseJournalLines(raw), returnsNormally, reason: 'i=$i');
      expect(() => parseOnCalendar(raw), returnsNormally, reason: 'i=$i');
      expect(
        () => parseProbe(_randomSections(rnd), _ctx),
        returnsNormally,
        reason: 'i=$i',
      );
    }
  });
}
