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
}

/// One controller survives tab switches, retaining undo, selection, find and
/// scroll state. Its path changes only after a successful Save As commit.
final class DocumentTab {
  DocumentTab._(this.id, this.untitledName);

  final int id;
  final String untitledName;
  late final EditorController editor;
  TextDocument? baseline;
  String? path;
  bool busy = false;

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

/// Where one save writes: the resolved path, the digest the write expects to
/// replace (null for a new file), and whether the user agreed, for this
/// write, to replace a protected file.
typedef _SaveTarget = ({String path, String? digest, bool acceptedReadOnly});

final class DocumentWorkspace extends ChangeNotifier {
  DocumentWorkspace({
    required this.store,
    required this.dialogs,
    paths.Context? pathContext,
  }) : _paths = pathContext ?? paths.context;

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
  int _nextId = 1;
  int _dialogCount = 0;
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
    final tab = DocumentTab._(id, 'Untitled $id')..path = path;
    tab.editor = EditorController(
      displayPath: path ?? tab.untitledName,
      initialText: initialText,
      loadDocument: path == null
          ? null
          : () async {
              final document = await store.load(path);
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
        return document.sha256;
      },
    )..addListener(_notify);
    return tab;
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

  Future<_OpenFailure?> _open(String path) async {
    final existing = _findPath(path);
    if (existing != null) {
      // No new tab will appear, so point at the one that already holds the
      // document. Activation is the whole behaviour; the flash is decoration.
      _active = existing;
      existing.flashRequest++;
      _notify();
      return null;
    }
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
    try {
      final target = await _saveTarget(tab, saveAs: saveAs);
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
      // Choosing the same file must not bypass its external-change guard.
      final digest = own
          ? tab.baseline!.sha256
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
      final dirty = [
        for (final tab in _documents)
          if (tab.editor.isDirty) tab,
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
      _notify();
      return true;
    } finally {
      _closingTabs.remove(tab);
      // Finishing a close can be the last thing that blocked a quit.
      _notify();
    }
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
    if (_active == tab) {
      _active = _documents.isEmpty
          ? null
          : _documents[index.clamp(0, _documents.length - 1)];
    }
    tab.editor.removeListener(_notify);
    tab.editor.dispose();
  }

  void _notify() {
    if (_disposed) return;
    if (_errorScope == _quitRefusal && _quitBlocker == null) {
      _error = null;
      _errorScope = null;
    }
    for (final tab in _documents) {
      tab.editor.setEditingLocked(interactionLocked, notify: false);
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
      tab.editor.removeListener(_notify);
      tab.editor.dispose();
    }
    super.dispose();
  }
}
