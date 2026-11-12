import 'dart:async';

import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show GhostPaneEdge, GhostResizeHandle;

import 'layout/pane_allocation.dart';
import 'shell/shell_splitter.dart';

const _defaultPaneRatio = 0.5;

typedef PaneRatioSaver = FutureOr<void> Function(double ratio);
typedef PaneRatioFormatter = String Function(double ratio);

/// Owns pane allocation and splitter input independently of pane contents.
class AdaptiveShell extends StatefulWidget {
  const AdaptiveShell({
    super.key,
    required this.primary,
    required this.secondary,
    required this.resizeLabel,
    required this.formatRatio,
    this.initialPaneRatio = _defaultPaneRatio,
    this.secondPaneIntent = SecondPaneIntent.shown,
    this.onSecondPaneVisibilityChanged,
    this.onPaneRatioChanged,
    this.onPaneRatioSaveError,
  });

  static const primaryPaneKey = ValueKey('primary-pane');
  static const secondaryPaneKey = ValueKey('secondary-pane');
  static const splitterKey = ValueKey('pane-splitter');

  final Widget primary;
  final Widget secondary;
  final String resizeLabel;
  final PaneRatioFormatter formatRatio;
  final double initialPaneRatio;

  /// `view.toggleSecondPane`'s intent (02 §3): `hidden` collapses the
  /// allocation to the primary pane at any width — the same mechanism
  /// the stage-2 auto-hide uses, so a user hide and a responsive hide
  /// are indistinguishable downstream.
  final SecondPaneIntent secondPaneIntent;

  /// Reports the allocation's effective `showsSecondPane` on every
  /// change (and once at first layout): Sync Browsing suspends while a
  /// pane is hidden — by the toggle OR the stage-2 auto-hide (02 §7's
  /// hidden-pane rule covers both through this one channel). Called
  /// post-frame, never mid-build.
  final ValueChanged<bool>? onSecondPaneVisibilityChanged;
  final PaneRatioSaver? onPaneRatioChanged;
  final void Function(Object, StackTrace)? onPaneRatioSaveError;

  @override
  State<AdaptiveShell> createState() => _AdaptiveShellState();
}

class _AdaptiveShellState extends State<AdaptiveShell> {
  late double _paneRatio;
  late double _lastSavedPaneRatio;
  double _contentWidth = 0;
  Future<void> _saveTail = Future.value();
  var _saveRevision = 0;
  var _hasPendingSave = false;
  bool? _reportedSecondPaneShown;

  @override
  void initState() {
    super.initState();
    _paneRatio = widget.initialPaneRatio.clamp(0, 1).toDouble();
    _lastSavedPaneRatio = _paneRatio;
  }

  @override
  void dispose() {
    _commitPaneRatio();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _contentWidth = constraints.maxWidth;
        final allocation = allocatePanes(
          width: _contentWidth,
          ratio: _paneRatio,
          secondPaneIntent: widget.secondPaneIntent,
        );
        _reportSecondPaneVisibility(allocation.showsSecondPane);

        return _buildPanes(context, allocation);
      },
    );
  }

  /// Posts the effective visibility change to the listener — post-frame
  /// because the allocation is computed mid-build, and the workspace's
  /// listener notifies (a build-phase notify would mark the tree dirty
  /// during its own build).
  void _reportSecondPaneVisibility(bool shown) {
    if (shown == _reportedSecondPaneShown) return;
    _reportedSecondPaneShown = shown;
    final reporter = widget.onSecondPaneVisibilityChanged;
    if (reporter == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      reporter(shown);
    });
  }

  Widget _buildPanes(BuildContext context, PaneAllocation allocation) {
    final primary = SizedBox(
      key: AdaptiveShell.primaryPaneKey,
      width: allocation.primaryWidth,
      child: widget.primary,
    );
    if (!allocation.showsSecondPane) return primary;

    // A 1 px seam between the panes, so each pane's own borders (the
    // active-side accent) run up to it; the grab area floats over it and
    // the secondary pane takes the pixels the splitter no longer holds.
    return ShellSeam.straddle(
      Row(
        children: [
          primary,
          ShellSeam(color: Theme.of(context).dividerColor),
          SizedBox(
            key: AdaptiveShell.secondaryPaneKey,
            width:
                allocation.secondaryWidth +
                allocation.splitterWidth -
                shellSeamWidth,
            child: widget.secondary,
          ),
        ],
      ),
      start: allocation.primaryWidth,
      extent: allocation.splitterWidth,
      handle: GhostResizeHandle(
        key: AdaptiveShell.splitterKey,
        label: widget.resizeLabel,
        width: allocation.primaryWidth,
        minimumWidth: _displayedPrimaryWidth(allocation, 0),
        maximumWidth: _displayedPrimaryWidth(allocation, 1),
        edge: GhostPaneEdge.leading,
        widthAfterStep: (delta) =>
            _displayedPrimaryWidth(
              allocation,
              _ratioAfterLogicalDelta(allocation, delta),
            ),
        onStep: _stepPaneRatio,
        // The shell tracks no drag state of its own.
        onStart: () {},
        onDelta: _resize,
        onEnd: _commitPaneRatio,
        dragStartBehavior: DragStartBehavior.down,
        handleWidth: allocation.splitterWidth,
        valueText: (width) =>
            widget.formatRatio(_ratioForWidth(allocation, width)),
      ),
    );
  }

  /// One arrow key or assistive adjustment is a complete interaction:
  /// move, then commit once, like the region splitters.
  void _stepPaneRatio(double logicalDelta) {
    _resize(logicalDelta);
    _commitPaneRatio();
  }

  void _resize(double logicalDelta) {
    // Several pointer updates can arrive before a frame. Resolve against
    // the latest ratio, not the allocation captured by the previous build.
    final allocation = allocatePanes(
      width: _contentWidth,
      ratio: _paneRatio,
      secondPaneIntent: SecondPaneIntent.shown,
    );
    final usableWidth = allocation.primaryWidth + allocation.secondaryWidth;
    if (usableWidth <= 0) return;

    final ratio = _ratioAfterLogicalDelta(allocation, logicalDelta);

    if (ratio == _paneRatio) return;

    setState(() => _paneRatio = ratio);
    _saveRevision++;
    _hasPendingSave = true;
  }

  /// The primary pane's rendered width at [logicalRatio]: the current
  /// allocation's own at the current ratio, a clamped edge's when a step
  /// or drag lands on one. The shared handle announces and bounds with it.
  double _displayedPrimaryWidth(
    PaneAllocation allocation,
    double logicalRatio,
  ) {
    final usableWidth = allocation.primaryWidth + allocation.secondaryWidth;
    if (usableWidth <= 0) return allocation.primaryWidth;
    return _displayedRatio(allocation, logicalRatio) * usableWidth;
  }

  /// The reading-direction ratio a primary width of [width] represents.
  double _ratioForWidth(PaneAllocation allocation, double width) {
    final usableWidth = allocation.primaryWidth + allocation.secondaryWidth;
    return usableWidth <= 0 ? 0 : width / usableWidth;
  }

  double _ratioAfterLogicalDelta(
    PaneAllocation allocation,
    double logicalDelta,
  ) {
    final usableWidth = allocation.primaryWidth + allocation.secondaryWidth;
    if (usableWidth <= 0) return _paneRatio;

    final displayedRatio = allocation.primaryWidth / usableWidth;
    final movesInFromRight = logicalDelta < 0 && _paneRatio > displayedRatio;
    final movesInFromLeft = logicalDelta > 0 && _paneRatio < displayedRatio;
    final startingRatio = movesInFromRight || movesInFromLeft
        ? displayedRatio
        : _paneRatio;
    final requestedRatio = startingRatio + logicalDelta / usableWidth;
    final minimumRatio =
        allocatePanes(
          width: _contentWidth,
          ratio: 0,
          secondPaneIntent: SecondPaneIntent.shown,
        ).primaryWidth /
        usableWidth;
    final maximumRatio =
        allocatePanes(
          width: _contentWidth,
          ratio: 1,
          secondPaneIntent: SecondPaneIntent.shown,
        ).primaryWidth /
        usableWidth;

    // Persist edge intent as 0/1, but adopt the visible edge when moving in.
    var ratio = requestedRatio.clamp(0, 1).toDouble();
    if (requestedRatio <= minimumRatio) ratio = 0;
    if (requestedRatio >= maximumRatio) ratio = 1;
    return ratio;
  }

  double _displayedRatio(PaneAllocation allocation, double logicalRatio) {
    final usableWidth = allocation.primaryWidth + allocation.secondaryWidth;
    if (usableWidth <= 0) return 0;

    final displayed = allocatePanes(
      width: _contentWidth,
      ratio: logicalRatio,
      secondPaneIntent: SecondPaneIntent.shown,
    );
    return displayed.primaryWidth / usableWidth;
  }

  void _commitPaneRatio() {
    if (!_hasPendingSave) return;

    // Persist at the drag boundary, or once per keyboard/assistive step.
    _hasPendingSave = false;
    _savePaneRatio(_paneRatio, _saveRevision);
  }

  void _savePaneRatio(double ratio, int revision) {
    final save = widget.onPaneRatioChanged;
    if (save == null) {
      _lastSavedPaneRatio = ratio;
      return;
    }

    final report = widget.onPaneRatioSaveError;
    _saveTail = _saveTail.then((_) async {
      try {
        await save(ratio);
        _lastSavedPaneRatio = ratio;
      } catch (error, stack) {
        try {
          report?.call(error, stack);
        } catch (_) {
          // Reporting cannot be allowed to create another async failure.
        }
        if (!mounted || revision != _saveRevision) return;

        setState(() => _paneRatio = _lastSavedPaneRatio);
      }
    });
  }
}
