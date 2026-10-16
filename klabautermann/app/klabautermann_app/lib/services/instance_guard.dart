import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart'
    show
        InstanceLock,
        InstanceLockAcquired,
        InstanceLockAttempt,
        InstanceLockHeld,
        InstanceLockUnavailable,
        SupportDirectoryAccess;

/// Takes the instance lock in [supportDirectory] (03 §4.10) on the
/// desktops, or returns null on a phone without touching the directory.
///
/// Each desktop launch can start another process (the Linux runner is
/// non-unique, macOS starts one for `open -n` or a direct start, and the
/// Windows runner has no mutex), and two processes over one support
/// directory overwrite each other's files: the last `settings.json` write
/// wins, device id included. A phone's system runs one process per app.
Future<InstanceLockAttempt?> lockInstanceFor(
  TargetPlatform platform,
  Directory supportDirectory,
) async => switch (platform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => await InstanceLock.acquire(supportDirectory),
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => null,
};

/// What [lockInstanceFor]'s [attempt] leaves this process (03 §4.10): the
/// directory alone with the lock or on a phone (null), so the engine may
/// write its capability cache there (D59); shared otherwise.
SupportDirectoryAccess supportDirectoryAccessFor(
  InstanceLockAttempt? attempt,
) => switch (attempt) {
  null || InstanceLockAcquired() => SupportDirectoryAccess.exclusive,
  InstanceLockHeld() ||
  InstanceLockUnavailable() => SupportDirectoryAccess.unguarded,
};
