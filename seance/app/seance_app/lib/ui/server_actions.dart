import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostUndoDeclined, GhostUndoableChange;
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../theme.dart';
import 'server_editor.dart';
import 'top_toast.dart';

// The server list's verbs: the row menu's, and the "+" menu's import.

/// Whether the import can pick the file itself on [platform]: the
/// desktop, where the user's `~/.ssh` is a folder an open panel can show.
bool _picksFile(TargetPlatform platform) => switch (platform) {
  TargetPlatform.linux ||
  TargetPlatform.macOS ||
  TargetPlatform.windows => true,
  _ => false,
};

/// The largest SSH config file the import reads: far beyond any real one,
/// small enough that a wrong pick cannot exhaust memory.
const int _maximumSshConfigBytes = 1024 * 1024;

/// Copy a server, then offer the editor — duplicating is almost always the
/// first half of "…and change one thing", and the toast's action is a
/// shorter route back than finding the new row and reopening its menu.
Future<void> duplicateServerInteractively(
  BuildContext context,
  AppState state,
  ServerConfig server,
) async {
  final ServerConfig copy;
  try {
    copy = await state.duplicateServer(server);
  } on SourceServerChanged catch (error) {
    // Verbatim: this one is written as a whole sentence *for* this toast,
    // and "Could not duplicate: …Nothing was created." says it twice.
    if (context.mounted) {
      showTopToastIn(context, message: '$error');
    } else {
      // Nowhere to show it. Logged so the refusal is not the failure that
      // vanished — the same reason the branch below logs.
      developer.log(
        'Could not duplicate "${server.label}": $error',
        name: 'seance.app',
        level: 900,
        error: error,
      );
    }
    return;
  } catch (error, stackTrace) {
    // The vault throws when the OS keyring is locked. Say so rather than
    // leaving the menu looking like it did nothing — and name the server,
    // because a toast is all the user gets and two rows can fail apart.
    // The error itself stays verbatim: `VaultLockedException.toString()` is
    // the sentence that says what to do about it.
    final message = 'Could not duplicate "${server.label}": $error';
    // Logged whether or not there is a toast to show: the toast and the
    // log are for different readers. With the trace, because this catch is
    // broad, and for the failures it was not written for the message names
    // the server and nothing else — no throw site to tell a locked keyring
    // from a bug in the vault.
    developer.log(
      message,
      name: 'seance.app',
      level: 900,
      error: error,
      stackTrace: stackTrace,
    );
    if (context.mounted) showTopToastIn(context, message: message);
    return;
  }
  // Undo removes the copy; Redo makes another, whose id the next Undo
  // removes. A copy in use has tabs, perhaps with unsaved text or local
  // edits, that only their own close guards may end: Undo waits for them.
  var latest = copy;
  state.undoHistory.record(
    GhostUndoableChange(
      name: 'Duplicate server',
      undo: () async {
        if (state.tabsForServer(latest.id).isNotEmpty) {
          throw GhostUndoDeclined(
            '“${latest.label}” has open tabs. Close them, then undo.',
          );
        }
        await state.deleteServer(latest.id);
      },
      redo: () async => latest = await state.duplicateServer(server),
    ),
  );
  if (!context.mounted) return;
  showTopToastIn(
    context,
    message: 'Duplicated as "${copy.label}"',
    actionLabel: 'Edit',
    // Checked again inside the closure, not only before showing the toast:
    // the action fires whenever the user taps it, which can be after this
    // pane is gone, and a defunct context reaches showDialog as an ancestor
    // lookup on a deactivated widget. The copy is the latest one, as stored:
    // Undo may have removed it, and Redo made another.
    onAction: () {
      final current = state.configFor(latest.id);
      if (current == null || !context.mounted) return;
      showServerEditor(context, state, current);
    },
  );
}

/// Pins [server] to the top of the list, or unpins it, as an undoable
/// change.
Future<void> toggleServerPinUndoably(
  AppState state,
  ServerConfig server,
) async {
  final pinning = !state.isServerPinned(server.id);
  await state.toggleServerPin(server.id);
  state.undoHistory.record(
    GhostUndoableChange(
      name: pinning ? 'Pin to top' : 'Unpin',
      undo: () => state.toggleServerPin(server.id),
      redo: () => state.toggleServerPin(server.id),
    ),
  );
}

/// Ask before deleting [server], naming what goes with it, then delete it.
Future<void> confirmDeleteServer(
  BuildContext context,
  AppState state,
  ServerConfig server,
) async {
  final localCopyCount = state
      .tabsForServer(server.id)
      .whereType<TerminalSession>()
      .fold<int>(
        0,
        (count, session) =>
            count +
            (session.files?.localCopies.length ?? 0) +
            session.retainedLocalCopies.length,
      );
  final title = 'Delete "${server.label}"?';
  final detail = localCopyCount == 0
      ? 'This removes the server and any stored secret.'
      : 'This removes the server, its stored secret, and '
            '$localCopyCount managed local '
            '${localCopyCount == 1 ? 'edit' : 'edits'}. Any changes not '
            'uploaded to the server will be deleted.';
  final confirmed =
      await showDialog<bool>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(title),
          content: Text(detail),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      ) ??
      false;
  if (confirmed) await state.deleteServer(server.id);
}

/// Import hosts from an OpenSSH config. On the desktop an open panel
/// starts in `~/.ssh` and reads the file picked; on phones and tablets,
/// whose apps cannot reach that folder, the user pastes the file's text.
Future<void> importSshConfigInteractively(
  BuildContext context,
  AppState state,
) async {
  final text = _picksFile(Theme.of(context).platform)
      ? await _pickSshConfigText(context)
      : await _pasteSshConfigText(context);
  if (text == null || text.trim().isEmpty) return;
  final (:imported, :skipped) = await state.importSshConfig(text);
  if (!context.mounted) return;
  showTopToastIn(
    context,
    message: skipped == 0
        ? 'Imported $imported host(s)'
        : 'Imported $imported host(s). Skipped $skipped with an '
              'unsupported Port.',
  );
}

/// The picked file's text, or why it is no SSH config: too large, or not
/// UTF-8 (a key, known_hosts or another binary file). An unreadable file
/// throws [FileSystemException].
@visibleForTesting
Future<({String? text, String? rejection})> readSshConfigFile(File file) async {
  if (await file.length() > _maximumSshConfigBytes) {
    return (
      text: null,
      rejection: 'That file is too large to be an SSH config.',
    );
  }
  try {
    // Decoded here: readAsString reports bad UTF-8 as the same
    // FileSystemException an unreadable file raises.
    return (text: utf8.decode(await file.readAsBytes()), rejection: null);
  } on FormatException {
    return (text: null, rejection: 'That file is not an SSH config.');
  }
}

Future<String?> _pickSshConfigText(BuildContext context) async {
  // Windows keeps the user's folder in USERPROFILE, and OpenSSH for
  // Windows its config under it, as the other platforms do under HOME.
  final home =
      Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
  final sshDirectory = home == null
      ? null
      : '$home${Platform.pathSeparator}.ssh';
  final FilePickerResult? result;
  try {
    result = await FilePicker.pickFiles(
      dialogTitle: 'Import SSH Config',
      initialDirectory:
          sshDirectory != null && Directory(sshDirectory).existsSync()
          ? sshDirectory
          : home,
    );
  } on PlatformException catch (error) {
    if (context.mounted) {
      showTopToastIn(context, message: 'Could not open the file: $error');
    }
    return null;
  }
  final path = result?.files.single.path;
  if (path == null) return null;
  try {
    final read = await readSshConfigFile(File(path));
    if (read.rejection case final rejection? when context.mounted) {
      showTopToastIn(context, message: rejection);
    }
    return read.text;
  } on FileSystemException catch (error) {
    if (context.mounted) {
      showTopToastIn(
        context,
        message: 'Could not read the file: ${error.message}',
      );
    }
    return null;
  }
}

Future<String?> _pasteSshConfigText(BuildContext context) async {
  // Not disposed: the dialog's field still builds through the route's
  // dismissal animation, after showDialog has returned.
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Import SSH config'),
      content: SizedBox(
        width: 480,
        child: TextField(
          controller: controller,
          maxLines: 12,
          style: SeanceTheme.mono,
          decoration: const InputDecoration(
            hintText: 'Paste the contents of ~/.ssh/config …',
            border: OutlineInputBorder(),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('Import'),
        ),
      ],
    ),
  );
}
