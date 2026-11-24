// The `fs` and `cron` fragments through real shells, on a host where one
// source fails: a `df` that cannot read one mount, and cron sources the
// login user may not read (HST-1, HST-4). Each installed shell (dash,
// bash, mksh, BusyBox ash) runs the slow program. A stand-in `df` plays
// the failing mount, named by its path in the program text because a
// BusyBox built to run its applets before PATH would run its own; the
// cron run reads a scratch copy of `/etc`, as an account that is not its
// owner where the test runs as root. Tagged `shell`; a shell that is not
// installed gets no tests.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

String? _which(String name) {
  for (final dir in ['/bin', '/usr/bin', '/usr/sbin']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Each installed shell, as the words that start it.
final _shells = <String, List<String>>{
  for (final name in ['dash', 'bash', 'mksh'])
    if (_which(name) case final p?) name: [p],
  if (_which('busybox') case final p?) 'busybox ash': [p, 'sh'],
};

final _isRoot = (Process.runSync('id', ['-u']).stdout as String).trim() == '0';

/// The words that drop root to the `nobody` ids, or none.
final _drop = <String>[
  if (_isRoot) ...[
    _which('setpriv') ?? 'setpriv',
    '--reuid=65534',
    '--regid=65534',
    '--clear-groups',
  ],
];

const _table = '''
Filesystem     Type  1-blocks       Used  Available Capacity Mounted on
/dev/sda1      ext4  1000000000 400000000 600000000      40% /
tmpfs          tmpfs       4096         0       4096       0% /run''';

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      late Directory dir;

      setUp(() {
        dir = Directory.systemTemp.createTempSync('klab-partial-');
        Process.runSync('chmod', ['0755', dir.path]);
        addTearDown(() => dir.deleteSync(recursive: true));
      });

      /// One tick of [collector] from [program] under [shell], with
      /// [dir]'s `bin` first on PATH.
      Future<HwsSection> tick(
        Collector collector, {
        String Function(String program)? rewrite,
        List<String> prefix = const [],
      }) async {
        final nonce = generateNonce(Random.secure());
        var program = buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce);
        if (rewrite != null) program = rewrite(program);
        final argv = [...prefix, ...shell, '-s'];
        final process = await Process.start(
          argv.first,
          argv.sublist(1),
          environment: {
            'PATH': '${dir.path}/bin:${Platform.environment['PATH'] ?? ''}',
            'LC_ALL': 'C',
            'TZ': 'UTC',
          },
        );
        final out = <int>[];
        final err = StringBuffer();
        final outDone = process.stdout.forEach(out.addAll);
        final errDone = process.stderr
            .transform(utf8.decoder)
            .forEach(err.write);
        process.stdin.write(program);
        process.stdin.write(encodeTickRequest(1, [collector]));
        await process.stdin.close();
        await outDone;
        await errDone;
        expect(await process.exitCode, 0, reason: '$err');

        for (final e in HwsTickAssembler(nonce: nonce).push(out)) {
          if (e case HwsTick(seq: 1)) return e.section(collector.wireName)!;
        }
        fail('no reply: $err');
      }

      /// A `df` that prints [stderr], then [stdout], and exits [status].
      void df({
        required String stderr,
        required String stdout,
        int status = 1,
      }) {
        Directory('${dir.path}/bin').createSync();
        final file = File('${dir.path}/bin/df')
          ..writeAsStringSync(
            '#!/bin/sh\n'
            "[ -z '$stderr' ] || printf '%s\\n' '$stderr' >&2\n"
            "[ -z '$stdout' ] || printf '%s\\n' '$stdout'\n"
            'exit $status\n',
          );
        Process.runSync('chmod', ['0755', file.path]);
      }

      /// The program with the stand-in in place of both `df` runs.
      String standIn(String program) {
        const run = 'hw_run df ';
        expect(run.allMatches(program), hasLength(2));
        return program.replaceAll(run, 'hw_run ${dir.path}/bin/df ');
      }

      FsSnapshot parsed(HwsSection s) =>
          parseFs(utf8.decode(s.payload), ParseContext.standard).value;

      test('fs: a df that fails on one mount still lists the others', () async {
        const said = 'df: /mnt/dead: Transport endpoint is not connected';
        df(stderr: said, stdout: _table);

        final s = await tick(Collector.fs, rewrite: standIn);
        expect(s.status, SectionStatus.ok);
        final fs = parsed(s);
        expect(fs.mounts.map((m) => (m.device, m.type, m.mountPoint)), [
          ('/dev/sda1', 'ext4', '/'),
          ('tmpfs', 'tmpfs', '/run'),
        ]);
        expect(fs.mounts.first.sizeBytes, 1000000000);
        expect(fs.errors, [said.substring(4)]);
      });

      test("fs: BusyBox df's refused mount does not hide the others", () async {
        df(stderr: 'df: /mnt/private: Permission denied', stdout: _table);

        final s = await tick(Collector.fs, rewrite: standIn);
        expect(s.status, SectionStatus.ok);
        expect(parsed(s).mounts, hasLength(2));
        expect(parsed(s).errors, ['/mnt/private: Permission denied']);
      });

      test('fs: a df that prints no row keeps its failure', () async {
        df(stderr: 'df: cannot read table of mounted file systems', stdout: '');
        expect(
          (await tick(Collector.fs, rewrite: standIn)).status,
          SectionStatus.error,
        );

        df(stderr: 'df: /: Permission denied', stdout: '');
        expect(
          (await tick(Collector.fs, rewrite: standIn)).status,
          SectionStatus.denied,
        );
      });

      test('fs: a clean df is unchanged', () async {
        df(stderr: '', stdout: _table, status: 0);

        final s = await tick(Collector.fs, rewrite: standIn);
        expect(s.status, SectionStatus.ok);
        expect(parsed(s).errors, isEmpty);
        expect(parsed(s).mounts, hasLength(2));
      });

      /// A scratch `/etc` with one readable and one closed source of each
      /// kind, and the program rewritten to read it.
      String scratchEtc() {
        final etc = '${dir.path}/etc';
        for (final d in ['cron.d', 'cron.daily', 'cron.weekly']) {
          Directory('$etc/$d').createSync(recursive: true);
        }
        File('$etc/crontab').writeAsStringSync('0 1 * * * root /bin/true\n');
        File(
          '$etc/cron.d/open',
        ).writeAsStringSync('5 4 * * * root /usr/bin/open-job\n');
        File(
          '$etc/cron.d/closed',
        ).writeAsStringSync('6 4 * * * root /usr/bin/closed-job\n');
        File('$etc/cron.daily/logrotate').writeAsStringSync('#!/bin/sh\n');
        File('$etc/cron.weekly/man-db').writeAsStringSync('#!/bin/sh\n');
        return etc;
      }

      void chmod(String mode, String path) =>
          expect(Process.runSync('chmod', [mode, path]).exitCode, 0);

      CronSnapshot cronOf(HwsSection s, String etc) => parseCron(
        utf8.decode(s.payload).replaceAll(etc, '/etc'),
        ParseContext.standard,
      ).value;

      test('cron: closed sources are named and the open ones read', () async {
        final etc = scratchEtc();
        chmod('0600', '$etc/crontab');
        chmod('0600', '$etc/cron.d/closed');
        chmod('0700', '$etc/cron.daily');
        if (!_isRoot) {
          // The owner reads through 0600; nothing reads through 0000.
          chmod('0000', '$etc/crontab');
          chmod('0000', '$etc/cron.d/closed');
          chmod('0000', '$etc/cron.daily');
          addTearDown(() => chmod('0700', '$etc/cron.daily'));
        }

        final s = await tick(
          Collector.cron,
          rewrite: (p) => p.replaceAll('/etc/cron', '$etc/cron'),
          prefix: _drop,
        );
        expect(s.status, SectionStatus.ok);
        final cron = cronOf(s, etc);
        expect(cron.unreadableSources, [
          '/etc/crontab',
          '/etc/cron.d/closed',
          '/etc/cron.daily',
        ]);
        expect(cron.jobs.map((j) => (j.source, j.command)), [
          ('/etc/cron.d/open', '/usr/bin/open-job'),
        ]);
        expect(cron.dirEntries.map((e) => (e.period, e.name)), [
          (CronPeriod.weekly, 'man-db'),
        ]);
      }, skip: _isRoot && _which('setpriv') == null ? 'needs setpriv' : null);

      test('cron: a closed /etc/cron.d is named, not read as empty', () async {
        final etc = scratchEtc();
        chmod(_isRoot ? '0700' : '0000', '$etc/cron.d');
        addTearDown(() => chmod('0700', '$etc/cron.d'));

        final s = await tick(
          Collector.cron,
          rewrite: (p) => p.replaceAll('/etc/cron', '$etc/cron'),
          prefix: _drop,
        );
        expect(s.status, SectionStatus.ok);
        final cron = cronOf(s, etc);
        expect(cron.unreadableSources, ['/etc/cron.d']);
        expect(cron.jobs.map((j) => j.source), ['/etc/crontab']);
      }, skip: _isRoot && _which('setpriv') == null ? 'needs setpriv' : null);

      test('cron: with every source open nothing is named', () async {
        final etc = scratchEtc();

        final s = await tick(
          Collector.cron,
          rewrite: (p) => p.replaceAll('/etc/cron', '$etc/cron'),
        );
        expect(s.status, SectionStatus.ok);
        final cron = cronOf(s, etc);
        expect(cron.unreadableSources, isEmpty);
        expect(cron.jobs.map((j) => j.source), [
          '/etc/crontab',
          '/etc/cron.d/closed',
          '/etc/cron.d/open',
        ]);
        expect(cron.dirEntries, hasLength(2));
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty);
  });
}
