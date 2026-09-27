import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_editor/planchette_editor.dart';

import 'document_store.dart';

enum CloseChoice { save, discard, cancel }

abstract interface class DocumentDialogs {
  Future<List<String>> pickOpenFiles();
  Future<String?> pickSavePath(String suggestedName);
  Future<bool> confirmReplace(String path);
  Future<CloseChoice> chooseClose(String name);
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

  String get name => path == null ? untitledName : paths.basename(path!);
}

final class DocumentWorkspace extends ChangeNotifier {
  DocumentWorkspace({
    required this.store,
    required this.dialogs,
    paths.Context? pathContext,
  }) : _paths = pathContext ?? paths.context;

  final paths.Context _paths;
  final DocumentStore store;
  final DocumentDialogs dialogs;
  final List<DocumentTab> _documents = [];
  final Map<String, Future<void>> _opening = {};
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
  String? _tabRefusal;

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

  void select(DocumentTab tab) {
    if (interactionLocked || !_documents.contains(tab)) return;
    _active = tab;
    _notify();
  }

  Future<void> openDialog() async {
    if (interactionLocked) return;
    try {
      final selected = await _dialog(dialogs.pickOpenFiles);
      for (final path in selected) {
        await open(path);
      }
    } catch (error) {
      _error = 'Could not open documents: $error';
      _notify();
    }
  }

  Future<void> open(String path) {
    if (_quitAccepted || _disposed) return Future.value();
    if (interactionLocked) {
      return (_unlocked ??= Completer<void>()).future.then((_) => open(path));
    }
    final key = _pathKey(path);
    return _opening.putIfAbsent(
      key,
      () => _open(path).whenComplete(() {
        _opening.remove(key);
      }),
    );
  }

  Future<void> _open(String path) async {
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
      return;
    }
    final previous = _active;
    final tab = _makeTab(path: _paths.normalize(_paths.absolute(path)));
    _documents.add(tab);
    _active = tab;
    _notify();
    await tab.editor.initialize();
    if (_disposed || !_documents.contains(tab)) return;
    final error = tab.editor.error;
    if (error != null) {
      _error = 'Could not open ${tab.name}: $error';
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
      // Opening into a fresh empty window replaces the empty tab instead
      // of stranding it. A failed open above keeps it untouched.
      _dropPristine(previous);
    }
    _notify();
  }

  Future<bool> save(DocumentTab tab, {bool saveAs = false}) {
    if (interactionLocked || !_documents.contains(tab)) {
      return Future.value(false);
    }
    return _save(tab, saveAs: saveAs);
  }

  Future<bool> _save(
    DocumentTab tab, {
    bool saveAs = false,
    EditorSaveAccess access = EditorSaveAccess.normal,
  }) => _saves.putIfAbsent(
    tab,
    () => _saveOnce(tab, saveAs: saveAs, access: access).whenComplete(() {
      _saves.remove(tab);
    }),
  );

  Future<bool> _saveOnce(
    DocumentTab tab, {
    required bool saveAs,
    required EditorSaveAccess access,
  }) async {
    if (tab.editor.isLoading || tab.editor.error != null) {
      // Reachable from a close, where a refusal needs an outcome. A document
      // that failed to load has already reported its own error, so only the
      // still-opening case speaks.
      if (tab.editor.error == null) _reportNotReady(tab);
      return false;
    }
    tab.busy = true;
    _notify();
    try {
      String target;
      String? digest;
      if (saveAs || tab.path == null) {
        final selected = await _dialog(
          () => dialogs.pickSavePath(tab.path ?? tab.name),
        );
        if (selected == null) return false;
        target = await store.canonicalSavePath(selected);
        final other = _findPath(target, except: tab);
        if (other != null) {
          _error = '${other.name} is already open in another tab.';
          return false;
        }
        if (tab.path != null && _pathKey(target) == _pathKey(tab.path!)) {
          // Choosing the same file must not bypass its external-change guard.
          digest = tab.baseline!.sha256;
        } else {
          digest = await store.existingDigest(target);
          if (digest != null &&
              !await _dialog(() => dialogs.confirmReplace(target))) {
            return false;
          }
        }
      } else {
        target = tab.path!;
        digest = tab.baseline!.sha256;
      }
      _saveTargets[tab] = (path: target, digest: digest);
      final result = await tab.editor.save(access: access);
      return result != null;
    } catch (error) {
      _error = 'Could not save ${tab.name}: $error';
      return false;
    } finally {
      _saveTargets.remove(tab);
      tab.busy = false;
      _notify();
    }
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
      _clearCloseRefusal();
      _notify();
      return true;
    } finally {
      _closingTabs.remove(tab);
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
  );

  /// Copy that fits both a refused close and a refused save: the document is
  /// not ready yet, and it will be.
  void _reportNotReady(DocumentTab tab) =>
      _reportTabRefusal('${tab.name} is still opening. Try again in a moment.');

  /// A retryable refusal names the tab it is about, so it stops being true
  /// the moment that tab closes. Tracking the last one keeps a stale excuse
  /// from outliving its cause without clearing errors the workspace owns —
  /// a failed save, a missing file and a declined destination still persist
  /// until they are replaced or dismissed.
  void _reportTabRefusal(String message) {
    _tabRefusal = message;
    _error = message;
    _notify();
  }

  void _clearCloseRefusal() {
    if (_error == _tabRefusal) _error = null;
    _tabRefusal = null;
  }

  /// Both the native close button and the OS Quit route share this decision.
  /// No tab is removed until every document has consented; a later Cancel
  /// therefore leaves the entire workspace available.
  Future<bool> confirmQuit() =>
      _quitDecision ??= _confirmQuit().whenComplete(() {
        _quitDecision = null;
      });

  Future<bool> _confirmQuit() async {
    if (_quitAccepted) return true;
    if (_dialogCount > 0 ||
        _closingTabs.isNotEmpty ||
        _opening.isNotEmpty ||
        _documents.any((tab) => tab.busy || tab.editor.isSaving)) {
      return false;
    }
    _closingAll = true;
    _notify();
    try {
      for (final tab in List.of(_documents)) {
        if (!await _confirmTab(tab)) return false;
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

  String _pathKey(String path) => _paths.canonicalize(path);

  /// A failed native destruction must not leave the surviving window locked.
  void quitFailed(Object error) {
    _quitAccepted = false;
    _error = 'Could not close Planchette: $error';
    _notify();
  }

  void clearError() {
    _error = null;
    _tabRefusal = null;
    _notify();
  }

  void _remove(DocumentTab tab) {
    final index = _documents.indexOf(tab);
    _documents.remove(tab);
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
