import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:poltergeist_core/poltergeist_core.dart';

const String _markerName = '.poltergeist-archive-owner';
const String _markerContents = 'poltergeist-archive-stage-v1\n';
const String _leaseName = '.poltergeist-archive-lease';

Future<void> main(List<String> arguments) async {
  switch (arguments.firstOrNull) {
    case 'hold-lease':
      await _holdLease(
        arguments[1],
        arguments.length > 2 ? arguments[2] : _markerContents,
      );
    case 'commit':
      await _commit(arguments[1], arguments[2]);
    case 'hold-file-lock':
      await _holdFileLock(arguments[1]);
    default:
      stderr.writeln('unknown helper mode');
      exitCode = 2;
  }
}

Future<void> _holdFileLock(String path) async {
  final file = await File(path).open(mode: FileMode.append);
  await file.lock(FileLock.blockingExclusive);
  stdout.writeln('ready');
  await stdout.flush();
  await stdin.first;
  await file.unlock();
  await file.close();
}

Future<void> _holdLease(String stagePath, String markerContents) async {
  final stage = Directory(stagePath)..createSync();
  File(p.join(stage.path, _markerName)).writeAsStringSync(markerContents);
  final lease = await File(
    p.join(stage.path, _leaseName),
  ).open(mode: FileMode.append);
  await lease.lock(FileLock.exclusive);
  stdout.writeln('ready');
  await stdin.first;
  await lease.unlock();
  await lease.close();
}

Future<void> _commit(String sourcePath, String destinationPath) async {
  final service = LocalArchiveService();
  final job = service.createZip(
    sourcePaths: [sourcePath],
    destinationPath: destinationPath,
  );
  final ready = Completer<void>();
  final release = Completer<void>();
  final input = stdin.listen((_) {
    if (!release.isCompleted) release.complete();
  });
  final progress = job.progress.listen((event) async {
    if (event.phase != LocalArchivePhase.preparing || ready.isCompleted) return;
    job.pause();
    ready.complete();
    stdout.writeln('ready');
    await release.future;
    job.resume();
  });

  await ready.future;
  final result = await job.done;
  stdout.writeln('result:${p.basename(result.destinationPath)}');
  await progress.cancel();
  await input.cancel();
  await service.close();
}
