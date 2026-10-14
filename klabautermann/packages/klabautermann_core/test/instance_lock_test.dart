import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/settings/instance_lock.dart'
    show lockHeldElsewhere;
import 'package:test/test.dart';

/// The helper's path from the workspace root or from the package,
/// whichever directory the suite runs in.
String _helperPath() {
  const packageRelative = 'test/support/instance_lock_process.dart';
  return [
    'packages/klabautermann_core/$packageRelative',
    packageRelative,
  ].firstWhere((path) => File(path).existsSync());
}

/// Another instance: a separate process running the helper in [mode].
/// Returns it with its first line, what its acquire found.
Future<(Process, String)> _instance(String mode, Directory directory) async {
  final packageConfig = Isolate.packageConfigSync;
  final process = await Process.start(Platform.resolvedExecutable, [
    if (packageConfig != null) '--packages=${packageConfig.toFilePath()}',
    _helperPath(),
    mode,
    directory.path,
  ]);
  unawaited(process.stderr.drain<void>());
  final firstLine = await process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .first;
  return (process, firstLine);
}

/// What a second process's acquire finds; it releases and exits after.
Future<String> _secondInstance(Directory directory) async {
  final (process, found) = await _instance('try', directory);
  expect(await process.exitCode, 0, reason: found);
  return found;
}

Future<InstanceLock> _acquired(Directory directory) async {
  final attempt = await InstanceLock.acquire(directory);
  expect(attempt, isA<InstanceLockAcquired>());
  return (attempt as InstanceLockAcquired).lock;
}

void main() {
  late Directory directory;

  setUp(() {
    directory = Directory.systemTemp.createTempSync('klab-instance-lock-');
  });

  tearDown(() => directory.deleteSync(recursive: true));

  test(
    'the first instance takes the lock in a new support directory',
    () async {
      final support = Directory('${directory.path}/support');
      final lock = await _acquired(support);
      addTearDown(lock.release);

      final file = File('${support.path}/$instanceLockFileName');
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), 0);
    },
  );

  test('a second instance is refused while the lock is held, and gets it '
      'once released', () async {
    final lock = await _acquired(directory);
    expect(await _secondInstance(directory), 'held');

    await lock.release();
    expect(await _secondInstance(directory), 'acquired');
    // The file stays for the next launch; only the lock went.
    expect(
      File('${directory.path}/$instanceLockFileName').existsSync(),
      isTrue,
    );
  });

  test('an instance that dies holding the lock leaves none behind', () async {
    final (holder, found) = await _instance('hold', directory);
    addTearDown(holder.kill);
    expect(found, 'acquired');
    expect(await InstanceLock.acquire(directory), isA<InstanceLockHeld>());

    holder.kill(ProcessSignal.sigkill);
    await holder.exitCode;
    final lock = await _acquired(directory);
    await lock.release();
  });

  test('a second acquire in the same isolate is refused and leaves the '
      'first lock in place', () async {
    final lock = await _acquired(directory);
    addTearDown(lock.release);

    // The same file under another spelling too, and no second descriptor
    // opens: under POSIX it would lock without conflict, and closing it
    // would drop the first lock.
    final attempts = await Future.wait([
      InstanceLock.acquire(directory),
      InstanceLock.acquire(Directory('${directory.path}/.')),
    ]);
    expect(attempts, everyElement(isA<InstanceLockHeld>()));
    expect(await _secondInstance(directory), 'held');
  });

  test('overlapping first acquires take the lock once', () async {
    final attempts = await Future.wait([
      InstanceLock.acquire(directory),
      InstanceLock.acquire(directory),
    ]);
    expect(attempts.whereType<InstanceLockAcquired>(), hasLength(1));
    expect(attempts.whereType<InstanceLockHeld>(), hasLength(1));
    await attempts.whereType<InstanceLockAcquired>().single.lock.release();
  });

  test('releasing twice is harmless and a released lock can be taken '
      'again', () async {
    final lock = await _acquired(directory);
    await lock.release();
    await lock.release();

    final again = await _acquired(directory);
    await lock.release();
    expect(
      await _secondInstance(directory),
      'held',
      reason: 'a stale release must not drop the newer lock',
    );
    await again.release();
  });

  test('a support directory that cannot hold the file is unavailable, '
      'not held', () async {
    final notADirectory = File('${directory.path}/file')..writeAsStringSync('');
    final attempt = await InstanceLock.acquire(Directory(notADirectory.path));
    expect(attempt, isA<InstanceLockUnavailable>());
    expect(
      (attempt as InstanceLockUnavailable).error,
      isA<FileSystemException>(),
    );
  });

  group('a failed lock means another holder', () {
    test('for the codes each platform reports a held lock with', () {
      for (final (os, code) in [
        ('linux', 11),
        ('linux', 13),
        ('android', 11),
        ('macos', 35),
        ('macos', 13),
        ('ios', 35),
        ('windows', 33),
      ]) {
        expect(
          lockHeldElsewhere(OSError('', code), os),
          isTrue,
          reason: '$os $code',
        );
      }
    });

    test('and for no other code', () {
      for (final (os, code) in [
        ('linux', 37), // ENOLCK
        ('linux', 35), // EDEADLK on Linux, EAGAIN on Darwin
        ('macos', 11), // EDEADLK on Darwin, EAGAIN on Linux
        ('windows', 13), // ERROR_INVALID_DATA
        ('windows', 5), // ERROR_ACCESS_DENIED
      ]) {
        expect(
          lockHeldElsewhere(OSError('', code), os),
          isFalse,
          reason: '$os $code',
        );
      }
      expect(lockHeldElsewhere(null, 'linux'), isFalse);
    });
  });
}
