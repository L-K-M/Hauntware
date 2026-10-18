import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../controllers/coverage_controller.dart';
import '../controllers/fleet_controller.dart';
import '../l10n/app_localizations.dart';

/// Below this width the coverage sheet is a bottom sheet (03 §10.5), and a
/// dialog above it.
const double _phoneMaxWidth = 600;

/// The most of its column the first-run card takes: at a large text scale
/// its words scroll inside it rather than push the column's content off
/// the screen.
const double _cardMaxShare = 0.5;

/// The coverage sheet's width as a desktop dialog.
const double _dialogMaxWidth = 520;

/// Where a [CoverageHeader] stands (03 §9.5).
enum CoveragePlacement {
  /// Over the phone's fleet list (03 §10.5): the first-run card over the
  /// coverage chip. It takes the place of the screen body's [SafeArea]
  /// and keeps both and the list inside the safe area.
  phoneFleetList,

  /// Over the desktop workspace (03 §10.2): the first-run card alone,
  /// since the rail carries the chip.
  desktopWorkspace,
}

/// Heads [child] with the first-run card (03 §9.5 item 1) until the user
/// dismisses it and, on the phone, the coverage chip (item 2). [child]
/// keeps its place in the tree when the card goes, so its state survives
/// the dismissal.
class CoverageHeader extends StatelessWidget {
  const CoverageHeader({
    super.key,
    required this.placement,
    required this.coverage,
    required this.fleet,
    required this.child,
  });

  final CoveragePlacement placement;
  final CoverageController coverage;
  final FleetController fleet;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final header = LayoutBuilder(
      builder: (context, box) => ListenableBuilder(
        listenable: coverage,
        builder: (context, child) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (coverage.showsFirstRunCard)
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: box.maxHeight * _cardMaxShare,
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: FirstRunCoverageCard(coverage: coverage, fleet: fleet),
                ),
              ),
            if (placement == CoveragePlacement.phoneFleetList)
              FleetCoverageChip(fleet: fleet),
            // Last, so the column's update matches it from the end
            // whatever shows above it.
            Expanded(child: child!),
          ],
        ),
        child: child,
      ),
    );
    return switch (placement) {
      CoveragePlacement.phoneFleetList => SafeArea(child: header),
      CoveragePlacement.desktopWorkspace => header,
    };
  }
}

/// 03 §9.5 item 1: what Klabautermann covers, said once, until the user
/// dismisses it on this device. It needs a bounded height, inside which
/// its words scroll.
class FirstRunCoverageCard extends StatelessWidget {
  const FirstRunCoverageCard({
    super.key,
    required this.coverage,
    required this.fleet,
  });

  final CoverageController coverage;

  /// What the coverage sheet counts.
  final FleetController fleet;

  /// Hides the card; a dismissal that cannot be saved says so, since the
  /// card returns at the next start, and prints why.
  Future<void> _dismiss(BuildContext context) async {
    // Captured first: the card is gone once the dismissal applies.
    final overlay = Overlay.of(context, rootOverlay: true);
    final notSaved = AppLocalizations.of(context).coverageFirstRunNotSaved;
    try {
      await coverage.dismissFirstRunCard();
    } on Exception catch (error) {
      debugPrint('$error');
      if (overlay.mounted) showTopToast(overlay, message: notSaved);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Card.outlined(
      color: colors.surfaceContainerLow,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // The words scroll and the buttons stay in view when the
            // card's bounded height is short of them.
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 12,
                      children: [
                        Icon(Icons.info_outline, color: colors.primary),
                        Expanded(
                          child: Semantics(
                            header: true,
                            child: Text(
                              l10n.coverageFirstRunTitle,
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                        ),
                      ],
                    ),
                    Text(
                      l10n.coverageFirstRunBody,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 4),
            // Stacks the buttons when a large text scale leaves no room
            // side by side.
            OverflowBar(
              alignment: MainAxisAlignment.end,
              overflowAlignment: OverflowBarAlignment.end,
              spacing: 8,
              overflowSpacing: 8,
              children: [
                TextButton(
                  onPressed: () => unawaited(showCoverageSheet(context, fleet)),
                  child: Text(l10n.coverageFirstRunDetails),
                ),
                TextButton(
                  onPressed: () => unawaited(_dismiss(context)),
                  child: Text(l10n.coverageFirstRunDismiss),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 03 §9.5 item 2: how many of the fleet's servers this device watches,
/// opening the coverage sheet. Nothing shows while the fleet is empty.
class FleetCoverageChip extends StatelessWidget {
  const FleetCoverageChip({super.key, required this.fleet});

  final FleetController fleet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return ListenableBuilder(
      listenable: fleet,
      builder: (context, _) {
        final coverage = FleetCoverage.of(
          fleet.servers,
          monitorSet: fleet.monitoredServerIds,
        );
        if (coverage.serverCount == 0) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: _CoverageChip(
              label: l10n.coverageChip(
                coverage.watchedCount,
                coverage.serverCount,
              ),
              fleet: fleet,
            ),
          ),
        );
      },
    );
  }
}

/// The server header's coverage chip (03 §10.2): the server's tier and
/// how it is read, opening the coverage sheet. Only T0 exists, and no
/// monitor set watches a server yet (FL-21), so every server reads the
/// same until they arrive.
class ServerCoverageChip extends StatelessWidget {
  const ServerCoverageChip({super.key, required this.fleet});

  final FleetController fleet;

  @override
  Widget build(BuildContext context) => _CoverageChip(
    label: AppLocalizations.of(context).coverageServerChip,
    fleet: fleet,
  );
}

/// A coverage chip's face: [label] beside an eye, opening the coverage
/// sheet over [fleet].
class _CoverageChip extends StatelessWidget {
  const _CoverageChip({required this.label, required this.fleet});

  final String label;
  final FleetController fleet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    // One node with the words, the action and its focus: the eye is
    // decoration.
    return MergeSemantics(
      child: Semantics(
        button: true,
        onTapHint: AppLocalizations.of(context).coverageChipHint,
        child: Material(
          color: colors.secondaryContainer,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: () => unawaited(showCoverageSheet(context, fleet)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    size: 16,
                    color: colors.onSecondaryContainer,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      label,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colors.onSecondaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens the coverage sheet over [context]: a bottom sheet on phones, a
/// dialog on wider windows. It counts [fleet] as it changes.
Future<void> showCoverageSheet(BuildContext context, FleetController fleet) {
  final style = MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null;
  if (MediaQuery.sizeOf(context).width < _phoneMaxWidth) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      sheetAnimationStyle: style,
      builder: (_) => CoverageSheet(fleet: fleet),
    );
  }
  return showDialog<void>(
    context: context,
    animationStyle: style,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: _dialogMaxWidth),
        child: CoverageSheet(fleet: fleet),
      ),
    ),
  );
}

/// The coverage sheet: the tier this device runs at (T0, the only one
/// there is; no control offers another), then what is covered and what is
/// not, said plainly (02 §1 principle 8).
class CoverageSheet extends StatelessWidget {
  const CoverageSheet({super.key, required this.fleet});

  final FleetController fleet;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    List<Widget> section(String heading, List<CoverageItem> items) => [
      Semantics(
        header: true,
        child: Text(heading, style: theme.textTheme.titleMedium),
      ),
      ...items,
    ];
    // The headings say covered or not in words, and the icons differ in
    // shape as well as colour (10.10: never colour alone).
    final covered = Icon(
      Icons.check_circle_outline,
      size: 20,
      color: theme.colorScheme.primary,
    );
    final notCovered = Icon(
      Icons.remove_circle_outline,
      size: 20,
      color: theme.colorScheme.onSurfaceVariant,
    );
    return ListenableBuilder(
      listenable: fleet,
      builder: (context, _) {
        final coverage = FleetCoverage.of(
          fleet.servers,
          monitorSet: fleet.monitoredServerIds,
        );
        // Continuous watching is covered only once a server is watched.
        final watching = coverage.watchedCount > 0;
        final watched = CoverageItem(
          leading: watching ? covered : notCovered,
          title: l10n.coverageWatchedTitle,
          body: l10n.coverageWatchedBody(coverage.watchedCount),
        );
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(24, 12, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(
                        l10n.coverageSheetTitle,
                        style: theme.textTheme.titleLarge,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 12,
                  children: [
                    CoverageItem(
                      leading: const CoverageTierBadge(),
                      title: l10n.coverageTierTitle,
                      body: l10n.coverageTierBody,
                    ),
                    const SizedBox(height: 4),
                    ...section(l10n.coverageCoveredHeading, [
                      CoverageItem(
                        leading: covered,
                        title: l10n.coverageLiveTitle,
                        body: l10n.coverageLiveBody,
                      ),
                      if (watching) watched,
                    ]),
                    const SizedBox(height: 4),
                    ...section(l10n.coverageNotCoveredHeading, [
                      if (!watching) watched,
                      CoverageItem(
                        leading: notCovered,
                        title: l10n.coverageClosedTitle,
                        body: l10n.coverageClosedBody,
                      ),
                      CoverageItem(
                        leading: notCovered,
                        title: l10n.coverageHostDownTitle,
                        body: l10n.coverageHostDownBody,
                      ),
                      CoverageItem(
                        leading: notCovered,
                        title: l10n.coverageHistoryTitle,
                        body: l10n.coverageHistoryBody,
                      ),
                      if (pausesInBackground(context))
                        CoverageItem(
                          leading: notCovered,
                          title: l10n.coverageBackgroundTitle,
                          body: l10n.coverageBackgroundBody,
                        ),
                    ]),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/// Whether this platform pauses sampling in the background: iOS and
/// Android (PLT-04, D34).
bool pausesInBackground(BuildContext context) => const {
  TargetPlatform.android,
  TargetPlatform.iOS,
}.contains(Theme.of(context).platform);

/// The T0 badge. 03 §9.5 item 3 gives each server's card a T0, T1 or T2
/// badge; only T0 exists, so the whole fleet runs at it.
class CoverageTierBadge extends StatelessWidget {
  const CoverageTierBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: colors.primary, width: 1.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Text(
          AppLocalizations.of(context).coverageTierBadge,
          style: theme.textTheme.labelLarge?.copyWith(color: colors.primary),
        ),
      ),
    );
  }
}

/// One line of the coverage sheet or a server's coverage, read as one
/// node: [leading] beside [title] over [body], if any.
class CoverageItem extends StatelessWidget {
  const CoverageItem({
    super.key,
    required this.leading,
    required this.title,
    this.body,
  });

  final Widget leading;
  final String title;
  final String? body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          leading,
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(title, style: theme.textTheme.titleSmall),
                if (body case final body?)
                  Text(
                    body,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
