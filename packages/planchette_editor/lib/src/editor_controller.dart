import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart'
    hide SearchResult, findSearchMatches, searchText;

import 'code_editing_controller.dart';

enum EditorSaveMode { local, primary }

enum EditorSaveAccess { normal, confirmedClose }

class EditorSaveResult {
  const EditorSaveResult({
    required this.publishRequested,
    required this.published,
    required this.hasUnsavedChanges,
  });
  final bool publishRequested;
  final bool published;
  final bool hasUnsavedChanges;
}

/// One buffer and its view state. Keep this controller alive while its document
/// is in a background tab; dispose it only when the document actually closes.
class EditorController extends ChangeNotifier {
  EditorController({
    required String displayPath,
    String? initialText,
    this.loadDocument,
    this.saveDocument,
    this.onSaved,
    this.onPublish,
    CaseFolder? caseFolder,
  }) : _displayPath = displayPath,
       _fold = caseFolder ?? _defaultCaseFolder {
    text = CodeEditingController(language: syntaxLanguageFor(displayPath));
    text.addListener(_textChanged);
    search.addListener(_queryChanged);
    if (initialText != null) {
      _installText(initialText);
    } else {
      _loading = loadDocument != null;
    }
  }

  final Future<TextDocument> Function()? loadDocument;
  final Future<String> Function(String text, TextDocument? baseline)?
  saveDocument;
  Future<void> Function()? onSaved;
  Future<bool> Function()? onPublish;

  /// How a case-insensitive find compares text. Defaults to
  /// [String.toLowerCase]; a host can supply a fold that fixes case
  /// differences the default misses while keeping the document's length —
  /// Greek final sigma, a locale's dotted and dotless i, canonical Cherokee
  /// forms. A fold that changes the *document's* length cannot be applied,
  /// because matches are located in the folded text and their offsets would
  /// stop addressing the original; the search then compares exactly and says
  /// so through [caseFoldingLimited]. Expanding `ß` to `ss` — what Unicode
  /// *full* case folding does — needs a folded-offset map, not a different
  /// fold, so do not promise it here.
  final CaseFolder _fold;

  static String _defaultCaseFolder(String value) => value.toLowerCase();

  late final CodeEditingController text;
  final search = TextEditingController();
  final replacement = TextEditingController();
  final editorFocus = FocusNode();
  final searchFocus = FocusNode();
  final replacementFocus = FocusNode();
  final scroll = ScrollController();
  final undoController = UndoHistoryController();

  TextDocument? _document;
  String _displayPath;
  String _savedText = '';
  String? _error;
  bool _loading = false;
  bool _saving = false;
  bool _disposed = false;
  bool _editingLocked = false;
  final Set<Object> _viewLocks = {};
  bool _searchOpen = false;
  bool _replaceOpen = false;
  bool _caseSensitive = false;
  CaseFolding _caseFolding = CaseFolding.exact;
  bool _updatingSearch = false;
  List<TextRange> _matches = const [];
  int _activeMatch = -1;
  int _revision = 0;
  int _revealRequest = 0;
  String _lastText = '';
  String? _lastQuery;
  String _languageProbe = '';
  String? _metricsText;
  List<int> _lineStarts = const [0];
  int _bytes = 0;
  Future<void>? _initialization;
  Future<bool>? _closeDecision;

  String get displayPath => _displayPath;
  set displayPath(String value) {
    if (_displayPath == value) return;
    _displayPath = value;
    _detectLanguage();
    _notify();
  }

  TextDocument? get document => _document;
  String? get error => _error;
  bool get isLoading => _loading;
  bool get isSaving => _saving;
  bool get isBusy => _loading || _saving;
  bool get isDirty => !_loading && text.text != _savedText;
  bool get canSave => !isBusy && !editingLocked && _error == null;
  bool get canPublish => onPublish != null;
  bool get searchOpen => _searchOpen;
  bool get replaceOpen => _replaceOpen;
  bool get caseSensitive => _caseSensitive;

  /// True when the last case-insensitive search had to compare exactly
  /// because this text could not be lowercased without moving its offsets.
  /// The find bar says so rather than showing a short count as if it were
  /// complete.
  bool get caseFoldingLimited => _caseFolding == CaseFolding.lengthChanging;
  List<TextRange> get matches => _matches;
  int get activeMatch => _activeMatch;
  int get revealRequest => _revealRequest;

  /// Whether edits, saves and reloads are refused. Two owners can lock: the
  /// host, through [setEditingLocked], and the mounted [PlanchetteEditor],
  /// through its `editingLocked` parameter. Either lock holds on its own, and
  /// each owner clears only its own, so rebuilding the view with its default
  /// `false` never unlocks a document the host locked.
  bool get editingLocked => _editingLocked || _viewLocks.isNotEmpty;
  set editingLocked(bool value) => setEditingLocked(value);

  /// The host's lock. [notify] is false only for hosts that update several
  /// controllers and notify once themselves.
  void setEditingLocked(bool value, {bool notify = true}) {
    if (_editingLocked == value) return;
    _editingLocked = value;
    if (notify) _notify();
  }

  /// A mounted view's lock, applied during its build, so it does not
  /// notify. Each view passes itself as [view] and clears only its own
  /// lock: when a host remounts the editor elsewhere in the same frame, the
  /// old view is disposed after the new one has locked. Hosts use
  /// [setEditingLocked] instead.
  void setViewEditingLocked(Object view, bool value) =>
      value ? _viewLocks.add(view) : _viewLocks.remove(view);

  List<int> get lineStarts {
    _updateMetrics();
    return _lineStarts;
  }

  int get byteCount {
    _updateMetrics();
    return _bytes;
  }

  (int, int) get caretLineColumn {
    final selection = text.selection;
    if (!selection.isValid) return (1, 1);
    final offset = selection.extentOffset.clamp(0, text.text.length);
    final starts = lineStarts;
    var lo = 0;
    var hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (lo + 1, offset - starts[lo] + 1);
  }

  Future<void> initialize() =>
      _initialization ??= _loading ? _load() : Future<void>.value();

  /// The host confirms any discard and refreshes a remote checkout first.
  Future<void> reload() async {
    if (isBusy || editingLocked || loadDocument == null) return;
    await _load();
  }

  Future<void> _load() async {
    final loader = loadDocument;
    if (loader == null || _disposed) return;
    _loading = true;
    _error = null;
    _notify();
    try {
      final loaded = await loader();
      if (_disposed) return;
      adoptDocument(loaded, replaceText: true);
    } catch (error) {
      if (!_disposed) _error = error.toString();
    } finally {
      _loading = false;
      _notify();
    }
  }

  /// Adopt Save As metadata without resetting the live selection or undo state.
  /// Replacing text is reserved for an explicitly confirmed reload.
  void adoptDocument(TextDocument document, {bool replaceText = false}) {
    _document = document;
    if (replaceText) _installText(document.text);
    _notify();
  }

  void _installText(String value) {
    _savedText = value;
    _lastText = value;
    text.value = TextEditingValue(
      text: value,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _detectLanguage();
    if (_searchOpen) _updateMatches(resetActive: true);
    if (scroll.hasClients) scroll.jumpTo(0);
    _revealRequest++;
  }

  void _detectLanguage() {
    _languageProbe = _leadingText(text.text);
    _applyLanguage(_languageProbe);
  }

  /// An untitled buffer has no extension to recognise, so the shebang machinery
  /// in [syntaxLanguageFor] is the only thing that can name its language. Watch
  /// the lead of the document while it is being typed, and re-recognise when
  /// that lead changes — but only then, so a keystroke deep inside a large
  /// document costs no more than the bound below.
  void _refreshLanguage() {
    final lead = _leadingText(text.text);
    if (lead == _languageProbe) return;
    _languageProbe = lead;
    _applyLanguage(lead);
  }

  void _applyLanguage(String lead) {
    final newline = lead.indexOf('\n');
    final language = syntaxLanguageFor(
      _displayPath,
      firstLine: newline < 0 ? lead : lead.substring(0, newline),
    );
    // Typing anywhere in the lead changes it on almost every keystroke while
    // leaving the answer alone. Only assign a real change: the field is a
    // plain one today, but a view that keys its highlighting off it should not
    // be handed the same value twice. Every language is a canonical
    // `SyntaxLanguages` instance, so identity is the comparison.
    if (identical(language, text.language)) return;
    text.language = language;
  }

  /// Bounds the per-keystroke language check. Every recogniser in
  /// [syntaxLanguageFor] looks at the start of the first line — a shebang is
  /// under a hundred characters — so a longer lead cannot change the answer.
  static const _languageProbeLimit = 4096;

  static String _leadingText(String value) =>
      value.length <= _languageProbeLimit
      ? value
      : value.substring(0, _languageProbeLimit);

  void _updateMetrics() {
    if (identical(_metricsText, text.text)) return;
    _metricsText = text.text;
    _lineStarts = lineStartOffsets(text.text);
    _bytes = utf8EncodedLength(text.text);
  }

  void _textChanged() {
    if (_updatingSearch || _disposed) return;
    if (text.text != _lastText) {
      _lastText = text.text;
      _revision++;
      _refreshLanguage();
      if (_searchOpen) _updateMatches(resetActive: false);
    }
    _notify();
  }

  Future<EditorSaveResult?> save({
    EditorSaveMode mode = EditorSaveMode.primary,
    EditorSaveAccess access = EditorSaveAccess.normal,
  }) async {
    final saver = saveDocument;
    if (isBusy ||
        _error != null ||
        saver == null ||
        _disposed ||
        (editingLocked && access != EditorSaveAccess.confirmedClose)) {
      return null;
    }
    _saving = true;
    _notify();
    final snapshot = text.text;
    final publishAction = onPublish;
    final afterSave = onSaved;
    final publish = mode == EditorSaveMode.primary && publishAction != null;
    try {
      final digest = await saver(snapshot, _document);
      _savedText = snapshot;
      final previous = _document;
      if (previous != null) {
        _document = previous.copyWith(text: snapshot, sha256: digest);
      }
      // These callbacks reconcile a committed disk write, and must finish even
      // when a route was removed during the write. Only UI notifications stop.
      var published = false;
      if (publish) {
        try {
          published = await publishAction();
        } finally {
          if (!published) await afterSave?.call();
        }
      } else {
        await afterSave?.call();
      }
      return EditorSaveResult(
        publishRequested: publish,
        published: published,
        hasUnsavedChanges: !_disposed && isDirty,
      );
    } finally {
      _saving = false;
      _notify();
    }
  }

  Future<bool> confirmClose(
    Future<bool> Function() askDiscard, {
    bool allowWhileSaving = false,
  }) async {
    if (_loading || (_saving && !allowWhileSaving)) return false;
    if (!isDirty) return true;
    final revision = _revision;
    final discard = await (_closeDecision ??= askDiscard().whenComplete(
      () => _closeDecision = null,
    ));
    // A native menu can start a save or edit while the dialog is pending.
    return discard &&
        (!_saving || allowWhileSaving) &&
        (_revision == revision || !isDirty);
  }

  void openSearch({bool replace = false}) {
    if (_loading || _error != null) return;
    final selection = text.selection;
    String? prefill;
    if (selection.isValid && !selection.isCollapsed) {
      final selected = selection.textInside(text.text);
      if (selected.isNotEmpty &&
          !selected.contains('\n') &&
          selected.length <= 200) {
        prefill = selected;
      }
    }
    _searchOpen = true;
    _replaceOpen = replace || _replaceOpen;
    if (prefill != null) search.text = prefill;
    _updateMatches(resetActive: true);
    search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: search.text.length,
    );
    searchFocus.requestFocus();
    _revealRequest++;
    _notify();
  }

  void closeSearch() {
    if (!_searchOpen) return;
    _searchOpen = false;
    _replaceOpen = false;
    _matches = const [];
    _activeMatch = -1;
    _lastQuery = null;
    _caseFolding = CaseFolding.exact;
    text.setSearchMatches(const [], -1);
    editorFocus.requestFocus();
    _notify();
  }

  void toggleReplace() {
    _replaceOpen = !_replaceOpen;
    _notify();
  }

  void toggleCaseSensitive() {
    _caseSensitive = !_caseSensitive;
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  void _queryChanged() {
    if (!_searchOpen || _disposed || search.text == _lastQuery) return;
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  void _updateMatches({required bool resetActive}) {
    _lastQuery = search.text;
    final result = _searchOpen
        ? searchText(
            text.text,
            search.text,
            caseSensitive: _caseSensitive,
            fold: _fold,
          )
        : const SearchResult(matches: [], caseFolding: CaseFolding.exact);
    // Reported, not hidden: a case-insensitive search that could not fold this
    // text found fewer matches than the user asked for.
    _caseFolding = result.caseFolding;
    _matches = result.matches;
    if (_matches.isEmpty) {
      _activeMatch = -1;
    } else if (resetActive ||
        _activeMatch < 0 ||
        _activeMatch >= _matches.length) {
      final caret = text.selection.isValid ? text.selection.start : 0;
      final index = _matches.indexWhere((match) => match.start >= caret);
      _activeMatch = index < 0 ? 0 : index;
    }
    _updatingSearch = true;
    try {
      text.setSearchMatches(_matches, _activeMatch);
    } finally {
      _updatingSearch = false;
    }
  }

  void nextMatch() => _stepMatch(1);
  void previousMatch() => _stepMatch(-1);
  void _stepMatch(int delta) {
    if (_matches.isEmpty) return;
    _activeMatch = (_activeMatch + delta + _matches.length) % _matches.length;
    text.setSearchMatches(_matches, _activeMatch);
    final match = _matches[_activeMatch];
    text.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
    _revealRequest++;
    _notify();
  }

  void replaceCurrent() {
    if (editingLocked || isBusy || _activeMatch < 0 || _matches.isEmpty) {
      return;
    }
    final match = _matches[_activeMatch];
    final value = text.text.replaceRange(
      match.start,
      match.end,
      replacement.text,
    );
    text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(
        offset: match.start + replacement.text.length,
      ),
    );
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  /// Replace every literal occurrence, including matches beyond the display cap.
  /// Offsets come from the original text so replacements never match themselves.
  void replaceAll() {
    if (editingLocked || isBusy || search.text.isEmpty) return;
    final source = text.text;
    final matches = findSearchMatches(
      source,
      search.text,
      caseSensitive: _caseSensitive,
      limit: source.length + 1,
      fold: _fold,
    );
    if (matches.isEmpty) return;
    final buffer = StringBuffer();
    var offset = 0;
    for (final match in matches) {
      buffer.write(source.substring(offset, match.start));
      buffer.write(replacement.text);
      offset = match.end;
    }
    buffer.write(source.substring(offset));
    final value = buffer.toString();
    final caret = matches.first.start + replacement.text.length;
    text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: caret),
    );
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    text.removeListener(_textChanged);
    search.removeListener(_queryChanged);
    text.dispose();
    search.dispose();
    replacement.dispose();
    editorFocus.dispose();
    searchFocus.dispose();
    replacementFocus.dispose();
    scroll.dispose();
    undoController.dispose();
    super.dispose();
  }
}
