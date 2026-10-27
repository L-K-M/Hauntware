import 'dart:developer' as developer;
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import '../services/mac_commands.dart';
import '../services/undo_history.dart';
import '../theme.dart';
import 'server_editor.dart';
import 'top_toast.dart';

// The server verbs shared by the server list's menus and the macOS menu
// bar, so a row's "Delete…" and Server ▸ Delete Server… ask the same
// question and do the same thing.

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
  // removes.
  var latest = copy;
  state.undoHistory.record(
    UndoableChange(
      name: 'Duplicate Server',
      undo: () => state.deleteServer(latest.id),
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
    // lookup on a deactivated widget.
    onAction: () {
      if (context.mounted) showServerEditor(context, state, copy);
    },
  );
}

/// Pins [server] to the top of the list, or unpins it, as an undoable
/// change (Edit ▸ Undo Pin to Top).
Future<void> toggleServerPinUndoably(
  AppState state,
  ServerConfig server,
) async {
  final pinning = !state.isServerPinned(server.id);
  await state.toggleServerPin(server.id);
  state.undoHistory.record(
    UndoableChange(
      name: pinning ? 'Pin to Top' : 'Unpin',
      undo: () => state.toggleServerPin(server.id),
      redo: () => state.toggleServerPin(server.id),
    ),
  );
}

/// Ask before deleting [server], naming what goes with it, then delete it.
/// On macOS the question is a sheet on the window, Delete marked as
/// destructive and Cancel the default, as Finder asks before an immediate
/// delete.
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
  final bool confirmed;
  if (Theme.of(context).platform == TargetPlatform.macOS) {
    const delete = 1;
    // Cancel first: the default button, so Return keeps the server.
    final answer = await showMacAlert(
      message: title,
      informative: '$detail You can’t undo this action.',
      buttons: const ['Cancel', 'Delete'],
      destructive: delete,
    );
    confirmed = answer?.button == delete;
  } else {
    confirmed =
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
  }
  if (confirmed) await state.deleteServer(server.id);
}

/// Import hosts from an OpenSSH config. On macOS an open panel starts in
/// `~/.ssh` and reads the file picked; elsewhere the user pastes the
/// file's text, which also works where no file system is reachable.
Future<void> importSshConfigInteractively(
  BuildContext context,
  AppState state,
) async {
  final text = Theme.of(context).platform == TargetPlatform.macOS
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

Future<String?> _pickSshConfigText(BuildContext context) async {
  final home = Platform.environment['HOME'];
  final sshDirectory = home == null ? null : '$home/.ssh';
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
    final file = File(path);
    if (await file.length() > _maximumSshConfigBytes) {
      if (context.mounted) {
        showTopToastIn(
          context,
          message: 'That file is too large to be an SSH config.',
        );
      }
      return null;
    }
    return await file.readAsString();
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
  final controller = TextEditingController();
  try {
    return await showDialog<String>(
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
  } finally {
    // After the route's dismissal animation, which still builds the field.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
  }
}
