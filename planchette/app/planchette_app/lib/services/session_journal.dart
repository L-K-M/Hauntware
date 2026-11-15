// The hot-exit journal (A2): every open window's documents, and the text of
// each one with unsaved changes, kept in the app's private data folder so a
// quit need not ask about them and a crash or an Android process kill does
// not lose them. The next launch reopens them.
//
// One file per window, `window-<id>.json`, replaced atomically and
// owner-only. A document's text is in it only until the document is saved
// or discarded: closing a tab rewrites the file at once, and closing a
// window (whose documents were asked about) deletes it. Nothing here is
// synced or uploaded.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_editor/planchette_editor.dart';
import 'package:seance_core/catalog.dart'
    show AtomicFilePrivacy, AtomicFileWriter;
import 'package:seance_core/seance_core.dart' show restrictDirectoryToOwner;

import 'app_settings.dart';
import 'document_windows.dart';
import 'document_workspace.dart';
import 'session_state.dart';

/// A window's journal as the store found it: its file's [id] and contents.
typedef KeptWindow = ({String id, SessionWindow window});

/// The journal's files: one per window in [directory], which only this
/// user can enter.
final class SessionJournalStore {
  SessionJournalStore(this.directory);

  final Directory directory;

  /// Held for the process's life once [acquire] succeeds.
  RandomAccessFile? _lock;

  static final _windowFile = RegExp(r'^window-([0-9a-f]{16})\.json$');

  /// Whether this process now owns the journal. A second running instance
  /// finds it locked: it restores and keeps nothing, so the first one's
  /// session is never taken over or overwritten.
  Future<bool> acquire() async {
    if (_lock != null) return true;
    try {
      await _prepareDirectory();
      final file = await File(
        paths.join(directory.path, '.lock'),
      ).open(mode: FileMode.append);
      try {
        await file.lock(FileLock.exclusive);
      } on FileSystemException {
        await file.close();
        return false;
      }
      _lock = file;
      return true;
    } on FileSystemException {
      return false;
    }
  }

  Future<void> _prepareDirectory() async {
    await directory.create(recursive: true);
    restrictDirectoryToOwner(directory);
  }

  /// Every window file that reads as a journal, oldest first so the main
  /// window gets the session the user had longest. Unreadable files are
  /// skipped and left in place.
  Future<List<KeptWindow>> readAll() async {
    final found = <({String id, SessionWindow window, DateTime modified})>[];
    try {
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is! File) continue;
        final match = _windowFile.firstMatch(paths.basename(entry.path));
        if (match == null) continue;
        try {
          final window = SessionWindow.fromJson(
            jsonDecode(await entry.readAsString()),
          );
          if (window == null) continue;
          found.add((
            id: match.group(1)!,
            window: window,
            modified: (await entry.stat()).modified,
          ));
        } on Object {
          // A file another version or a crash left unreadable restores
          // nothing; it is not this launch's to delete.
          continue;
        }
      }
    } on FileSystemException {
      return const [];
    }
    found.sort((a, b) => a.modified.compareTo(b.modified));
    return [for (final kept in found) (id: kept.id, window: kept.window)];
  }

  Future<void> write(String id, SessionWindow window) async {
    await _prepareDirectory();
    await const AtomicFileWriter().write(
      _file(id),
      jsonEncode(window.toJson()),
      privacy: AtomicFilePrivacy.ownerOnly,
    );
  }

  Future<void> delete(String id) async {
    try {
      await _file(id).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }

  /// Deletes every window file: the user turned hot exit off.
  Future<void> clear() async {
    try {
      await for (final entry in directory.list(followLinks: false)) {
        if (entry is File && _windowFile.hasMatch(paths.basename(entry.path))) {
          await entry.delete();
        }
      }
    } on PathNotFoundException {
      // Nothing was ever kept.
    }
  }

  File _file(String id) => File(paths.join(directory.path, 'window-$id.json'));

  /// A fresh window file id.
  static String newId() {
    final random = Random.secure();
    return [
      for (var i = 0; i < 8; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
  }
}

/// Keeps one workspace's window file current.
///
/// A change to what the window holds (a tab opened or closed, a document
/// becoming clean or dirty, another active tab) is written at once, so a
/// discarded document's text leaves the disk with it. Typing is written
/// [delay] after it pauses, which bounds what a crash or process kill can
/// lose without writing on every keystroke.
final class WorkspaceJournal {
  WorkspaceJournal({
    required this.workspace,
    required this.store,
    required this.id,
    this.delay = defaultDelay,
    this.onError,
  });

  static const defaultDelay = Duration(milliseconds: 500);

  final DocumentWorkspace workspace;
  final SessionJournalStore store;
  final String id;
  final Duration delay;

  /// Told once about the first write that fails; later failures of the same
  /// run stay quiet until a write succeeds again.
  final void Function(Object error)? onError;

  final _editors = <EditorController>{};
  Timer? _timer;
  SessionWindow? _written;
  Future<bool> _tail = Future.value(true);
  bool _failing = false;
  bool _running = false;

  void start() {
    if (_running) return;
    _running = true;
    workspace.addListener(_workspaceChanged);
    workspace.keepUnsavedOnQuit = flush;
    _workspaceChanged();
  }

  void stop() {
    if (!_running) return;
    _running = false;
    _timer?.cancel();
    workspace.removeListener(_workspaceChanged);
    if (workspace.keepUnsavedOnQuit == flush) {
      workspace.keepUnsavedOnQuit = null;
    }
    for (final editor in _editors) {
      editor.removeListener(_editorChanged);
    }
    _editors.clear();
  }

  /// Writes what the window holds now and answers whether it is on disk.
  Future<bool> flush() {
    _timer?.cancel();
    return _write();
  }

  void _workspaceChanged() {
    if (!_running) return;
    final current = {for (final tab in workspace.documents) tab.editor};
    for (final editor in _editors.difference(current)) {
      editor.removeListener(_editorChanged);
    }
    for (final editor in current.difference(_editors)) {
      editor.addListener(_editorChanged);
    }
    _editors
      ..clear()
      ..addAll(current);
    final snapshot = workspace.sessionSnapshot();
    final written = _written;
    if (written == null || !_sameShape(written, snapshot)) {
      _timer?.cancel();
      unawaited(_write(snapshot));
    } else {
      _editorChanged();
    }
  }

  /// Every keystroke and caret move: wait for a pause.
  void _editorChanged() {
    if (!_running) return;
    _timer?.cancel();
    _timer = Timer(delay, () => unawaited(_write()));
  }

  Future<bool> _write([SessionWindow? snapshot]) {
    final next = snapshot ?? workspace.sessionSnapshot();
    // Writes run one after another, so the last one wins on disk.
    return _tail = _tail.then((_) async {
      final written = _written;
      if (written != null && _sameContent(written, next) && !_failing) {
        return true;
      }
      try {
        await store.write(id, next);
        _written = next;
        _failing = false;
        return true;
      } on Object catch (error) {
        if (!_failing) onError?.call(error);
        _failing = true;
        return false;
      }
    });
  }

  /// Whether [a] and [b] keep the same documents in the same states:
  /// differing only in text or caret, a write may wait for a pause.
  static bool _sameShape(SessionWindow a, SessionWindow b) {
    if (a.active != b.active || a.tabs.length != b.tabs.length) return false;
    for (var i = 0; i < a.tabs.length; i++) {
      final left = a.tabs[i];
      final right = b.tabs[i];
      if (left.path != right.path ||
          left.untitledName != right.untitledName ||
          (left.text == null) != (right.text == null)) {
        return false;
      }
    }
    return true;
  }

  static bool _sameContent(SessionWindow a, SessionWindow b) {
    if (!_sameShape(a, b)) return false;
    for (var i = 0; i < a.tabs.length; i++) {
      final left = a.tabs[i];
      final right = b.tabs[i];
      // Strings are immutable: an unchanged buffer hands out the same one.
      if (!identical(left.text, right.text) && left.text != right.text) {
        return false;
      }
      if (left.metadata != right.metadata ||
          left.baselineSha256 != right.baselineSha256 ||
          left.line != right.line ||
          left.column != right.column) {
        return false;
      }
    }
    return true;
  }
}

/// The journal for the whole app: which workspaces it keeps, and whether
/// it keeps any, following [settings]' [UnsavedOnQuit] while it runs.
final class SessionJournal {
  SessionJournal({
    required this.store,
    required this.settings,
    this.delay = WorkspaceJournal.defaultDelay,
    this.onError,
  });

  final SessionJournalStore store;
  final SettingsController settings;
  final Duration delay;

  /// Told when a window file cannot be written, with that window's
  /// workspace, so its banner can say its changes may not be kept.
  final void Function(DocumentWorkspace workspace, Object error)? onError;

  final _journals = <DocumentWorkspace, WorkspaceJournal>{};
  final _ids = <DocumentWorkspace, String>{};
  bool _owned = false;
  bool _enabled = false;

  /// Set once a quit was accepted: the teardown that follows closes windows
  /// and tabs, and none of that may reach the files the next launch reads.
  bool _frozen = false;
  DocumentWindows? _windows;
  final _watched = <DocumentWindow>{};

  bool get isEnabled => _enabled;

  bool get _wanted => settings.value.unsavedOnQuit == UnsavedOnQuit.keep;

  /// Takes the journal and answers what it kept from the last session:
  /// nothing when hot exit is off (whose files it then deletes) or another
  /// instance holds the journal.
  Future<List<KeptWindow>> open() async {
    _owned = await store.acquire();
    settings.addListener(_settingsChanged);
    if (!_owned) return const [];
    _enabled = _wanted;
    if (!_enabled) {
      await _clear();
      return const [];
    }
    return store.readAll();
  }

  /// Keeps [workspace] from now on, in the file [id] when it continues a
  /// kept window.
  void attach(DocumentWorkspace workspace, {String? id}) {
    _ids[workspace] = id ?? _ids[workspace] ?? SessionJournalStore.newId();
    if (_enabled) _startFor(workspace);
  }

  /// Stops keeping [workspace] and deletes its file: its window closed, and
  /// its documents were asked about.
  Future<void> detach(DocumentWorkspace workspace) async {
    if (_frozen) return;
    _journals.remove(workspace)?.stop();
    final id = _ids.remove(workspace);
    if (id == null || !_owned) return;
    try {
      await store.delete(id);
    } on FileSystemException catch (error) {
      onError?.call(workspace, error);
    }
  }

  /// Writes every kept window now: Android's pause, before the system may
  /// end the process.
  Future<void> flushAll() async {
    await Future.wait([
      for (final journal in _journals.values) journal.flush(),
    ]);
  }

  /// Reopens [kept] into [windows]' main window and new windows as the
  /// runner allows, merging into the main window what it cannot open, and
  /// then keeps every window as it comes and goes.
  Future<void> restoreInto(
    DocumentWindows windows,
    List<KeptWindow> kept,
  ) async {
    final adopted = <DocumentWorkspace, String>{};
    final merged = <String>[];
    final main = windows.windows.firstOrNull;
    // A window that kept nothing (its documents all closed) reopens as
    // nothing: its file only goes.
    final restorable = [
      for (final window in kept)
        if (window.window.tabs.isNotEmpty) window,
    ];
    merged.addAll([
      for (final window in kept)
        if (window.window.tabs.isEmpty) window.id,
    ]);
    if (main != null) {
      for (final (index, window) in restorable.indexed) {
        final target = index == 0 ? main : await windows.openWindow() ?? main;
        await target.workspace.restoreSession(window.window);
        if (adopted.containsKey(target.workspace)) {
          merged.add(window.id);
        } else {
          adopted[target.workspace] = window.id;
        }
      }
    }
    for (final MapEntry(key: workspace, value: id) in adopted.entries) {
      attach(workspace, id: id);
    }
    watch(windows);
    // The merged windows' documents are in another window's file now.
    await flushAll();
    for (final id in merged) {
      await store.delete(id);
    }
  }

  /// Reopens everything [kept] into the one [workspace] a phone has, and
  /// keeps that workspace from now on in a single file.
  Future<void> restoreWorkspace(
    DocumentWorkspace workspace,
    List<KeptWindow> kept,
  ) async {
    for (final window in kept) {
      if (window.window.tabs.isEmpty) continue;
      await workspace.restoreSession(window.window);
    }
    attach(workspace, id: kept.firstOrNull?.id);
    await flushAll();
    for (final window in kept.skip(1)) {
      await store.delete(window.id);
    }
  }

  /// Keeps every window [windows] opens, and forgets each one it closes.
  void watch(DocumentWindows windows) {
    _windows = windows;
    windows.addListener(_windowsChanged);
    _windowsChanged();
  }

  /// Stops every write once a quit was accepted, after the windows were
  /// flushed by their own consent; [thaw] undoes it when the quit fails.
  void freeze() {
    if (_frozen) return;
    _frozen = true;
    for (final journal in _journals.values) {
      journal.stop();
    }
    _journals.clear();
  }

  /// The quit did not happen after all: keep journaling what is open.
  void thaw() {
    if (!_frozen) return;
    _frozen = false;
    // The setting may have changed while the quit was under way.
    _settingsChanged();
    if (_enabled) {
      for (final workspace in _ids.keys) {
        _startFor(workspace);
      }
    }
    _windowsChanged();
  }

  void _windowsChanged() {
    final windows = _windows;
    if (windows == null || _frozen) return;
    final open = windows.windows.toSet();
    for (final closed in _watched.difference(open)) {
      unawaited(detach(closed.workspace));
    }
    for (final opened in open.difference(_watched)) {
      attach(opened.workspace);
    }
    _watched
      ..clear()
      ..addAll(open);
  }

  void _startFor(DocumentWorkspace workspace) {
    if (_frozen || _journals.containsKey(workspace)) return;
    final journal = WorkspaceJournal(
      workspace: workspace,
      store: store,
      id: _ids[workspace]!,
      delay: delay,
      onError: (error) => onError?.call(workspace, error),
    );
    _journals[workspace] = journal;
    journal.start();
  }

  void _settingsChanged() {
    if (!_owned || _frozen || _wanted == _enabled) return;
    _enabled = _wanted;
    if (_enabled) {
      for (final workspace in _ids.keys) {
        _startFor(workspace);
      }
      return;
    }
    for (final journal in _journals.values) {
      journal.stop();
    }
    _journals.clear();
    unawaited(_clear());
  }

  Future<void> _clear() async {
    try {
      await store.clear();
    } on FileSystemException catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
  }

  void dispose() {
    settings.removeListener(_settingsChanged);
    _windows?.removeListener(_windowsChanged);
    for (final journal in _journals.values) {
      journal.stop();
    }
    _journals.clear();
  }
}
