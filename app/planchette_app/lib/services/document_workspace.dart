import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_editor/planchette_editor.dart';

import 'document_store.dart';

enum CloseChoice { save, discard, cancel }

/// The answer to saving over a read-only file.
enum ReadOnlyChoice { saveAs, saveAnyway, cancel }

/// The answer to the one-question close of several dirty documents at once.
enum BulkCloseChoice { saveAll, discardAll, cancel }

/// Who is walking the dirty tabs, which decides what the walk may assume.
enum _SaveRun {
  /// File › Save All: an ordinary save per tab, stopped by any modal.
  saveAll(EditorSaveAccess.normal),

  /// The quit question's Save All: it holds the interaction lock itself, so
  /// each save carries the close's consent, and a declined save cancels the
  /// quit rather than skipping one document.
  quit(EditorSaveAccess.confirmedClose);

  const _SaveRun(this.access);
  final EditorSaveAccess access;
}

/// How an open document's file relates to the text its tab last read from
/// it or wrote to it, as the latest disk check found it.
enum DiskState {
  /// The file holds what the tab last read or saved.
  current,

  /// Another program changed the file and the tab kept its own text: it had
  /// edits, or the new version could not be read.
  changed,

  /// The file was deleted or moved away; saving creates it again.
  missing,
}

/// Why a disk check runs, which decides what it may do about a change.
enum _DiskCheck {
  /// The window came back to the front: an unchanged stamp skips hashing,
  /// and a tab without edits takes the new version.
  focus,

  /// A write to the tab's own file failed. The failure is the evidence, so
  /// the file is hashed whatever its stamp, and nothing is replaced while
  /// the user is trying to save.
  failedSave,
}

/// Who asked for a tab's text to be read again from its file.
enum _Reread {
  /// Revert to Saved or the notice's Reload: the user chose to drop edits.
  chosen,

  /// A disk check found a new version for a tab without edits. It installs
  /// only over the text it found unedited.
  background,
}

abstract interface class DocumentDialogs {
  Future<List<String>> pickOpenFiles();
  Future<String?> pickSavePath(String suggestedName);
  Future<bool> confirmReplace(String path);
  Future<CloseChoice> chooseClose(String name);
  Future<ReadOnlyChoice> chooseReadOnlySave(String name);

  /// One question for every unsaved document, offered only when more than one
  /// is dirty. [names] lists them, so the answer is about files the user can
  /// see rather than a count.
  Future<BulkCloseChoice> chooseBulkClose(List<String> names);
  Future<bool> confirmRevert(String name);
}

/// One controller survives tab switches, retaining undo, selection, find and
/// scroll state. Its path changes only after a successful Save As commit.
final class DocumentTab {
  DocumentTab._(this.id, this.untitledName);

  final int id;
  final String untitledName;
  late final EditorController editor;
  late final VoidCallback _editorListener;
  _ShellState? _shown;
  TextDocument? baseline;
  String? path;
  bool busy = false;

  /// Set while a confirmed revert reads the file. The buffer is about to be
  /// replaced, so it takes no edits and no save may write it.
  bool _reverting = false;

  /// Whether the file still holds what this tab last read or wrote. The
  /// shell shows a notice for the other states.
  DiskState get disk => _disk;
  DiskState _disk = DiskState.current;

  /// The digest of the version another program wrote, while [disk] is
  /// [DiskState.changed]. Keep Mine makes it the next save's guard.
  String? _diskDigest;

  /// The baseline and file stamp [disk] was last decided for. A check that
  /// finds the same pair again skips hashing the file.
  ({TextDocument baseline, FileStamp stamp})? _decided;

  /// The last failure to read this tab's file that a check reported, so the
  /// next window focus does not report the same failure again.
  ({FileStamp? stamp, String message})? _unreadable;

  /// Bumped when the tab is chosen by opening a document it already holds, so
  /// the shell can point at it. Monotonic, never reset: a view compares it to
  /// the previous build's value.
  int flashRequest = 0;

  /// The read-only file the user already agreed to save over, so each later
  /// save does not ask again. A Save As to another file asks afresh.
  String? _acceptedReadOnlyPath;

  String get name => path == null ? untitledName : paths.basename(path!);
}

/// One file that failed to open, for callers that aggregate batch results.
typedef _OpenFailure = ({String path, String name, String message});

/// The part of a tab's editor state that the shell draws: its label, dirty
/// marker, window title and menu enablement. Shell code that reads another
/// editor property must add it here, or the shell goes stale until one of
/// these changes.
typedef _ShellState = ({
  bool dirty,
  bool loading,
  bool saving,
  String? error,
  String? path,
  bool canEditText,
  bool canToggleComment,
});

/// Where one save writes: the resolved path, the digest the write expects to
/// replace (null for a new file), and whether the user agreed, for this
/// write, to replace a protected file.
typedef _SaveTarget = ({String path, String? digest, bool acceptedReadOnly});

final class DocumentWorkspace extends ChangeNotifier {
  DocumentWorkspace({
    required this.store,
    required this.dialogs,
    paths.Context? pathContext,
    TextToolHistory? toolHistory,
  }) : _paths = pathContext ?? paths.context,
       toolHistory = toolHistory ?? TextToolHistory();

  /// Scope of a refused quit's notice. The notice describes a state, not a
  /// failure, so [_notify] retires it the moment nothing blocks a quit any
  /// more, whichever piece of work was the last to finish.
  static const Object _quitRefusal = Object();

  final paths.Context _paths;
  final DocumentStore store;
  final DocumentDialogs dialogs;
  final List<DocumentTab> _documents = [];
  final Map<String, Future<_OpenFailure?>> _opening = {};
  final Set<DocumentTab> _closingTabs = {};
  final Map<DocumentTab, Future<bool>> _saves = {};

  /// Files whose tabs the user closed, most recent last, for Reopen Closed
  /// Tab. Bounded so a long session does not keep every path it touched.
  /// Closed files, oldest first, with where the caret was: a line and
  /// column survive the file changing on disk better than an offset would.
  final List<({String path, int line, int column})> _closedPaths = [];
  static const _closedPathLimit = 20;
  int _nextId = 1;
  int _dialogCount = 0;

  /// The run history every tab's editor shares, so Repeat and Recent see
  /// tools run in any document.
  final TextToolHistory toolHistory;
  Indentation? _indentationPreference;

  /// The indentation for documents that neither use nor mandate one, from the
  /// user's settings: every open editor takes it now, and every editor made
  /// later takes it as it is created.
  Indentation? get indentationPreference => _indentationPreference;
  set indentationPreference(Indentation? value) {
    if (_indentationPreference == value) return;
    _indentationPreference = value;
    for (final tab in _documents) {
      tab.editor.indentationPreference = value;
    }
  }

  bool _closingAll = false;
  bool _quitAccepted = false;
  bool _disposed = false;
  Future<bool>? _quitDecision;
  Completer<void>? _unlocked;
  DocumentTab? _active;
  String? _error;

  /// What the current [_error] is about: the tab or the path key that failed,
  /// or null for failures with no retry counterpart (quit, the picker). The
  /// matching success clears its own scope and nothing else, so a resolved
  /// failure retires its banner without hiding another document's.
  Object? _errorScope;

  List<DocumentTab> get documents => List.unmodifiable(_documents);
  DocumentTab? get active => _active;
  String? get error => _error;
  bool get interactionLocked =>
      _dialogCount > 0 || _closingAll || _quitAccepted;
  String get windowTitle {
    final tab = active;
    if (tab == null) return 'Planchette';
    return '${tab.editor.isDirty ? '● ' : ''}${tab.name} — Planchette';
  }

  DocumentTab? newDocument() {
    if (interactionLocked) return null;
    final tab = _makeTab(initialText: '');
    _documents.add(tab);
    _active = tab;
    _notify();
    return tab;
  }

  DocumentTab _makeTab({String? path, String? initialText}) {
    final id = _nextId++;
    final tab = DocumentTab._(id, path == null ? _freeUntitledName() : '')
      ..path = path;
    tab.editor = EditorController(
      displayPath: path ?? tab.untitledName,
      initialText: initialText,
      toolHistory: toolHistory,
      // Read the path at call time: Save As retargets the tab, and a reload
      // must follow the new location rather than the one it was opened with.
      loadDocument: path == null
          ? null
          : () async {
              final document = await store.load(tab.path!);
              tab.baseline = document;
              tab.path = document.file.path;
              return document;
            },
      saveDocument: (text, _) async {
        final target = _saveTargets[tab];
        if (target == null) {
          throw StateError('Choose a save destination first.');
        }
        final document = await store.write(
          path: target.path,
          text: text,
          source: tab.baseline,
          expectedSha256: target.digest,
        );
        tab.baseline = document;
        tab.path = document.file.path;
        tab.editor.adoptDocument(document);
        tab.editor.displayPath = document.file.path;
        _settle(tab);
        return document.sha256;
      },
    );
    tab.editor.indentationPreference = _indentationPreference;
    tab._editorListener = () => _editorChanged(tab);
    tab.editor.addListener(tab._editorListener);
    return tab;
  }

  /// Editors notify on every keystroke and caret move. Forwarding those would
  /// rebuild the whole shell (every tab's editor, the menus, and the native
  /// macOS menu bar) and reset the window title each time, so only changes
  /// the shell actually draws are passed on.
  void _editorChanged(DocumentTab tab) {
    final editor = tab.editor;
    final state = (
      dirty: editor.isDirty,
      loading: editor.isLoading,
      saving: editor.isSaving,
      error: editor.error,
      path: tab.path,
      canEditText: editor.canEditText,
      canToggleComment: editor.canToggleComment,
    );
    if (state == tab._shown) return;
    tab._shown = state;
    _notify();
  }

  final Map<DocumentTab, ({String path, String? digest})> _saveTargets = {};

  /// The reason each tab's most recent [_saveOnce] failed, keyed by tab so a
  /// concurrent save of another tab cannot be read as this one's reason.
  /// [saveAll] reads it directly after its own await to fold several failures
  /// into one message; a tab's entry is replaced by every attempt it makes.
  final Map<DocumentTab, String> _saveFailures = {};

  /// Tabs whose most recent [_saveOnce] stopped at the user's own answer: a
  /// cancelled picker, Replace question or read-only question. Kept like
  /// [_saveFailures], but a declined save is a decision, so a Save All does
  /// not name it as a failure.
  final Set<DocumentTab> _declinedSaves = {};

  /// Set while [saveAll] walks its snapshot so a second trigger — a repeated
  /// shortcut or another menu activation — cannot start a second pass over
  /// the same tabs and interleave its result.
  bool _savingAll = false;

  /// "Untitled", then "Untitled 2" and so on, reusing the lowest number no
  /// open tab currently shows, a saved file called "Untitled 2" included.
  String _freeUntitledName() {
    final used = {for (final tab in _documents) tab.name};
    for (var number = 1; ; number++) {
      final name = number == 1 ? 'Untitled' : 'Untitled $number';
      if (!used.contains(name)) return name;
    }
  }

  void select(DocumentTab tab) {
    if (interactionLocked || !_documents.contains(tab)) return;
    _active = tab;
    _notify();
  }

  Future<void> openDialog() async {
    if (interactionLocked) return;
    try {
      final selected = await _dialog(dialogs.pickOpenFiles);
      final failures = <_OpenFailure>[];
      final reported = <String>{};
      for (final path in selected) {
        try {
          final failure = await _openDeduped(path);
          if (failure != null && reported.add(_pathKey(path))) {
            failures.add(failure);
          }
        } catch (error, stackTrace) {
          // One exceptional path must not abort the rest of the batch, but a
          // non-OS throwable is likely a bug — keep it diagnosable. The same
          // `reported` set dedupes the diagnostic with the visible failure.
          if (reported.add(_pathKey(path))) {
            FlutterError.reportError(
              FlutterErrorDetails(exception: error, stack: stackTrace),
            );
            failures.add((
              path: path,
              name: _paths.basename(path),
              message: '$error',
            ));
          }
        }
      }
      // A single failure belongs to its path, so opening that file again
      // successfully retires it; a batch summary belongs to no one document.
      if (failures.length == 1) {
        _reportError(
          _openFailureMessage(failures),
          scope: _pathKey(failures.single.path),
        );
      } else if (failures.isNotEmpty) {
        _reportError(_openFailureMessage(failures));
      }
    } catch (error) {
      _reportError('Could not open documents: $error');
    }
  }

  Future<void> open(String path) async {
    final failure = await _openDeduped(path);
    if (failure != null) {
      _reportError(_openFailureMessage([failure]), scope: _pathKey(path));
    }
  }

  /// One line naming every failure — the last error alone would hide the
  /// rest of the batch. The enumeration is capped so a large multi-select
  /// stays readable.
  String _openFailureMessage(List<_OpenFailure> failures) {
    if (failures.length == 1) {
      return 'Could not open ${failures.single.name}: '
          '${failures.single.message}';
    }
    const maxListed = 5;
    // Two files from different folders can share a basename; fall back to
    // the full path for those so each failure names its file. Compared
    // case-insensitively — on case-insensitive volumes 'Notes.txt' and
    // 'notes.txt' are different files that read identically in the list.
    final ambiguous = <String>{};
    final seen = <String>{};
    for (final failure in failures) {
      final key = failure.name.toLowerCase();
      if (!seen.add(key)) ambiguous.add(key);
    }
    String label(_OpenFailure failure) =>
        ambiguous.contains(failure.name.toLowerCase())
        ? failure.path
        : failure.name;
    final listed = failures
        .take(maxListed)
        .map((failure) => '${label(failure)} (${failure.message})')
        .join(', ');
    final extra = failures.length - maxListed;
    return 'Could not open ${failures.length} files: '
        '$listed${extra > 0 ? ', and $extra more' : ''}';
  }

  Future<_OpenFailure?> _openDeduped(String path) {
    if (_quitAccepted || _disposed) return Future.value();
    if (interactionLocked) {
      return (_unlocked ??= Completer<void>()).future.then(
        (_) => _openDeduped(path),
      );
    }
    final key = _pathKey(path);
    return _opening.putIfAbsent(
      key,
      () => _open(path).whenComplete(() {
        _opening.remove(key);
        // The open's own notification ran while it was still listed, so a
        // quit notice waiting on it needs one more.
        _notify();
      }),
    );
  }

  /// Whether Reopen Closed Tab has a closed file that is not open again.
  bool get canReopenClosed =>
      !interactionLocked &&
      _closedPaths.any((closed) => _findPath(closed.path) == null);

  /// Reopens the most recently closed file. Entries opened again some other
  /// way are skipped, so the command always brings back a closed tab.
  Future<void> reopenClosed() async {
    if (interactionLocked) return;
    while (_closedPaths.isNotEmpty) {
      final closed = _closedPaths.removeLast();
      if (_findPath(closed.path) != null) continue;
      _notify();
      await open(closed.path);
      // Back where the caret was, clamped to the file as it is now. Only a
      // tab this open created: a failed open shows nothing to move.
      final reopened = _findPath(closed.path);
      if (reopened != null && reopened == _active) {
        reopened.editor.goToLine(closed.line, column: closed.column);
      }
      return;
    }
  }

  void _rememberClosed(DocumentTab tab) {
    final path = tab.path;
    if (path == null) return;
    final key = _pathKey(path);
    final (line, column) = tab.editor.caretLineColumn;
    _closedPaths
      ..removeWhere((closed) => _pathKey(closed.path) == key)
      ..add((path: path, line: line, column: column));
    if (_closedPaths.length > _closedPathLimit) _closedPaths.removeAt(0);
  }

  Future<_OpenFailure?> _open(String path) async {
    final existing = _findPath(path);
    if (existing != null) {
      // No new tab will appear, so point at the one that already holds the
      // document. Activation is the whole behaviour; the flash is decoration.
      // Activating a tab the window already shows still drops the empty
      // scratch tab it replaces, so the outcome matches a fresh open.
      final previous = _active;
      _active = existing;
      existing.flashRequest++;
      _dropPristine(previous);
      _notify();
      return null;
    }
    final previous = _active;
    final tab = _makeTab(path: _paths.normalize(_paths.absolute(path)));
    _documents.add(tab);
    _active = tab;
    _notify();
    await tab.editor.initialize();
    if (_disposed || !_documents.contains(tab)) return null;
    final error = tab.editor.error;
    _OpenFailure? failure;
    if (error != null) {
      failure = (path: tab.path ?? tab.name, name: tab.name, message: error);
      _remove(tab);
    } else {
      // A symlink may resolve onto an already-open document. Keep the existing
      // buffer rather than allowing two tabs to overwrite the same target.
      final duplicate = _findPath(tab.path!, except: tab);
      if (duplicate != null) {
        _remove(tab);
        _active = duplicate;
        // The link resolved onto an open document, so again no new tab.
        duplicate.flashRequest++;
      } else {
        tab.editor.displayPath = tab.path!;
      }
      // The path opened: any earlier failure about it (and any
      // still-opening refusal raised against this tab) has been resolved.
      _clearScope(_pathKey(path));
      _clearScope(tab);
      // Opening into a fresh empty window replaces the empty tab instead
      // of stranding it. A failed open above keeps it untouched.
      _dropPristine(previous);
    }
    _notify();
    return failure;
  }

  Future<bool> save(DocumentTab tab, {bool saveAs = false}) {
    if (interactionLocked || !_documents.contains(tab)) {
      return Future.value(false);
    }
    return _save(tab, saveAs: saveAs);
  }

  /// Saves for one tab run in request order. Deduplicating instead would hand
  /// a Save As issued mid-save the in-flight future: the chosen destination is
  /// dropped and the old path reports success.
  Future<bool> _save(
    DocumentTab tab, {
    bool saveAs = false,
    EditorSaveAccess access = EditorSaveAccess.normal,
  }) => _saveAfter(tab, _saves[tab], saveAs: saveAs, access: access);

  Future<bool> _saveAfter(
    DocumentTab tab,
    Future<bool>? inFlight, {
    required bool saveAs,
    required EditorSaveAccess access,
  }) async {
    // Several callers can queue behind the same in-flight save, so re-read the
    // slot after every wait instead of trusting the future captured on entry.
    // Whoever claims the slot next becomes the new predecessor.
    while (inFlight != null) {
      await inFlight;

      // The wait above is an await point, so the tab may be gone by now. The
      // close and quit decisions call _save directly while they hold the
      // interaction lock, so only tab membership is re-checked here.
      if (!_documents.contains(tab)) return false;
      inFlight = _saves[tab];
    }

    final save = _saveOnce(tab, saveAs: saveAs, access: access);
    _saves[tab] = save;
    try {
      return await save;
    } finally {
      // Only the newest save owns the slot; an older chain must not clear it.
      if (identical(_saves[tab], save)) _saves.remove(tab);
    }
  }

  Future<bool> _saveOnce(
    DocumentTab tab, {
    required bool saveAs,
    required EditorSaveAccess access,
  }) async {
    _saveFailures.remove(tab);
    _declinedSaves.remove(tab);
    if (tab._reverting) {
      // Reachable only through a shortcut pressed before the menus caught up;
      // writing now would put the discarded edits back on disk.
      _saveFailures[tab] = 'it is being reverted';
      return false;
    }
    if (tab.editor.isLoading || tab.editor.error != null) {
      // Reachable from a close, where a refusal needs an outcome. A document
      // that failed to load has already reported its own error, so only the
      // still-opening case speaks.
      if (tab.editor.error == null) {
        _reportNotReady(tab);
        _saveFailures[tab] = 'still opening';
      }
      return false;
    }
    tab.busy = true;
    _notify();
    _SaveTarget? target;
    try {
      target = await _saveTarget(tab, saveAs: saveAs);
      if (target == null) return false;
      _saveTargets[tab] = (path: target.path, digest: target.digest);
      final result = await tab.editor.save(access: access);
      if (result == null) return false;
      // Consent to replace a protected file covers the write it was given
      // for, so it is remembered only once that write lands.
      if (target.acceptedReadOnly) tab._acceptedReadOnlyPath = target.path;
      _clearScope(tab);
      return true;
    } catch (error) {
      if (await _explainedByDisk(tab, target) case final reason?) {
        // The notice says what happened and offers the way on; the save's
        // own error would only repeat it less helpfully.
        _saveFailures[tab] = reason;
        _clearScope(tab);
        return false;
      }
      _reportError('Could not save ${tab.name}: $error', scope: tab);
      _saveFailures[tab] = '$error';
      return false;
    } finally {
      _saveTargets.remove(tab);
      tab.busy = false;
      _notify();
    }
  }

  /// Where [tab] saves, once everything that destination needs has been
  /// asked: the picker for Save As and new documents, the read-only question
  /// for a protected file, and Replace for another existing one. Null stops
  /// the save, recorded in [_declinedSaves] when the user said no and in
  /// [_saveFailures] when the destination was refused.
  Future<_SaveTarget?> _saveTarget(
    DocumentTab tab, {
    required bool saveAs,
  }) async {
    var chooseTarget = saveAs || tab.path == null;
    while (true) {
      final String target;
      if (chooseTarget) {
        final selected = await _dialog(
          () => dialogs.pickSavePath(tab.path ?? tab.name),
        );
        if (selected == null) {
          _declinedSaves.add(tab);
          return null;
        }
        target = await store.canonicalSavePath(selected);
        final other = _findPath(target, except: tab);
        if (other != null) {
          final message = '${other.name} is already open in another tab.';
          _reportError(message, scope: tab);
          _saveFailures[tab] = message;
          return null;
        }
      } else {
        target = tab.path!;
      }
      final own = tab.path != null && _pathKey(target) == _pathKey(tab.path!);
      // Choosing the same file must not bypass its external-change guard. A
      // file found missing expects none, so the save creates it again, and
      // exclusively: a file back in its place is never overwritten.
      final digest = own
          ? (tab.disk == DiskState.missing ? null : tab.baseline!.sha256)
          : await store.existingDigest(target);

      // Every route onto a protected file asks, Save As included. Consent
      // given for this tab's own file holds; any other file, including a
      // return to that one after saving elsewhere, is a new decision.
      final accepted = tab._acceptedReadOnlyPath;
      final consented =
          own && accepted != null && _pathKey(accepted) == _pathKey(target);
      var acceptedReadOnly = false;
      if (!consented && await store.isWriteProtected(target)) {
        final choice = await _dialog(
          () => dialogs.chooseReadOnlySave(_paths.basename(target)),
        );
        switch (choice) {
          case ReadOnlyChoice.cancel:
            _declinedSaves.add(tab);
            return null;
          case ReadOnlyChoice.saveAs:
            chooseTarget = true;
            continue;
          case ReadOnlyChoice.saveAnyway:
            acceptedReadOnly = true;
        }
      }
      // Save Anyway has already agreed to replace this file.
      if (!own &&
          digest != null &&
          !acceptedReadOnly &&
          !await _dialog(() => dialogs.confirmReplace(target))) {
        _declinedSaves.add(tab);
        return null;
      }
      return (path: target, digest: digest, acceptedReadOnly: acceptedReadOnly);
    }
  }

  /// Saves every dirty tab, one after another through the same serialization
  /// a single [save] uses, so concurrent writes never race on the digest
  /// guard. The dirty set is taken up front: a tab that closes while the
  /// loop yields was the user's decision and does not fail the run. A second
  /// call while one is running is refused, and a modal that opens mid-run
  /// stops the walk short of a success rather than saving underneath it.
  ///
  /// A partial failure is reported once, counting what was written and
  /// naming each document that was not, in the shape multi-open aggregation
  /// uses. Tabs the walk never reached are counted as not saved too, either
  /// in that summary or on their own when nothing failed. A save the user
  /// declines, at the picker or at the Replace or read-only question, is a
  /// decision, not a failure: it is neither written nor named, and the
  /// result simply is not a success. With a single dirty tab there is
  /// nothing to aggregate, so the individual save's own message stands.
  Future<bool> saveAll() async {
    if (interactionLocked || _savingAll) return false;
    _savingAll = true;
    try {
      // A tab being reverted is dirty only with edits the user discarded.
      final dirty = [
        for (final tab in _documents)
          if (tab.editor.isDirty && !tab._reverting) tab,
      ];
      return await _saveEach(dirty, _SaveRun.saveAll);
    } finally {
      _savingAll = false;
    }
  }

  /// The walk behind [saveAll] and the quit question's Save All: one save at a
  /// time through [_save], and one report for the whole run. [run] decides
  /// what the walk may assume; see [_SaveRun].
  Future<bool> _saveEach(List<DocumentTab> dirty, _SaveRun run) async {
    var saved = 0;
    var vanished = 0;
    var attempted = 0;
    final failures = <String>[];
    for (final tab in dirty) {
      // The quit holds the interaction lock for its whole decision; any
      // other run stops when a modal takes it.
      if (run == _SaveRun.saveAll && interactionLocked) break;
      attempted++;
      if (!_documents.contains(tab)) {
        vanished++;
        continue;
      }
      if (await _save(tab, access: run.access)) {
        saved++;
      } else if (!_documents.contains(tab)) {
        // Closed while this request waited behind the tab's own in-flight
        // save, typically a close that saved it first.
        vanished++;
      } else if (_declinedSaves.contains(tab)) {
        // A declined save under the quit question means "not now": stop
        // asking and keep the window, without calling it a failure.
        if (run == _SaveRun.quit) return false;
      } else if (_saveFailures[tab] case final detail?) {
        failures.add('${tab.name} (${_withoutFinalStop(detail)})');
      } else {
        failures.add(tab.name);
      }
    }
    // Every dirty tab belongs in the total: saved, failed, vanished or
    // never reached. A declined save is attempted, so it stays out of the
    // parts and only shares the denominator like any not-saved tab.
    final skipped = dirty.length - attempted;
    // Unscoped: a summary names several documents, so no single one of
    // them saving later makes it untrue.
    if (failures.isNotEmpty && dirty.length > 1) {
      _reportError(
        'Saved $saved of ${dirty.length}. '
        'Could not save: ${failures.join(', ')}.',
      );
    } else if (skipped > 0 && dirty.length > 1) {
      final notSaved = dirty.sublist(attempted).map((tab) => tab.name);
      _reportError(
        'Save All stopped with $skipped document'
        '${skipped == 1 ? '' : 's'} not saved: ${notSaved.join(', ')}.',
      );
    }
    return failures.isEmpty && saved + vanished == dirty.length;
  }

  /// Writes [tab] as a highlighted HTML page, by default beside the file.
  /// A page is never written over a document open in a tab, and replacing
  /// an existing file asks first, as Save As does. Returns whether a page
  /// was written.
  Future<bool> exportHtml(DocumentTab tab, HtmlPalette palette) async {
    if (interactionLocked ||
        !_documents.contains(tab) ||
        tab.editor.isLoading ||
        tab.editor.error != null) {
      return false;
    }
    final scope = _exportScope(tab);
    // A confirmed revert has discarded the buffer's edits, which stay on
    // screen until the file is read: exporting them would publish the text
    // the user just chose to throw away. Checked again before the buffer is
    // read, since a revert can start while the export settles its target.
    bool reverting() {
      if (!tab._reverting) return false;
      _reportError(
        '${tab.name} is being reverted. Export it once the file is read.',
        scope: scope,
      );
      return true;
    }

    try {
      if (reverting()) return false;
      String target;
      String? digest;
      while (true) {
        final selected = await _dialog(
          () => dialogs.pickSavePath('${tab.path ?? tab.name}.html'),
        );
        if (selected == null) return false;
        target = await store.canonicalSavePath(selected);
        final open = _findPath(target);
        if (open != null) {
          _reportError(
            '${open.name} is open in a tab. Export to another file.',
            scope: scope,
          );
          return false;
        }
        digest = await store.existingDigest(target);
        // A protected page is asked about as a save would be; Save Anyway
        // already agrees to replace it.
        if (await store.isWriteProtected(target)) {
          final choice = await _dialog(
            () => dialogs.chooseReadOnlySave(_paths.basename(target)),
          );
          if (choice == ReadOnlyChoice.cancel) return false;
          if (choice == ReadOnlyChoice.saveAs) continue;
        } else if (digest != null &&
            !await _dialog(() => dialogs.confirmReplace(target))) {
          return false;
        }
        break;
      }
      if (reverting()) return false;
      final text = tab.editor.text.text;
      final language = tab.editor.text.language;
      await store.write(
        path: target,
        text: highlightedHtml(
          text: text,
          tokens: language == null ? const [] : tokenizeSyntax(text, language),
          palette: palette,
          title: tab.name,
        ),
        source: null,
        expectedSha256: digest,
      );
      _clearScope(scope);
      return true;
    } catch (error) {
      _reportError('Could not export ${tab.name}: $error', scope: scope);
      return false;
    } finally {
      _notify();
    }
  }

  /// A tab's export failures, apart from its save failures: saving the
  /// document says nothing about an export that did not work.
  static Object _exportScope(DocumentTab tab) => (exportOf: tab);

  Future<bool> closeTab(DocumentTab tab) async {
    if (interactionLocked ||
        !_documents.contains(tab) ||
        !_closingTabs.add(tab)) {
      return false;
    }
    try {
      if (tab.busy) {
        _reportBusy(tab);
        return false;
      }
      if (!await _confirmTab(tab)) return false;
      // A save can start in the gap between the decision and the removal, so
      // the tab can still be busy here. Report it rather than closing nothing
      // in silence: _confirmTab returning true means it had nothing to say.
      if (tab.busy) {
        _reportBusy(tab);
        return false;
      }
      _remove(tab);
      // A save or destination failure about this tab cannot be retried
      // anymore, so its banner goes with it. Path-scoped and scope-less
      // errors are untouched.
      _clearScope(tab);
      _rememberClosed(tab);
      _notify();
      return true;
    } finally {
      _closingTabs.remove(tab);
      // Finishing a close can be the last thing that blocked a quit.
      _notify();
    }
  }

  /// Batch closes still run each tab through the same consent decision as
  /// a lone close; a Cancel stops the sweep — tabs closed so far stay
  /// closed, the rest stay open. Each returns whether the sweep completed.
  Future<bool> closeAllTabs() => _closeAllExcept(null);

  /// Closes every tab but [keep], which becomes active once the sweep
  /// completes. After a Cancel the refused tab stays active: its prompt
  /// showed it, and it is what the user is looking at.
  Future<bool> closeOthers(DocumentTab keep) async {
    if (!_documents.contains(keep)) return false;
    final completed = await _closeAllExcept(keep);
    if (completed && _documents.contains(keep)) select(keep);
    return completed;
  }

  Future<bool> _closeAllExcept(DocumentTab? keep) async {
    for (final tab in List.of(_documents)) {
      // A tab closed some other way while a save ran is already done.
      if (tab == keep || !_documents.contains(tab)) continue;
      if (!await closeTab(tab)) return false;
    }
    return true;
  }

  Future<bool> _confirmTab(DocumentTab tab) async {
    if (tab.busy || tab.editor.isSaving) {
      _reportBusy(tab);
      return false;
    }
    if (!tab.editor.isDirty) return true;
    final reviewedText = tab.editor.text.text;
    _active = tab;
    _notify();
    final choice = await _dialog(() => dialogs.chooseClose(tab.name));
    if (tab.busy || tab.editor.isSaving) {
      _reportBusy(tab);
      return false;
    }
    switch (choice) {
      case CloseChoice.cancel:
        return false;
      case CloseChoice.discard:
        if (tab.editor.text.text == reviewedText) return true;
        // The buffer moved on while the prompt was open, so the reviewed text
        // is no longer what would be dropped. Say so instead of closing
        // nothing in silence.
        _reportTabRefusal(
          '${tab.name} changed while the prompt was open, so nothing was '
          'discarded. Review it, then close again.',
          tab,
        );
        return false;
      case CloseChoice.save:
        return await _save(tab, access: EditorSaveAccess.confirmedClose) &&
            !tab.editor.isDirty;
    }
  }

  /// A close refused for a reason the user did not choose needs an outcome.
  /// A cancelled prompt and a locked workspace stay silent: the user can see
  /// the dialog and knows why.
  void _reportBusy(DocumentTab tab) => _reportTabRefusal(
    tab.editor.isSaving
        ? '${tab.name} is still being saved. Close it again once the save '
              'finishes.'
        : '${tab.name} is busy. Close it again in a moment.',
    tab,
  );

  /// Copy that fits both a refused close and a refused save: the document is
  /// not ready yet, and it will be.
  void _reportNotReady(DocumentTab tab) => _reportTabRefusal(
    '${tab.name} is still opening. Try again in a moment.',
    tab,
  );

  /// A retryable refusal is scoped to the tab it is about, like that tab's
  /// save failures: it retires when that tab saves or closes, and closing
  /// any other tab leaves it alone while it is still true.
  void _reportTabRefusal(String message, DocumentTab tab) =>
      _reportError(message, scope: tab);

  /// Reload a tab's file after the host confirmed discarding local edits.
  /// A failed reload keeps the buffer and reports through [error], so a
  /// broken read never destroys the user's text.
  Future<bool> revert(DocumentTab tab) async {
    if (!_canReread(tab)) return false;
    if (tab.editor.isDirty) {
      final confirmed = await _dialog(() => dialogs.confirmRevert(tab.name));
      if (!confirmed) return false;
    }
    return _rereadChosen(tab, 'revert');
  }

  /// The disk notice's Reload. Choosing it already says to drop the edits
  /// for the version on disk, so unlike [revert] it does not ask again.
  Future<bool> reloadFromDisk(DocumentTab tab) async {
    if (!_canReread(tab)) return false;
    return _rereadChosen(tab, 'reload');
  }

  bool _canReread(DocumentTab tab) =>
      !interactionLocked &&
      !tab.busy &&
      _documents.contains(tab) &&
      tab.path != null &&
      !tab.editor.isBusy;

  Future<bool> _rereadChosen(DocumentTab tab, String verb) async {
    try {
      return await _reread(tab, _Reread.chosen);
    } catch (error) {
      // Runs unawaited from the menu and the notice; report instead of
      // leaking an unhandled async error.
      _reportError('Could not $verb ${tab.name}: $error', scope: tab);
      return false;
    }
  }

  /// Reads [tab]'s file and installs it as the buffer and its baseline,
  /// rethrowing a failed read. The tab stays on screen, locked, while the
  /// file is read.
  Future<bool> _reread(DocumentTab tab, _Reread why) async {
    final baseline = tab.baseline;
    tab.busy = true;
    tab._reverting = true;
    _notify();
    try {
      // Read here rather than through the editor's loader: the document
      // stays on screen while the file is read, and a failed read never
      // reaches the editor, so the buffer survives it untouched. The read
      // follows the tab's current path, which Save As may have changed.
      final document = await store.load(tab.path!);
      if (_disposed || !_documents.contains(tab)) return false;
      if (why == _Reread.background &&
          (tab.editor.isDirty || !identical(tab.baseline, baseline))) {
        return false;
      }
      tab.baseline = document;
      tab.path = document.file.path;
      // An install: the view starts a fresh undo history, so the replaced
      // text cannot be undone back into a buffer whose baseline has moved.
      // The caret and scroll position stay where they still fit.
      tab.editor.adoptDocument(document, replaceText: true);
      tab.editor.displayPath = document.file.path;
      _settle(tab);
      if (why == _Reread.chosen) _clearScope(tab);
      return true;
    } finally {
      tab.busy = false;
      tab._reverting = false;
      _notify();
    }
  }

  /// The disk notice's Keep Mine: keep the edits, and let the next save
  /// replace the version now on disk. Only that version: its digest becomes
  /// the save's guard, so a later outside change is still caught. A tab
  /// without edits is refused, since nothing would mark its text unsaved
  /// and the file would keep the other version while the tab shows this one.
  void keepMine(DocumentTab tab) {
    final baseline = tab.baseline;
    final digest = tab._diskDigest;
    if (interactionLocked ||
        tab.busy ||
        !_documents.contains(tab) ||
        tab.disk != DiskState.changed ||
        !tab.editor.isDirty ||
        baseline == null ||
        digest == null) {
      return;
    }
    tab.baseline = baseline.copyWith(sha256: digest);
    // The file was hashed at this stamp, so an unchanged file needs no
    // second look against the adopted digest.
    if (tab._decided case final decided?) {
      tab._decided = (baseline: tab.baseline!, stamp: decided.stamp);
    }
    _settle(tab);
  }

  /// Compares each open file with the text its tab last read or wrote,
  /// typically when the window comes back to the front. A tab without edits
  /// takes the new version in place, a tab with edits gets a notice, and a
  /// vanished file is flagged so Save creates it again. A request while a
  /// check runs sends it round once more: it may have passed the file that
  /// changed.
  Future<void> checkDisk() {
    if (_diskCheck case final running?) {
      _checkAgain = true;
      return running;
    }
    return _diskCheck = _checkDiskRounds().whenComplete(
      () => _diskCheck = null,
    );
  }

  Future<void>? _diskCheck;
  bool _checkAgain = false;

  Future<void> _checkDiskRounds() async {
    do {
      _checkAgain = false;
      for (final tab in List.of(_documents)) {
        // A question on screen owns the window: a notice or a reload now
        // would change what it asks about. Checking resumes once it closes.
        while (interactionLocked && !_quitAccepted && !_disposed) {
          await (_unlocked ??= Completer<void>()).future;
        }
        if (_disposed || _quitAccepted) return;
        if (!_documents.contains(tab) ||
            tab.path == null ||
            tab.baseline == null ||
            tab.busy ||
            tab.editor.isBusy ||
            tab.editor.error != null) {
          continue;
        }
        await _checkTab(tab, _DiskCheck.focus);
      }
    } while (_checkAgain && !_disposed);
  }

  /// Decides [tab]'s [DiskState] from its file, and returns the digest found
  /// there (null for no file), or null when the check could not tell or its
  /// result was dropped. Only a stamp that changed since the last decision
  /// is worth hashing the file for.
  Future<({String? digest})?> _checkTab(DocumentTab tab, _DiskCheck why) async {
    final path = tab.path!;
    final baseline = tab.baseline!;

    // Another operation took the tab over while the file was read, and its
    // own outcome decides what the tab holds now.
    bool superseded() =>
        _disposed ||
        !_documents.contains(tab) ||
        !identical(tab.baseline, baseline) ||
        (why == _DiskCheck.focus && (tab.busy || tab.editor.isBusy));

    FileStamp? stamp;
    String? digest;
    var steady = false;
    try {
      stamp = await store.stamp(path);
      if (stamp != null) {
        final decided = tab._decided;
        if (why == _DiskCheck.focus &&
            decided != null &&
            identical(decided.baseline, baseline) &&
            decided.stamp == stamp) {
          return null;
        }
        digest = await store.existingDigest(path);
        // Only a stamp that held across the read describes this digest.
        steady = await store.stamp(path) == stamp;
      }
    } catch (error) {
      if (!superseded()) {
        _reportUnreadable(
          tab,
          stamp,
          'Could not check ${tab.name} for changes on disk: $error',
        );
      }
      return null;
    }
    if (superseded()) return null;
    tab._unreadable = null;
    _clearScope(_diskScope(tab));

    if (stamp == null || digest == null) {
      tab._decided = null;
      tab._diskDigest = null;
      _setDisk(tab, DiskState.missing);
      return (digest: null);
    }
    final decision = steady ? (baseline: baseline, stamp: stamp) : null;
    if (digest == baseline.sha256) {
      tab._decided = decision;
      _settle(tab);
      return (digest: digest);
    }
    if (why == _DiskCheck.focus && !tab.editor.isDirty) {
      // A later check tries again if the tab cannot take the text now.
      if (!_canReread(tab)) return null;
      try {
        if (!await _reread(tab, _Reread.background)) return null;
      } catch (error) {
        if (superseded()) return null;
        _flagChanged(tab, digest, decision);
        _reportUnreadable(
          tab,
          stamp,
          'Could not read the new version of ${tab.name}: $error',
        );
      }
      return (digest: digest);
    }
    _flagChanged(tab, digest, decision);
    return (digest: digest);
  }

  /// Why a failed write to [tab]'s own file failed, when the file explains
  /// it: it no longer holds what the save expected, and the notice now says
  /// so. Null for any other failure, such as a permission error, whose own
  /// message must stay visible, notice or not.
  Future<String?> _explainedByDisk(DocumentTab tab, _SaveTarget? target) async {
    final path = tab.path;
    if (target == null ||
        path == null ||
        tab.baseline == null ||
        _pathKey(target.path) != _pathKey(path)) {
      return null;
    }
    final found = await _checkTab(tab, _DiskCheck.failedSave);
    if (found == null || found.digest == target.digest) return null;
    return switch (tab.disk) {
      DiskState.current => null,
      DiskState.changed => 'it changed on disk',
      DiskState.missing => 'it was deleted or moved',
    };
  }

  void _flagChanged(
    DocumentTab tab,
    String digest,
    ({TextDocument baseline, FileStamp stamp})? decision,
  ) {
    tab._diskDigest = digest;
    tab._decided = decision;
    _setDisk(tab, DiskState.changed);
  }

  /// The file holds what [tab] last read or wrote.
  void _settle(DocumentTab tab) {
    tab._diskDigest = null;
    tab._unreadable = null;
    _clearScope(_diskScope(tab));
    _setDisk(tab, DiskState.current);
  }

  void _setDisk(DocumentTab tab, DiskState state) {
    if (tab._disk == state) return;
    tab._disk = state;
    _notify();
  }

  /// Reports a file a check could not read, once for each failure: every
  /// window focus checks again, and the same message each time would make
  /// the banner impossible to dismiss.
  void _reportUnreadable(DocumentTab tab, FileStamp? stamp, String message) {
    final failure = (stamp: stamp, message: message);
    if (tab._unreadable == failure) return;
    tab._unreadable = failure;
    _reportError(message, scope: _diskScope(tab));
  }

  /// A tab's disk-check failures, apart from its save failures: a save says
  /// nothing about whether the file can be read.
  static Object _diskScope(DocumentTab tab) => (diskOf: tab);

  /// Both the native close button and the OS Quit route share this decision.
  /// No tab is removed until every document has consented; a later Cancel
  /// therefore leaves the entire workspace available.
  Future<bool> confirmQuit() =>
      _quitDecision ??= _confirmQuit().whenComplete(() {
        _quitDecision = null;
      });

  Future<bool> _confirmQuit() async {
    if (_quitAccepted) return true;

    // A busy window cannot ask about its tabs, and refusing in silence looks
    // like a broken Quit button. Say what to wait for instead — but a failure
    // the user has not dealt with yet outranks a notice about work that is
    // about to finish.
    if (_quitBlocker case final waitFor?) {
      if (_error == null || _errorScope == _quitRefusal) {
        _reportError(waitFor, scope: _quitRefusal);
      }
      return false;
    }
    _closingAll = true;
    _notify();
    try {
      final unsaved = [
        for (final tab in _documents)
          if (tab.editor.isDirty) tab,
      ];

      // One question for a pile of dirty tabs beats a queue of per-document
      // prompts. A single dirty document keeps its own question, which names
      // the file and can be answered per file.
      if (unsaved.length > 1) {
        // The answer covers the text the question was asked about, as
        // _confirmTab's does for one document.
        final reviewed = {
          for (final tab in _documents) tab: tab.editor.text.text,
        };
        final choice = await _dialog(
          () => dialogs.chooseBulkClose([for (final tab in unsaved) tab.name]),
        );
        switch (choice) {
          case BulkCloseChoice.cancel:
            return false;
          case BulkCloseChoice.saveAll:
            // Whatever is dirty now, including edits made while the question
            // was open: saving them is what the answer asked for.
            final dirty = [
              for (final tab in _documents)
                if (tab.editor.isDirty) tab,
            ];
            if (!await _saveEach(dirty, _SaveRun.quit)) return false;
          case BulkCloseChoice.discardAll:
            final changed = _documents.where(
              (tab) => reviewed[tab] != tab.editor.text.text,
            );
            if (changed.isNotEmpty) {
              _reportTabRefusal(
                '${changed.first.name} changed while the prompt was open, so '
                'nothing was discarded. Review it, then quit again.',
                changed.first,
              );
              return false;
            }
        }
      } else {
        for (final tab in List.of(_documents)) {
          if (!await _confirmTab(tab)) return false;
        }
      }
      _quitAccepted = true;
      return true;
    } finally {
      _closingAll = false;
      _notify();
    }
  }

  Future<T> _dialog<T>(Future<T> Function() show) async {
    _dialogCount++;
    _notify();
    try {
      return await show();
    } finally {
      _dialogCount--;
      _notify();
    }
  }

  DocumentTab? _findPath(String path, {DocumentTab? except}) {
    final key = _pathKey(path);
    for (final tab in _documents) {
      if (tab != except && tab.path != null && _pathKey(tab.path!) == key) {
        return tab;
      }
    }
    return null;
  }

  /// A New tab still in its initial state: never saved, nothing typed,
  /// nothing to lose. Type-then-erase-all also reads pristine (the buffer is
  /// empty and clean); its dropped undo tail is accepted and documented.
  bool _isPristineTab(DocumentTab tab) =>
      tab.path == null &&
      !tab.busy &&
      !tab.editor.isDirty &&
      tab.editor.text.text.isEmpty;

  /// Closes the scratch tab an open just replaced. Only the previously active
  /// tab qualifies, and only while it is still open, unnamed, empty and
  /// unedited: background scratch tabs belong to the user.
  void _dropPristine(DocumentTab? tab) {
    if (tab != null && _documents.contains(tab) && _isPristineTab(tab)) {
      _remove(tab);
    }
  }

  /// The tab's name, with its folder while another open tab has the same
  /// name, so two index.js tabs can be told apart. Ported from #43.
  String labelFor(DocumentTab tab) {
    final path = tab.path;
    if (path == null) return tab.name;
    final others = [
      for (final other in _documents)
        if (other != tab && other.name == tab.name && other.path != null)
          _folders(other.path!),
    ];
    if (others.isEmpty) return tab.name;
    // As few folders as tell this tab from every other of the same name:
    // x/src/index.js and y/src/index.js need two, a/b.txt and c/b.txt one.
    final mine = _folders(path);
    for (var count = 1; count <= mine.length; count++) {
      final suffix = mine.sublist(mine.length - count).join('/');
      final unique = others.every(
        (theirs) =>
            theirs.length < count ||
            theirs.sublist(theirs.length - count).join('/') != suffix,
      );
      if (unique) {
        return _paths.joinAll([...mine.sublist(mine.length - count), tab.name]);
      }
    }
    // Every folder is shared, as with /a/index.js beside /x/a/index.js:
    // show them all, which the longer path's label then extends.
    return _paths.joinAll([...mine, tab.name]);
  }

  /// The folders above [path]'s file, outermost first, without the root.
  List<String> _folders(String path) {
    final parts = _paths.split(_paths.dirname(path));
    final root = _paths.rootPrefix(path);
    return [
      for (final part in parts)
        if (part.isNotEmpty && part != root && part != '.') part,
    ];
  }

  String _pathKey(String path) => _paths.canonicalize(path);

  /// A failed native destruction must not leave the surviving window locked.
  void quitFailed(Object error) {
    _quitAccepted = false;
    _reportError('Could not close Planchette: $error');
  }

  /// Replace the banner with [message], remembering what it is about so the
  /// matching success can retire it. Failures with no retry counterpart pass
  /// no scope and stay until dismissed.
  /// A failure detail quoted inside a sentence keeps that sentence's own
  /// full stop only.
  static String _withoutFinalStop(String detail) =>
      detail.endsWith('.') ? detail.substring(0, detail.length - 1) : detail;

  void _reportError(String message, {Object? scope}) {
    _error = message;
    _errorScope = scope;
    _notify();
  }

  /// Drop the banner only when it belongs to [scope]: the operation that
  /// failed has now succeeded, or its tab is gone. An unrelated failure
  /// keeps its message — a generic success must never hide another
  /// document's error. Notify here so the helper stands on its own and no
  /// caller can clear the state without updating the banner.
  void _clearScope(Object scope) {
    if (_errorScope != scope) return;
    _error = null;
    _errorScope = null;
    _notify();
  }

  void clearError() {
    _error = null;
    _errorScope = null;
    _notify();
  }

  /// What a quit would have to wait for, or null when nothing blocks it.
  /// [_confirmQuit] refuses on it and [_notify] retires the notice with it,
  /// so the two can never disagree about whether the wait is over.
  String? get _quitBlocker {
    if (_dialogCount > 0 || _closingTabs.isNotEmpty || _opening.isNotEmpty) {
      return 'A document is still opening or closing, or a dialog is '
          'waiting. Quit again once it finishes.';
    }
    if (_documents.any((tab) => tab.busy || tab.editor.isSaving)) {
      return 'A save is still running. Quit again once it finishes.';
    }
    return null;
  }

  void _remove(DocumentTab tab) {
    final index = _documents.indexOf(tab);
    _documents.remove(tab);
    _saveFailures.remove(tab);
    _declinedSaves.remove(tab);
    // An export or a disk check of a closed tab cannot be retried from it.
    if (_errorScope == _exportScope(tab) || _errorScope == _diskScope(tab)) {
      _error = null;
      _errorScope = null;
    }
    if (_active == tab) {
      _active = _documents.isEmpty
          ? null
          : _documents[index.clamp(0, _documents.length - 1)];
    }
    tab.editor.removeListener(tab._editorListener);
    tab.editor.dispose();
  }

  void _notify() {
    if (_disposed) return;
    if (_errorScope == _quitRefusal && _quitBlocker == null) {
      _error = null;
      _errorScope = null;
    }
    for (final tab in _documents) {
      tab.editor.setEditingLocked(
        interactionLocked || tab._reverting,
        notify: false,
      );
    }
    if (interactionLocked) {
      _unlocked ??= Completer<void>();
    } else {
      final waiting = _unlocked;
      _unlocked = null;
      waiting?.complete();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _unlocked?.complete();
    _unlocked = null;
    for (final tab in _documents) {
      tab.editor.removeListener(tab._editorListener);
      tab.editor.dispose();
    }
    super.dispose();
  }
}
