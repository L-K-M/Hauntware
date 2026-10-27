// LogService through real login shells (03 §7.6, §8.8): dash and bash run
// each command line as sshd hands an exec request to the account's shell.
// tail is the host's own; journalctl and dmesg are stand-ins on the
// commands' PATH, so the kernel log's fallback runs the same everywhere.
// Tagged `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/log_service.dart';
import 'package:klabautermann_core/src/logs/log_stream_router.dart';
import 'package:test/test.dart';

import '../support/local_process_link.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    if (localShell(name) case final path?) name: path,
};

Future<void> _until(bool Function() condition) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 10)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  for (final MapEntry(key: name, value: path) in _shells.entries) {
    group(name, () {
      late LocalProcessLink link;
      late Directory dir;
      late List<EngineEvent> events;
      late LogService service;

      setUp(() async {
        link = await LocalProcessLink.create(path);
        dir = await Directory.systemTemp.createTemp('klab-logs-');
        events = [];
        service = LogService(
          link: link,
          quote: quoteShellWord,
          emit: events.add,
        );
      });
      tearDown(() async {
        await service.close();
        await link.dispose();
        await dir.delete(recursive: true);
      });

      List<LogStreamStatus> statuses(String id) => [
        for (final e in events)
          if (e case LogStreamState(:final streamId, :final status)
              when streamId == id)
            status,
      ];

      Future<LogStreamEnded> read(String id, LogSource source) async {
        service.open(
          id,
          LogStreamSpec(
            serverId: 'srv-1',
            source: source,
            window: kLogWindowMax,
            follow: false,
          ),
        );
        await _until(() => statuses(id).lastOrNull is LogStreamEnded);
        return statuses(id).last as LogStreamEnded;
      }

      List<String> texts() => [
        for (final batch in events.whereType<LogBatch>())
          for (final r in batch.records) (r as FileRecord).text,
      ];

      test(
        'tail reads a file whose path needs quoting, newest first',
        () async {
          final file = File('${dir.path}/it\'s a "log" \$(touch pwned).txt');
          await file.writeAsBytes([
            ...utf8.encode('first\n\x1e0123456789abcdef E 1\n'),
            0x61, 0x00, 0xff, 0x0a, //
            ...utf8.encode('last\n'),
          ]);

          final end = await read('f', FileLogSource(file.path));
          expect(end, const LogStreamEnded(LogStreamEndReason.oldestReached));
          expect(texts(), [
            'last',
            'a\x00�',
            '\x1e0123456789abcdef E 1',
            'first',
          ]);
          for (final d in [dir, link.workingDirectory]) {
            expect(File('${d.path}/pwned').existsSync(), isFalse);
          }
        },
      );

      test('a missing file ends as missing with tail\'s error', () async {
        final end = await read('f', FileLogSource('${dir.path}/absent.log'));
        expect(end.reason, LogStreamEndReason.missing);
        expect(end.detail, contains('No such file or directory'));
      });

      test('the kernel log falls back to dmesg', () async {
        final args = File('${dir.path}/journalctl-args');
        await _tool(link, 'journalctl', 'printf "%s\\n" "\$@" > ${args.path}');
        await _tool(
          link,
          'dmesg',
          "printf '%s' '${jsonEncode({
            'dmesg': [
              {'fac': 'kern', 'pri': 'err', 'time': 1.0, 'msg': 'oops'},
              {'fac': 'kern', 'pri': 'info', 'time': 2.0, 'msg': 'fine'},
            ],
          })}'",
        );

        final end = await read('k', const KernelLogSource());
        expect(end, const LogStreamEnded(LogStreamEndReason.oldestReached));
        expect(statuses('k').take(2), [
          const LogStreamRunning(),
          const LogStreamRunning(reader: LogReader.fallback),
        ]);
        expect(
          await args.readAsLines(),
          '-o json --no-pager -k -b -n 500 -r'.split(' '),
        );
        final kernel = events.whereType<LogBatch>().single.records;
        expect(kernel.cast<KernelRecord>().map((r) => r.priority), [
          LogPriority.info,
          LogPriority.error,
        ]);
      });

      // tail of the command's own stdin waits for input that never comes.
      const waiting = FileLogSource('/dev/stdin');

      test('closeStream stops a read the host has not finished', () async {
        service.open(
          'w',
          LogStreamSpec(
            serverId: 'srv-1',
            source: waiting,
            window: 10,
            follow: false,
          ),
        );
        await _until(() => link.processes.isNotEmpty);
        service.closeStream('w');
        expect(
          statuses('w').last,
          const LogStreamEnded(LogStreamEndReason.closed),
        );
        await link.processes.single.exit.timeout(const Duration(seconds: 10));
      });

      test('through the router, a third window waits for a channel and '
          'runs once one frees; each ends once', () async {
        final router = LogStreamRouter(linkFor: (_) => link, emit: events.add)
          ..retain({'srv-1'});
        final file = File('${dir.path}/app.log');
        await file.writeAsString('one\ntwo\n');
        for (final (id, source) in [
          ('w1', waiting),
          ('w2', waiting),
          ('f', FileLogSource(file.path)),
        ]) {
          final spec = LogStreamSpec(
            serverId: 'srv-1',
            source: source,
            window: 10,
            follow: false,
          );
          expect(router.open(OpenLogStream(streamId: id, spec: spec)), isNull);
        }
        expect(statuses('f'), [
          const LogStreamWaiting(LogStreamWaitReason.channel),
        ]);
        await _until(() => link.processes.length == 2);

        router.closeStream('w1');
        await _until(() => statuses('f').lastOrNull is LogStreamEnded);
        expect(
          statuses('f').last,
          const LogStreamEnded(LogStreamEndReason.oldestReached),
        );
        expect(texts(), ['two', 'one']);

        await router.close();
        expect(
          statuses('w2').last,
          const LogStreamEnded(LogStreamEndReason.failed),
        );
        for (final id in ['w1', 'w2', 'f']) {
          expect(statuses(id).whereType<LogStreamEnded>(), hasLength(1));
        }
        for (final p in link.processes) {
          await p.exit.timeout(const Duration(seconds: 10));
        }
      });
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty, reason: 'install dash or bash to run this');
  });
}

/// A stand-in for the host tool [name] that runs [script], first on the
/// commands' PATH.
Future<void> _tool(LocalProcessLink link, String name, String script) async {
  final file = File('${link.workingDirectory.path}/$name');
  await file.writeAsString('#!/bin/sh\n$script\n');
  final chmod = await Process.run('chmod', ['+x', file.path]);
  expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
}
