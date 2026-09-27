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

  String get name => path == null ? untitledName : paths.basename(path!);
}

/// One file that failed to open, for callers that aggregate batch results.
typedef _OpenFailure = ({String name, String message});

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
      final failures = <_OpenFailure>[];
      final reported = <String>{};
      for (final path in selected) {
        try {
          final failure = await _openDeduped(path);
          if (failure != null && reported.add(_pathKey(path))) {
            failures.add(failure);
          }
        } catch (error) {
          // One exceptional path must not abort the rest of the batch.
          if (reported.add(_pathKey(path))) {
            failures.add((name: _paths.basename(path), message: '$error'));
          }
        }
      }
      if (failures.isNotEmpty) {
        _error = _openFailureMessage(failures);
        _notify();
      }
    } catch (error) {
      _error = 'Could not open documents: $error';
      _notify();
    }
  }

  Future<void> open(String path) async {
    final failure = await _openDeduped(path);
    if (failure != null) {
      _error = _openFailureMessage([failure]);
      _notify();
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
    final listed = failures
        .take(maxListed)
        .map((failure) => '${failure.name} (${failure.message})')
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
      }),
    );
  }

  Future<_OpenFailure?> _open(String path) async {
    final existing = _findPath(path);
    if (existing != null) {
      _active = existing;
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
      failure = (name: tab.name, message: error);
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
    return failure;
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
