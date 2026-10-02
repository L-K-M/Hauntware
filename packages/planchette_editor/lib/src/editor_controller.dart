import 'dart:async';
import 'dart:collection';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:planchette_core/planchette_core.dart'
    hide SearchResult, findSearchMatches, searchText;
import 'package:planchette_core/planchette_core.dart'
    as core
    show
        copyLineText,
        decrementNumber,
        deleteIndentBackward,
        deleteLines,
        duplicateLines,
        incrementNumber,
        insertLineAbove,
        insertLineBelow,
        joinLines,
        moveLines,
        pasteWithIndentation,
        patternSearchBudget,
        selectEnclosingBracketsRange,
        selectLineRange,
        selectParagraphRange,
        toggleBlockComments;

import 'code_editing_controller.dart';
import 'pattern_find.dart';
import 'search_history.dart';
import 'text_tool_history.dart';

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
    Duration? patternSearchBudget,
    DateTime Function()? now,
    this.maximumBytes = defaultTextDocumentMaximumBytes,
    this.undoQuiet = defaultUndoQuiet,
    this.normalization = TextNormalization.normalize,
    TextToolHistory? toolHistory,
  }) : _displayPath = displayPath,
       _fold = caseFolder ?? _defaultCaseFolder,
       _patternSearchBudget = patternSearchBudget ?? core.patternSearchBudget,
       _toolHistory = toolHistory ?? TextToolHistory(),
       _now = now ?? clock.now {
    text = CodeEditingController(language: syntaxLanguageFor(displayPath));
    text.addListener(_textChanged);
    search.addListener(_queryChanged);
    replacement.addListener(_replacementChanged);
    extraction.addListener(_extractionChanged);
    goToLineInput.addListener(_goToLineEdited);
    for (final node in [
      editorFocus,
      searchFocus,
      replacementFocus,
      extractionFocus,
      goToLineFocus,
    ]) {
      trackTextField(node);
    }
    if (initialText != null) {
      _installText(initialText);
    } else {
      _loading = loadDocument != null;
    }
  }

  final Future<TextDocument> Function()? loadDocument;

  /// Writes a snapshot using the document's metadata and conflict digest.
  /// For a first save the document is null: read [metadata] synchronously
  /// in the callback, as the app's store adapter does, until it adopts a file.
  final Future<String> Function(String text, TextDocument? baseline)?
  saveDocument;
  Future<void> Function()? onSaved;
  Future<bool> Function()? onPublish;

  /// What Extract Matches to a new document calls. Left null, the
  /// destination stays off and the row's picker omits it.
  void Function(String text)? onNewDocument;

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

  /// How long one regular-expression search may run in its worker before it
  /// is stopped and the find bar reports [PatternTimedOut]. Defaults to
  /// [core.patternSearchBudget].
  final Duration _patternSearchBudget;

  /// The clock the undo-quiet window is measured on; injectable for tests.
  /// A frozen fake clock still needs a fake timer zone driving it — the
  /// wait itself sleeps on a real `Future.delayed`.
  final DateTime Function() _now;

  /// The largest buffer a text tool may write back, as UTF-8: the same
  /// limit loading enforces. Tools that only remove text can always run;
  /// a tool whose result outgrows this is refused before it applies.
  final int maximumBytes;

  /// Match the host's load/save policy. Normalized buffers use LF; hosts
  /// preserving raw line endings normalize to the chosen file convention.
  final TextNormalization normalization;

  TextSaveOptions saveOptions = const TextSaveOptions();

  /// How old the last value change must be before a tool run applies, so
  /// the run lands in its own undo step. Flutter's undo history merges
  /// value changes that arrive inside this window — currently 500 ms in
  /// the framework — and offers no way to flush a pending step, so a run
  /// has to wait it out instead. A change during the wait restarts it.
  final Duration undoQuiet;

  /// The default [undoQuiet]: Flutter's undo-merge window itself — a
  /// change this old has already committed its undo step. Tests pump past
  /// this instead of duplicating the number.
  static const defaultUndoQuiet = Duration(milliseconds: 500);

  /// The clock the last field change was stamped with; the pending undo
  /// step it belongs to commits [undoQuiet] after this.
  DateTime _lastValueChangeAt = DateTime.fromMillisecondsSinceEpoch(0);
  TextEditingValue _seenValue = const TextEditingValue();

  late final CodeEditingController text;
  final search = TextEditingController();
  final replacement = TextEditingController();
  final extraction = TextEditingController();
  final goToLineInput = TextEditingController();
  final editorFocus = FocusNode();
  final searchFocus = FocusNode();
  final extractionFocus = FocusNode();
  final replacementFocus = FocusNode();
  final goToLineFocus = FocusNode();

  /// Every text field this editor owns: the document, find, replace, Go to
  /// Line and any open tool-bar fields. A host routing Cut, Copy, Paste or
  /// Select All from its own menus sends them to whichever of these has
  /// focus.
  List<FocusNode> get textFocusNodes => UnmodifiableListView(_textFocusNodes);
  final List<FocusNode> _textFocusNodes = [];
  final _fieldListeners = <FocusNode, VoidCallback>{};

  /// Registers a field's node so focus memory and the host's clipboard
  /// routing see it — the tool bar's option fields live as long as the bar
  /// does, so they cannot be in the fixed constructor list. The owner must
  /// [untrackTextField] before disposing the node: removing a listener
  /// from a disposed node asserts in debug builds.
  void trackTextField(FocusNode node) {
    if (_fieldListeners.containsKey(node)) return;
    void listener() {
      if (node.hasFocus) _focusMemory = node;
    }

    _fieldListeners[node] = listener;
    node.addListener(listener);
    _textFocusNodes.add(node);
  }

  /// Removes a node [trackTextField] registered.
  void untrackTextField(FocusNode node) {
    final listener = _fieldListeners.remove(node);
    if (listener != null) node.removeListener(listener);
    _textFocusNodes.remove(node);
    if (_focusMemory == node) _focusMemory = null;
  }

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
  TextDocumentMetadata _metadata = const TextDocumentMetadata();
  TextDocumentMetadata _savedMetadata = const TextDocumentMetadata();
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
  bool _useRegularExpression = false;

  /// The stored find-in-selection range, or null while search covers the
  /// document. It lives on [text] too, where it is painted as a wash so it
  /// survives the selection returning to match-stepping.
  TextRange? _searchScope;

  /// The line-action row (Keep/Delete Lines Matching) and the extraction
  /// row (Extract Matches) the find bar can carry, mutually exclusive.
  bool _lineActionsOpen = false;
  bool _extractOpen = false;
  bool _extractWholeLines = false;

  /// Where Extract Matches sends its list: 'inPlace', 'clipboard' or
  /// 'newDocument' — the Extract tool's declared `target` choices.
  String _extractTarget = 'inPlace';

  /// The debounced matching-line/extraction count while a row is open;
  /// worker-backed like the pattern search itself.
  int? _lineActionCount;
  bool _lineCountPending = false;
  PatternFailure? _lineCountFailure;
  PatternWorker? _linesWorker;
  Timer? _linesCountDelay;
  int _linesGeneration = 0;

  /// The regular-expression search, while that mode is on.
  PatternFind? _patternFind;

  /// Session-only find queries, newest first. Never written to disk:
  /// a query can hold a secret. Each controller keeps its own, like the
  /// tool history without a shared host instance.
  final SearchHistory searchHistory = SearchHistory();

  /// Keyboard recall through [searchHistory]: -1 while typing, else the
  /// index recalled, with [_historyDraft] the text recall started from.
  int _historyCursor = -1;
  String? _historyDraft;

  /// The active-match replacement preview: what Replace would do now.
  /// Literal mode computes it synchronously; regex mode asks a worker
  /// under the search budget, so a catastrophic pattern times out instead
  /// of freezing the editor. A newer query, edit, match step or template
  /// cancels one on its way.
  ReplacementPreview? _replacementPreview;
  PatternFailure? _previewFailure;
  bool _previewPending = false;
  Timer? _replacementPreviewTimer;
  PatternWorker? _replacementPreviewWorker;
  int _replacementPreviewGeneration = 0;
  _PreviewKey? _replacementPreviewKey;

  /// Whether the find bar shows its inline grep cheat sheet.
  bool _cheatSheetOpen = false;

  /// Whether the pattern search on its way was asked for by a new query or
  /// setting, whose first match the view should scroll to when it arrives.
  bool _revealPatternResults = false;

  /// Find commands given while a pattern search was on its way, run in
  /// order once it arrives.
  final List<void Function()> _afterPatternSearch = [];
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
  TextToolReport? _toolReport;

  /// The runs this editor feeds Repeat and Recent with; shared when the
  /// host hands every controller the same one.
  final TextToolHistory _toolHistory;

  /// The tool the options bar is open for, plus the values its controls
  /// hold and the dry-run outcome they produce.
  TextTool? _barTool;
  Map<String, Object?> _barOptions = const {};
  bool _barWholeDocument = false;
  TextToolReport? _barPreview;
  bool _barOverLimit = false;
  Timer? _barPreviewTimer;
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

  TextDocumentMetadata get metadata => _metadata;

  bool get canChangeMetadata =>
      !_disposed && !isBusy && !editingLocked && _error == null;

  /// Change what the next save writes, without rewriting the editing buffer
  /// or its undo history. Returning to the saved choices clears their dirt.
  bool setMetadata(TextDocumentMetadata value) {
    if (!canChangeMetadata || value == _metadata) return false;
    _metadata = value;
    _document = _document?.copyWith(
      lineEnding: value.lineEnding,
      hasUtf8Bom: value.utf8Bom == Utf8Bom.present,
    );
    _revision++;
    _notify();
    return true;
  }

  LineEnding get bufferLineEnding =>
      normalization == TextNormalization.normalize
      ? LineEnding.lf
      : _metadata.lineEnding;
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
    return _dirty || _metadata != _savedMetadata;
  }

  bool get canSave => !isBusy && !editingLocked && _error == null;
  bool get canPublish => onPublish != null;
  bool get searchOpen => _searchOpen;
  bool get goToLineOpen => _goToLineOpen;

  /// Whether the selection covers text — what Find in Selection needs.
  bool get hasSelection =>
      text.selection.isValid && !text.selection.isCollapsed;

  /// The stored find-in-selection range searches are bounded to, or null.
  TextRange? get searchScope => _searchScope;

  /// Whether the find bar shows its line-action row — Keep and Delete
  /// Lines Matching on the find field's pattern.
  bool get lineActionsOpen => _lineActionsOpen;

  /// Whether the find bar shows its extraction row.
  bool get extractOpen => _extractOpen;

  /// Whether Extract collects whole matching lines rather than each match.
  bool get extractWholeLines => _extractWholeLines;

  /// Where Extract Matches sends its list: 'inPlace', 'clipboard' or
  /// 'newDocument'.
  String get extractTarget => _extractTarget;

  /// Whether 'newDocument' is a live Extract destination for this editor.
  bool get canExtractToNewDocument => onNewDocument != null;

  /// The count a find-bar action row reports: matching lines for Keep and
  /// Delete, produced entries for Extract. Null while the first count is
  /// on its way or after it failed — [lineCountFailure] says why.
  int? get lineActionCount => _lineActionCount;

  /// Whether the action row's count is being recomputed.
  bool get lineCountPending => _lineCountPending;
  PatternFailure? get lineCountFailure => _lineCountFailure;

  /// Whether the Go to Line field holds input [submitGoToLine] could not
  /// read, until that input is edited or the field closes.
  bool get goToLineInputInvalid => _invalidGoToLine != null;
  bool get replaceOpen => _replaceOpen;
  bool get caseSensitive => _caseSensitive;

  /// Whether find and Replace All skip hits that run on into a word, such as
  /// `cat` inside `concat`.
  bool get wholeWord => _wholeWord;

  /// Whether the query is a regular expression rather than literal text.
  bool get useRegularExpression => _useRegularExpression;

  /// Why the regular expression in the find field finds nothing: it does not
  /// compile, or its search failed or took longer than the budget. Null in
  /// literal mode and whenever the pattern searched normally.
  PatternFailure? get patternFailure =>
      _useRegularExpression ? _patternFind?.failure : null;

  /// Whether a regular-expression search is waiting or running, so the
  /// matches shown may be about to change. Literal search never waits.
  bool get patternSearchPending =>
      _useRegularExpression && (_patternFind?.pending ?? false);

  /// What Replace would do to the active match, or null when there is no
  /// active match or its answer is still on its way ([previewPending]) or
  /// failed ([previewFailure]). Literal mode is synchronous; regex mode
  /// arrives from a worker under the search budget with stale answers
  /// discarded.
  ReplacementPreview? get replacementPreview => _replacementPreview;
  PatternFailure? get replacementPreviewFailure => _previewFailure;
  bool get replacementPreviewPending => _previewPending;

  /// Whether the find bar shows its inline grep cheat sheet.
  bool get cheatSheetOpen => _cheatSheetOpen;
  void toggleCheatSheet() {
    _cheatSheetOpen = !_cheatSheetOpen;
    _notify();
  }

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
  /// A regular expression with more than [patternMatchLimit] matches lists
  /// only that many, so its total is always a lower bound.
  bool get matchesMayContinue =>
      _matchesMayContinue ||
      (_useRegularExpression && (_patternFind?.capped ?? false));
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
  /// level its format mandates (tabs for Makefiles and Go, whatever some of
  /// their lines use), the level its own lines use (re-checked after edits
  /// until they show one), the host's [indentationPreference], and finally
  /// four spaces.
  Indentation get indentation =>
      _chosenIndentation ??
      requiredIndentationFor(_displayPath) ??
      _detectedIndentation ??
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
  /// a lone CR; each counts once. Untitled buffers use their pending
  /// [metadata], defaulting to LF without a mark. With preserve normalization,
  /// the size is [byteCount] plus the selected byte-order mark instead.
  int get fileByteCount {
    _updateMetrics();
    final bomBytes = _metadata.utf8Bom.byteLength;
    if (normalization == TextNormalization.preserve) {
      return byteCount + bomBytes;
    }
    // Folding to LF drops the CR of each CRLF and turns a lone CR into LF.
    final breaks = lineStarts.length - 1 + _returns - _returnNewlines;
    return byteCount -
        _returnNewlines +
        (_metadata.lineEnding == LineEnding.crlf ? breaks : 0) +
        bomBytes;
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
    _metadata = document.metadata;
    _savedMetadata = document.metadata;
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
  /// language has a line-comment marker, or a block pair for the fallback.
  /// Plain text, Markdown and JSON have neither.
  bool get canToggleComment {
    if (!canEditText) return false;
    final language = text.language;
    return language != null &&
        (language.lineComments.isNotEmpty || language.blockComments.isNotEmpty);
  }

  /// Comments the touched lines with the language's line-comment marker, or
  /// uncomments them when all already carry one. Languages without a line
  /// marker but with a block pair (XML, CSS) wrap with that pair instead.
  /// See [toggleLineComments] and [toggleBlockComments].
  bool toggleComment() {
    final language = text.language;
    if (language == null) return false;
    if (language.lineComments.isNotEmpty) {
      final markers = language.lineComments;
      return _applyLineEdit(
        (text, base, extent) => toggleLineComments(text, base, extent, markers),
      );
    }
    if (language.blockComments.isNotEmpty) {
      final pair = language.blockComments.first;
      return _applyLineEdit(
        (text, base, extent) =>
            core.toggleBlockComments(text, base, extent, pair[0], pair[1]),
      );
    }
    return false;
  }

  /// Selects the caret's line, or every line the selection touches.
  /// Selection only, so a locked document allows it.
  bool selectLine() {
    if (!canMoveCaret) return false;
    final selection = text.selection;
    final range = core.selectLineRange(
      text.text,
      selection.baseOffset,
      selection.extentOffset,
    );
    _requestCaretReveal(CaretReveal.nearest);
    text.selection = TextSelection(
      baseOffset: range.base,
      extentOffset: range.extent,
    );
    return true;
  }

  /// Selects the paragraph at the caret: a run of non-blank lines.
  /// Selection only, so a locked document allows it.
  bool selectParagraph() {
    if (!canMoveCaret) return false;
    final selection = text.selection;
    final range = core.selectParagraphRange(
      text.text,
      selection.baseOffset,
      selection.extentOffset,
    );
    _requestCaretReveal(CaretReveal.nearest);
    text.selection = TextSelection(
      baseOffset: range.base,
      extentOffset: range.extent,
    );
    return true;
  }

  /// Selects the innermost bracket pair around the selection, expanding
  /// outwards on repeat. Selection only, so a locked document allows it.
  /// Returns false with no enclosing pair.
  bool selectEnclosingBrackets() {
    if (!canMoveCaret) return false;
    final selection = text.selection;
    final range = core.selectEnclosingBracketsRange(
      text.text,
      selection.baseOffset,
      selection.extentOffset,
      text.syntaxTokens,
    );
    if (range == null) return false;
    _requestCaretReveal(CaretReveal.nearest);
    text.selection = TextSelection(
      baseOffset: range.base,
      extentOffset: range.extent,
    );
    return true;
  }

  /// Inserts an empty indented line above the caret's line.
  bool insertLineAbove() => _applyLineEdit(
    (text, base, extent) => core.insertLineAbove(text, base, extent),
  );

  /// Inserts an empty indented line below the caret's line.
  bool insertLineBelow() => _applyLineEdit(
    (text, base, extent) => core.insertLineBelow(text, base, extent),
  );

  /// Adds one to the number at the caret or selection, keeping its width,
  /// decimal places and hex shape. Returns false with no number there.
  bool incrementNumber() => _applyLineEdit(
    (text, base, extent) => core.incrementNumber(text, base, extent),
  );

  /// Subtracts one from the number at the caret or selection. See
  /// [incrementNumber].
  bool decrementNumber() => _applyLineEdit(
    (text, base, extent) => core.decrementNumber(text, base, extent),
  );

  /// Copies the touched lines to the clipboard. No edit, so a locked
  /// document allows it. Returns false when the buffer changed mid-copy
  /// or the clipboard refused it.
  Future<bool> copyLine() async {
    if (!canMoveCaret) return false;
    final source = text.text;
    final selection = text.selection;
    if (!selection.isValid) return false;
    final copyText = core.copyLineText(
      source,
      selection.baseOffset,
      selection.extentOffset,
    );
    if (copyText.isEmpty) return false;
    try {
      await Clipboard.setData(ClipboardData(text: copyText));
    } catch (_) {
      return false;
    }
    if (_disposed || text.text != source) return false;
    return true;
  }

  /// Copies the touched lines and removes them. The clipboard write lands
  /// first; a buffer that changed meanwhile keeps its text. The deletion
  /// stays anchored to the copied lines, so clipboard and buffer agree
  /// even when the caret moved during the write.
  Future<bool> cutLine() async {
    if (!canEditText) return false;
    final source = text.text;
    final selection = text.selection;
    if (!selection.isValid) return false;
    final copyText = core.copyLineText(
      source,
      selection.baseOffset,
      selection.extentOffset,
    );
    if (copyText.isEmpty) return false;
    // Delete exactly the lines that were copied; a caret move during the
    // clipboard write must not re-target the deletion away from them.
    final removed = core.deleteLines(
      source,
      selection.baseOffset,
      selection.extentOffset,
    );
    if (removed == null) return false;
    try {
      await Clipboard.setData(ClipboardData(text: copyText));
    } catch (_) {
      return false;
    }
    if (_disposed || !canEditText || text.text != source) return false;
    _requestCaretReveal(CaretReveal.nearest);
    text.value = TextEditingValue(
      text: removed.text,
      selection: TextSelection(
        baseOffset: removed.selectionBase,
        extentOffset: removed.selectionExtent,
      ),
    );
    return true;
  }

  /// Pastes the clipboard with later lines reindented to the caret line.
  /// Default paste is untouched. Reads the clipboard first, then waits out
  /// the undo throttle so the insert is one undo step; the caret is reread
  /// afterwards, so a move during the waits pastes where it now stands.
  /// A buffer that changed meanwhile is left alone.
  Future<bool> pasteAndMatchIndentation() async {
    if (!canEditText) return false;
    final source = text.text;
    if (!text.selection.isValid) return false;
    final ClipboardData? data;
    try {
      data = await Clipboard.getData('text/plain');
    } catch (_) {
      return false;
    }
    final pasted = data?.text;
    if (pasted == null || pasted.isEmpty) return false;
    if (_disposed || !canEditText || text.text != source) return false;
    await _waitForUndoQuiet();
    if (_disposed || !canEditText || text.text != source) return false;
    final current = text.selection;
    if (!current.isValid) return false;
    final edit = core.pasteWithIndentation(
      source,
      current.baseOffset,
      current.extentOffset,
      pasted,
      separator: bufferLineEnding == LineEnding.crlf ? '\r\n' : '\n',
    );
    _requestCaretReveal(CaretReveal.nearest);
    text.value = TextEditingValue(
      text: edit.text,
      selection: TextSelection.collapsed(offset: edit.selectionBase),
    );
    return true;
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

  // ── Text tools ──

  /// The report of the most recent text-tool run, for the result notice
  /// the view shows; cleared by the next change to the field's value.
  TextToolReport? get toolReport => _toolReport;

  /// Dismisses the notice [toolReport] shows — the notice offers this so
  /// the band it covers is never a dead zone.
  void clearToolReport() {
    if (_toolReport == null) return;
    _toolReport = null;
    _notify();
  }

  /// Runs the catalog tool [toolId] and reports what it did.
  ///
  /// Returns null when the buffer cannot be edited at all right now —
  /// loading, locked or composing — the same gate the line commands use.
  /// Otherwise the report of the run lands in [toolReport]: the buffer
  /// changed, nothing needed changing, or the tool refused with a reason.
  ///
  /// The run waits out [undoQuiet] first: Flutter's undo history merges
  /// changes that close together into one step, and a tool result must be
  /// a step of its own so Undo returns the buffer to what it was before
  /// the run rather than before the last typing pause.
  Future<TextToolOutcome?> runTextTool(
    String toolId, {
    Map<String, Object?> options = const {},
    bool wholeDocument = false,
  }) async {
    final tool = textToolById(toolId);
    if (tool == null) {
      throw ArgumentError.value(toolId, 'toolId', 'No text tool');
    }
    if (!canEditText) return null;
    await _waitForUndoQuiet();
    if (_disposed || !canEditText) return null;

    final selection = text.value.selection;
    final resolved = resolveTextToolRange(
      tool,
      text.text,
      selection.baseOffset,
      selection.extentOffset,
      wholeDocument: wholeDocument,
    );

    final runOptions = _toolOptions(tool, options);
    TextToolOutcome outcome;
    if (resolved.refusal != null) {
      outcome = TextToolRefused(resolved.refusal!);
    } else {
      outcome = tool.run(
        TextToolRun(
          text: text.text,
          base: resolved.base,
          extent: resolved.extent,
          caret: resolved.caret,
          ranOn: resolved.ranOn,
          options: runOptions,
          context: _toolContext(),
        ),
      );
      // Preflight the size the run would leave. UTF-16 length is not a
      // safe proxy for UTF-8 size — an equal-length replacement can still
      // grow in bytes — so every changed result is measured; removals
      // always pass.
      if (outcome is TextToolChanged &&
          _exceedsToolSize(text.text, outcome.edit.text)) {
        outcome = const TextToolRefused(TextToolRefusal.tooLarge);
      }
      if (outcome case TextToolChanged(:final edit, :final indentation)) {
        _requestCaretReveal(CaretReveal.nearest);
        text.value = TextEditingValue(
          text: edit.text,
          selection: TextSelection(
            baseOffset: edit.selectionBase,
            extentOffset: edit.selectionExtent,
          ),
        );
        if (indentation != null) this.indentation = indentation;
      }
      // Conversion still chooses the editing convention on an empty or
      // already-converted buffer; there is simply no text edit to undo.
      if (outcome case TextToolUnchanged(indentation: final chosen?)) {
        indentation = chosen;
      }
    }
    _toolReport = TextToolReport(
      tool: tool,
      outcome: outcome,
      ranOn: resolved.ranOn,
    );
    // A refused run never touched the document, so it does not earn a
    // Repeat/Recent slot — rerunning it would refuse again.
    if (outcome is! TextToolRefused) {
      _toolHistory.record(toolId, runOptions, wholeDocument: wholeDocument);
    }
    _notify();
    return outcome;
  }

  /// The shared run history [toolReport] feeds — Repeat and Recent read
  /// from it.
  TextToolHistory get toolHistory => _toolHistory;

  // ── Text tools browser ──

  /// Whether the catalog browser is open. Hosts open it from a header
  /// icon through [openTextTools]; the shared view renders it, and the
  /// standalone app also offers it from its Text menu.
  bool get textToolsOpen => _textToolsOpen;
  bool _textToolsOpen = false;

  /// Opens the catalog browser: Repeat and Recent first, then the seven
  /// groups with a keyword filter. Browsing edits nothing, so a locked
  /// document may still open it — its rows then stay disabled. Takes the
  /// find bar's slot, closing find, Go to Line and the options bar.
  void openTextTools() {
    if (_loading || _error != null) return;
    if (_searchOpen) closeSearch();
    if (_goToLineOpen) closeGoToLine();
    if (_barTool != null) closeTextTool(refocus: false);
    _textToolsOpen = true;
    _notify();
  }

  /// Closes the catalog browser. Focus returns to the document, so Escape
  /// and choosing an immediate tool both leave the caret usable; [refocus]
  /// is off for callers handing focus to another bar right after.
  void closeTextTools({bool refocus = true}) {
    if (!_textToolsOpen) return;
    _textToolsOpen = false;
    _notify();
    if (refocus) editorFocus.requestFocus();
  }

  /// Chooses a catalog tool from the browser list: a find-bar tool opens
  /// its find row, a tool with options opens the options bar, and the rest
  /// run at their defaults through the guarded [runTextTool]. Closes the
  /// browser first; focus moves to the bar or row, or back to the document.
  void chooseTextTool(String toolId) {
    final tool = textToolById(toolId);
    if (tool == null) {
      throw ArgumentError.value(toolId, 'toolId', 'No text tool');
    }
    if (_loading || _error != null) return;
    if (tool.usesFindBar) {
      closeTextTools(refocus: false);
      openFindTool(toolId);
    } else if (tool.options.isEmpty) {
      closeTextTools();
      unawaited(runTextTool(toolId));
    } else {
      closeTextTools(refocus: false);
      openTextTool(toolId);
    }
  }

  /// Reruns a recorded tool with the options it ran with: a find-bar tool
  /// reopens its seeded find row, the rest rerun through [runTextTool].
  Future<TextToolOutcome?> runRecentTextTool(TextToolRunRecord record) {
    final tool = textToolById(record.toolId);
    if (tool == null) return Future.value(null);
    if (tool.usesFindBar) {
      closeTextTools(refocus: false);
      openFindTool(record.toolId, options: record.options);
      return Future.value(null);
    }
    closeTextTools();
    return runTextTool(
      record.toolId,
      options: record.options,
      wholeDocument: record.wholeDocument,
    );
  }

  /// Reruns the last recorded tool, or null before the first run.
  Future<TextToolOutcome?> repeatTextTool() {
    final last = _toolHistory.last;
    if (last == null) return Future.value(null);
    return runRecentTextTool(last);
  }

  /// Declared option defaults overlaid with the caller's [overrides];
  /// unknown overrides and values that no longer fit their option — a
  /// restored choice outside the current choices — drop to the default.
  Map<String, Object?> _toolOptions(
    TextTool tool,
    Map<String, Object?> overrides,
  ) => {
    for (final option in tool.options)
      option.id: _resolvedOption(option, overrides[option.id]),
  };

  static Object? _resolvedOption(TextToolOption option, Object? value) {
    if (option is ChoiceOption &&
        value != null &&
        !option.choices.contains(value)) {
      return option.defaultValue;
    }
    if (option is IntegerOption) {
      if (value is! int) return option.defaultValue;
      if (value < option.min) return option.min;
    }
    return value ?? option.defaultValue;
  }

  TextToolContext _toolContext() => TextToolContext(
    fold: _fold,
    indentation: indentation,
    indentationPreference: _preferredIndentation,
    displayPath: _displayPath,
    lineEnding: bufferLineEnding,
    now: _now,
  );

  bool _exceedsToolSize(String before, String after) {
    final size = textDocumentByteCount(
      after,
      _metadata,
      normalization: normalization,
    );
    return size > maximumBytes &&
        size >
            textDocumentByteCount(
              before,
              _metadata,
              normalization: normalization,
            );
  }

  // ── Text tool bar ──

  /// The buffer size past which the bar stops dry-running a tool and its
  /// count is computed on Apply instead: a sort across a large file per
  /// keystroke is not worth a live count.
  static const toolBarPreviewLimit = 1 << 20;

  /// How long after an edit or caret move the dry run reruns — the count
  /// settles with the selection rather than chasing every keystroke.
  static const _previewDelay = Duration(milliseconds: 150);

  /// The tool the options bar is open for, or null.
  TextTool? get toolBarTool => _barTool;
  bool get toolBarOpen => _barTool != null;

  /// The values the bar's controls hold — defaults seeded with the tool's
  /// last-used ones — for the controls to read back.
  Map<String, Object?> get toolBarOptions => Map.unmodifiable(_barOptions);

  /// Whether the bar's scope control sends the run to the whole document
  /// rather than the selection. Only a document-scope tool offers the
  /// choice; for anything else the flag stays false.
  bool get toolBarWholeDocument => _barWholeDocument;

  /// The dry-run result the bar's count line shows, or null until the
  /// first recompute lands — and past [toolBarPreviewLimit], where the
  /// count is computed on Apply.
  TextToolReport? get toolBarPreview => _barPreview;

  /// Whether the buffer is large enough that the bar skips the dry run:
  /// the count is computed on Apply and reported in the notice.
  bool get toolBarPreviewDeferred => _barOverLimit;

  /// The lines the current scope radio covers: the selection's when it
  /// applies, else the document's.
  (int selected, int document) get toolBarScopeLines =>
      (_barSelectedLines, _barDocumentLines);
  int _barSelectedLines = 0;
  int _barDocumentLines = 0;

  /// Opens the options bar for [toolId] — the menu's "…" items and a host's
  /// list call here. The bar takes the find bar's slot, so opening it
  /// closes find and Go to Line.
  void openTextTool(String toolId) {
    final tool = textToolById(toolId);
    if (tool == null) {
      throw ArgumentError.value(toolId, 'toolId', 'No text tool');
    }
    if (_loading || _error != null) return;
    if (_textToolsOpen) closeTextTools(refocus: false);
    // A pattern tool's options live in the find bar, not here.
    if (tool.usesFindBar) return openFindTool(toolId);
    if (_searchOpen) closeSearch();
    if (_goToLineOpen) closeGoToLine();
    _barTool = tool;
    _barOptions = _toolHistory.lastOptionsFor(toolId);
    _barWholeDocument = false;
    _markBarStale();
    _notify();
  }

  /// Closes the options bar. The bar's focus goes back to the document, so
  /// Escape and Apply both leave the caret usable; [refocus] is off for
  /// callers handing focus to another bar right after.
  void closeTextTool({bool refocus = true}) {
    if (_barTool == null) return;
    _barTool = null;
    _barPreview = null;
    _barOverLimit = false;
    _barPreviewTimer?.cancel();
    _notify();
    if (refocus) editorFocus.requestFocus();
  }

  /// Sets one option while the bar is open; the dry run reschedules.
  void setToolOption(String id, Object? value) {
    if (_barTool == null) return;
    _barOptions = {..._barOptions, id: value};
    _markBarStale();
    _notify();
  }

  /// Sets the scope control; [wholeDocument] is ignored for tools that do
  /// not offer it.
  void setToolBarScope({required bool wholeDocument}) {
    if (_barTool == null) return;
    _barWholeDocument =
        wholeDocument && _barTool!.scope == TextToolScope.document;
    _markBarStale();
    _notify();
  }

  /// Applies the bar's current options and closes it — the bar's Enter.
  Future<TextToolOutcome?> applyTextTool() async {
    final tool = _barTool;
    if (tool == null || !canEditText) return null;
    final options = _barOptions;
    final wholeDocument = _barWholeDocument;
    closeTextTool();
    return runTextTool(tool.id, options: options, wholeDocument: wholeDocument);
  }

  /// Marks the dry run out of date and reschedules it. A stale flag rather
  /// than an immediate recompute: option toggles and keystrokes can arrive
  /// faster than a large sort is worth.
  void _markBarStale() {
    if (_barTool == null) return;
    _barPreviewTimer?.cancel();
    _barPreviewTimer = Timer(_previewDelay, _refreshBarPreview);
  }

  void _refreshBarPreview() {
    final tool = _barTool;
    if (tool == null || _disposed) return;
    final selection = text.value.selection;
    final source = text.text;
    _barDocumentLines = _documentLineCount(source);
    _barSelectedLines =
        selection.isValid && selection.baseOffset != selection.extentOffset
        ? _rangeLineCount(
            source,
            touchedLineRange(
              source,
              selection.baseOffset,
              selection.extentOffset,
            ),
          )
        : 0;
    _barOverLimit = utf8EncodedLength(source) > toolBarPreviewLimit;
    if (_barOverLimit) {
      _barPreview = null;
    } else {
      final resolved = resolveTextToolRange(
        tool,
        source,
        selection.baseOffset,
        selection.extentOffset,
        wholeDocument: _barWholeDocument,
      );
      _barPreview = TextToolReport(
        tool: tool,
        outcome: resolved.refusal != null
            ? TextToolRefused(resolved.refusal!)
            : tool.run(
                TextToolRun(
                  text: source,
                  base: resolved.base,
                  extent: resolved.extent,
                  caret: resolved.caret,
                  ranOn: resolved.ranOn,
                  options: _toolOptions(tool, _barOptions),
                  context: _toolContext(),
                ),
              ),
        ranOn: resolved.ranOn,
      );
    }
    _notify();
  }

  /// The lines a touched range spans. The range is line-aligned, so every
  /// break inside it ends a real line.
  static int _rangeLineCount(String text, ({int start, int end}) range) {
    var count = 1;
    for (var i = range.start; i < range.end; i++) {
      if (text.codeUnitAt(i) == 0x0a) count++;
    }
    return count;
  }

  /// The lines the document holds. A break at the end of the buffer ends
  /// the last line rather than starting an empty one — the same rule
  /// [touchedLineRange] applies to a range.
  static int _documentLineCount(String text) {
    if (text.isEmpty) return 0;
    var count = _rangeLineCount(text, (start: 0, end: text.length));
    if (text.codeUnitAt(text.length - 1) == 0x0a) count--;
    return count;
  }

  /// Waits until the last change to the text field's value is at least
  /// [undoQuiet] old. The undo history merges changes inside the window
  /// into one step and offers no flush, so a tool run waits it out — the
  /// pending step commits, the tool's lands after it, and Undo returns to
  /// the state before the run. A change during the wait restarts it, so a
  /// run mid-typing keeps waiting rather than cutting in.
  Future<void> _waitForUndoQuiet() async {
    while (!_disposed) {
      final wait = undoQuiet - _now().difference(_lastValueChangeAt);
      if (wait <= Duration.zero) return;
      await Future<void>.delayed(wait);
    }
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
    // A reload or revert keeps the reader's place as far as the new text
    // reaches, never between the halves of a surrogate pair; the view
    // carries the scroll offset over to the new document field.
    final previous = text.selection;
    var caret = previous.isValid
        ? previous.extentOffset.clamp(0, value.length)
        : 0;
    if (caret > 0 &&
        caret < value.length &&
        _isLowSurrogate(value.codeUnitAt(caret)) &&
        _isHighSurrogate(value.codeUnitAt(caret - 1))) {
      caret--;
    }
    text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: caret),
    );
    _detectLanguage();
    _detectIndentation(reset: true);
    if (_searchOpen) _updateMatches(resetActive: true);
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
    // A tool run waits out this stamp so its result is a step of its own.
    // EditableText's shouldChangeUndoStack pushes only text and composing
    // changes — a caret move never opens a throttle window — so the stamp
    // tracks exactly those.
    final value = text.value;
    if (value.text != _seenValue.text ||
        value.composing != _seenValue.composing) {
      _lastValueChangeAt = _now();
      _toolReport = null;
    }
    _seenValue = value;
    if (_updatingSearch || _disposed) return;
    // An open tool bar dry-runs against where the caret lands; it reruns
    // when the selection or the text settles.
    if (_barTool != null) _markBarStale();
    if (text.text != _lastText) {
      final before = _lastText;
      _lastText = text.text;
      _revision++;
      _refreshLanguage();
      _detectIndentation();
      if (_searchOpen) _followEdit(before);
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

  /// Cleanup cannot rewrite text owned by an input method. A save needing
  /// cleanup returns null during composition; retry after committing input.
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
    if (text.value.composing.isValid && _saveCleanup() != null) return null;
    _saving = true;
    _notify();
    final publishAction = onPublish;
    final afterSave = onSaved;
    final publish = mode == EditorSaveMode.primary && publishAction != null;
    try {
      // Save cleanup is visible and undoable, not a hidden disk-only rewrite.
      // Wait only when cleanup is needed; ordinary saves keep their timing.
      var cleanup = _saveCleanup();
      if (cleanup != null) {
        await _waitForUndoQuiet();
        if (_disposed ||
            text.value.composing.isValid ||
            (editingLocked && access != EditorSaveAccess.confirmedClose)) {
          return null;
        }
        cleanup = _saveCleanup();
        if (cleanup != null) {
          text.value = TextEditingValue(
            text: cleanup.text,
            selection: TextSelection(
              baseOffset: cleanup.selectionBase,
              extentOffset: cleanup.selectionExtent,
            ),
          );
          _requestCaretReveal(CaretReveal.nearest);
        }
      }
      final snapshot = text.text;
      final metadataSnapshot = _metadata;
      final digest = await saver(snapshot, _document);
      _savedText = snapshot;
      _savedMetadata = metadataSnapshot;
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

  LineEdit? _saveCleanup() {
    final selection = text.selection;
    final source = text.text;
    return prepareTextForSave(
      source,
      selection.isValid ? selection.baseOffset : 0,
      selection.isValid ? selection.extentOffset : 0,
      saveOptions,
      lineEnding: bufferLineEnding,
    );
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
    if (_textToolsOpen) closeTextTools(refocus: false);
    // The find bar and the tool bar share one slot.
    if (_barTool != null) closeTextTool(refocus: false);
    // A plain Find reopens without the pattern-tool rows; the menu paths
    // that want them set them after this returns.
    _closeFindRows();
    final selection = text.selection;
    String? prefill;
    // A stored scope came from this very selection — it is the range to
    // search, not text to offer as the query.
    if (selection.isValid && !selection.isCollapsed && _searchScope == null) {
      final selected = selection.textInside(text.text);
      if (selected.isNotEmpty &&
          !selected.contains('\n') &&
          selected.length <= 200) {
        // A pattern finds the selection as it stands, not as an expression:
        // a selected `a.b` should not also find `axb`.
        prefill = _useRegularExpression ? RegExp.escape(selected) : selected;
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
    text.setSearchScope(_searchScope);
    _updateMatches(resetActive: true);
    search.selection = TextSelection(
      baseOffset: 0,
      extentOffset: search.text.length,
    );
    searchFocus.requestFocus();
    _revealRequest++;
    _notify();
  }

  /// Stores the selection as the search scope — the range the find bar's
  /// matches, Replace All and its pattern rows stay inside — and opens the
  /// bar. Edits map the scope through; it ends with the bar or with
  /// [clearSearchScope].
  void findInSelection() {
    if (_loading || _error != null || !hasSelection) return;
    final selection = text.selection;
    _searchScope = TextRange(
      start: selection.start.clamp(0, text.text.length),
      end: selection.end.clamp(0, text.text.length),
    );
    openSearch();
  }

  /// Drops the stored find-in-selection range; the find bar stays open and
  /// searches the whole document again.
  void clearSearchScope() {
    if (_searchScope == null) return;
    _searchScope = null;
    text.setSearchScope(null);
    _updateMatches(resetActive: false);
    _notify();
  }

  void closeSearch() {
    if (!_searchOpen) return;
    _searchOpen = false;
    _replaceOpen = false;
    _cheatSheetOpen = false;
    _closeFindRows();
    _clearPreview(notify: false);
    _historyCursor = -1;
    _historyDraft = null;
    _searchScope = null;
    if (_focusMemory == searchFocus ||
        _focusMemory == replacementFocus ||
        _focusMemory == extractionFocus) {
      _focusMemory = null;
    }
    _matches = const [];
    _matchOffset = 0;
    _matchesMayContinue = false;
    _activeMatch = -1;
    _lastQuery = null;
    _caseFolding = CaseFolding.exact;
    _patternFind?.reset();
    _revealPatternResults = false;
    _afterPatternSearch.clear();
    text.setSearchMatches(const [], -1);
    text.setSearchScope(null);
    // Go to Line may stay open with the user typing in it.
    if (!goToLineFocus.hasFocus) editorFocus.requestFocus();
    _notify();
  }

  /// Closes the line-action and extraction rows: their count, its debounce
  /// and its worker die with the row.
  void _closeFindRows() {
    _lineActionsOpen = false;
    _extractOpen = false;
    _linesCountDelay?.cancel();
    _linesCountDelay = null;
    _linesGeneration++;
    _linesWorker?.dispose();
    _linesWorker = null;
    _lineActionCount = null;
    _lineCountPending = false;
    _lineCountFailure = null;
  }

  // ── Find-bar pattern tools ──

  /// Opens the find bar armed for a pattern tool — the find field collects
  /// the query and the bar shows the tool's action row.
  /// 'keepLinesMatching' and 'deleteLinesMatching' open the line-action
  /// row; 'extractMatches' the extraction row. [options], when given —
  /// from a recorded run — reseeds the field, the toggles and the row.
  void openFindTool(String toolId, {Map<String, Object?>? options}) {
    final tool = textToolById(toolId);
    if (tool == null) {
      throw ArgumentError.value(toolId, 'toolId', 'No text tool');
    }
    if (!tool.usesFindBar) {
      throw ArgumentError.value(toolId, 'toolId', 'Not a find-bar tool');
    }
    if (_loading || _error != null) return;
    final saved = options ?? _toolHistory.lastOptionsFor(toolId);
    // Set the toggles through their methods so regex-mode cleanup runs.
    if ((saved['regularExpression'] == true) != _useRegularExpression) {
      toggleRegularExpression();
    }
    if ((saved['caseSensitive'] == true) != _caseSensitive) {
      toggleCaseSensitive();
    }
    if ((saved['wholeWord'] == true) != _wholeWord) {
      toggleWholeWord();
    }
    openSearch();
    final pattern = saved['pattern'];
    if (pattern is String && pattern.isNotEmpty) {
      _updatingQuery = true;
      try {
        search.text = pattern;
      } finally {
        _updatingQuery = false;
      }
      // openSearch scanned with the old field's contents.
      _updateMatches(resetActive: true);
    }
    _extractWholeLines = saved['wholeLines'] == true;
    final target = saved['target'];
    _extractTarget = target is String ? target : 'inPlace';
    final template = saved['template'];
    extraction.value = TextEditingValue(
      text: template is String ? template : '',
    );
    // The rows are mutually exclusive — the count row answers for the
    // visible one, so restoring one retires the other.
    if (toolId == 'extractMatches') {
      _extractOpen = true;
      _lineActionsOpen = false;
    } else {
      _lineActionsOpen = true;
      _extractOpen = false;
    }
    _scheduleLineCount();
    _notify();
  }

  /// The stored scope as the core's bounds record, for the worker calls.
  ({int start, int end})? get _scopeAsRecord {
    final scope = _searchScope;
    return scope == null ? null : (start: scope.start, end: scope.end);
  }

  /// The find bar's Lines control: shows or hides the line-action row.
  void toggleLineActions() {
    _lineActionsOpen = !_lineActionsOpen;
    if (_lineActionsOpen) _extractOpen = false;
    if (_lineActionsOpen) {
      _scheduleLineCount();
    } else {
      _closeFindRows();
    }
    _notify();
  }

  /// Sets whether Extract collects whole matching lines; the row's count
  /// changes meaning with it, so it recomputes.
  void setExtractWholeLines(bool value) {
    if (_extractWholeLines == value) return;
    _extractWholeLines = value;
    _scheduleLineCount();
    _notify();
  }

  /// Sets the Extract destination: 'inPlace', 'clipboard' or
  /// 'newDocument'.
  void setExtractTarget(String value) {
    if (_extractTarget == value) return;
    _extractTarget = value;
    _notify();
  }

  void _extractionChanged() {
    if (_extractOpen) _scheduleLineCount();
  }

  /// The options a find-bar tool would run with now: the find field's
  /// query, the bar's toggles and the row's own controls.
  Map<String, Object?> _findToolOptions(TextTool tool) => _toolOptions(tool, {
    'pattern': search.text,
    'regularExpression': _useRegularExpression,
    'caseSensitive': _caseSensitive,
    'wholeWord': _wholeWord,
    'wholeLines': _extractWholeLines,
    'template': extraction.text,
    'target': _extractTarget,
  });

  /// Schedules the action row's count — debounced like the pattern search,
  /// worker-backed for the same reason: a catastrophic expression must not
  /// reach the UI isolate.
  void _scheduleLineCount() {
    if (!_lineActionsOpen && !_extractOpen) return;
    _lineCountPending = true;
    _linesCountDelay?.cancel();
    _linesCountDelay = Timer(PatternFind.settleDelay, _countLineAction);
    _notify();
  }

  Future<void> _countLineAction() async {
    final generation = ++_linesGeneration;
    final query = search.text;
    if (query.isEmpty) {
      _lineActionCount = 0;
      _lineCountPending = false;
      _lineCountFailure = null;
      _notify();
      return;
    }
    final worker = _linesWorker ??= PatternWorker(budget: _patternSearchBudget);
    final source = text.text;
    final outcome = _extractOpen
        ? await worker.extractMatches(
            source,
            query,
            caseSensitive: _caseSensitive,
            wholeWord: _wholeWord,
            wholeLines: _extractWholeLines,
            template: extraction.text.isEmpty ? null : extraction.text,
            literal: !_useRegularExpression,
            scope: _scopeAsRecord,
          )
        : await worker.countMatchingLines(
            source,
            query,
            caseSensitive: _caseSensitive,
            wholeWord: _wholeWord,
            literal: !_useRegularExpression,
            scope: _scopeAsRecord,
          );
    // A newer count, a closed row or an edit makes this answer stale.
    if (_disposed ||
        generation != _linesGeneration ||
        !identical(text.text, source)) {
      return;
    }
    _lineCountPending = false;
    switch (outcome) {
      case PatternCompleted(:final value):
        _lineActionCount = switch (value) {
          final int count => count,
          final List<String> lines => lines.length,
          _ => null,
        };
        _lineCountFailure = null;
      case PatternFailed(:final failure):
        _lineActionCount = null;
        _lineCountFailure = failure;
      case PatternCancelled():
        return;
    }
    _notify();
  }

  /// Applies Keep or Delete Lines Matching — the line row's buttons and
  /// its Enter. The find field holds the pattern; the live selection is
  /// the active match, never the scope, so the action spans the document.
  Future<TextToolOutcome?> applyLineFilter({required bool keep}) async {
    final tool = textToolById(
      keep ? 'keepLinesMatching' : 'deleteLinesMatching',
    )!;
    if (!canEditText) return null;
    final options = _findToolOptions(tool);
    final query = search.text;
    // closeSearch drops the scope; the run keeps the stored bounds.
    final scope = _scopeAsRecord;
    closeSearch();
    await _waitForUndoQuiet();
    if (_disposed || !canEditText) return null;
    final outcome = await _runPatternOutcome(
      tool,
      query,
      (worker, source) => worker.filterLines(
        source,
        query,
        keep: keep,
        caseSensitive: _caseSensitive,
        wholeWord: _wholeWord,
        literal: !_useRegularExpression,
        scope: scope,
      ),
      (value, source) {
        final filtered = value! as PatternLineFilter;
        final removed = keep
            ? filtered.total - filtered.matched
            : filtered.matched;
        if (removed == 0) return TextToolUnchanged(scope: filtered.total);
        final caret = (text.selection.isValid ? text.selection.extentOffset : 0)
            .clamp(0, filtered.text.length);
        _requestCaretReveal(CaretReveal.nearest);
        text.value = TextEditingValue(
          text: filtered.text,
          selection: TextSelection.collapsed(offset: caret),
        );
        return TextToolChanged(
          LineEdit(filtered.text, caret, caret),
          changed: removed,
          scope: filtered.total,
        );
      },
    );
    if (outcome == null) return null;
    _toolReport = TextToolReport(
      tool: tool,
      outcome: outcome,
      ranOn: scope == null ? TextToolRanOn.document : TextToolRanOn.selection,
    );
    if (outcome is! TextToolRefused) {
      _toolHistory.record(tool.id, options);
    }
    _notify();
    return outcome;
  }

  /// Applies Extract Matches to the row's destination. 'inPlace' rewrites
  /// the document — or the scoped region — to the extraction; 'clipboard'
  /// and 'newDocument' leave it alone — the latter asks [onNewDocument].
  Future<TextToolOutcome?> applyExtract() async {
    final tool = textToolById('extractMatches')!;
    if (!canEditText) return null;
    final options = _findToolOptions(tool);
    final query = search.text;
    final target = _extractTarget;
    final wholeLines = _extractWholeLines;
    final template = extraction.text.isEmpty ? null : extraction.text;
    // closeSearch drops the scope; the run keeps the stored bounds.
    final scope = _scopeAsRecord;
    closeSearch();
    await _waitForUndoQuiet();
    if (_disposed || !canEditText) return null;
    final outcome = await _runPatternOutcome(
      tool,
      query,
      (worker, source) => worker.extractMatches(
        source,
        query,
        caseSensitive: _caseSensitive,
        wholeWord: _wholeWord,
        wholeLines: wholeLines,
        template: template,
        literal: !_useRegularExpression,
        scope: scope,
      ),
      (value, source) {
        final lines = value! as List<String>;
        final unit = wholeLines ? 'lines' : 'matches';
        if (lines.isEmpty) return TextToolUnchanged(scope: 0);
        final joined = lines.join('\n');
        switch (target) {
          case 'clipboard':
            unawaited(Clipboard.setData(ClipboardData(text: joined)));
            return TextToolUnchanged(
              scope: lines.length,
              detail: 'clipboard:$unit',
            );
          case 'newDocument' when onNewDocument != null:
            onNewDocument!(joined);
            return TextToolUnchanged(
              scope: lines.length,
              detail: 'newDocument:$unit',
            );
          case 'newDocument':
            // The callback is not wired — refuse rather than fall through
            // to the in-place rewrite the user did not choose.
            return const TextToolRefused(TextToolRefusal.unavailable);
          default:
            // A scoped extraction replaces the region — the lines it
            // touched when whole lines were collected — not the document.
            // The scope predates the awaits, so clamp: an edit meanwhile
            // can leave it beyond the source's bounds.
            final clamped = scope == null
                ? null
                : (
                    start: scope.start.clamp(0, source.length),
                    end: scope.end.clamp(0, source.length),
                  );
            final splice = clamped == null
                ? (start: 0, end: source.length)
                : wholeLines
                ? touchedLineRange(source, clamped.start, clamped.end)
                : clamped;
            // Measure bytes, not units — a template can grow the result
            // in UTF-8 while its code-unit length stays put.
            final extracted =
                source.substring(0, splice.start) +
                joined +
                source.substring(splice.end);
            if (_exceedsToolSize(source, extracted)) {
              return const TextToolRefused(TextToolRefusal.tooLarge);
            }
            final caret = splice.start + joined.length;
            _requestCaretReveal(CaretReveal.nearest);
            text.value = TextEditingValue(
              text: extracted,
              selection: TextSelection.collapsed(offset: caret),
            );
            return TextToolChanged(
              LineEdit(text.text, caret, caret),
              changed: lines.length,
              scope: lines.length,
              detail: 'inPlace:$unit',
            );
        }
      },
    );
    if (outcome == null) return null;
    _toolReport = TextToolReport(
      tool: tool,
      outcome: outcome,
      ranOn: scope == null ? TextToolRanOn.document : TextToolRanOn.selection,
    );
    if (outcome is! TextToolRefused) {
      _toolHistory.record(tool.id, options);
    }
    _notify();
    return outcome;
  }

  /// The worker round-trip both applies share: compile failures and worker
  /// failures become refusals, an edit that lands mid-run retries on the
  /// new text, and a disposed worker reports nothing.
  Future<TextToolOutcome?> _runPatternOutcome(
    TextTool tool,
    String query,
    Future<PatternOutcome<Object?>> Function(PatternWorker, String) request,
    TextToolOutcome? Function(Object? value, String source) install,
  ) async {
    if (query.isEmpty) {
      return const TextToolRefused(TextToolRefusal.noPattern);
    }
    for (var attempt = 0; attempt < 3; attempt++) {
      final source = text.text;
      final worker = PatternWorker(budget: _patternSearchBudget);
      final PatternOutcome<Object?> outcome;
      try {
        outcome = await request(worker, source);
      } finally {
        worker.dispose();
      }
      if (_disposed || outcome is PatternCancelled) return null;
      if (!identical(text.text, source)) continue;
      if (outcome case PatternFailed(:final failure)) {
        return TextToolRefused(
          failure is PatternUnusable
              ? TextToolRefusal.invalidPattern
              : TextToolRefusal.patternFailed,
        );
      }
      return install((outcome as PatternCompleted).value, source);
    }
    return null;
  }

  void openGoToLine() {
    if (_loading || _error != null) return;
    if (_textToolsOpen) closeTextTools(refocus: false);
    if (_barTool != null) closeTextTool(refocus: false);
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
    // The find bar may stay open with the user typing in it.
    if (!searchFocus.hasFocus && !replacementFocus.hasFocus) {
      editorFocus.requestFocus();
    }
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
    var end = index + 1 < starts.length
        ? starts[index + 1] - 1
        : text.text.length;
    // A CRLF break is one break: past the line's end is before its CR.
    if (end > start &&
        end < text.text.length &&
        text.text.codeUnitAt(end - 1) == 0x0d) {
      end--;
    }
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
    _schedulePreview();
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

  /// Switches the query between literal text and a regular expression. The
  /// pattern's matches arrive from a worker shortly after, and until then
  /// the find bar shows none.
  void toggleRegularExpression() {
    _useRegularExpression = !_useRegularExpression;
    if (!_useRegularExpression) {
      _patternFind?.dispose();
      _patternFind = null;
      _revealPatternResults = false;
      _afterPatternSearch.clear();
    }
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
    _historyCursor = -1;
    _historyDraft = null;
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  void _updateMatches({required bool resetActive}) {
    _lastQuery = search.text;
    _scheduleLineCount();
    if (_searchOpen && _useRegularExpression) {
      final find = _patternFind ??= PatternFind(
        budget: _patternSearchBudget,
        onSettled: _patternSearchSettled,
      );
      find.update(
        text.text,
        search.text,
        caseSensitive: _caseSensitive,
        wholeWord: _wholeWord,
        scope: _scopeAsRecord,
      );
      // Every caller that resets the active match then reveals it, which
      // for a pattern has to wait for its matches.
      if (resetActive && find.pending) _revealPatternResults = true;
    }
    if (_searchOpen) {
      // Stay on the user's page: a new query or a replacement starts from
      // the caret.
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
    _schedulePreview();
  }

  /// Searches again after an edit without moving the user: the page and the
  /// active match are found again at their offsets carried through the edit,
  /// so typing anywhere keeps the find bar on the same occurrence.
  void _followEdit(String before) {
    _Edit? edit;
    _scheduleLineCount();
    final find = _useRegularExpression ? _patternFind : null;
    if (find != null || _searchScope != null) {
      // Carried through the edit first, so the pages below come from the
      // edited text while it is searched again — and the stored scope is
      // mapped through, or dropped when the edit consumed it.
      edit = _Edit.between(before, text.text);
      // The stored scope maps through first — dropped when the edit
      // consumed it — so the pattern search it reschedules runs under the
      // mapped bounds, not the stale ones.
      final scope = _searchScope;
      if (scope != null) {
        final start = edit.map(scope.start).clamp(0, text.text.length);
        final end = edit.map(scope.end).clamp(start, text.text.length);
        _searchScope = start < end ? TextRange(start: start, end: end) : null;
        text.setSearchScope(_searchScope);
      }
      if (find != null) {
        find.followEdit(
          before,
          text.text,
          start: edit._start,
          end: edit._end,
          delta: edit._delta,
          scope: _scopeAsRecord,
        );
      }
    }
    if (_matches.isEmpty ||
        _activeMatch < 0 ||
        _activeMatch >= _matches.length) {
      _updateMatches(resetActive: false);
      return;
    }
    _lastQuery = search.text;
    edit ??= _Edit.between(before, text.text);
    _stayOn(
      active: edit.map(_matches[_activeMatch].start),
      pageStart: edit.map(_matches.first.start),
    );
  }

  /// Shows the page and the match the user was on, found again at [active]
  /// and on the page that starts at [pageStart].
  void _stayOn({required int active, required int pageStart}) {
    if (_matchOffset == 0) {
      _showPage(_page(), offset: 0);
    } else {
      _showPageFrom(pageStart);
    }
    // Matches added earlier on the page can push the active one past it.
    if (_matches.isEmpty ||
        (_matchesMayContinue && _matches.last.start < active)) {
      _showPageFrom(active);
    }
    final index = _matches.indexWhere((match) => match.start >= active);
    // With the active occurrence gone and nothing after it, the nearest
    // earlier match takes its place.
    _activeMatch = _matches.isEmpty
        ? -1
        : index < 0
        ? _matches.length - 1
        : index;
    _updatingSearch = true;
    try {
      text.setSearchMatches(_matches, _activeMatch);
    } finally {
      _updatingSearch = false;
    }
    _schedulePreview();
  }

  void nextMatch() {
    _recordHistory();
    _findAgain(1);
  }

  void previousMatch() {
    _recordHistory();
    _findAgain(-1);
  }

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
      // With nothing focused, the reopened find field would take focus as it
      // appears, and typing would edit the query instead of the document.
      if (!textFocusNodes.any((node) => node.hasFocus)) {
        editorFocus.requestFocus();
      }
      // Makes the first match at or after the caret active.
      _updateMatches(resetActive: true);
      if (patternSearchPending) {
        _afterPatternSearch.add(() => _stepReopened(delta, selection));
        _notify();
        return;
      }
      _stepReopened(delta, selection);
      return;
    }
    if (patternSearchPending) {
      _afterPatternSearch.add(() => _findAgain(delta));
      return;
    }
    _stepMatch(delta);
  }

  /// Find Next or Previous from a find bar that was closed, once its matches
  /// are known: [selection] is where the caret was when it was asked.
  void _stepReopened(int delta, TextSelection selection) {
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
    _stepMatch(delta);
  }

  /// Adopts a pattern search's answer, keeping the user's place when it only
  /// refreshed an edited text, then runs the find commands that waited for
  /// it.
  void _patternSearchSettled() {
    if (_disposed || !_searchOpen) return;
    final reveal = _revealPatternResults;
    _revealPatternResults = false;
    if (reveal || _activeMatch < 0 || _activeMatch >= _matches.length) {
      _updateMatches(resetActive: reveal);
      if (reveal) _revealRequest++;
    } else {
      _stayOn(
        active: _matches[_activeMatch].start,
        pageStart: _matches.first.start,
      );
    }
    // _updateMatches/_stayOn already scheduled the preview for the settled
    // matches; a queued command may step it right away, which reschedules.
    final waiting = List.of(_afterPatternSearch);
    _afterPatternSearch.clear();
    for (final command in waiting) {
      command();
    }
    _notify();
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
      _schedulePreview();
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
    _schedulePreview();
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
    final first = _page();
    if (first.matches.length >= searchMatchLimit &&
        first.matches.last.start < anchor) {
      final later = _pageFrom(anchor);
      if (later.page.matches.isNotEmpty) {
        _showPage(later.page, offset: later.offset);
        return;
      }
    }
    _showPage(first, offset: 0);
  }

  /// The page that starts with the first match at or after [anchor]. It
  /// continues the enumeration after the last match before the anchor, so it
  /// never overlaps the page before it, and [offset] counts the matches
  /// before it.
  ({SearchResult page, int offset}) _pageFrom(int anchor) {
    final before = _page(start: anchor, reverse: true, limit: 1);
    if (before.matches.isEmpty) return (page: _page(), offset: 0);
    return (
      page: _page(start: before.matches.last.end),
      offset: before.precedingCount! + 1,
    );
  }

  void _showPageFrom(int anchor) {
    final later = _pageFrom(anchor);
    _showPage(later.page, offset: later.offset);
  }

  void _showPage(SearchResult page, {required int offset}) => _adoptPage(
    page.matches,
    offset: offset,
    mayContinue: page.matches.length >= searchMatchLimit,
  );

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
    if (_useRegularExpression) {
      // The engine folds case itself, so the host's fold is not involved.
      _caseFolding = CaseFolding.exact;
      return _patternFind?.page(
            text.text,
            start: start,
            scope: _scopeAsRecord,
            reverse: reverse,
            limit: limit,
          ) ??
          const SearchResult(
            matches: [],
            caseFolding: CaseFolding.exact,
            precedingCount: 0,
          );
    }
    final result = searchText(
      text.text,
      search.text,
      caseSensitive: _caseSensitive,
      wholeWord: _wholeWord,
      fold: _fold,
      limit: limit,
      start: start,
      scope: _searchScope,
      reverse: reverse,
    );
    // Reported, not hidden: a case-insensitive search that could not fold
    // this text found fewer matches than the user asked for.
    _caseFolding = result.caseFolding;
    return result;
  }

  /// Replaces the active match. A regular expression's replacement expands
  /// `$1`, `${1}`, `${name}` and `$$` — backslashes stay literal by owner
  /// decision; while its search is on its way, the
  /// replacement waits for it, so it never acts on a match carried through
  /// an edit that may no longer match.
  void replaceCurrent() {
    if (editingLocked || isBusy || _activeMatch < 0 || _matches.isEmpty) {
      return;
    }
    if (patternSearchPending) {
      _afterPatternSearch.add(replaceCurrent);
      return;
    }
    _recordHistory();
    final match = _matches[_activeMatch];
    var replaced = replacement.text;
    if (_useRegularExpression) {
      // The worker found this match in this very text, so repeating the one
      // anchored attempt here costs no more than it did within the budget.
      final found = _patternFind?.pattern?.matchAt(
        text.text,
        match.start,
        wholeWord: _wholeWord,
      );
      if (found == null || found.end != match.end) return;
      replaced = expandPatternReplacement(replacement.text, found);
    }
    final value = text.text.replaceRange(match.start, match.end, replaced);
    text.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: match.start + replaced.length),
    );
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  /// Replace every occurrence, including matches beyond the display cap.
  /// Offsets come from the original text so replacements never match
  /// themselves. Completes with whether anything was replaced.
  ///
  /// Literal text is replaced before this returns. A regular expression is
  /// replaced in a worker under the search budget, expanding `$1`, `${1}`,
  /// `${name}` and `$$` (backslashes stay literal); its result is dropped if
  /// the document was edited,
  /// locked or closed meanwhile, since it describes the text as it was, and
  /// a timeout is reported through [patternFailure].
  Future<bool> replaceAll() async {
    if (editingLocked || isBusy || search.text.isEmpty) return false;
    _recordHistory();
    if (_useRegularExpression) return _replaceAllMatches();
    final source = text.text;
    final matches = findSearchMatches(
      source,
      search.text,
      caseSensitive: _caseSensitive,
      wholeWord: _wholeWord,
      limit: source.length + 1,
      fold: _fold,
      scope: _searchScope,
    );
    if (matches.isEmpty) return false;
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
    return true;
  }

  Future<bool> _replaceAllMatches() async {
    final source = text.text;
    // Replace All covers the matches that find commands queued on the
    // search were waiting for; run later, they would edit its result.
    _revealPatternResults = false;
    _afterPatternSearch.clear();
    final find = _patternFind ??= PatternFind(
      budget: _patternSearchBudget,
      onSettled: _patternSearchSettled,
    );
    final outcome = await find.replaceAll(
      source,
      search.text,
      replacement.text,
      caseSensitive: _caseSensitive,
      wholeWord: _wholeWord,
      scope: _scopeAsRecord,
    );
    if (_disposed) return false;
    // By content: an input method may send the same text back as a new
    // string, and one comparison per Replace All is cheap.
    if (editingLocked || isBusy || text.text != source) {
      _notify();
      return false;
    }
    if (outcome case PatternCompleted(value: final replaced?)) {
      text.value = TextEditingValue(
        text: replaced.text,
        selection: TextSelection.collapsed(offset: replaced.firstEnd),
      );
      _updateMatches(resetActive: true);
      _revealRequest++;
      _notify();
      return true;
    }
    // Nothing matched, or the pattern is unusable, timed out or was
    // replaced by a newer Replace All; a failure is in patternFailure.
    _notify();
    return false;
  }

  // ── Search history, selection seeds and replacement preview ──

  /// Records the find field's query in the session history. Empty queries
  /// and repeats of the newest add nothing; older repeats move to front.
  void _recordHistory() {
    searchHistory.push(search.text);
    _historyCursor = -1;
    _historyDraft = null;
  }

  /// Recalls history with the keyboard: [older] true for Up, false for
  /// Down. While an input method composes, recall stays off so it cannot
  /// steal the composition. Returns false when there is nothing to recall.
  bool recallSearchHistory({required bool older}) {
    // Recall edits the find field, so it is the find field's composition
    // that must not be disturbed — not the document's.
    if (search.value.composing.isValid) return false;
    final queries = searchHistory.queries;
    if (queries.isEmpty) return false;
    if (_historyCursor < 0) {
      if (!older) return false;
      _historyDraft = search.text;
      _historyCursor = 0;
    } else if (older) {
      if (_historyCursor + 1 >= queries.length) return false;
      _historyCursor++;
    } else {
      _historyCursor--;
      if (_historyCursor < 0) {
        _updatingQuery = true;
        try {
          search.text = _historyDraft ?? '';
        } finally {
          _updatingQuery = false;
        }
        _historyDraft = null;
        _updateMatches(resetActive: true);
        _notify();
        return true;
      }
    }
    _updatingQuery = true;
    try {
      search.text = queries[_historyCursor];
      search.selection = TextSelection(
        baseOffset: 0,
        extentOffset: queries[_historyCursor].length,
      );
    } finally {
      _updatingQuery = false;
    }
    _updateMatches(resetActive: true);
    _notify();
    return true;
  }

  /// Use Selection for Find: seeds the find field from the selection without
  /// opening the bar or moving focus, so Cmd+G finds it next. A multiline
  /// or long selection is ignored; in regex mode the text is escaped so a
  /// selected `a.b` does not also find `axb`.
  void useSelectionForFind() {
    if (!hasSelection) return;
    final selected = text.selection.textInside(text.text);
    if (selected.isEmpty || selected.contains('\n') || selected.length > 200) {
      return;
    }
    final query = _useRegularExpression ? RegExp.escape(selected) : selected;
    _updatingQuery = true;
    try {
      search.text = query;
    } finally {
      _updatingQuery = false;
    }
    _recordHistory();
    if (_searchOpen) {
      _updateMatches(resetActive: true);
      _revealRequest++;
    }
    _notify();
  }

  /// Find Selected Text: opens the find bar seeded from the selection using
  /// the existing open/prefill/focus flow. With no selection, opens the bar
  /// as usual.
  void findSelectedText() {
    openSearch();
    _recordHistory();
  }

  void _replacementChanged() {
    _historyCursor = -1;
    _historyDraft = null;
    _schedulePreview();
    // The literal path inside answers synchronously without notifying, so
    // the preview line repaints for every keystroke in the replace field.
    _notify();
  }

  /// Schedules the active-match replacement preview. Literal mode answers
  /// synchronously; regex mode debounces into a worker under the search
  /// budget, discarding answers for a text, query, template or active match
  /// that changed meanwhile. While an input method composes in any of the
  /// three fields, the preview waits: the composition owns the text.
  void _schedulePreview() {
    if (!_searchOpen || !_replaceOpen) {
      _clearPreview(notify: false);
      return;
    }
    if (text.value.composing.isValid ||
        search.value.composing.isValid ||
        replacement.value.composing.isValid) {
      return;
    }
    final active = _activeMatch >= 0 && _activeMatch < _matches.length
        ? _matches[_activeMatch]
        : null;
    final template = replacement.text;
    if (active == null || template.isEmpty) {
      _clearPreview(notify: false);
      return;
    }
    if (!_useRegularExpression) {
      _replacementPreviewTimer?.cancel();
      _replacementPreviewTimer = null;
      _previewPending = false;
      _previewFailure = null;
      _replacementPreview = ReplacementPreview(
        expanded: truncatePreview(template, replacementPreviewLimit),
        groups: const [],
        matchStart: active.start,
        matchEnd: active.end,
      );
      _replacementPreviewKey = _PreviewKey(
        text.text,
        search.text,
        template,
        _caseSensitive,
        _wholeWord,
        false,
        active.start,
        active.end,
      );
      return;
    }
    if (patternSearchPending || _patternFind?.pattern == null) return;
    final key = _PreviewKey(
      text.text,
      search.text,
      template,
      _caseSensitive,
      _wholeWord,
      true,
      active.start,
      active.end,
    );
    if (_replacementPreviewKey == key &&
        (_previewPending || _replacementPreview != null)) {
      return;
    }
    _replacementPreviewKey = key;
    _previewPending = true;
    _previewFailure = null;
    final generation = ++_replacementPreviewGeneration;
    _replacementPreviewTimer?.cancel();
    _replacementPreviewTimer = Timer(
      PatternFind.settleDelay,
      () => unawaited(_runPreview(key, generation)),
    );
  }

  Future<void> _runPreview(_PreviewKey key, int generation) async {
    final worker = _replacementPreviewWorker ??= PatternWorker(
      budget: _patternSearchBudget,
    );
    final outcome = await worker.previewReplacement(
      key.text,
      key.query,
      key.template,
      key.matchStart,
      caseSensitive: key.caseSensitive,
      wholeWord: key.wholeWord,
    );
    if (_disposed ||
        generation != _replacementPreviewGeneration ||
        !identical(key, _replacementPreviewKey) ||
        text.text != key.text ||
        _activeMatch < 0 ||
        _activeMatch >= _matches.length ||
        _matches[_activeMatch].start != key.matchStart ||
        _matches[_activeMatch].end != key.matchEnd) {
      return;
    }
    _previewPending = false;
    switch (outcome) {
      case PatternCompleted(:final value):
        _replacementPreview = value;
        _previewFailure = null;
      case PatternFailed(:final failure):
        _replacementPreview = null;
        _previewFailure = failure;
      case PatternCancelled():
        // A successor already owns the pending flag when it cancelled this
        // one; resetting keeps it honest when none did.
        _previewPending = false;
        return;
    }
    _notify();
  }

  void _clearPreview({bool notify = true}) {
    _replacementPreviewGeneration++;
    _replacementPreviewTimer?.cancel();
    _replacementPreviewTimer = null;
    _previewPending = false;
    _replacementPreview = null;
    _previewFailure = null;
    _replacementPreviewKey = null;
    _replacementPreviewWorker?.dispose();
    _replacementPreviewWorker = null;
    if (notify) _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _patternFind?.dispose();
    _linesWorker?.dispose();
    _linesCountDelay?.cancel();
    _replacementPreviewTimer?.cancel();
    _replacementPreviewWorker?.dispose();
    _replacementPreviewWorker = null;
    text.removeListener(_textChanged);
    search.removeListener(_queryChanged);
    replacement.removeListener(_replacementChanged);
    extraction.removeListener(_extractionChanged);
    goToLineInput.removeListener(_goToLineEdited);
    text.dispose();
    search.dispose();
    replacement.dispose();
    extraction.dispose();
    goToLineInput.dispose();
    for (final MapEntry(:key, :value) in _fieldListeners.entries) {
      key.removeListener(value);
    }
    _fieldListeners.clear();
    _textFocusNodes.clear();
    editorFocus.dispose();
    searchFocus.dispose();
    replacementFocus.dispose();
    extractionFocus.dispose();
    goToLineFocus.dispose();
    scroll.dispose();
    undoController.dispose();
    _barPreviewTimer?.cancel();
    super.dispose();
  }
}

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

/// What a replacement preview was requested for. A newer query, template,
/// text, flag or active match makes an answer stale, so it is discarded.
final class _PreviewKey {
  const _PreviewKey(
    this.text,
    this.query,
    this.template,
    this.caseSensitive,
    this.wholeWord,
    this.regularExpression,
    this.matchStart,
    this.matchEnd,
  );

  final String text;
  final String query;
  final String template;
  final bool caseSensitive;
  final bool wholeWord;

  /// Literal and regex previews differ even for identical inputs: literal
  /// inserts the template as it stands, regex expands its groups. The mode
  /// is part of the key so a mode toggle forces a recomputation.
  final bool regularExpression;
  final int matchStart;
  final int matchEnd;

  @override
  bool operator ==(Object other) =>
      other is _PreviewKey &&
      identical(text, other.text) &&
      query == other.query &&
      template == other.template &&
      caseSensitive == other.caseSensitive &&
      wholeWord == other.wholeWord &&
      regularExpression == other.regularExpression &&
      matchStart == other.matchStart &&
      matchEnd == other.matchEnd;

  @override
  int get hashCode => Object.hash(
    identityHashCode(text),
    query,
    template,
    caseSensitive,
    wholeWord,
    regularExpression,
    matchStart,
    matchEnd,
  );
}

/// Where one edit changed the text, found by comparing it before and after:
/// the unchanged runs at both ends are the prefix and suffix, and the rest
/// is what the edit replaced. Lets offsets from before the edit be carried
/// to where the same text sits after it.
final class _Edit {
  _Edit._(this._start, this._end, this._delta);

  factory _Edit.between(String before, String after) {
    final shorter = before.length < after.length ? before.length : after.length;
    var prefix = 0;
    while (prefix < shorter &&
        before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < shorter - prefix &&
        before.codeUnitAt(before.length - 1 - suffix) ==
            after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    return _Edit._(
      prefix,
      before.length - suffix,
      after.length - before.length,
    );
  }

  /// The replaced run in the text before the edit.
  final int _start;
  final int _end;
  final int _delta;

  /// [offset], from the text before the edit, in the text after it. Text
  /// typed at the offset lands before it; an offset inside the replaced run
  /// moves to the end of what replaced it.
  int map(int offset) {
    if (offset >= _end) return offset + _delta;
    if (offset <= _start) return offset;
    return _end + _delta;
  }
}
