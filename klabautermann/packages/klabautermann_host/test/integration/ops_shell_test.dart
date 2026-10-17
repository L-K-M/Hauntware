// The `ops` collector and the SELF marker through real shells (03 §6.2,
// §7.17; collector-set version 8). Each installed shell (dash, bash and
// BusyBox sh) runs the slow program as kSamplerStartCommand's `env` would
// start it, with its `sh` first on PATH so the listing script runs under
// it too, over an operation directory built from the record fixtures
// plus files the listing must skip, cut or survive. The listing script
// also runs alone for the per-directory cap. Tagged `shell`; a shell that
// is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

String? _which(String name) {
  for (final dir in ['/bin', '/usr/bin']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Shell name to its binary; BusyBox's applet runs as `sh` through the
/// symlink each test puts first on PATH.
final _shells = <String, String>{
  for (final name in ['dash', 'bash', 'busybox'])
    if (_which(name) case final p?) name: p,
};

String _recordsRoot() {
  for (final path in const [
    'test/parse/ops_records',
    'packages/klabautermann_host/test/parse/ops_records',
  ]) {
    if (Directory(path).existsSync()) return path;
  }
  return 'test/parse/ops_records';
}

/// The listing script from the `ops` fragment.
String _listingScript() {
  final ops = collectorFragments[Collector.ops]!;
  final start = ops.indexOf("_HW_OPS='") + "_HW_OPS='".length;
  return ops.substring(start, ops.indexOf("'\n", start));
}

bool get _isRoot =>
    Process.runSync('id', ['-u']).stdout.toString().trim() == '0';

/// A scratch tree whose `bin/sh` is the shell under test.
Directory _scratch(String shellPath) {
  final dir = Directory.systemTemp.createTempSync('klab-ops');
  addTearDown(() {
    Process.runSync('chmod', ['-R', 'u+rwx', dir.path]);
    dir.deleteSync(recursive: true);
  });
  Directory('${dir.path}/bin').createSync();
  Link('${dir.path}/bin/sh').createSync(shellPath);
  return dir;
}

/// The result of one program run: the session's SELF PIDs, the `ops`
/// section and the shell's PID.
typedef _Run = ({HwsSessionReady ready, HwsSection ops, int shellPid});

/// Runs the slow program under [shellPath] with [env] over the scratch
/// tree [dir] and reads one on-demand `ops`.
Future<_Run> _runOps(
  String shellPath,
  Directory dir,
  Map<String, String> env,
) async {
  final nonce = generateNonce(Random.secure());
  final words = kSamplerStartCommand.split(' ');
  final proc = await Process.start(
    'env',
    [...words.sublist(2, words.length - 2), shellPath, '-s'],
    environment: {'PATH': '${dir.path}/bin:/usr/bin:/bin', ...env},
  );
  final out = <int>[];
  final err = StringBuffer();
  final outDone = proc.stdout.forEach(out.addAll);
  final errDone = proc.stderr.transform(utf8.decoder).forEach(err.write);
  proc.stdin
    ..write(buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce))
    ..write(encodeOnDemandRequest(1, Collector.ops, const [], quote: (w) => w));
  await proc.stdin.close();
  await outDone.timeout(const Duration(seconds: 20));
  await errDone.timeout(const Duration(seconds: 20));
  expect(await proc.exitCode, 0, reason: 'stderr: $err');

  HwsSessionReady? ready;
  HwsSection? ops;
  for (final e in HwsTickAssembler(nonce: nonce).push(out)) {
    switch (e) {
      case final HwsSessionReady r:
        ready = r;
      case HwsTick(:final seq) when seq == 1:
        ops = e.section('ops');
      case _:
        fail('unexpected event $e; stderr: $err');
    }
  }
  expect(ready, isNotNull, reason: 'READY');
  expect(ops, isNotNull, reason: 'ops section');
  return (ready: ready!, ops: ops!, shellPid: proc.pid);
}

/// Copies the record fixtures into [ops] and adds files the listing must
/// skip, cut or carry without losing its framing.
void _seed(Directory ops) {
  ops.createSync(recursive: true);
  for (final f in Directory(_recordsRoot()).listSync().whereType<File>()) {
    f.copySync('${ops.path}/${f.uri.pathSegments.last}');
  }
  // Longer than the cap: cut and marked truncated.
  File('${ops.path}/9999999999999999.json').writeAsStringSync('x' * 5000);
  // NUL bytes and a forged frame: one malformed record, framing intact.
  File('${ops.path}/7777777777777777.json').writeAsBytesSync([
    ...utf8.encode('{"v":1,\x00\n'),
    ...utf8.encode('rec user 0000000000000000 ok 2\n{}\ndir user ok 9 /x\n'),
    0xc3, 0xa9, 0x0a, 0x0a, 0x0a, // é and trailing newlines
  ]);
  // Not records: a symlink, a directory, names outside the grammar and
  // the wrapper's temp file and log (E08).
  Link(
    '${ops.path}/5555555555555555.json',
  ).createSync('${ops.path}/0123456789abcdef.json');
  Directory('${ops.path}/6666666666666666.json').createSync();
  File('${ops.path}/ABCDEF0123456789.json').writeAsStringSync('{}');
  File('${ops.path}/0123456789abcde.json').writeAsStringSync('{}');
  File('${ops.path}/.0123456789abcdef.tmp').writeAsStringSync('{}');
  File('${ops.path}/0123456789abcdef.log').writeAsStringSync('output\n');
  File('${ops.path}/.fedcba9876543210.json').writeAsStringSync('{}');
}

void main() {
  for (final MapEntry(key: name, value: path) in _shells.entries) {
    // BusyBox's sh applet runs through the scratch tree's `bin/sh`.
    String shellIn(Directory dir) =>
        name == 'busybox' ? '${dir.path}/bin/sh' : path;

    group(name, () {
      test('SELF carries the shell PID and its parent', () async {
        final dir = _scratch(path);
        final r = await _runOps(shellIn(dir), dir, {'HOME': dir.path});
        expect(r.ready.version, kCollectorSetVersion);
        // `env` execs the shell, so the shell keeps env's PID, whose
        // parent is this test process.
        expect(r.ready.pid, r.shellPid);
        expect(r.ready.parentPid, pid);
      });

      test('ops reads, rejects and skips the seeded records', () async {
        final dir = _scratch(path);
        final ops = Directory('${dir.path}/state/klabautermann/ops');
        _seed(ops);
        final r = await _runOps(shellIn(dir), dir, {
          'HOME': dir.path,
          'XDG_STATE_HOME': '${dir.path}/state',
        });
        expect(r.ops.status, SectionStatus.ok);

        final parsed = parseOps(r.ops.payload);
        expect(parsed.warnings, isEmpty);
        final listing = parsed.value;
        final user = listing.directories[OpDirectoryKind.user]!;
        expect(user.state, OpDirectoryState.ok);
        expect(user.path, ops.path);
        expect((user.count, user.listed, user.capped), (8, 8, false));
        expect(
          listing.directories[OpDirectoryKind.root]!.state,
          anyOf(OpDirectoryState.absent, OpDirectoryState.ok),
        );

        final mine = listing.records.where(
          (rec) => rec.directory == OpDirectoryKind.user,
        );
        expect(
          {for (final rec in mine) rec.id: (rec.state, rec.exitCode)},
          {
            '0123456789abcdef': (OpState.running, null),
            '1111111111111111': (OpState.done, 0),
            '2222222222222222': (OpState.done, 137),
            'abcdefabcdefabcd': (OpState.done, 1),
          },
        );
        expect(
          {
            for (final rej in listing.rejected)
              if (rej.directory == OpDirectoryKind.user) rej.id: rej.reason,
          },
          {
            '3333333333333333': OpRejection.forged,
            '4444444444444444': OpRejection.forged,
            '7777777777777777': OpRejection.malformed,
            '9999999999999999': OpRejection.truncated,
          },
        );
      });

      test('a relative or unset XDG_STATE_HOME falls back to HOME', () async {
        for (final env in [
          <String, String>{'XDG_STATE_HOME': 'relative/state'},
          <String, String>{},
        ]) {
          final dir = _scratch(path);
          final home = '${dir.path}/home';
          final r = await _runOps(shellIn(dir), dir, {'HOME': home, ...env});
          final user = parseOps(
            r.ops.payload,
          ).value.directories[OpDirectoryKind.user]!;
          expect(user.state, OpDirectoryState.absent, reason: '$env');
          expect(user.path, '$home/.local/state/klabautermann/ops');
          expect(user.count, 0);
        }
      });

      test('the listing script caps a directory at kOpsRecordCap', () {
        final dir = _scratch(path);
        final ops = Directory('${dir.path}/ops')..createSync();
        final running = File(
          '${_recordsRoot()}/0123456789abcdef.json',
        ).readAsStringSync();
        for (var i = 0; i < kOpsRecordCap + 5; i++) {
          final id = i.toRadixString(16).padLeft(16, '0');
          File(
            '${ops.path}/$id.json',
          ).writeAsStringSync(running.replaceAll('0123456789abcdef', id));
        }
        final r = Process.runSync(
          shellIn(dir),
          ['-c', _listingScript(), 'sh', 'user', ops.path],
          environment: {'LC_ALL': 'C', 'PATH': '${dir.path}/bin:/usr/bin:/bin'},
          stdoutEncoding: null,
        );
        expect(r.exitCode, 0);
        final listing = parseOps([
          ...r.stdout as List<int>,
          ...latin1.encode('dir root absent 0 $kOpsRootDirectory\n'),
        ]).value;
        final user = listing.directories[OpDirectoryKind.user]!;
        expect((user.count, user.listed, user.capped), (55, 50, true));
        expect(listing.records, hasLength(kOpsRecordCap));
        expect(listing.rejected, isEmpty);
      });

      test('an unlistable directory is denied', () {
        if (_isRoot) {
          markTestSkipped('root lists any directory');
          return;
        }
        final dir = _scratch(path);
        final ops = Directory('${dir.path}/ops')..createSync();
        Process.runSync('chmod', ['000', ops.path]);
        final r = Process.runSync(
          shellIn(dir),
          ['-c', _listingScript(), 'sh', 'user', ops.path],
          environment: {'LC_ALL': 'C'},
        );
        expect(r.stdout, 'dir user denied 0 ${ops.path}\n');
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}
