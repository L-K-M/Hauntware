import 'dart:async';

import 'package:flutter/material.dart';
import 'package:planchette_core/planchette_core.dart'
    hide SearchResult, findSearchMatches, searchText;
import 'package:planchette_core/planchette_core.dart'
    as core
    show
        deleteIndentBackward,
        deleteLines,
        duplicateLines,
        joinLines,
        moveLines;

import 'code_editing_controller.dart';

enum EditorSaveMode { local, primary }

enum EditorSaveAccess { normal, confirmedClose }

/// How the view scrolls to a caret that a command moved.
enum CaretReveal {
  /// Just far enough to show it, the way typing does: an edit or a jump the
  /// user can see the start of.
  nearest,

  /// A third of the way down the view, unless it is already in view: a jump
  /// to somewhere the user named, which may be far away.
  upperThird,
}

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
    goToLineInput.addListener(_goToLineEdited);
    for (final node in textFocusNodes) {
      node.addListener(() {
        if (node.hasFocus) _focusMemory = node;
      });
    }
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
  final goToLineInput = TextEditingController();
  final editorFocus = FocusNode();
  final searchFocus = FocusNode();
  final replacementFocus = FocusNode();
  final goToLineFocus = FocusNode();

  /// Every text field this editor owns: the document, find, replace and Go to
  /// Line. A host routing Cut, Copy, Paste or Select All from its own menus
  /// sends them to whichever of these has focus.
  late final List<FocusNode> textFocusNodes = List.unmodifiable([
    editorFocus,
    searchFocus,
    replacementFocus,
    goToLineFocus,
  ]);
  final scroll = ScrollController();
  final undoController = UndoHistoryController();

  /// The node to focus when this editor's tab becomes active. Deactivation
  /// unfocuses all three, so remembering the last-focused node lets a tab
  /// switch restore a focused find field instead of always the document.
  /// Falls back to the document when the remembered node is detached —
  /// the find or replace field it belonged to may have closed.
  FocusNode get _focusTarget =>
      _focusMemory?.context != null ? _focusMemory! : editorFocus;

  /// Focuses the field that last had focus in this editor (the document, or
  /// an open find or replace field), for a host showing this editor again.
  ///
  /// The request runs after the current frame's focus bookkeeping: a
  /// same-frame `unfocus` marks the enclosing scope for focus and would
  /// overwrite a request issued right now — last mark wins.
  void restoreFocus() {
    final target = _focusTarget;
    scheduleMicrotask(() {
      if (!_disposed) target.requestFocus();
    });
  }

  TextDocument? _document;
  String _displayPath;
  String _savedText = '';
  // A full-buffer comparison per call is O(document); the shell and status
  // bar ask several times per frame, so remember the answer per text pair.
  // Strings are immutable, so an identical pair always has the same answer.
  String? _dirtyText;
  String? _dirtySavedText;
  bool _dirty = false;
  String? _error;
  bool _loading = false;
  bool _saving = false;
  bool _disposed = false;
  bool _editingLocked = false;
  final Set<Object> _viewLocks = {};
  bool _searchOpen = false;
  bool _goToLineOpen = false;
  String? _invalidGoToLine;
  bool _replaceOpen = false;
  bool _caseSensitive = false;
  bool _wholeWord = false;
  CaseFolding _caseFolding = CaseFolding.exact;
  bool _updatingSearch = false;
  bool _updatingQuery = false;
  List<TextRange> _matches = const [];
  int _matchOffset = 0;
  bool _matchesMayContinue = false;
  int _activeMatch = -1;
  FocusNode? _focusMemory;
  int _revision = 0;
  int _revealRequest = 0;
  int _installGeneration = 0;
  int _caretRevealRequest = 0;
  CaretReveal _caretRevealPlacement = CaretReveal.nearest;
  ({String text, int offset, int bracket})? _lastBracketJump;
  String _lastText = '';
  String? _lastQuery;
  String _languageProbe = '';
  String? _metricsText;
  List<int> _lineStarts = const [0];
  int _bytes = 0;
  int _returns = 0;
  int _returnNewlines = 0;
  Future<void>? _initialization;
  Future<bool>? _closeDecision;
  Indentation? _chosenIndentation;
  Indentation? _detectedIndentation;
  Indentation? _preferredIndentation;

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
  bool get isDirty {
    if (_loading) return false;
    final current = text.text;
    if (!identical(current, _dirtyText) ||
        !identical(_savedText, _dirtySavedText)) {
      _dirtyText = current;
      _dirtySavedText = _savedText;
      _dirty = current != _savedText;
    }
    return _dirty;
  }

  bool get canSave => !isBusy && !editingLocked && _error == null;
  bool get canPublish => onPublish != null;
  bool get searchOpen => _searchOpen;
  bool get goToLineOpen => _goToLineOpen;

  /// Whether the Go to Line field holds input [submitGoToLine] could not
  /// read, until that input is edited or the field closes.
  bool get goToLineInputInvalid => _invalidGoToLine != null;
  bool get replaceOpen => _replaceOpen;
  bool get caseSensitive => _caseSensitive;

  /// Whether find and Replace All skip hits that run on into a word, such as
  /// `cat` inside `concat`.
  bool get wholeWord => _wholeWord;

  /// True when the last case-insensitive search had to compare exactly
  /// because this text could not be lowercased without moving its offsets.
  /// The find bar says so rather than showing a short count as if it were
  /// complete.
  bool get caseFoldingLimited => _caseFolding == CaseFolding.lengthChanging;

  /// The page of matches the find bar highlights and steps through: at most
  /// [searchMatchLimit] of them, so a minified file cannot flood the text
  /// with spans. [activeMatch] indexes this page.
  List<TextRange> get matches => _matches;
  int get activeMatch => _activeMatch;

  /// How many of the document's matches come before [matches], so a counter
  /// can number a match on a later page, such as 1,001 of 1,003.
  int get matchOffset => _matchOffset;

  /// Whether more matches may follow the last of [matches], unknown until
  /// the find bar pages there; a counter shows its total as a lower bound.
  bool get matchesMayContinue => _matchesMayContinue;
  int get revealRequest => _revealRequest;

  /// Increments whenever a whole buffer is installed: loaded, reloaded or
  /// reverted. The view gives each generation its own document field, so
  /// undo never crosses from the installed text back into the previous one.
  int get installGeneration => _installGeneration;

  /// Increments when a command moved the caret somewhere the view should
  /// scroll to; typing scrolls by itself, but a programmatic change does not.
  int get caretRevealRequest => _caretRevealRequest;

  /// How the view should scroll to the caret for the latest
  /// [caretRevealRequest].
  CaretReveal get caretRevealPlacement => _caretRevealPlacement;

  void _requestCaretReveal(CaretReveal placement) {
    _caretRevealPlacement = placement;
    _caretRevealRequest++;
  }

  /// Whether edits, saves and reloads are refused. Two owners can lock: the
  /// host, through [setEditingLocked], and the mounted [PlanchetteEditor],
  /// through its `editingLocked` parameter. Either lock holds on its own, and
  /// each owner clears only its own, so rebuilding the view with its default
  /// `false` never unlocks a document the host locked.
  bool get editingLocked => _editingLocked || _viewLocks.isNotEmpty;

  /// Sets the host's lock, like [setEditingLocked]. A mounted view's own lock
  /// still holds, so the getter can read true after setting false.
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

  /// One level of indentation for Tab, Shift+Tab and Enter, from the most
  /// specific source that has one: a level chosen for this document, the
  /// level its own lines use (re-checked after edits until they show one),
  /// the level its format mandates (tabs for Makefiles and Go), the host's
  /// [indentationPreference], and finally four spaces.
  Indentation get indentation =>
      _chosenIndentation ??
      _detectedIndentation ??
      requiredIndentationFor(_displayPath) ??
      _preferredIndentation ??
      const Indentation.spaces();

  /// Chooses the level for this document, overriding what its lines use.
  /// A host applying one setting to every document sets
  /// [indentationPreference] instead, so each file's convention still wins.
  set indentation(Indentation value) {
    if (_chosenIndentation == value) return;
    _chosenIndentation = value;
    _notify();
  }

  /// The host's level for documents that neither use nor mandate one yet,
  /// such as a new untitled document.
  Indentation? get indentationPreference => _preferredIndentation;
  set indentationPreference(Indentation? value) {
    if (_preferredIndentation == value) return;
    _preferredIndentation = value;
    _notify();
  }

  void _detectIndentation({bool reset = false}) {
    if (reset) _detectedIndentation = null;
    if (_chosenIndentation != null || _detectedIndentation != null) return;
    _detectedIndentation = detectIndentation(text.text);
  }

  List<int> get lineStarts {
    _updateMetrics();
    return _lineStarts;
  }

  int get byteCount {
    _updateMetrics();
    return _bytes;
  }

  /// Whether the buffer is small enough to highlight. Above
  /// [syntaxHighlightingMaxChars] it edits as plain text, and the status bar
  /// says so rather than leaving the missing colours unexplained.
  bool get highlightingEnabled =>
      text.text.length <= syntaxHighlightingMaxChars;

  /// The size the document has once saved: the buffer holds no byte-order
  /// mark, and saving writes each line break as the document's own ending,
  /// as `saveTextDocument` does by default. The buffer may hold LF breaks
  /// (loaded normalized), CRLF breaks (loaded as they were, or pasted), or
  /// a lone CR; each counts once. A host that saves raw line endings writes
  /// exactly [byteCount] bytes plus any byte-order mark instead.
  int get fileByteCount {
    final document = _document;
    if (document == null) return byteCount;
    _updateMetrics();
    // Folding to LF drops the CR of each CRLF and turns a lone CR into LF.
    final breaks = lineStarts.length - 1 + _returns - _returnNewlines;
    return byteCount -
        _returnNewlines +
        (document.lineEnding == LineEnding.crlf ? breaks : 0) +
        (document.hasUtf8Bom ? 3 : 0);
  }

  (int, int) get caretLineColumn {
    final selection = text.selection;
    if (!selection.isValid) return (1, 1);
    final offset = selection.extentOffset.clamp(0, text.text.length);
    final line = _lineIndexOf(offset);
    return (line + 1, offset - lineStarts[line] + 1);
  }

  /// The UTF-16 code units a selection covers and the lines it touches, in
  /// either direction; zero for a collapsed selection. Like the line
  /// commands, a selection that ends at the start of a line does not touch
  /// that line.
  ({int characters, int lines}) get selectionStats {
    final selection = text.selection;
    if (!selection.isValid || selection.isCollapsed) {
      return (characters: 0, lines: 0);
    }
    final length = text.text.length;
    final start = selection.start.clamp(0, length);
    final end = selection.end.clamp(0, length);
    if (end <= start) return (characters: 0, lines: 0);
    return (
      characters: end - start,
      lines: _lineIndexOf(end - 1) - _lineIndexOf(start) + 1,
    );
  }

  /// The 0-based line holding [offset], by binary search over [lineStarts].
  int _lineIndexOf(int offset) {
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
    return lo;
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

  /// Whether a command may change the buffer now: not while it loads, is
  /// locked or failed to load, and not while an input method composes, since
  /// the composition owns the text until it is committed.
  bool get canEditText =>
      !_loading &&
      !editingLocked &&
      _error == null &&
      text.selection.isValid &&
      !text.value.composing.isValid;

  /// Whether a command may move the caret now: not while the document loads
  /// or failed to load, and not while an input method composes. Moving the
  /// caret is not an edit, so a locked document allows it.
  bool get canMoveCaret =>
      !_loading &&
      _error == null &&
      text.selection.isValid &&
      !text.value.composing.isValid;

  /// Copies the selected lines, or the caret's line, below themselves.
  bool duplicateLines() => _applyLineEdit(core.duplicateLines);

  /// Swaps the selected lines, or the caret's line, with the neighbouring
  /// line. Returns false at the top or bottom of the document.
  bool moveLines(LineDirection direction) => _applyLineEdit(
    (text, base, extent) => core.moveLines(text, base, extent, direction),
  );

  /// Removes the selected lines, or the caret's line.
  bool deleteLines() => _applyLineEdit(core.deleteLines);

  /// Joins the selected lines, or the caret's line with the next one.
  bool joinLines() => _applyLineEdit(core.joinLines);

  /// Whether [toggleComment] can act: the buffer is editable and its
  /// language has a line-comment marker. Plain text, Markdown, JSON, XML and
  /// CSS have none.
  bool get canToggleComment =>
      canEditText && (text.language?.lineComments.isNotEmpty ?? false);

  /// Comments the touched lines with the language's line-comment marker, or
  /// uncomments them when all already carry one. See [toggleLineComments].
  bool toggleComment() {
    final markers = text.language?.lineComments;
    if (markers == null) return false;
    return _applyLineEdit(
      (text, base, extent) => toggleLineComments(text, base, extent, markers),
    );
  }

  bool _applyLineEdit(
    LineEdit? Function(String text, int base, int extent) command,
  ) {
    if (!canEditText) return false;
    final selection = text.selection;
    final edit = command(
      text.text,
      selection.baseOffset,
      selection.extentOffset,
    );
    if (edit == null) return false;
    _requestCaretReveal(CaretReveal.nearest);
    text.value = TextEditingValue(
      text: edit.text,
      selection: TextSelection(
        baseOffset: edit.selectionBase,
        extentOffset: edit.selectionExtent,
      ),
    );
    return true;
  }

  /// Moves the caret to the partner of the bracket beside it, on the same
  /// side, so a second jump returns; away from a bracket, to the closing
  /// bracket around it. With [extend] the other end of the selection stays.
  /// Returns false when there is nowhere to go.
  bool goToMatchingBracket({bool extend = false}) {
    if (!canMoveCaret) return false;
    final source = text.text;
    final selection = text.selection;
    final caret = selection.extentOffset;
    final last = _lastBracketJump;
    final jump = bracketJump(
      source,
      caret,
      text.syntaxTokens,
      preferred: last != null && last.text == source && last.offset == caret
          ? last.bracket
          : null,
    );
    if (jump == null) return false;
    _lastBracketJump = (
      text: source,
      offset: jump.offset,
      bracket: jump.bracket,
    );
    _requestCaretReveal(CaretReveal.nearest);
    text.selection = extend
        ? selection.extendTo(TextPosition(offset: jump.offset))
        : TextSelection.collapsed(offset: jump.offset);
    return true;
  }

  void _installText(String value) {
    _savedText = value;
    _lastText = value;
    text.value = TextEditingValue(
      text: value,
      selection: const TextSelection.collapsed(offset: 0),
    );
    _detectLanguage();
    _detectIndentation(reset: true);
    if (_searchOpen) _updateMatches(resetActive: true);
    if (scroll.hasClients) scroll.jumpTo(0);
    _revealRequest++;
    _installGeneration++;
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
    _returns = 0;
    _returnNewlines = 0;
    final value = text.text;
    for (var i = value.indexOf('\r'); i >= 0; i = value.indexOf('\r', i + 1)) {
      _returns++;
      if (i + 1 < value.length && value.codeUnitAt(i + 1) == 0x0a) {
        _returnNewlines++;
      }
    }
  }

  void _textChanged() {
    if (_updatingSearch || _disposed) return;
    if (text.text != _lastText) {
      _lastText = text.text;
      _revision++;
      _refreshLanguage();
      _detectIndentation();
      if (_searchOpen) _updateMatches(resetActive: false);
    }
    _notify();
  }

  // The indentation keys go through _applyLineEdit like the line commands:
  // one lock and composition check, and a caret reveal, since a programmatic
  // edit does not scroll the field the way typing does.

  /// Tab. Indents every selected line, or inserts indentation at the caret.
  bool indent() => _applyLineEdit(
    (text, base, extent) => indentLines(text, base, extent, indentation),
  );

  /// Shift+Tab. Removes one level of indentation from every selected line.
  bool outdent() => _applyLineEdit(
    (text, base, extent) => outdentLines(text, base, extent, indentation),
  );

  /// Enter. Starts the new line at the current indentation, one level deeper
  /// after an opening bracket, and splits an empty bracket pair. The view
  /// calls this for hardware Enter; a newline that a software keyboard or
  /// input method inserts arrives as text and is not indented.
  bool insertNewline() => _applyLineEdit(
    (text, base, extent) => insertIndentedNewline(
      text,
      base,
      extent,
      indentation,
      indentAfterColon: this.text.language?.indentAfterColon ?? false,
    ),
  );

  /// Whether Backspace at the caret removes a whole level of space
  /// indentation rather than one character.
  bool get canDeleteIndentBackward => _indentBackward() != null;

  /// Backspace inside space indentation. Returns false when an ordinary
  /// one-character Backspace applies instead.
  bool deleteIndentBackward() {
    final edit = _indentBackward();
    return edit != null && _applyLineEdit((_, _, _) => edit);
  }

  LineEdit? _indentBackward() {
    final selection = text.selection;
    if (!canEditText || !selection.isCollapsed) return null;
    return core.deleteIndentBackward(
      text.text,
      selection.baseOffset,
      indentation,
    );
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
    // Assign the prefill while the query listener cannot scan — still
    // closed on a fresh open, guarded on re-entry — so the explicit call
    // below stays the single whole-document scan on every path.
    _updatingQuery = true;
    try {
      if (prefill != null) search.text = prefill;
    } finally {
      _updatingQuery = false;
    }
    _searchOpen = true;
    _replaceOpen = replace || _replaceOpen;
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
    if (_focusMemory != editorFocus) _focusMemory = null;
    _matches = const [];
    _matchOffset = 0;
    _matchesMayContinue = false;
    _activeMatch = -1;
    _lastQuery = null;
    _caseFolding = CaseFolding.exact;
    text.setSearchMatches(const [], -1);
    editorFocus.requestFocus();
    _notify();
  }

  void openGoToLine() {
    if (_loading || _error != null) return;
    _goToLineOpen = true;
    _invalidGoToLine = null;
    final (line, _) = caretLineColumn;
    goToLineInput.value = TextEditingValue(
      text: '$line',
      selection: TextSelection(baseOffset: 0, extentOffset: '$line'.length),
    );
    goToLineFocus.requestFocus();
    _notify();
  }

  void closeGoToLine() {
    if (!_goToLineOpen) return;
    _goToLineOpen = false;
    _invalidGoToLine = null;
    if (_focusMemory == goToLineFocus) _focusMemory = null;
    editorFocus.requestFocus();
    _notify();
  }

  void _goToLineEdited() {
    if (_invalidGoToLine == null || goToLineInput.text == _invalidGoToLine) {
      return;
    }
    _invalidGoToLine = null;
    _notify();
  }

  /// Jumps to the go-to-line field's `line` or `line:column` and closes it.
  /// Returns false, leaving the field open, when the input is not a number,
  /// which [goToLineInputInvalid] then reports, or when the document cannot
  /// be navigated right now.
  bool submitGoToLine() {
    if (_loading || _error != null) return false;
    final match = RegExp(
      r'^\s*(\d+)\s*(?:[:,]\s*(\d+)\s*)?$',
    ).firstMatch(goToLineInput.text);
    if (match == null) {
      _invalidGoToLine = goToLineInput.text;
      _notify();
      return false;
    }
    // Digits too many for an int still mean "past the end"; goToLine clamps.
    int number(String? digits) =>
        digits == null ? 1 : int.tryParse(digits) ?? 0x7fffffff;
    _goToLineOpen = false;
    _invalidGoToLine = null;
    if (_focusMemory == goToLineFocus) _focusMemory = null;
    goToLine(number(match[1]), column: number(match[2]));
    return true;
  }

  /// Places the caret at 1-based [line] and [column], clamped to the
  /// document, focuses the editor and asks the view to scroll there.
  void goToLine(int line, {int column = 1}) {
    if (_loading || _error != null) return;
    final starts = lineStarts;
    final index = (line - 1).clamp(0, starts.length - 1);
    final start = starts[index];
    final end = index + 1 < starts.length
        ? starts[index + 1] - 1
        : text.text.length;
    var offset = (start + column - 1).clamp(start, end);
    // Columns count UTF-16 code units, like the status bar's; one that
    // falls between the halves of a surrogate pair lands before the pair.
    if (offset > start &&
        offset < text.text.length &&
        _isLowSurrogate(text.text.codeUnitAt(offset)) &&
        _isHighSurrogate(text.text.codeUnitAt(offset - 1))) {
      offset--;
    }
    text.selection = TextSelection.collapsed(offset: offset);
    _requestCaretReveal(CaretReveal.upperThird);
    editorFocus.requestFocus();
    _notify();
  }

  void toggleReplace() {
    _replaceOpen = !_replaceOpen;
    if (!_replaceOpen && _focusMemory == replacementFocus) {
      _focusMemory = searchFocus;
      // The collapsing field may hold focus; hand it to the find field now
      // rather than leaving primary focus on the enclosing scope. Only
      // steal when it really did — a host may share our focus scope.
      if (replacementFocus.hasFocus) restoreFocus();
    }
    _notify();
  }

  void toggleCaseSensitive() {
    _caseSensitive = !_caseSensitive;
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  void toggleWholeWord() {
    _wholeWord = !_wholeWord;
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  void _queryChanged() {
    if (!_searchOpen ||
        _disposed ||
        _updatingQuery ||
        search.text == _lastQuery) {
      return;
    }
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  void _updateMatches({required bool resetActive}) {
    _lastQuery = search.text;
    if (_searchOpen) {
      // Stay on the user's page: a new query or a replacement starts from
      // the caret, and an edit keeps the page that was showing.
      final caret = text.selection.isValid ? text.selection.start : 0;
      _showPageAt(
        resetActive || _matches.isEmpty ? caret : _matches.first.start,
      );
    } else {
      _caseFolding = CaseFolding.exact;
      _adoptPage(const [], offset: 0, mayContinue: false);
    }
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

  void nextMatch() => _findAgain(1);

  void previousMatch() => _findAgain(-1);

  /// Find Next and Find Previous. With the find bar closed, they reopen it
  /// on the remembered query and step from the caret, leaving focus in the
  /// document so typing still edits it; with nothing remembered, they open
  /// the find field to type a query.
  void _findAgain(int delta) {
    if (!_searchOpen) {
      if (search.text.isEmpty) {
        openSearch();
        return;
      }
      if (_loading || _error != null) return;
      final selection = text.selection;
      _searchOpen = true;
      // Makes the first match at or after the caret active.
      _updateMatches(resetActive: true);
      if (_matches.isEmpty) {
        _notify();
        return;
      }
      final active = _matches[_activeMatch];
      final onActive =
          selection.isValid &&
          selection.start == active.start &&
          selection.end == active.end;
      // Unless it is the match an earlier find left selected, Find Next
      // takes that match as it is.
      if (delta > 0 && !onActive) {
        _selectMatch(_activeMatch);
        return;
      }
    }
    _stepMatch(delta);
  }

  /// The find bar holds one window of matches, capped so a minified file cannot
  /// flood it with spans. Stepping inside the window is instant; stepping off
  /// its end pages the query, so every occurrence in the document is reachable
  /// instead of only the first [searchMatchLimit] of them.
  void _stepMatch(int delta) {
    if (_matches.isEmpty) return;
    final stepped = _activeMatch + delta;
    if (stepped >= 0 && stepped < _matches.length) {
      _selectMatch(stepped);
      return;
    }
    if (delta > 0) {
      _pageForward();
    } else {
      _pageBackward();
    }
  }

  void _selectMatch(int index) {
    if (_matches.isEmpty) {
      _activeMatch = -1;
      text.setSearchMatches(_matches, _activeMatch);
      _notify();
      return;
    }
    _activeMatch = index;
    text.setSearchMatches(_matches, _activeMatch);
    final match = _matches[_activeMatch];
    text.selection = TextSelection(
      baseOffset: match.start,
      extentOffset: match.end,
    );
    _revealRequest++;
    _notify();
  }

  /// Adopts a page of matches, replacing the highlighted set so what is
  /// painted stays the page the user is stepping through.
  void _adoptPage(
    List<TextRange> page, {
    required int offset,
    required bool mayContinue,
  }) {
    _matches = page;
    _matchOffset = offset;
    _matchesMayContinue = mayContinue;
  }

  /// Shows the first page of matches, unless [anchor] lies past it: then the
  /// page that starts with the first match at or after [anchor].
  void _showPageAt(int anchor) {
    var page = _page();
    var offset = 0;
    if (page.matches.length >= searchMatchLimit &&
        page.matches.last.start < anchor) {
      // Some match starts before the anchor, so this finds the last one.
      final before = _page(start: anchor, reverse: true, limit: 1);
      final after = _page(start: before.matches.last.end);
      if (after.matches.isNotEmpty) {
        page = after;
        offset = before.precedingCount! + 1;
      }
    }
    _adoptPage(
      page.matches,
      offset: offset,
      mayContinue: page.matches.length >= searchMatchLimit,
    );
  }

  void _pageForward() {
    // Matches at or after the end of this page, or the first page again when
    // the document is exhausted.
    final next = _page(start: _matches.last.end);
    if (next.matches.isNotEmpty) {
      _adoptPage(
        next.matches,
        offset: _matchOffset + _matches.length,
        mayContinue: next.matches.length >= searchMatchLimit,
      );
    } else {
      final first = _page();
      _adoptPage(
        first.matches,
        offset: 0,
        mayContinue: first.matches.length >= searchMatchLimit,
      );
    }
    _selectMatch(0);
  }

  void _pageBackward() {
    // Matches strictly before this page, which this page follows, or the
    // last page in the document when there is nothing earlier left.
    final previous = _page(start: _matches.first.start, reverse: true);
    final wrapped = previous.matches.isEmpty;
    final page = wrapped ? _page(reverse: true) : previous;
    _adoptPage(
      page.matches,
      offset: page.precedingCount!,
      mayContinue: !wrapped,
    );
    _selectMatch(_matches.length - 1);
  }

  /// One page of the query's matches, searched as the find bar searches:
  /// with the case setting and the host's fold, whose report it records.
  SearchResult _page({
    int? start,
    bool reverse = false,
    int limit = searchMatchLimit,
  }) {
    final result = searchText(
      text.text,
      search.text,
      caseSensitive: _caseSensitive,
      wholeWord: _wholeWord,
      fold: _fold,
      limit: limit,
      start: start,
      reverse: reverse,
    );
    // Reported, not hidden: a case-insensitive search that could not fold
    // this text found fewer matches than the user asked for.
    _caseFolding = result.caseFolding;
    return result;
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
      wholeWord: _wholeWord,
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
    goToLineInput.removeListener(_goToLineEdited);
    text.dispose();
    search.dispose();
    replacement.dispose();
    goToLineInput.dispose();
    editorFocus.dispose();
    searchFocus.dispose();
    replacementFocus.dispose();
    goToLineFocus.dispose();
    scroll.dispose();
    undoController.dispose();
    super.dispose();
  }
}

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;
