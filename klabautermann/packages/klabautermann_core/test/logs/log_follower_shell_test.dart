// Followers through real login shells (03 §7.6, §8.8; LOG-02, LOG-22):
// dash and bash run each command line as sshd hands an exec request to
// the account's shell, with the host's own `tail -F` and a journalctl
// stand-in on the commands' PATH that follows a file of JSON entries.
// Tagged `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/log_stream_router.dart';
import 'package:seance_core/seance_core.dart' show SshLink;
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

/// The processes whose command line names [dir]: what a follow left
/// running.
Future<List<int>> _strays(Directory dir) async {
  final ps = await Process.run('ps', ['-eo', 'pid=,args=']);
  return [
    for (final line in (ps.stdout as String).split('\n'))
      if (line.contains(dir.path)) int.parse(line.trim().split(' ').first),
  ];
}

String _entry(int n) =>
    '${jsonEncode({'__CURSOR': 's=$n', 'MESSAGE': 'entry $n'})}\n';

void main() {
  for (final MapEntry(key: name, value: path) in _shells.entries) {
    group(name, () {
      late Directory dir;
      late List<LocalProcessLink> links;
      late SshLink? current;
      late List<EngineEvent> events;
      late LogStreamRouter router;

      setUp(() async {
        dir = await Directory.systemTemp.createTemp('klab-follow-');
        links = [await LocalProcessLink.create(path)];
        current = links.single;
        events = [];
        router = LogStreamRouter(linkFor: (_) => current, emit: events.add)
          ..retain({'srv-1'});
      });
      tearDown(() async {
        await router.close();
        for (final link in links) {
          await link.dispose();
        }
        // A safety net: the tests check that nothing is left.
        for (final pid in await _strays(dir)) {
          Process.killPid(pid, ProcessSignal.sigkill);
        }
        await dir.delete(recursive: true);
      });

      List<LogStreamStatus> statuses(String id) => [
        for (final e in events)
          if (e case LogStreamState(:final streamId, :final status)
              when streamId == id)
            status,
      ];

      List<String> texts() => [
        for (final batch in events.whereType<LogBatch>())
          for (final r in batch.records)
            switch (r) {
              FileRecord(:final text) => text,
              JournalRecord(:final message) => message ?? '',
              KernelRecord(:final message) => message,
              ContainerRecord(:final text) => text,
            },
      ];

      void follow(String id, LogSource source, {int window = 2}) => expect(
        router.open(
          OpenLogStream(
            streamId: id,
            spec: LogStreamSpec(
              serverId: 'srv-1',
              source: source,
              window: window,
              follow: true,
            ),
          ),
        ),
        isNull,
      );

      test('tail -F follows a file whose path needs quoting across '
          'rotation; a close ends it, and nothing is left running', () async {
        final file = File('${dir.path}/it\'s a "log" \$(touch pwned).txt');
        await file.writeAsString('one\ntwo\nthree\n');

        follow('f', FileLogSource(file.path));
        expect(statuses('f'), [const LogStreamRunning()]);
        await _until(() => texts().length == 2);
        expect(texts(), ['two', 'three']);

        await file.writeAsString('four\n', mode: FileMode.append);
        await _until(() => texts().contains('four'));

        // Rotation: tail -F follows the name to the new file.
        await file.rename('${file.path}.1');
        await File(file.path).writeAsString('five\n');
        await _until(() => texts().contains('five'));

        router.closeStream('f');
        expect(
          statuses('f').last,
          const LogStreamEnded(LogStreamEndReason.closed),
        );
        await links.single.processes.single.exit.timeout(
          const Duration(seconds: 10),
        );
        final sw = Stopwatch()..start();
        while ((await _strays(dir)).isNotEmpty) {
          if (sw.elapsed > const Duration(seconds: 10)) fail('tail is left');
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        for (final d in [dir, links.single.workingDirectory]) {
          expect(File('${d.path}/pwned').existsSync(), isFalse);
        }
      });

      test('a journal follow resumes after its newest cursor on the next '
          'link, without a state or a repeated entry', () async {
        final next = await LocalProcessLink.create(path);
        links.add(next);
        for (final (i, link) in links.indexed) {
          final entries = File('${dir.path}/entries-$i');
          await entries.writeAsString(i == 0 ? _entry(1) + _entry(2) : '');
          await _tool(
            link,
            'journalctl',
            'printf "%s\\n" "\$*" >> ${dir.path}/args-$i\n'
                'exec tail -n +1 -F ${entries.path}',
          );
        }

        follow('j', const JournalLogSource(unit: 'a.service'), window: 500);
        await _until(() => texts().length == 2);

        current = next;
        router.update('srv-1');
        await File('${dir.path}/entries-1').writeAsString(_entry(3));
        await _until(() => texts().length == 3);
        expect(texts(), ['entry 1', 'entry 2', 'entry 3']);
        expect(statuses('j'), [const LogStreamRunning()]);
        expect(await File('${dir.path}/args-0').readAsLines(), [
          '-o json --no-pager -u a.service -n 500 -f',
        ]);
        expect(await File('${dir.path}/args-1').readAsLines(), [
          '-o json --no-pager -u a.service --after-cursor=s=2 --no-tail -f',
        ]);
        await links.first.processes.single.exit.timeout(
          const Duration(seconds: 10),
        );

        await router.close();
        expect(statuses('j').whereType<LogStreamEnded>(), [
          const LogStreamEnded(LogStreamEndReason.failed),
        ]);
      });

      test(
        'the background pauses a file follow, and the foreground starts '
        'it again with new lines only and says lines may be missing',
        () async {
          final file = File('${dir.path}/app.log');
          await file.writeAsString('one\n');
          follow('f', FileLogSource(file.path));
          await _until(() => texts().isNotEmpty);

          router.activity = AppActivity.background;
          expect(
            statuses('f').last,
            const LogStreamWaiting(LogStreamWaitReason.background),
          );
          await links.single.processes.single.exit.timeout(
            const Duration(seconds: 10),
          );
          await file.writeAsString('while paused\n', mode: FileMode.append);

          router.activity = AppActivity.foreground;
          expect(
            statuses('f').last,
            const LogStreamRunning(continuity: LogContinuity.gap),
          );
          // tail -n 0 starts at the end it finds, so keep writing until it
          // has opened the file.
          var n = 0;
          while (!texts().any((t) => t.startsWith('after'))) {
            await file.writeAsString('after ${n++}\n', mode: FileMode.append);
            await Future<void>.delayed(const Duration(milliseconds: 50));
            if (n > 200) fail('no line after the restart');
          }
          expect(texts().first, 'one');
          expect(texts(), isNot(contains('while paused')));
          expect(links.single.processes, hasLength(2));
        },
      );
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
