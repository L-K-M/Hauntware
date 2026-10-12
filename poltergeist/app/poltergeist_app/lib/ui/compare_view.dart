import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show
        GhostChordBinding,
        GhostChordScope,
        GhostUnmodifiedChordPolicy,
        formatShortcutActivator;
import 'package:planchette_editor/planchette_editor.dart' as pe;
import 'package:poltergeist_core/poltergeist_core.dart';

import '../l10n/app_localizations.dart';
import '../services/compare_diff_controller.dart';
import '../services/sync_compare_controller.dart';
import '../theme/app_theme.dart' show poltergeistMonoTextStyle;
import 'compact/compact_posture.dart' show compactPostureApplies;
import 'compare_diff_rows.dart';
import 'editor_strings.dart';
import 'panes/pane_format.dart';

/// The widget keys the compare view exposes to tests. Enum-valued so they
/// stay plumbing and never drift into copy.
enum CompareKey {
  changeBar,
  regionCount,
  regionPosition,
  previousChange,
  nextChange,
  layout,
  rows,
  computing,
  showFilesNow,
  noticeOverLineCap,
  noticeFailed,
  noticeIdenticalFiles,
  noticeIdenticalText,
  noticeSimplified,
}

/// What the layout switch offers: the diff's two row layouts, or each file
/// in its own editor (the v1 view, with Find and independent scrolling).
enum _CompareLayout { sideBySide, unified, separate }

/// What the body shows below the notices.
enum _Presentation {
  /// Each side in its own column: still loading, refused, unmarked, or
  /// the Separate layout.
  sides,
  computing,
  rows,
}

/// Whether a side column shows its editor or only its header above the
/// shared diff rows.
enum _SideBody { full, header }

/// n / Shift+N step through changed regions, outside text fields only.
const _nextChange = SingleActivator(LogicalKeyboardKey.keyN);
const _previousChange = SingleActivator(LogicalKeyboardKey.keyN, shift: true);

const _arrowScrollLines = 3;
const _pageScrollFraction = 0.9;

/// The width the change bar needs for one row with labelled layout
/// buttons; narrower, it takes two rows and icon-only buttons.
const double _wideChangeBarWidth = 760;

/// The most of a one-row change bar the region count may take.
const double _countShare = 0.4;

/// The read-only, side-by-side text comparison (06 §6), opened from a
/// sync-plan row or by File ▸ Compare Files.
final class CompareView extends StatefulWidget {
  const CompareView({
    super.key,
    required this.controller,
    this.title,
    this.clock,
    @visibleForTesting this.startDiff,
  });

  /// Owned by this route so teardown cancels both side loads.
  final SyncCompareController controller;

  /// The app bar title; null shows the request's relative path.
  final String? title;

  /// Test seam for the metadata header's relative modified-time labels.
  final DateTime Function()? clock;

  /// Test seam for the diff worker; null runs [startTextComparison].
  final TextComparisonStarter? startDiff;

  @override
  State<CompareView> createState() => _CompareViewState();
}

class _CompareViewState extends State<CompareView> {
  late CompareDiffController _diff;
  late Listenable _listenable;

  /// The layout picked for this route; null follows the posture.
  _CompareLayout? _chosenLayout;

  /// The region n / Shift+N last moved to.
  int? _activeRegion;
  final _rowsController = CompareRowsController();
  final _bodyFocus = FocusNode();

  // The side columns move between the full and the header-only body, so
  // each keeps its editor and find state across layout switches.
  final _leftSideKey = GlobalKey();
  final _rightSideKey = GlobalKey();

  TextComparisonComputed? _rowsFor;
  final _rowsCache = <LineDiffLayout, LineDiffRows>{};

  /// The row layout the body last showed, null outside the rows: a change
  /// of layout, by the switch or by the posture after a rotation, keeps the
  /// reader's place from it.
  _CompareLayout? _shownLayout;

  @override
  void initState() {
    super.initState();
    _attach();
    unawaited(widget.controller.start());
    // Sides are often loaded before the view mounts.
    _syncDiff();
  }

  @override
  void didUpdateWidget(CompareView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.controller, widget.controller)) return;

    oldWidget.controller.removeListener(_syncDiff);
    _diff.dispose();
    oldWidget.controller.dispose();
    _attach();
    _activeRegion = null;
    _shownLayout = null;
    _rowsFor = null;
    _rowsCache.clear();
    unawaited(widget.controller.start());
    _syncDiff();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncDiff);
    _diff.dispose();
    widget.controller.dispose();
    _rowsController.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  void _attach() {
    _diff = CompareDiffController(
      start: widget.startDiff ?? startTextComparison,
    );
    _listenable = Listenable.merge([widget.controller, _diff]);
    widget.controller.addListener(_syncDiff);
  }

  /// Hands the diff both documents once both sides have loaded.
  void _syncDiff() {
    final left = widget.controller.left;
    final right = widget.controller.right;
    final ready =
        left.phase == SyncComparePhase.ready &&
        right.phase == SyncComparePhase.ready;
    // Someone typing in one side's find bar, or reading in its editor, while
    // the other side finished loading keeps that editor: the rows would
    // replace it under their input.
    if (ready &&
        _chosenLayout == null &&
        _diff.phase == CompareDiffPhase.waiting &&
        _editingInView()) {
      _chosenLayout = _CompareLayout.separate;
    }
    _diff.compare(ready ? left.document : null, ready ? right.document : null);
  }

  /// Whether focus is in a text field: here, only the side editors and
  /// their find bars have one.
  static bool _editingInView() =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<EditableText>() !=
      null;

  _CompareLayout _layout(BuildContext context) =>
      _chosenLayout ??
      (compactPostureApplies(
            width: MediaQuery.sizeOf(context).width,
            platform: Theme.of(context).platform,
          )
          ? _CompareLayout.unified
          : _CompareLayout.sideBySide);

  _Presentation _presentation(_CompareLayout layout) {
    if (layout == _CompareLayout.separate) return _Presentation.sides;
    return switch (_diff.phase) {
      CompareDiffPhase.computing => _Presentation.computing,
      CompareDiffPhase.ready => _Presentation.rows,
      CompareDiffPhase.waiting ||
      CompareDiffPhase.overLineCap ||
      CompareDiffPhase.failed => _Presentation.sides,
    };
  }

  static LineDiffLayout _lineLayout(_CompareLayout layout) =>
      layout == _CompareLayout.unified
      ? LineDiffLayout.unified
      : LineDiffLayout.sideBySide;

  LineDiffRows _rowsOf(TextComparisonComputed result, LineDiffLayout layout) {
    if (!identical(result, _rowsFor)) {
      _rowsCache.clear();
      _rowsFor = result;
    }
    return _rowsCache.putIfAbsent(
      layout,
      () => alignLineDiff(result.diff, layout),
    );
  }

  /// The rows the body shows, or null when it shows anything else.
  LineDiffRows? _shownRows(BuildContext context) {
    final layout = _layout(context);
    final result = _diff.result;
    if (result == null || _presentation(layout) != _Presentation.rows) {
      return null;
    }
    return _rowsOf(result, _lineLayout(layout));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The chord scope wraps the whole route, app bar included, so n and
    // Shift+N step wherever focus sits outside a text field.
    return ListenableBuilder(
      listenable: _listenable,
      builder: (context, child) {
        final rows = _shownRows(context);
        return GhostChordScope(
          unmodifiedPolicy: GhostUnmodifiedChordPolicy.allow,
          suspendWhileEditing: true,
          bindings: rows != null && rows.regionCount > 0
              ? [
                  GhostChordBinding(
                    activator: _nextChange,
                    onInvoke: () => _step(rows, 1),
                  ),
                  GhostChordBinding(
                    activator: _previousChange,
                    onInvoke: () => _step(rows, -1),
                  ),
                ]
              : const [],
          child: child!,
        );
      },
      child: Scaffold(
        key: const ValueKey('sync.compare.view'),
        appBar: AppBar(
          title: Text(
            widget.title ??
                l10n.syncCompareTitle(widget.controller.request.relativePath),
          ),
        ),
        body: ListenableBuilder(
          listenable: _listenable,
          builder: (context, _) {
            final left = widget.controller.left;
            final right = widget.controller.right;
            final notices = _differenceNotices(l10n, left, right);
            final now = widget.clock?.call() ?? DateTime.now();
            final layout = _layout(context);
            final presentation = _presentation(layout);
            final result = _diff.result;
            final rows = _shownRows(context);
            _keepPlaceAcrossLayouts(layout, presentation, result);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (notices.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                    child: Wrap(spacing: 8, runSpacing: 4, children: notices),
                  ),
                ..._diffNotices(context, l10n),
                if (result != null) ...[
                  _changeBar(context, l10n, layout, rows, result),
                  const Divider(height: 1),
                ],
                Expanded(
                  child: switch (presentation) {
                    _Presentation.sides => _sides(left, right, now),
                    _Presentation.computing || _Presentation.rows => _diffBody(
                      context,
                      l10n,
                      left,
                      right,
                      now,
                      result: result,
                      rows: rows,
                      layout: layout,
                    ),
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Keeps the active region, or else the line at the top, in view when the
  /// rows change layout: by the switch, or by the posture after a rotation
  /// or resize.
  void _keepPlaceAcrossLayouts(
    _CompareLayout layout,
    _Presentation presentation,
    TextComparisonComputed? result,
  ) {
    final previous = _shownLayout;
    final showsRows = result != null && presentation == _Presentation.rows;
    _shownLayout = showsRows ? layout : null;
    if (!showsRows || previous == layout) return;

    var anchorLeft = -1;
    var anchorRight = -1;
    if (previous != null) {
      final shown = _rowsOf(result, _lineLayout(previous));
      final top = _rowsController.topVisibleRow;
      if (top < shown.length) {
        anchorLeft = shown.leftLineAt(top);
        anchorRight = shown.rightLineAt(top);
      }
    }
    final active = _activeRegion;
    if (active == null && anchorLeft < 0 && anchorRight < 0) return;

    final rows = _rowsOf(result, _lineLayout(layout));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !identical(_diff.result, result)) return;
      if (active != null && active < rows.regionCount) {
        _rowsController.reveal(rows.regionFirstRow(active));
      } else if (anchorLeft >= 0) {
        _rowsController.jumpToRow(rows.rowOfLeftLine(anchorLeft));
      } else if (anchorRight >= 0) {
        _rowsController.jumpToRow(rows.rowOfRightLine(anchorRight));
      }
    });
  }

  Widget _side(
    GlobalKey key,
    SyncCompareSideState state,
    String label,
    DateTime now,
    _SideBody body,
  ) {
    return _CompareSide(
      key: key,
      controller: widget.controller,
      state: state,
      label: label,
      now: now,
      body: body,
      onFindInSeparate: _openSeparate,
    );
  }

  /// Each file in its own column: the v1 view, and every state the diff
  /// cannot cover.
  Widget _sides(
    SyncCompareSideState left,
    SyncCompareSideState right,
    DateTime now,
  ) {
    final l10n = AppLocalizations.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: KeyedSubtree(
            key: const ValueKey('sync.compare.left'),
            child: _side(
              _leftSideKey,
              left,
              l10n.syncCompareSideLeft,
              now,
              _SideBody.full,
            ),
          ),
        ),
        const VerticalDivider(width: 1),
        Expanded(
          child: KeyedSubtree(
            key: const ValueKey('sync.compare.right'),
            child: _side(
              _rightSideKey,
              right,
              l10n.syncCompareSideRight,
              now,
              _SideBody.full,
            ),
          ),
        ),
      ],
    );
  }

  /// Both headers above one shared body: the computing card or the rows.
  Widget _diffBody(
    BuildContext context,
    AppLocalizations l10n,
    SyncCompareSideState left,
    SyncCompareSideState right,
    DateTime now, {
    required TextComparisonComputed? result,
    required LineDiffRows? rows,
    required _CompareLayout layout,
  }) {
    final leftDocument = _diff.left;
    final rightDocument = _diff.right;
    final body =
        result != null &&
            rows != null &&
            leftDocument != null &&
            rightDocument != null
        ? CompareDiffRows(
            key: const ValueKey(CompareKey.rows),
            result: result,
            leftText: leftDocument.text,
            rightText: rightDocument.text,
            rows: rows,
            layout: _lineLayout(layout),
            activeRegion: _activeRegion,
            controller: _rowsController,
          )
        : _computingCard(context, l10n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('sync.compare.left'),
                  child: _side(
                    _leftSideKey,
                    left,
                    l10n.syncCompareSideLeft,
                    now,
                    _SideBody.header,
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: KeyedSubtree(
                  key: const ValueKey('sync.compare.right'),
                  child: _side(
                    _rightSideKey,
                    right,
                    l10n.syncCompareSideRight,
                    now,
                    _SideBody.header,
                  ),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Listener(
            onPointerDown: (_) => _bodyFocus.requestFocus(),
            child: Focus(
              focusNode: _bodyFocus,
              autofocus: true,
              onKeyEvent: _onBodyKey,
              child: body,
            ),
          ),
        ),
      ],
    );
  }

  Widget _computingCard(BuildContext context, AppLocalizations l10n) => _card(
    context,
    key: const ValueKey(CompareKey.computing),
    children: [
      const Center(child: CircularProgressIndicator()),
      const SizedBox(height: 12),
      Semantics(
        liveRegion: true,
        child: Text(l10n.syncCompareComputing, textAlign: TextAlign.center),
      ),
      const SizedBox(height: 8),
      Center(
        child: TextButton(
          key: const ValueKey(CompareKey.showFilesNow),
          onPressed: _openSeparate,
          child: Text(l10n.syncCompareShowFilesNow),
        ),
      ),
    ],
  );

  /// The diff's count, position, step buttons and layout switch, styled
  /// like the find bar's controls.
  Widget _changeBar(
    BuildContext context,
    AppLocalizations l10n,
    _CompareLayout layout,
    LineDiffRows? rows,
    TextComparisonComputed result,
  ) {
    final theme = Theme.of(context);
    final count = result.diff.regions.length;
    final navigable = rows != null && count > 0;
    final active = navigable ? _activeRegion : null;
    // Each announcement is a node of its own; merged into the body, the
    // count would be read with both headers and the layout label.
    final countLabel = Semantics(
      container: true,
      liveRegion: true,
      child: Text(
        l10n.syncCompareRegionCount(count),
        key: const ValueKey(CompareKey.regionCount),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelLarge,
      ),
    );
    final position = active == null
        ? null
        : Semantics(
            container: true,
            liveRegion: true,
            label: l10n.syncCompareRegionAnnouncement(active + 1, count),
            child: ExcludeSemantics(
              child: Text(
                l10n.editorMatchCount(active + 1, count),
                key: const ValueKey(CompareKey.regionPosition),
                style: theme.textTheme.labelSmall,
              ),
            ),
          );
    final previous = IconButton(
      key: const ValueKey(CompareKey.previousChange),
      visualDensity: VisualDensity.compact,
      tooltip: l10n.syncComparePreviousChange(
        formatShortcutActivator(_previousChange, theme.platform)!,
      ),
      onPressed: navigable ? () => _step(rows, -1) : null,
      icon: const Icon(Icons.keyboard_arrow_up),
    );
    final next = IconButton(
      key: const ValueKey(CompareKey.nextChange),
      visualDensity: VisualDensity.compact,
      tooltip: l10n.syncCompareNextChange(
        formatShortcutActivator(_nextChange, theme.platform)!,
      ),
      onPressed: navigable ? () => _step(rows, 1) : null,
      icon: const Icon(Icons.keyboard_arrow_down),
    );
    return Padding(
      key: const ValueKey(CompareKey.changeBar),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 8, 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final wide =
              constraints.maxWidth >=
              MediaQuery.textScalerOf(context).scale(_wideChangeBarWidth);
          final toggle = _layoutToggle(l10n, layout, iconsOnly: !wide);
          // The controls scroll sideways rather than overflow when a font
          // or text scale makes them wider than the bar.
          Widget controls(List<Widget> children) => Align(
            alignment: AlignmentDirectional.centerEnd,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(mainAxisSize: MainAxisSize.min, children: children),
            ),
          );
          if (wide) {
            return Row(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: constraints.maxWidth * _countShare,
                  ),
                  child: countLabel,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: controls([
                    ?position,
                    previous,
                    next,
                    const SizedBox(width: 8),
                    toggle,
                  ]),
                ),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              countLabel,
              Row(
                children: [
                  ?position,
                  Expanded(child: controls([previous, next, toggle])),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _layoutToggle(
    AppLocalizations l10n,
    _CompareLayout layout, {
    required bool iconsOnly,
  }) {
    ButtonSegment<_CompareLayout> segment(
      _CompareLayout value,
      IconData icon,
      String label, {
      String? tooltip,
    }) => ButtonSegment(
      value: value,
      icon: Icon(icon),
      label: iconsOnly ? null : Text(label),
      tooltip: iconsOnly ? label : tooltip,
    );

    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: l10n.syncCompareLayoutLabel,
      child: SegmentedButton<_CompareLayout>(
        key: const ValueKey(CompareKey.layout),
        showSelectedIcon: false,
        segments: [
          segment(
            _CompareLayout.sideBySide,
            Icons.vertical_split,
            l10n.syncCompareLayoutSideBySide,
          ),
          segment(
            _CompareLayout.unified,
            Icons.view_agenda,
            l10n.syncCompareLayoutUnified,
          ),
          segment(
            _CompareLayout.separate,
            Icons.find_in_page,
            l10n.syncCompareLayoutSeparate,
            tooltip: l10n.syncCompareLayoutSeparateTooltip,
          ),
        ],
        selected: {layout},
        onSelectionChanged: (selection) => _selectLayout(selection.single),
      ),
    );
  }

  /// Moves to the next or previous changed region, wrapping around. The
  /// first step starts from the top of the viewport rather than the file.
  void _step(LineDiffRows rows, int delta) {
    final count = rows.regionCount;
    if (count == 0) return;

    final active = _activeRegion;
    final int target;
    if (active != null && active < count) {
      target = (active + delta) % count;
    } else {
      final top = _rowsController.topVisibleRow;
      var region = delta > 0 ? 0 : count - 1;
      for (var r = 0; r < count; r++) {
        final first = rows.regionFirstRow(r);
        if (delta > 0 && first >= top) {
          region = r;
          break;
        }
        if (delta < 0 && first < top) region = r;
      }
      target = region;
    }
    setState(() => _activeRegion = target);
    _rowsController.reveal(rows.regionFirstRow(target));
  }

  /// Switches layout; the body keeps the reader's place
  /// ([_keepPlaceAcrossLayouts]).
  void _selectLayout(_CompareLayout next) =>
      setState(() => _chosenLayout = next);

  void _openSeparate() =>
      setState(() => _chosenLayout = _CompareLayout.separate);

  KeyEventResult _onBodyKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }

    final rows = _rowsController;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        rows.scrollByLines(-_arrowScrollLines);
      case LogicalKeyboardKey.arrowDown:
        rows.scrollByLines(_arrowScrollLines);
      case LogicalKeyboardKey.pageUp:
        rows.scrollByPages(-_pageScrollFraction);
      case LogicalKeyboardKey.pageDown:
        rows.scrollByPages(_pageScrollFraction);
      case LogicalKeyboardKey.home:
        rows.scrollToEdge(end: false);
      case LogicalKeyboardKey.end:
        rows.scrollToEdge(end: true);
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Why changes are not marked, or what an empty or coarse diff means.
  List<Widget> _diffNotices(BuildContext context, AppLocalizations l10n) {
    final outcome = _diff.outcome;
    final left = _diff.left;
    final right = _diff.right;
    return switch (outcome) {
      TextComparisonOverLineCap() => [
        _DiffNotice(
          key: const ValueKey(CompareKey.noticeOverLineCap),
          message: l10n.syncCompareOverLineCap(
            outcome.maximumLines,
            outcome.leftLines,
            outcome.rightLines,
          ),
        ),
      ],
      TextComparisonFailed() => [
        _DiffNotice(
          key: const ValueKey(CompareKey.noticeFailed),
          message: l10n.syncCompareDiffFailed,
          error: true,
        ),
      ],
      TextComparisonComputed(:final diff) => [
        if (diff.regions.isEmpty)
          left != null && right != null && left.sha256 == right.sha256
              ? _DiffNotice(
                  key: const ValueKey(CompareKey.noticeIdenticalFiles),
                  message: l10n.syncCompareIdenticalFiles,
                )
              : _DiffNotice(
                  key: const ValueKey(CompareKey.noticeIdenticalText),
                  message: l10n.syncCompareIdenticalText,
                ),
        if (!diff.minimal)
          _DiffNotice(
            key: const ValueKey(CompareKey.noticeSimplified),
            message: l10n.syncCompareDiffSimplified,
          ),
      ],
      null => const [],
    };
  }

  List<Widget> _differenceNotices(
    AppLocalizations l10n,
    SyncCompareSideState left,
    SyncCompareSideState right,
  ) {
    if (left.phase != SyncComparePhase.ready ||
        right.phase != SyncComparePhase.ready) {
      return const [];
    }
    final leftDocument = left.document;
    final rightDocument = right.document;
    if (leftDocument == null || rightDocument == null) return const [];

    return [
      if (leftDocument.lineEnding != rightDocument.lineEnding)
        Chip(
          key: const ValueKey('sync.compare.line-endings'),
          label: Text(
            l10n.syncCompareLineEndingsDiffer(
              leftDocument.lineEnding.name.toUpperCase(),
              rightDocument.lineEnding.name.toUpperCase(),
            ),
          ),
        ),
      if (leftDocument.hasUtf8Bom != rightDocument.hasUtf8Bom)
        Chip(
          key: const ValueKey('sync.compare.bom'),
          label: Text(l10n.syncCompareBomDiffers),
        ),
    ];
  }
}

/// Owns one editor so each side keeps independent find and scroll state.
class _CompareSide extends StatefulWidget {
  const _CompareSide({
    super.key,
    required this.controller,
    required this.state,
    required this.label,
    required this.now,
    required this.body,
    required this.onFindInSeparate,
  });

  final SyncCompareController controller;
  final SyncCompareSideState state;
  final String label;
  final DateTime now;
  final _SideBody body;

  /// Switches to the Separate layout, from a header-only Find.
  final VoidCallback onFindInSeparate;

  @override
  State<_CompareSide> createState() => _CompareSideState();
}

class _CompareSideState extends State<_CompareSide> {
  pe.EditorController? _editor;
  BuiltInTextDocument? _editorDocument;
  String? _editorPath;

  @override
  void initState() {
    super.initState();
    _synchronizeEditor();
  }

  @override
  void didUpdateWidget(_CompareSide oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronizeEditor();
  }

  void _synchronizeEditor() {
    final state = widget.state;
    final document = state.phase == SyncComparePhase.ready
        ? state.document
        : null;
    final path = state.source.fullPath;
    final current = identical(document, _editorDocument) && path == _editorPath;
    // A header-only side builds no editor until Find or Separate needs it.
    final headerOnly = widget.body == _SideBody.header;
    if (current && (_editor != null || headerOnly)) return;

    _editor?.dispose();
    _editor = document == null || headerOnly
        ? null
        : pe.EditorController(displayPath: path, initialText: document.text);
    _editorDocument = document;
    _editorPath = path;
  }

  @override
  void dispose() {
    _editor?.dispose();
    super.dispose();
  }

  /// Find from a header above the diff rows: the editor and its find bar
  /// live in the Separate layout, so switch there and open it once built.
  void _findInSeparate() {
    widget.onFindInSeparate();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _editor?.openSearch();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (widget.body == _SideBody.header) return _header(context, l10n);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context, l10n),
        const Divider(height: 1),
        Expanded(child: _body(context, l10n)),
      ],
    );
  }

  Widget _header(BuildContext context, AppLocalizations l10n) {
    final colors = Theme.of(context).colorScheme;
    final source = widget.state.source;
    final snapshot = source.snapshot;
    final modified = snapshot.mtimeSecs == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(snapshot.mtimeSecs! * 1000);
    final modifiedLabel = formatPaneModified(
      modified,
      now: widget.now,
      localeName: Localizations.localeOf(context).toString(),
      today: l10n.paneDateToday,
      yesterday: l10n.paneDateYesterday,
    );
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.label,
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                ),
                Text(
                  source.fullPath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  l10n.syncCompareMetadata(
                    formatPaneSize(
                      snapshot.size,
                      platform: Theme.of(context).platform,
                    ),
                    modifiedLabel,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: l10n.editorFindTooltip,
            onPressed: switch (widget.body) {
              _SideBody.full => _editor?.openSearch,
              _SideBody.header =>
                widget.state.phase == SyncComparePhase.ready
                    ? _findInSeparate
                    : null,
            },
            icon: const Icon(Icons.search),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l10n) {
    return switch (widget.state.phase) {
      SyncComparePhase.loading => _message(
        context,
        l10n.syncCompareLoading,
        progress: true,
      ),
      SyncComparePhase.confirming => _confirmation(context, l10n),
      SyncComparePhase.downloading => _progress(context, l10n),
      SyncComparePhase.gateConfirm => _gate(context, l10n),
      SyncComparePhase.ready => _ready(context, l10n),
      SyncComparePhase.refused => _message(
        context,
        _refusalMessage(l10n, widget.state.refusal),
      ),
      SyncComparePhase.cancelled => _message(
        context,
        l10n.previewDownloadCancelled,
      ),
      SyncComparePhase.failed => _failure(context, l10n),
    };
  }

  Widget _confirmation(BuildContext context, AppLocalizations l10n) {
    final state = widget.state;
    final bytes = state.totalBytes ?? state.source.snapshot.size;
    return _card(
      context,
      children: [
        Text(
          l10n.previewDownloadConfirm(
            formatPaneSize(bytes, platform: Theme.of(context).platform),
            state.source.fullPath,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: () => widget.controller.cancel(state.source.side),
              child: Text(l10n.previewCancelLabel),
            ),
            FilledButton(
              onPressed: () => widget.controller.confirm(state.source.side),
              child: Text(l10n.previewDownloadLabel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _progress(BuildContext context, AppLocalizations l10n) {
    final state = widget.state;
    final total = state.totalBytes;
    final platform = Theme.of(context).platform;
    final transferred = formatPaneSize(state.transferred, platform: platform);
    final progress = total == null
        ? transferred
        : l10n.previewDownloadProgress(
            transferred,
            formatPaneSize(total, platform: platform),
          );
    return _card(
      context,
      children: [
        Text(l10n.previewDownloadingLabel),
        const SizedBox(height: 8),
        Semantics(
          label: l10n.previewDownloadingLabel,
          value: progress,
          child: LinearProgressIndicator(
            value: total != null && total > 0
                ? (state.transferred / total).clamp(0.0, 1.0)
                : null,
          ),
        ),
        const SizedBox(height: 8),
        Text(progress, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: () => widget.controller.cancel(state.source.side),
            child: Text(l10n.previewCancelLabel),
          ),
        ),
      ],
    );
  }

  Widget _gate(BuildContext context, AppLocalizations l10n) {
    final state = widget.state;
    return _card(
      context,
      children: [
        Text(
          l10n.previewGatePrompt(
            formatPaneSize(
              state.transferred,
              platform: Theme.of(context).platform,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            TextButton(
              onPressed: () => widget.controller.cancel(state.source.side),
              child: Text(l10n.previewCancelLabel),
            ),
            FilledButton(
              onPressed: () => widget.controller.confirm(state.source.side),
              child: Text(l10n.previewKeepDownloadingLabel),
            ),
          ],
        ),
      ],
    );
  }

  Widget _ready(BuildContext context, AppLocalizations l10n) {
    final editor = _editor;
    if (editor == null) {
      return _message(context, l10n.syncCompareLoading, progress: true);
    }
    return pe.PlanchetteEditor(
      controller: editor,
      strings: PoltergeistEditorStrings(l10n),
      editingLocked: true,
      showStatus: false,
      textStyle: poltergeistMonoTextStyle.copyWith(fontSize: 14, height: 1.35),
    );
  }

  Widget _failure(BuildContext context, AppLocalizations l10n) {
    return _card(
      context,
      children: [
        Text(
          _failureMessage(l10n, widget.state.failure),
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    );
  }

  String _failureMessage(AppLocalizations l10n, SyncCompareFailure? failure) =>
      switch (failure) {
        SyncCompareFailure.invalidUtf8 => l10n.syncCompareInvalidUtf8,
        SyncCompareFailure.binary => l10n.syncCompareBinary,
        SyncCompareFailure.changed => l10n.syncCompareChanged,
        SyncCompareFailure.missing => l10n.syncCompareMissing,
        SyncCompareFailure.other || null => l10n.syncCompareFailed,
      };

  String _refusalMessage(AppLocalizations l10n, SyncCompareRefusal? refusal) =>
      switch (refusal) {
        SyncCompareRefusal.editorLimit => l10n.syncCompareEditorLimit,
        SyncCompareRefusal.cacheLimit => l10n.previewRefusalOverCacheCap,
        SyncCompareRefusal.cacheUnavailable ||
        SyncCompareRefusal.producerUnavailable ||
        null => l10n.syncCompareRemoteUnavailable,
      };
}

Widget _message(
  BuildContext context,
  String message, {
  bool progress = false,
}) => _card(
  context,
  children: [
    if (progress) ...[
      const Center(child: CircularProgressIndicator()),
      const SizedBox(height: 12),
    ],
    Text(message, textAlign: TextAlign.center),
  ],
);

Widget _card(
  BuildContext context, {
  Key? key,
  required List<Widget> children,
}) => Center(
  key: key,
  child: SingleChildScrollView(
    padding: const EdgeInsets.all(24),
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: children,
      ),
    ),
  ),
);

/// One line under the line-ending and BOM chips saying what the diff did
/// or could not do.
class _DiffNotice extends StatelessWidget {
  const _DiffNotice({super.key, required this.message, this.error = false});

  final String message;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = error
        ? theme.colorScheme.error
        : theme.colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              error ? Icons.error_outline : Icons.info_outline,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: error ? color : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
