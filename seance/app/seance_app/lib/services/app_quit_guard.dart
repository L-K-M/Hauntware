import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';

/// The small surface the quit guard needs from the separate Settings window.
///
/// Hiding for a confirmation is deliberately different from closing: it must
/// not tell the Settings engine to discard the mounted page and its drafts.
abstract interface class QuitSettingsWindow {
  Future<bool> yieldForQuitConfirmation();

  Future<void> restoreAfterQuitConfirmation();
}

enum QuitSessionStatus { connecting, connected }

@immutable
class QuitDirtyEditor {
  const QuitDirtyEditor({required this.server, required this.path});

  final String server;
  final String path;
}

@immutable
class QuitActiveSession {
  const QuitActiveSession({
    required this.label,
    required this.target,
    required this.status,
  });

  final String label;
  final String target;
  final QuitSessionStatus status;
}

/// A stable copy of everything an application exit would interrupt.
@immutable
class QuitRiskSnapshot {
  QuitRiskSnapshot({
    Iterable<QuitDirtyEditor> dirtyEditors = const [],
    Iterable<QuitActiveSession> activeSessions = const [],
  }) : dirtyEditors = List.unmodifiable(dirtyEditors),
       activeSessions = List.unmodifiable(activeSessions);

  factory QuitRiskSnapshot.fromTabs(Iterable<PaneTab> tabs) {
    final dirtyEditors = <QuitDirtyEditor>[];
    final activeSessions = <QuitActiveSession>[];
    for (final tab in tabs) {
      switch (tab) {
        case EditorTab() when tab.dirty.value:
          dirtyEditors.add(
            QuitDirtyEditor(
              server: _safeLine(tab.server.label),
              path: _safeLine(tab.remotePath),
            ),
          );
        case TerminalSession() when tab.connecting || tab.isConnected:
          activeSessions.add(
            QuitActiveSession(
              label: _safeLine(tab.displayLabel),
              target: _safeLine(tab.displayTarget),
              status: tab.connecting
                  ? QuitSessionStatus.connecting
                  : QuitSessionStatus.connected,
            ),
          );
        default:
          break;
      }
    }
    return QuitRiskSnapshot(
      dirtyEditors: dirtyEditors,
      activeSessions: activeSessions,
    );
  }

  final List<QuitDirtyEditor> dirtyEditors;
  final List<QuitActiveSession> activeSessions;

  bool get isEmpty => dirtyEditors.isEmpty && activeSessions.isEmpty;
}

typedef QuitDialogPresenter =
    Future<bool?> Function(BuildContext context, QuitRiskSnapshot snapshot);

/// Serializes every desktop exit route behind one review of at-risk work.
final class AppQuitGuard {
  factory AppQuitGuard({
    required GlobalKey<NavigatorState> navigatorKey,
    QuitSettingsWindow? Function()? settingsWindow,
    @visibleForTesting QuitDialogPresenter? presentDialog,
    @visibleForTesting QuitRiskSnapshot Function()? snapshotOverride,
    @visibleForTesting void Function(Object, StackTrace)? onError,
  }) => AppQuitGuard._(
    navigatorKey: navigatorKey,
    settingsWindow: settingsWindow,
    presentDialog: presentDialog ?? _showConfirmation,
    snapshotOverride: snapshotOverride,
    onError: onError,
  );

  AppQuitGuard._({
    required this.navigatorKey,
    this.settingsWindow,
    required this._presentDialog,
    this._snapshotOverride,
    this._onError,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final QuitSettingsWindow? Function()? settingsWindow;
  final QuitDialogPresenter _presentDialog;
  final QuitRiskSnapshot Function()? _snapshotOverride;
  final void Function(Object, StackTrace)? _onError;

  AppState? _state;
  Future<bool>? _inFlight;
  bool _accepted = false;
  QuitSettingsWindow? _yieldedAfterAcceptance;

  void bind(AppState state) {
    if (identical(_state, state)) return;
    _state = state;
    _accepted = false;
    _yieldedAfterAcceptance = null;
  }

  void unbind(AppState state) {
    if (!identical(_state, state)) return;
    _state = null;
    _accepted = false;
    _yieldedAfterAcceptance = null;
  }

  /// Makes a failed native close retryable and gives a yielded Settings
  /// window back to the user. A successful close needs neither operation:
  /// its process and owned window are going away.
  Future<void> handleCloseFailure() async {
    _accepted = false;
    final settings = _yieldedAfterAcceptance;
    _yieldedAfterAcceptance = null;
    if (settings == null) return;
    try {
      await settings.restoreAfterQuitConfirmation();
    } catch (error, stackTrace) {
      _report(error, stackTrace);
    }
  }

  Future<bool> confirmClose() {
    if (_accepted) return Future.value(true);
    final existing = _inFlight;
    if (existing != null) return existing;

    late final Future<bool> decision;
    decision = _confirmClose().whenComplete(() {
      if (identical(_inFlight, decision)) _inFlight = null;
    });
    _inFlight = decision;
    return decision;
  }

  Future<bool> _confirmClose() async {
    final snapshot =
        _snapshotOverride?.call() ??
        QuitRiskSnapshot.fromTabs(_state?.tabs ?? const <PaneTab>[]);
    if (snapshot.isEmpty) {
      _accepted = true;
      return true;
    }

    final navigator = navigatorKey.currentState;
    if (navigator == null || !navigator.mounted) return false;
    final context = navigator.context;

    final settings = settingsWindow?.call();
    var yieldedSettings = false;
    Future<void> restoreSettings() async {
      if (!yieldedSettings || settings == null) return;
      yieldedSettings = false;
      try {
        await settings.restoreAfterQuitConfirmation();
      } catch (error, stackTrace) {
        _report(error, stackTrace);
      }
    }

    if (settings != null) {
      try {
        yieldedSettings = await settings.yieldForQuitConfirmation();
      } catch (error, stackTrace) {
        _report(error, stackTrace);
        return false;
      }
    }
    if (!context.mounted) {
      await restoreSettings();
      return false;
    }

    var accepted = false;
    try {
      accepted = await _presentDialog(context, snapshot) == true;
      if (accepted) {
        _accepted = true;
        if (yieldedSettings) {
          _yieldedAfterAcceptance = settings;
          yieldedSettings = false;
        }
      }
      return accepted;
    } catch (error, stackTrace) {
      _report(error, stackTrace);
      return false;
    } finally {
      if (!accepted) await restoreSettings();
    }
  }

  void _report(Object error, StackTrace stackTrace) {
    final callback = _onError;
    if (callback != null) {
      callback(error, stackTrace);
      return;
    }
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'seance quit guard',
      ),
    );
  }

  static Future<bool?> _showConfirmation(
    BuildContext context,
    QuitRiskSnapshot snapshot,
  ) => showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (context) => _QuitConfirmationDialog(snapshot: snapshot),
  );
}

class _QuitConfirmationDialog extends StatelessWidget {
  const _QuitConfirmationDialog({required this.snapshot});

  final QuitRiskSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Quit Séance?'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 440),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Unsaved changes and active sessions will be lost.'),
              if (snapshot.dirtyEditors.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Unsaved files',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                for (final editor in snapshot.dirtyEditors)
                  _QuitRiskRow(
                    icon: Icons.edit_outlined,
                    title: editor.path,
                    subtitle: editor.server,
                  ),
              ],
              if (snapshot.activeSessions.isNotEmpty) ...[
                const SizedBox(height: 20),
                Text(
                  'Active sessions',
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                for (final session in snapshot.activeSessions)
                  _QuitRiskRow(
                    icon: Icons.terminal,
                    title: session.label,
                    subtitle:
                        '${session.target} · '
                        '${session.status == QuitSessionStatus.connecting ? 'Connecting' : 'Connected'}',
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('quit-cancel'),
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('quit-confirm'),
          style: FilledButton.styleFrom(
            backgroundColor: colors.error,
            foregroundColor: colors.onError,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Quit'),
        ),
      ],
    );
  }
}

class _QuitRiskRow extends StatelessWidget {
  const _QuitRiskRow({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title),
              Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ],
    ),
  );
}

String _safeLine(String value) {
  final result = StringBuffer();
  var previousWasSpace = false;
  for (final rune in value.runes) {
    final unsafe =
        rune < 0x20 ||
        (rune >= 0x7f && rune <= 0x9f) ||
        rune == 0x200b ||
        rune == 0x200c ||
        rune == 0x200d ||
        rune == 0x2060 ||
        (rune >= 0x202a && rune <= 0x202e) ||
        (rune >= 0x2066 && rune <= 0x2069);
    final isSpace = unsafe || rune == 0x20;
    if (isSpace) {
      if (!previousWasSpace) result.write(' ');
      previousWasSpace = true;
    } else {
      result.writeCharCode(rune);
      previousWasSpace = false;
    }
  }
  return result.toString().trim();
}
