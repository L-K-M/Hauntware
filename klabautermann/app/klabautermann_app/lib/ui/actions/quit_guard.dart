import 'dart:async' show Completer;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../../controllers/operations_controller.dart';
import '../../controllers/app_lock_controller.dart';
import '../../l10n/app_localizations.dart';

/// Window close, application Quit and the Settings engine share one
/// decision, including when closing the last window triggers Quit too.
final class AppQuitGuard {
  AppQuitGuard({
    required this._operations,
    required this._contextOf,
    this._lock,
  }) {
    _exitRequests = AppLifecycleListener(onExitRequested: _requestExit);
  }

  final OperationsController _operations;
  final BuildContext? Function() _contextOf;
  final AppLockSettings? _lock;
  late final AppLifecycleListener _exitRequests;
  Future<bool>? _pending;
  bool _accepted = false;

  Future<bool> confirm() {
    // The lock gate blocks navigator dialogs. Quitting stays possible
    // without authenticating or revealing the work behind the lock.
    if (_lock?.locked == true) return Future.value(true);
    if (_accepted) return Future.value(true);
    return _pending ??= _ask().whenComplete(() => _pending = null);
  }

  Future<bool> _ask() async {
    final locked = Completer<bool>();
    void onLock() {
      if (_lock?.locked == true && !locked.isCompleted) locked.complete(true);
    }

    _lock?.addListener(onLock);
    try {
      // Locking can cover an already-open question too. Resolve the quit
      // request instead of leaving it waiting for inaccessible buttons.
      _accepted = await Future.any([
        confirmQuitWhileRunning(_operations, _contextOf),
        locked.future,
      ]);
      return _accepted;
    } finally {
      _lock?.removeListener(onLock);
    }
  }

  Future<AppExitResponse> _requestExit() async =>
      await confirm() ? AppExitResponse.exit : AppExitResponse.cancel;

  void dispose() => _exitRequests.dispose();
}

/// The main window's close gate (the intercepting [GhostClosePolicy]):
/// asks before quitting while detached operations still run. They keep
/// running on their servers either way — a quit only defers their
/// results to the next connect — so with none running this returns true
/// and the window closes without asking.
///
/// [contextOf] finds the app's navigator; a close it cannot reach, which
/// happens only before the first frame, closes without asking because
/// nothing can run that early.
Future<bool> confirmQuitWhileRunning(
  OperationsController operations,
  BuildContext? Function() contextOf,
) async {
  final running = operations.runningDetachedCount;
  if (running == 0) return true;
  final context = contextOf();
  if (context == null) return true;
  final l10n = AppLocalizations.of(context);
  final materialL10n = MaterialLocalizations.of(context);
  final quit = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(l10n.quitWhileRunningTitle(running)),
      content: Text(l10n.quitWhileRunningBody),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(materialL10n.cancelButtonLabel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(l10n.quitWhileRunningQuit),
        ),
      ],
    ),
  );
  return quit ?? false;
}
