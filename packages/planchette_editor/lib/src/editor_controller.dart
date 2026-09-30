import 'dart:async';
import 'dart:collection';

import 'package:clock/clock.dart';
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
        moveLines,
        patternSearchBudget;

import 'code_editing_controller.dart';
import 'pattern_find.dart';
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
    this.undoQuiet = _defaultUndoQuiet,
    TextToolHistory? toolHistory,
  }) : _displayPath = displayPath,
       _fold = caseFolder ?? _defaultCaseFolder,
       _patternSearchBudget = patternSearchBudget ?? core.patternSearchBudget,
       _toolHistory = toolHistory ?? TextToolHistory(),
       _now = now ?? clock.now {
    text = CodeEditingController(language: syntaxLanguageFor(displayPath));
    text.addListener(_textChanged);
    search.addListener(_queryChanged);
    goToLineInput.addListener(_goToLineEdited);
    for (final node in [
      editorFocus,
      searchFocus,
      replacementFocus,
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

  /// How long one regular-expression search may run in its worker before it
  /// is stopped and the find bar reports [PatternTimedOut]. Defaults to
  /// [core.patternSearchBudget].
  final Duration _patternSearchBudget;

  /// The clock the undo-quiet window is measured on; injectable for tests.
  final DateTime Function() _now;

  /// The largest buffer a text tool may write back, as UTF-8: the same
  /// limit loading enforces. Tools that only remove text can always run;
  /// a tool whose result outgrows this is refused before it applies.
  final int maximumBytes;

  /// How old the last value change must be before a tool run applies, so
  /// the run lands in its own undo step. Flutter's undo history merges
  /// value changes that arrive inside this window — currently 500 ms in
  /// the framework — and offers no way to flush a pending step, so a run
  /// has to wait it out instead. A change during the wait restarts it.
  final Duration undoQuiet;

  static const _defaultUndoQuiet = Duration(milliseconds: 500);

  /// The clock the last field change was stamped with; the pending undo
  /// step it belongs to commits [_undoQuiet] after this.
  DateTime _lastValueChangeAt = DateTime.fromMillisecondsSinceEpoch(0);
  TextEditingValue _seenValue = const TextEditingValue();

  late final CodeEditingController text;
  final search = TextEditingController();
  final replacement = TextEditingController();
  final goToLineInput = TextEditingController();
  final editorFocus = FocusNode();
  final searchFocus = FocusNode();
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
  /// does, so they cannot be in the fixed constructor list.
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

  /// The regular-expression search, while that mode is on.
  PatternFind? _patternFind;

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
  /// a lone CR; each counts once. An untitled buffer counts as a new file is
  /// saved, with LF breaks and no mark. A host that saves raw line endings
  /// writes exactly [byteCount] bytes plus any byte-order mark instead.
  int get fileByteCount {
    final document = _document;
    _updateMetrics();
    // Folding to LF drops the CR of each CRLF and turns a lone CR into LF.
    final breaks = lineStarts.length - 1 + _returns - _returnNewlines;
    return byteCount -
        _returnNewlines +
        (document?.lineEnding == LineEnding.crlf ? breaks : 0) +
        (document?.hasUtf8Bom ?? false ? 3 : 0);
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

  // ── Text tools ──

  /// The report of the most recent text-tool run, for the result notice
  /// the view shows; cleared by the next change to the field's value.
  TextToolReport? get toolReport => _toolReport;

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
      // Preflight the size the run would leave. A growing result must stay
      // inside the limit; a shrinking or equal one is fine.
      if (outcome is TextToolChanged &&
          outcome.edit.text.length > text.text.length &&
          utf8EncodedLength(outcome.edit.text) > maximumBytes) {
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
    }
    _toolReport = TextToolReport(
      tool: tool,
      outcome: outcome,
      ranOn: resolved.ranOn,
    );
    _toolHistory.record(toolId, runOptions);
    _notify();
    return outcome;
  }

  /// The shared run history [toolReport] feeds — Repeat and Recent read
  /// from it.
  TextToolHistory get toolHistory => _toolHistory;

  /// Declared option defaults overlaid with the caller's [overrides];
  /// unknown overrides are dropped.
  Map<String, Object?> _toolOptions(
    TextTool tool,
    Map<String, Object?> overrides,
  ) => {
    for (final option in tool.options)
      option.id: overrides[option.id] ?? option.defaultValue,
  };

  TextToolContext _toolContext() => TextToolContext(
    fold: _fold,
    indentation: indentation,
    indentationPreference: _preferredIndentation,
    displayPath: _displayPath,
    now: _now,
  );

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
                  options: _barOptions,
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
    final last = text.codeUnitAt(text.length - 1);
    if (last == 0x0a || last == 0x0d) count--;
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
    // The find bar and the tool bar share one slot.
    if (_barTool != null) closeTextTool(refocus: false);
    final selection = text.selection;
    String? prefill;
    if (selection.isValid && !selection.isCollapsed) {
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
    if (_focusMemory == searchFocus || _focusMemory == replacementFocus) {
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
    // Go to Line may stay open with the user typing in it.
    if (!goToLineFocus.hasFocus) editorFocus.requestFocus();
    _notify();
  }

  void openGoToLine() {
    if (_loading || _error != null) return;
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
    _updateMatches(resetActive: true);
    _revealRequest++;
    _notify();
  }

  void _updateMatches({required bool resetActive}) {
    _lastQuery = search.text;
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
  }

  /// Searches again after an edit without moving the user: the page and the
  /// active match are found again at their offsets carried through the edit,
  /// so typing anywhere keeps the find bar on the same occurrence.
  void _followEdit(String before) {
    _Edit? edit;
    final find = _useRegularExpression ? _patternFind : null;
    if (find != null) {
      // Carried through the edit first, so the pages below come from the
      // edited text while it is searched again.
      edit = _Edit.between(before, text.text);
      find.followEdit(
        before,
        text.text,
        start: edit._start,
        end: edit._end,
        delta: edit._delta,
      );
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
      reverse: reverse,
    );
    // Reported, not hidden: a case-insensitive search that could not fold
    // this text found fewer matches than the user asked for.
    _caseFolding = result.caseFolding;
    return result;
  }

  /// Replaces the active match. A regular expression's replacement expands
  /// `$1`, `${1}`, `${name}` and `$$`; while its search is on its way, the
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
  /// `${name}` and `$$`; its result is dropped if the document was edited,
  /// locked or closed meanwhile, since it describes the text as it was, and
  /// a timeout is reported through [patternFailure].
  Future<bool> replaceAll() async {
    if (editingLocked || isBusy || search.text.isEmpty) return false;
    if (_useRegularExpression) return _replaceAllMatches();
    final source = text.text;
    final matches = findSearchMatches(
      source,
      search.text,
      caseSensitive: _caseSensitive,
      wholeWord: _wholeWord,
      limit: source.length + 1,
      fold: _fold,
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

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _patternFind?.dispose();
    text.removeListener(_textChanged);
    search.removeListener(_queryChanged);
    goToLineInput.removeListener(_goToLineEdited);
    text.dispose();
    search.dispose();
    replacement.dispose();
    goToLineInput.dispose();
    for (final MapEntry(:key, :value) in _fieldListeners.entries) {
      key.removeListener(value);
    }
    _fieldListeners.clear();
    _textFocusNodes.clear();
    editorFocus.dispose();
    searchFocus.dispose();
    replacementFocus.dispose();
    goToLineFocus.dispose();
    scroll.dispose();
    undoController.dispose();
    _barPreviewTimer?.cancel();
    super.dispose();
  }
}

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

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
