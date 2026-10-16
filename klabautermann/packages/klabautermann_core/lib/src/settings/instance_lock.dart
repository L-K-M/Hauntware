import 'dart:io';

import 'package:meta/meta.dart';

/// The lock file under the app's support directory (03 §4.10). It stays
/// empty and is never deleted: deleting it while a lock is held would let
/// a later instance lock a new file at the same path beside the old one.
const String instanceLockFileName = 'instance.lock';

/// Whether this process alone writes the files in the app's support
/// directory (03 §4.10). The engine writes and purges its per-server
/// caches there only when it does (D59).
enum SupportDirectoryAccess {
  /// The desktop instance lock is held, or the platform runs one process
  /// per app (phones).
  exclusive,

  /// The lock could not be taken, so another instance may write the same
  /// files: the engine reads its caches and writes none.
  unguarded,
}

/// What [InstanceLock.acquire] found.
sealed class InstanceLockAttempt {
  const InstanceLockAttempt();
}

/// This instance holds the lock.
final class InstanceLockAcquired extends InstanceLockAttempt {
  const InstanceLockAcquired(this.lock);

  final InstanceLock lock;
}

/// Another instance holds the lock: another process, or an earlier
/// [InstanceLock.acquire] in this isolate that has not been released.
final class InstanceLockHeld extends InstanceLockAttempt {
  const InstanceLockHeld();
}

/// The lock could not be taken for a reason other than another holder,
/// such as a support directory that cannot be written or a file system
/// without locks. Nothing is known about other instances.
final class InstanceLockUnavailable extends InstanceLockAttempt {
  const InstanceLockUnavailable(this.error);

  final FileSystemException error;
}

/// One desktop instance per support directory (03 §4.10): an exclusive,
/// non-blocking advisory lock on [instanceLockFileName], which the
/// composition root takes before `settings.json` opens and the engine
/// isolate starts. The operating system drops the lock when the process
/// ends, however it ends, so a crash leaves no stale lock behind.
///
/// The lock is advisory: it keeps out only processes that ask for it.
/// POSIX record locks (`fcntl`) belong to the process, not the descriptor:
/// a second descriptor in the same process would lock the file again
/// without conflict, and closing either one drops both locks. So within
/// an isolate a second [acquire] of the same file, under any spelling but
/// a symbolic link or another letter case, is refused without opening it,
/// and nothing else in the app may open the file.
final class InstanceLock {
  InstanceLock._(this._path, this._handle);

  final String _path;
  final RandomAccessFile _handle;

  /// The locks this isolate holds, by [_lockFilePath]. A lock stays here
  /// until [release], which also keeps its handle reachable: a handle
  /// closed by anything but [release] would drop the lock while the app
  /// runs.
  static final Map<String, InstanceLock> _held = {};

  /// The attempts in flight, by the same path. An attempt is registered
  /// before its first await, so two overlapping [acquire] calls cannot both
  /// open the file; the later one reports what the first found.
  static final Map<String, Future<InstanceLockAttempt>> _pending = {};

  /// Takes the lock in [supportDirectory], creating the directory and the
  /// file when they are missing. Never throws and never waits for another
  /// holder.
  static Future<InstanceLockAttempt> acquire(Directory supportDirectory) async {
    final path = _lockFilePath(supportDirectory);
    if (_held.containsKey(path)) return const InstanceLockHeld();
    if (_pending[path] case final pending?) {
      // Held by this isolate if that attempt took the lock; whatever kept
      // it from the lock otherwise keeps this one from it too.
      return switch (await pending) {
        InstanceLockAcquired() => const InstanceLockHeld(),
        final attempt => attempt,
      };
    }

    final attempt = _lock(supportDirectory, path);
    _pending[path] = attempt;
    try {
      final result = await attempt;
      if (result case InstanceLockAcquired(:final lock)) _held[path] = lock;
      return result;
    } finally {
      final finished = _pending.remove(path);
      assert(identical(finished, attempt), 'one attempt per path at a time');
    }
  }

  /// Opens and locks the file at [path]; the claims are [acquire]'s.
  static Future<InstanceLockAttempt> _lock(
    Directory supportDirectory,
    String path,
  ) async {
    final RandomAccessFile handle;
    try {
      await supportDirectory.create(recursive: true);
      // Read and write without truncating: POSIX write locks need a
      // descriptor open for writing.
      handle = await File(path).open(mode: FileMode.append);
    } on FileSystemException catch (error) {
      return InstanceLockUnavailable(error);
    }

    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      try {
        await handle.close();
      } on FileSystemException {
        // The lock's own failure is the one to report.
      }
      return lockHeldElsewhere(error.osError, Platform.operatingSystem)
          ? const InstanceLockHeld()
          : InstanceLockUnavailable(error);
    }

    return InstanceLockAcquired(InstanceLock._(path, handle));
  }

  /// The lock file's path in [supportDirectory], one spelling per file:
  /// absolute, without `.`, `..` or the empty segments that a trailing or
  /// doubled separator leaves (`normalizePath` keeps those). Symbolic links
  /// and letter case are not resolved.
  static String _lockFilePath(Directory supportDirectory) {
    final uri = File(
      '${supportDirectory.path}${Platform.pathSeparator}$instanceLockFileName',
    ).absolute.uri;
    return uri
        .replace(pathSegments: uri.pathSegments.where((s) => s.isNotEmpty))
        .normalizePath()
        .toFilePath();
  }

  /// Unlocks and closes the file, letting the next instance in. The app
  /// never calls it: the lock lasts as long as the process. Calling it
  /// again does nothing.
  Future<void> release() async {
    if (!identical(_held[_path], this)) return;
    _held.remove(_path);
    try {
      await _handle.unlock();
    } finally {
      await _handle.close();
    }
  }
}

// Error codes of a non-blocking exclusive lock that another process holds.
// `fcntl(F_SETLK)` reports EACCES or EAGAIN (POSIX allows either), and
// `LockFileEx` with LOCKFILE_FAIL_IMMEDIATELY reports ERROR_LOCK_VIOLATION.
const int _eacces = 13;
const int _eagainLinux = 11;
const int _eagainDarwin = 35;
const int _errorLockViolation = 33;

/// Whether a failed lock with [error] means another holder on
/// [operatingSystem] (a `Platform.operatingSystem` value). Any other code
/// reads as [InstanceLockUnavailable], so an unknown code lets the app run
/// unguarded rather than lock the user out. Internal: the barrel hides it.
@visibleForTesting
bool lockHeldElsewhere(OSError? error, String operatingSystem) {
  final code = error?.errorCode;
  return switch (operatingSystem) {
    'windows' => code == _errorLockViolation,
    'macos' || 'ios' => code == _eacces || code == _eagainDarwin,
    _ => code == _eacces || code == _eagainLinux,
  };
}
