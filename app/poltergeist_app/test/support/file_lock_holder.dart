import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _readyTimeout = Duration(seconds: 10);
const _exitTimeout = Duration(seconds: 10);
const _pollInterval = Duration(milliseconds: 10);

/// Holds one advisory file lock in another Dart process until [stop].
Future<TestFileLockHolder> startTestFileLockHolder(
  Directory directory,
  String lockPath, {
  String markerContents = '',
}) async {
  final script = File(p.join(directory.path, 'hold_lock.dart'));
  final ready = File(p.join(directory.path, 'ready'));
  final stop = File(p.join(directory.path, 'stop'));
  await script.writeAsString('''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final lockPath = arguments[0];
  final readyPath = arguments[1];
  final stopPath = arguments[2];
  final markerContents = arguments[3];
  final file = await File(lockPath).open(mode: FileMode.append);
  await file.lock(FileLock.exclusive);
  if (markerContents.isNotEmpty) {
    await file.truncate(0);
    await file.setPosition(0);
    await file.writeString(markerContents);
    await file.flush();
  }
  await File(readyPath).writeAsString('ready');
  while (!await File(stopPath).exists()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await file.unlock();
  await file.close();
}
''');
  final process = await Process.start(_dartExecutable(), [
    script.path,
    lockPath,
    ready.path,
    stop.path,
    markerContents,
  ]);
  final stderr = process.stderr.transform(utf8.decoder).join();
  final holder = TestFileLockHolder._(process, stop, stderr);

  final deadline = DateTime.now().add(_readyTimeout);
  while (!await ready.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      await holder.stop();
      throw StateError('Lock-holder process did not start: ${await stderr}');
    }
    await Future<void>.delayed(_pollInterval);
  }

  return holder;
}

String _dartExecutable() {
  final current = Platform.resolvedExecutable;
  if (p.basename(current) == 'dart') return current;

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    return p.join(flutterRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'dart');
  }

  const cacheSegment = '/bin/cache/';
  final cacheIndex = current.indexOf(cacheSegment);
  if (cacheIndex >= 0) {
    return p.join(
      current.substring(0, cacheIndex),
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      'dart',
    );
  }
  return 'dart';
}

final class TestFileLockHolder {
  TestFileLockHolder._(this._process, this._stopFile, this._stderr);

  final Process _process;
  final File _stopFile;
  final Future<String> _stderr;
  Future<void>? _stopping;

  Future<void> stop() => _stopping ??= _stop();

  Future<void> _stop() async {
    await _stopFile.writeAsString('stop');
    final exitCode = await _process.exitCode.timeout(_exitTimeout);
    final error = await _stderr;
    if (exitCode == 0) return;

    throw StateError('Lock-holder process exited $exitCode: $error');
  }
}
