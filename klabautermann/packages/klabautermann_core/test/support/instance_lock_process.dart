// Another app instance for instance_lock_test.dart. POSIX record locks
// belong to the process, so only a second process can see the lock held.
//
//   try <directory>   prints what acquire found, releases, exits
//   hold <directory>  prints what acquire found; when acquired, holds the
//                     lock until a line arrives on stdin or it is killed
import 'dart:io';

// The library alone, not the barrel: each spawn compiles far less.
import 'package:klabautermann_core/src/settings/instance_lock.dart';

Future<void> main(List<String> arguments) async {
  final [mode, directory] = arguments;
  final attempt = await InstanceLock.acquire(Directory(directory));
  stdout.writeln(switch (attempt) {
    InstanceLockAcquired() => 'acquired',
    InstanceLockHeld() => 'held',
    InstanceLockUnavailable(:final error) => 'unavailable $error',
  });
  await stdout.flush();

  if (attempt case InstanceLockAcquired(:final lock)) {
    if (mode == 'hold') await stdin.first;
    await lock.release();
  }
}
