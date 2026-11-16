import 'package:flutter/foundation.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostUndoDeclined, GhostUndoHistory, GhostUndoableChange;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import 'app_transfer_queue.dart';
import 'file_clipboard.dart';
import 'pane_controller.dart';
import 'pane_drop.dart';
import 'pane_location.dart';
import 'workspace_controller.dart';

/// A live channel on one host, borrowed from an open tab: what a
/// same-server Cut, an inline rename's undo and Put Back need beyond
/// the transfer queue.
abstract interface class FileHostChannel {
  /// Renames [from] to [to]; a taken [to] fails with the typed conflict
  /// error, never an overwrite.
  Future<void> rename(String from, String to);

  /// The names in [folder], hidden files included.
  Future<Set<String>> listNames(String folder);
}

/// Finds a [FileHostChannel] on [host], or null when no open tab has a
/// live one.
typedef FileHostLookup = FileHostChannel? Function(FsLocation host);

/// Asks the user to confirm that undoing a copy deletes [paths] on
/// [host]. Resolves true to delete.
typedef FileCopyUndoConfirm =
    Future<bool> Function(FsLocation host, List<String> paths);

/// A file operation that did not finish, worded for the Undo toast.
class FileOperationFailed implements Exception {
  const FileOperationFailed(this.message);

  final String message;

  @override
  String toString() => message;
}

/// How a Paste went.
enum FilePasteOutcome {
  /// A copy or move task is in the transfer queue.
  queued,

  /// Every item was renamed into the folder on its server.
  renamed,

  /// Some renames failed; [FilePasteResult.failures] says which.
  partial,

  /// The containment rules refuse this folder (into itself, or a cut
  /// item back into its own folder).
  refused,

  /// Nothing to paste, or no queue or live channel to paste with.
  unavailable,
}

@immutable
class FilePasteResult {
  const FilePasteResult(this.outcome, {this.failures = const []});

  final FilePasteOutcome outcome;

  /// The items a same-server move could not rename, with the reason.
  final List<({String path, Object error})> failures;
}

/// P4-21's file operations (decision Q5): Paste from the app-internal
/// [FileClipboard], and the Edit ▸ Undo entries for pastes, inline
/// renames and deletes, recorded on the app's [GhostUndoHistory].
///
/// What Undo can reverse:
/// - a same-server move, an inline rename or a Rename Items run (local
///   or remote): renamed back through a live channel on that host;
/// - a transfer-queue move (local, or across hosts): moved back through
///   the queue once the move has finished;
/// - a copy: after the user confirms, the items the copy created are
///   deleted (to the Trash where the host has one);
/// - a local Move to Trash: Put Back, where the system's trash reports
///   where it put each item (macOS).
///
/// A remote delete, or any permanent delete, cannot be undone: it
/// records an entry Undo declines, so the Edit menu reads "Can't Undo
/// Delete" ([blockedUndoName]) instead of reaching past it.
///
/// Items that existed in the destination before a paste (a folder the
/// copy merged into, a file it replaced) are never deleted or moved
/// back by Undo: only what the paste created is taken back. The
/// destination's names are read just before the paste for that.
class FileOperations {
  FileOperations({
    required this._history,
    required this._clipboard,
    required this._delegate,
    required this._hostChannel,
    required this._confirmCopyUndo,
    required this._hostLabel,
    required this._notify,
    required this._strings,
  });

  final GhostUndoHistory _history;
  final FileClipboard _clipboard;
  final PaneDropDelegate? Function() _delegate;
  final FileHostLookup _hostChannel;
  final FileCopyUndoConfirm _confirmCopyUndo;
  final String Function(FsLocation host) _hostLabel;

  /// Tells the user something an Undo that still succeeded could not do
  /// (a moved-back item that kept its Keep Both name).
  final void Function(String message) _notify;
  final AppLocalizations Function() _strings;

  final Expando<bool> _irreversible = Expando();
  GhostUndoableChange? _lastIrreversible;

  /// The name of the change Undo would reach next when it cannot be
  /// undone (a remote or permanent delete), else null.
  String? get blockedUndoName {
    final change = _lastIrreversible;
    if (change == null || _irreversible[change] != true) return null;
    return _history.isNextUndo(change) ? change.name : null;
  }

  /// Pastes the clipboard into [destinationDir] on [destination].
  Future<FilePasteResult> paste({
    required FsLocation destination,
    required String destinationDir,
  }) async {
    final content = _clipboard.content;
    if (content == null) {
      return const FilePasteResult(FilePasteOutcome.unavailable);
    }
    final kind = filePasteKind(
      content,
      destination: destination,
      destinationDir: destinationDir,
    );
    if (kind == null) return const FilePasteResult(FilePasteOutcome.refused);

    final l10n = _strings();
    switch (kind) {
      case FilePasteKind.rename:
        return _pasteByRename(content, destination, destinationDir, l10n);
      case FilePasteKind.copy || FilePasteKind.move:
        final delegate = _delegate();
        if (delegate == null) {
          return const FilePasteResult(FilePasteOutcome.unavailable);
        }
        final preexisting = await _namesIn(destination, destinationDir);
        final operation = kind == FilePasteKind.copy
            ? TransferOperation.copy
            : TransferOperation.move;
        final task = delegate.enqueue(
          source: content.source,
          rootPaths: content.rootPaths,
          destination: destination,
          destinationDir: destinationDir,
          operation: operation,
        );
        if (task == null) {
          return const FilePasteResult(FilePasteOutcome.unavailable);
        }
        if (kind == FilePasteKind.move) _clipboard.clear();
        final paste = _QueuedPaste(
          source: content.source,
          rootPaths: content.rootPaths,
          destination: destination,
          destinationDir: destinationDir,
          operation: operation,
          task: task,
          preexisting: preexisting,
        );
        _history.record(
          kind == FilePasteKind.copy
              ? GhostUndoableChange(
                  name: l10n.fileUndoCopyName,
                  undo: () => _undoCopy(paste),
                  redo: () => _repeat(paste),
                )
              : GhostUndoableChange(
                  name: l10n.fileUndoMoveName,
                  undo: () => _undoQueuedMove(paste),
                  redo: () => _repeat(paste),
                ),
        );
        return const FilePasteResult(FilePasteOutcome.queued);
    }
  }

  Future<FilePasteResult> _pasteByRename(
    FileClipboardContent content,
    FsLocation host,
    String destinationDir,
    AppLocalizations l10n,
  ) async {
    final channel = _hostChannel(host);
    if (channel == null) {
      return const FilePasteResult(FilePasteOutcome.unavailable);
    }
    final done = <({String from, String to})>[];
    final failures = <({String path, Object error})>[];
    for (final root in content.rootPaths) {
      final to = fileChildPath(destinationDir, paneLastSegment(root));
      try {
        await channel.rename(root, to);
        done.add((from: root, to: to));
      } on Object catch (error) {
        failures.add((path: root, error: error));
      }
    }
    // A cut is used up by its paste, as in Finder; what failed stays
    // where it was and can be cut again.
    _clipboard.clear();
    if (done.isNotEmpty) {
      _history.record(_renameChange(l10n.fileUndoMoveName, host, done));
    }
    if (failures.isEmpty) {
      return const FilePasteResult(FilePasteOutcome.renamed);
    }
    return FilePasteResult(FilePasteOutcome.partial, failures: failures);
  }

  /// Records an inline rename of [from] to [to] on [host], so Undo can
  /// rename it back.
  void recordRename(FsLocation host, String from, String to) {
    _history.record(
      _renameChange(_strings().fileUndoRenameName, host, [
        (from: from, to: to),
      ]),
    );
  }

  /// Records a Rename Items run on [host], [renames] in the order they
  /// ran, so Undo can rename each item back (last first) as one change.
  void recordBatchRename(
    FsLocation host,
    List<({String from, String to})> renames,
  ) {
    if (renames.isEmpty) return;
    _history.record(
      _renameChange(_strings().fileUndoRenameItemsName, host, renames),
    );
  }

  /// Records a local Move to Trash [task], so Undo can put the items
  /// back.
  void recordTrash(TransferTask task) {
    final trash = _Trash(task);
    _history.record(
      GhostUndoableChange(
        name: _strings().fileUndoTrashName,
        undo: () => _putBack(trash),
        redo: () => _trashAgain(trash),
      ),
    );
  }

  /// Records a delete that cannot be undone (remote, or permanent):
  /// Undo then declines it and the menu says so, rather than undoing an
  /// older change past it.
  void recordIrreversibleDelete() {
    final change = GhostUndoableChange(
      name: _strings().fileUndoDeleteName,
      undo: () async =>
          throw GhostUndoDeclined(_strings().fileUndoIrreversibleDelete),
      redo: () async {},
    );
    _irreversible[change] = true;
    _lastIrreversible = change;
    _history.record(change);
  }

  GhostUndoableChange _renameChange(
    String name,
    FsLocation host,
    List<({String from, String to})> renames,
  ) => GhostUndoableChange(
    name: name,
    undo: () async {
      final channel = _requireChannel(host);
      for (final rename in renames.reversed) {
        await channel.rename(rename.to, rename.from);
      }
    },
    redo: () async {
      final channel = _requireChannel(host);
      for (final rename in renames) {
        await channel.rename(rename.from, rename.to);
      }
    },
  );

  FileHostChannel _requireChannel(FsLocation host) {
    final channel = _hostChannel(host);
    if (channel != null) return channel;
    throw GhostUndoDeclined(_strings().fileUndoNeedsTab(_hostLabel(host)));
  }

  /// The destination's names before a paste, or null when they could not
  /// be read (Undo then refuses to guess which items the paste created).
  Future<Set<String>?> _namesIn(FsLocation host, String folder) async {
    final channel = _hostChannel(host);
    if (channel == null) return null;
    try {
      final names = await channel.listNames(folder);
      return {for (final name in names) _nameKey(host, name)};
    } on Object {
      return null;
    }
  }

  /// Local volumes may fold case, so a local name compares folded: a
  /// pre-existing "Photos" then protects a pasted "photos" too. Being
  /// conservative here only ever keeps an item Undo could have removed.
  static String _nameKey(FsLocation host, String name) =>
      host is LocalFsLocation ? name.toLowerCase() : name;

  /// The finished task, or a decline while it still runs.
  TransferTask _settled(TransferTask task) {
    if (task.isTerminal) return task;
    throw GhostUndoDeclined(_strings().fileUndoWaitForTransfer);
  }

  /// The roots [paste] created: completed root items whose final name
  /// did not exist in the destination before the paste.
  List<({String original, String created})> _createdRoots(_QueuedPaste paste) {
    final preexisting = paste.preexisting;
    if (preexisting == null) {
      throw GhostUndoDeclined(_strings().fileUndoUnknownOrigin);
    }
    final roots = paste.rootPaths.toSet();
    final created = [
      for (final item in _settled(paste.task).items)
        if (roots.contains(item.sourcePath) &&
            item.state == TransferItemState.completed &&
            !preexisting.contains(
              _nameKey(
                paste.destination,
                paneLastSegment(item.destinationPath),
              ),
            ))
          (original: item.sourcePath, created: item.destinationPath),
    ];
    if (created.isEmpty) {
      throw GhostUndoDeclined(_strings().fileUndoNothing);
    }
    return created;
  }

  PaneDropDelegate _requireDelegate() {
    final delegate = _delegate();
    if (delegate != null) return delegate;
    throw FileOperationFailed(_strings().fileUndoNoQueue);
  }

  Future<void> _undoCopy(_QueuedPaste paste) async {
    final created = [for (final root in _createdRoots(paste)) root.created];
    final delegate = _requireDelegate();
    if (!await _confirmCopyUndo(paste.destination, created)) {
      throw GhostUndoDeclined(_strings().fileUndoCopyKept);
    }
    final queue = delegate.queue;
    final confirmation = await queue.prepareDelete(
      source: paste.destination,
      rootPaths: created,
    );
    final task = await queue.enqueueDelete(
      DeleteRequest(
        source: paste.destination,
        rootPaths: created,
        disposition: confirmation.effectiveDisposition,
        confirmed: true,
      ),
    );
    await _awaitCompleted(queue, task);
  }

  /// Moves what [paste] created back to the folders it came from. A root
  /// that comes back under another name (Keep Both renamed it "name 2"
  /// on the way out, or on the way back) then gets its own name again
  /// when that name is free; otherwise it keeps the name it has, and the
  /// user is told why.
  Future<void> _undoQueuedMove(_QueuedPaste paste) async {
    final moved = _createdRoots(paste);
    final delegate = _requireDelegate();
    final byFolder = <String, List<String>>{};
    for (final root in moved) {
      byFolder
          .putIfAbsent(paneParentPath(root.original), () => [])
          .add(root.created);
    }
    final tasks = [
      for (final MapEntry(key: folder, value: roots) in byFolder.entries)
        delegate.enqueue(
          source: paste.destination,
          rootPaths: roots,
          destination: paste.source,
          destinationDir: folder,
          operation: TransferOperation.move,
        ),
    ].nonNulls;
    final settled = [
      for (final task in tasks) await _awaitCompleted(delegate.queue, task),
    ];
    final originals = {for (final root in moved) root.created: root.original};
    // One notice for the whole Undo: the toast stack shows only a few at
    // once, so a notice per root could push others out of view.
    final keptNames = <String>[];
    for (final task in settled) {
      for (final item in task.items) {
        final original = originals[item.sourcePath];
        if (original == null) continue;
        final kept = await _restoreName(
          paste.source,
          item.destinationPath,
          original,
        );
        if (kept != null) keptNames.add(kept);
      }
    }
    if (keptNames.isNotEmpty) _notify(keptNames.join('\n'));
  }

  /// Renames [current] on [host] back to [original], its name before a
  /// Keep Both rename, unless that name is taken or no tab can rename.
  /// Never fails the Undo: the item is back either way. Returns why the
  /// item kept its name, or null when it has its own name again.
  Future<String?> _restoreName(
    FsLocation host,
    String current,
    String original,
  ) async {
    if (current == original) return null;
    final l10n = _strings();
    final currentName = paneLastSegment(current);
    final channel = _hostChannel(host);
    if (channel == null) {
      return l10n.fileUndoNameKept(
        currentName,
        l10n.fileUndoNameNoTab(_hostLabel(host)),
      );
    }
    try {
      // The channel refuses a taken name rather than replacing it.
      await channel.rename(current, original);
      return null;
    } on Object catch (error) {
      final taken =
          error is RemoteFileException &&
          error.kind == RemoteFileErrorKind.conflict;
      final reason = taken
          ? l10n.fileUndoNameTaken(paneLastSegment(original))
          : '$error';
      return l10n.fileUndoNameKept(currentName, reason);
    }
  }

  /// Redo: the same paste again, as a fresh task.
  Future<void> _repeat(_QueuedPaste paste) async {
    final delegate = _requireDelegate();
    final preexisting = await _namesIn(paste.destination, paste.destinationDir);
    final task = delegate.enqueue(
      source: paste.source,
      rootPaths: paste.rootPaths,
      destination: paste.destination,
      destinationDir: paste.destinationDir,
      operation: paste.operation,
    );
    if (task == null) throw FileOperationFailed(_strings().fileUndoNoQueue);
    paste
      ..task = task
      ..preexisting = preexisting;
  }

  Future<void> _putBack(_Trash trash) async {
    final task = _settled(trash.task);
    final roots = task.rootPaths.toSet();
    final trashed = [
      for (final item in task.items)
        if (roots.contains(item.sourcePath) &&
            item.state == TransferItemState.completed &&
            item.disposition == ItemDisposition.osTrash)
          item,
    ];
    if (trashed.isEmpty) throw GhostUndoDeclined(_strings().fileUndoNothing);
    // Only a trash that reports where it put an item (macOS) gives Put
    // Back an anchor; elsewhere the item's path stayed the original.
    final anchored = [
      for (final item in trashed)
        if (item.destinationPath != item.sourcePath) item,
    ];
    if (anchored.isEmpty) {
      throw GhostUndoDeclined(_strings().fileUndoPutBackUnavailable);
    }
    final channel = _requireChannel(const LocalFsLocation());
    for (final item in anchored) {
      await channel.rename(item.destinationPath, item.sourcePath);
    }
    final missed = trashed.length - anchored.length;
    if (missed > 0) {
      throw FileOperationFailed(_strings().fileUndoPutBackPartial(missed));
    }
  }

  Future<void> _trashAgain(_Trash trash) async {
    final queue = _requireDelegate().queue;
    trash.task = await queue.enqueueDelete(
      DeleteRequest(
        source: trash.task.spec.source,
        rootPaths: trash.task.rootPaths,
        disposition: DeleteDisposition.trash,
        confirmed: true,
      ),
    );
  }

  /// Waits for [task] and throws unless every item completed; returns
  /// the settled task.
  Future<TransferTask> _awaitCompleted(
    AppTransferQueue queue,
    TransferTask task,
  ) async {
    final settled = await awaitTransferTaskTerminal(
      events: queue.events,
      tasks: () => queue.tasks,
      taskId: task.id,
    );
    if (settled == null) {
      throw FileOperationFailed(_strings().fileUndoNoQueue);
    }
    if (settled.state == TransferTaskState.completed &&
        settled.items.every(
          (item) => item.state == TransferItemState.completed,
        )) {
      return settled;
    }
    throw FileOperationFailed(settled.error ?? _strings().fileUndoIncomplete);
  }
}

/// A queued paste and what Undo needs to reverse it. [task] and
/// [preexisting] move to the newest run after a Redo.
class _QueuedPaste {
  _QueuedPaste({
    required this.source,
    required this.rootPaths,
    required this.destination,
    required this.destinationDir,
    required this.operation,
    required this.task,
    required this.preexisting,
  });

  final FsLocation source;
  final List<String> rootPaths;
  final FsLocation destination;
  final String destinationDir;
  final TransferOperation operation;
  TransferTask task;
  Set<String>? preexisting;
}

class _Trash {
  _Trash(this.task);

  TransferTask task;
}

/// The live channel of an open tab on [host] in [workspace], or null.
FileHostChannel? fileHostChannelIn(
  WorkspaceController workspace,
  FsLocation host,
) {
  for (final strip in [workspace.left, workspace.right]) {
    for (final tab in strip.tabs) {
      final pane = tab.controller;
      final location = pane.location;
      if (location == null || !pane.hasLiveChannel) continue;
      if (!paneDropSameFilesystem(fsLocationForLocation(location), host)) {
        continue;
      }
      return _PaneHostChannel(pane);
    }
  }
  return null;
}

class _PaneHostChannel implements FileHostChannel {
  _PaneHostChannel(this._pane);

  final PaneController _pane;

  @override
  Future<void> rename(String from, String to) => _pane.renamePath(from, to);

  @override
  Future<Set<String>> listNames(String folder) => _pane.listNames(folder);
}
