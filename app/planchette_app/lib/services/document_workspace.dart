import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_editor/planchette_editor.dart';

import 'document_store.dart';

enum CloseChoice { save, discard, cancel }

/// How a saved document relates to the file it came from.
enum DiskState {
  /// The file still holds what was last loaded or saved.
  current,

  /// Another program changed the file while this tab has unsaved edits.
  changed,

  /// The file was moved or deleted; saving creates it again.
  missing,
}

abstract interface class DocumentDialogs {
  Future<List<String>> pickOpenFiles();
  Future<String?> pickSavePath(String suggestedName);
  Future<bool> confirmReplace(String path);
  Future<CloseChoice> chooseClose(String name);
  Future<bool> confirmRevert(String name);
}

/// What a disk check does when a tab without edits changed on disk.
enum _CleanTabChange { reload, flag }

enum _ReloadMode {
  /// The user chose to replace their edits.
  discardEdits,

  /// A background refresh; edits made while reading turn it into a notice.
  onlyIfClean,
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
  DiskState disk = DiskState.current;
  String? _diskDigest;
  ({TextDocument baseline, FileStamp stamp})? _verified;

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
        tab.disk = DiskState.current;
        tab._diskDigest = null;
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
      _active = existing;
      _notify();
      return;
    }
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
      } else {
        tab.editor.displayPath = tab.path!;
      }
    }
    _notify();
  }

  Future<bool> save(DocumentTab tab, {bool saveAs = false}) {
    if (interactionLocked || !_documents.contains(tab)) {
      return Future.value(false);
    }
    return _save(tab, saveAs: saveAs);
  }

  /// File › Revert to Saved: re-reads [tab] from disk, asking first when it
  /// has unsaved edits.
  Future<bool> revert(DocumentTab tab) async {
    if (!_canReload(tab)) return false;
    if (tab.editor.isDirty &&
        !await _dialog(() => dialogs.confirmRevert(tab.name))) {
      return false;
    }
    return _canReload(tab) && await _reload(tab, _ReloadMode.discardEdits);
  }

  /// The disk notice's Reload button, an explicit choice to discard edits.
  /// The replacement is still one undoable edit in the document.
  Future<bool> reloadFromDisk(DocumentTab tab) => _canReload(tab)
      ? _reload(tab, _ReloadMode.discardEdits)
      : Future.value(false);

  /// The disk notice's Keep Mine button: keep editing, and let the next save
  /// replace the version now on disk. A later outside change is still caught.
  void keepMine(DocumentTab tab) {
    final baseline = tab.baseline;
    final digest = tab._diskDigest;
    if (tab.disk != DiskState.changed || baseline == null || digest == null) {
      return;
    }
    tab.baseline = baseline.copyWith(sha256: digest);
    _markDisk(tab, DiskState.current);
  }

  bool _canReload(DocumentTab tab) =>
      !interactionLocked &&
      !tab.busy &&
      tab.path != null &&
      _documents.contains(tab) &&
      !tab.editor.isBusy &&
      tab.editor.error == null;

  Future<bool> _reload(DocumentTab tab, _ReloadMode mode) async {
    tab.busy = true;
    _notify();
    try {
      final document = await store.load(tab.path!);
      if (_disposed || !_documents.contains(tab)) return false;
      if (mode == _ReloadMode.onlyIfClean && tab.editor.isDirty) {
        // Edited while the file was being read: ask rather than discard.
        _markDisk(tab, DiskState.changed, digest: document.sha256);
        return false;
      }
      tab.baseline = document;
      tab.path = document.file.path;
      tab.disk = DiskState.current;
      tab._diskDigest = null;
      tab.editor.revertTo(document);
      return true;
    } catch (error) {
      _error = 'Could not reload ${tab.name}: $error';
      return false;
    } finally {
      tab.busy = false;
      _notify();
    }
  }

  /// Compares each saved document with its file, typically when the window
  /// regains focus. A tab without edits silently takes the new version, a tab
  /// with edits shows a notice instead, and a vanished file is flagged so
  /// Save creates it again. File stamps avoid rehashing unchanged files.
  Future<void> checkDisk() =>
      _diskCheck ??= _checkDisk().whenComplete(() => _diskCheck = null);

  Future<void>? _diskCheck;

  Future<void> _checkDisk() async {
    for (final tab in List.of(_documents)) {
      if (_disposed || interactionLocked) return;
      if (tab.busy || tab.editor.isBusy || !_documents.contains(tab)) continue;
      await _checkTab(tab, _CleanTabChange.reload);
    }
  }

  Future<void> _checkTab(DocumentTab tab, _CleanTabChange clean) async {
    final path = tab.path;
    final baseline = tab.baseline;
    if (path == null || baseline == null || tab.editor.error != null) return;
    FileStamp? stamp;
    String? digest;
    try {
      stamp = await store.stamp(path);
      final verified = tab._verified;
      if (stamp != null &&
          verified != null &&
          identical(verified.baseline, baseline) &&
          verified.stamp == stamp) {
        return;
      }
      digest = stamp == null ? null : await store.existingDigest(path);
    } on Object {
      // Unreadable or no longer a regular file: the next save reports it.
      return;
    }
    if (_disposed ||
        !_documents.contains(tab) ||
        !identical(tab.baseline, baseline)) {
      return;
    }
    if (stamp == null || digest == null) {
      _markDisk(tab, DiskState.missing);
    } else if (digest == baseline.sha256) {
      tab._verified = (baseline: baseline, stamp: stamp);
      _markDisk(tab, DiskState.current);
    } else if (clean == _CleanTabChange.reload &&
        !tab.editor.isDirty &&
        _canReload(tab)) {
      await _reload(tab, _ReloadMode.onlyIfClean);
    } else {
      _markDisk(tab, DiskState.changed, digest: digest);
    }
  }

  void _markDisk(DocumentTab tab, DiskState state, {String? digest}) {
    if (tab.disk == state && tab._diskDigest == digest) return;
    tab.disk = state;
    tab._diskDigest = digest;
    _notify();
  }

  /// The digest a save must find on disk: none when the file vanished, so
  /// the save creates it again rather than failing to replace it.
  String? _expectedDigest(DocumentTab tab) =>
      tab.disk == DiskState.missing ? null : tab.baseline!.sha256;

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
    if (tab.editor.isLoading || tab.editor.error != null) return false;
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
          digest = _expectedDigest(tab);
        } else {
          digest = await store.existingDigest(target);
          if (digest != null &&
              !await _dialog(() => dialogs.confirmReplace(target))) {
            return false;
          }
        }
      } else {
        target = tab.path!;
        digest = _expectedDigest(tab);
      }
      _saveTargets[tab] = (path: target, digest: digest);
      final result = await tab.editor.save(access: access);
      return result != null;
    } catch (error) {
      _error = 'Could not save ${tab.name}: $error';
      // An outside change or deletion is the usual cause. The document's own
      // notice then explains it and offers Reload or Keep Mine.
      await _checkTab(tab, _CleanTabChange.flag);
      if (tab.disk != DiskState.current) _error = null;
      return false;
    } finally {
      _saveTargets.remove(tab);
      tab.busy = false;
      _notify();
    }
  }

  Future<bool> closeTab(DocumentTab tab) async {
    if (interactionLocked ||
        tab.busy ||
        !_documents.contains(tab) ||
        !_closingTabs.add(tab)) {
      return false;
    }
    try {
      if (!await _confirmTab(tab) || tab.busy) return false;
      _remove(tab);
      _notify();
      return true;
    } finally {
      _closingTabs.remove(tab);
    }
  }

  Future<bool> _confirmTab(DocumentTab tab) async {
    if (tab.busy || tab.editor.isSaving) return false;
    if (!tab.editor.isDirty) return true;
    final reviewedText = tab.editor.text.text;
    _active = tab;
    _notify();
    final choice = await _dialog(() => dialogs.chooseClose(tab.name));
    if (tab.busy || tab.editor.isSaving) return false;
    switch (choice) {
      case CloseChoice.cancel:
        return false;
      case CloseChoice.discard:
        return tab.editor.text.text == reviewedText;
      case CloseChoice.save:
        return await _save(tab, access: EditorSaveAccess.confirmedClose) &&
            !tab.editor.isDirty;
    }
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

  String _pathKey(String path) => _paths.canonicalize(path);

  /// A failed native destruction must not leave the surviving window locked.
  void quitFailed(Object error) {
    _quitAccepted = false;
    _error = 'Could not close Planchette: $error';
    _notify();
  }

  void clearError() {
    _error = null;
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
