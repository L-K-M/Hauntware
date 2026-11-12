import 'dart:async' show Completer;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import '../../controllers/operations_controller.dart';
import '../../controllers/app_lock_controller.dart';
import '../../controllers/container_terminals.dart';
import '../../l10n/app_localizations.dart';

/// Window close, application Quit and the Settings engine share one
/// decision, including when closing the last window triggers Quit too.
final class AppQuitGuard {
  AppQuitGuard({
    required this._operations,
    required this._contextOf,
    this._shells,
    this._lock,
  }) {
    _exitRequests = AppLifecycleListener(onExitRequested: _requestExit);
  }

  final OperationsController _operations;
  final BuildContext? Function() _contextOf;

  /// The open shells at quit time, or null where the app has none.
  final List<ContainerShell> Function()? _shells;
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
        confirmQuitWhileRunning(
          _operations,
          _contextOf,
          shells: _shells?.call() ?? const [],
        ),
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
/// asks before quitting would lose edits an open remote editor has not
/// saved, then while detached operations still run, then while container
/// shells are open. Those keep running on their servers either way — a
/// quit only defers their results to the next connect; the shells end.
/// With none of the three, this returns true and the window closes
/// without asking.
///
/// [contextOf] finds the app's navigator; a close it cannot reach, which
/// happens only before the first frame, closes without asking because
/// nothing can be edited or run that early. [shells] are the open shells,
/// of which the question names each container.
Future<bool> confirmQuitWhileRunning(
  OperationsController operations,
  BuildContext? Function() contextOf, {
  List<ContainerShell> shells = const [],
}) async {
  final unsaved = operations.unsavedEdits;
  final running = operations.runningDetachedCount;
  final liveShells = [for (final shell in shells) if (shell.isLive) shell];
  if (unsaved.isEmpty && running == 0 && liveShells.isEmpty) return true;
  final context = contextOf();
  if (context == null) return true;
  final l10n = AppLocalizations.of(context);
  final materialL10n = MaterialLocalizations.of(context);
  if (unsaved.isNotEmpty) {
    final discard = await _confirmQuit(
      context,
      title: l10n.quitWithUnsavedEditsTitle(unsaved.length),
      body: l10n.quitWithUnsavedEditsBody(
        unsaved.join(l10n.quitWithUnsavedEditsSeparator),
      ),
      quit: l10n.quitWithUnsavedEditsQuit,
      cancel: materialL10n.cancelButtonLabel,
    );
    if (!discard ||
        (running == 0 && liveShells.isEmpty) ||
        !context.mounted) {
      return discard;
    }
  }

  if (running > 0) {
    final quit = await _confirmQuit(
      context,
      title: l10n.quitWhileRunningTitle(running),
      body: l10n.quitWhileRunningBody,
      quit: l10n.quitWhileRunningQuit,
      cancel: materialL10n.cancelButtonLabel,
    );
    if (!quit || liveShells.isEmpty || !context.mounted) return quit;
  }

  return _confirmQuit(
    context,
    title: l10n.quitWithShellsTitle(liveShells.length),
    body: l10n.quitWithShellsBody(
      liveShells.length,
      liveShells
          .map((shell) => shell.containerName)
          .join(l10n.quitWithShellsSeparator),
    ),
    quit: l10n.quitWithShellsQuit,
    cancel: materialL10n.cancelButtonLabel,
  );
}

Future<bool> _confirmQuit(
  BuildContext context, {
  required String title,
  required String body,
  required String quit,
  required String cancel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: Text(cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(quit),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
