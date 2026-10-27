import 'dart:async' show unawaited;

import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart' show showTopToast;

import '../controllers/overview_layout.dart';
import '../l10n/app_localizations.dart';

/// The device's Overview layout for every route (OV-06); absent in tests
/// that leave it out, where the Overview shows the standard layout and no
/// way to change it.
class OverviewLayoutScope extends InheritedNotifier<OverviewLayoutController> {
  const OverviewLayoutScope({
    super.key,
    required OverviewLayoutController layout,
    required super.child,
  }) : super(notifier: layout);

  /// The layout for [context], which rebuilds when it changes, or null
  /// when none is provided.
  static OverviewLayoutController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<OverviewLayoutScope>()
      ?.notifier;
}

/// [shown]'s cards as the Overview lays them out: a full-width card on
/// its own, and each run of half-width cards between two columns on a
/// [wide] panel, the first half on the left, as a newspaper reads; one
/// under the other otherwise. [card] builds a card, or null for one the
/// server cannot show, which is left out.
List<Widget> arrangedOverviewCards(
  List<OverviewCard> shown, {
  required bool wide,
  required double gap,
  required Widget? Function(OverviewCard card) card,
}) {
  final arranged = <Widget>[];
  var run = <Widget>[];

  void endRun() {
    if (run.isEmpty) return;
    if (!wide) {
      arranged.addAll(run);
    } else {
      final split = (run.length + 1) ~/ 2;
      Widget column(List<Widget> children) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: gap,
          children: children,
        ),
      );
      arranged.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: gap,
          children: [column(run.sublist(0, split)), column(run.sublist(split))],
        ),
      );
    }
    run = [];
  }

  for (final shownCard in shown) {
    final built = card(shownCard);
    if (built == null) continue;
    if (shownCard.fullWidth) {
      endRun();
      arranged.add(built);
    } else {
      run.add(built);
    }
  }
  endRun();
  return arranged;
}

/// [card]'s name, as its heading on the Overview reads.
String overviewCardTitle(AppLocalizations l10n, OverviewCard card) =>
    switch (card) {
      OverviewCard.quickActions => l10n.quickActionsTitle,
      OverviewCard.cpu => l10n.overviewCpuTitle,
      OverviewCard.load => l10n.overviewLoadTitle,
      OverviewCard.memory => l10n.overviewMemoryTitle,
      OverviewCard.swap => l10n.overviewSwapTitle,
      OverviewCard.pressure => l10n.overviewPressureTitle,
      OverviewCard.disks => l10n.systemDisksTitle,
      OverviewCard.network => l10n.systemNetworkTitle,
      OverviewCard.host => l10n.overviewHostTitle,
      OverviewCard.docker => l10n.overviewDockerTitle,
      OverviewCard.topLists => l10n.topListsTitle,
      OverviewCard.history => l10n.historyTitle,
    };

/// The Overview's way to arrange its cards (OV-06), at its end.
class EditOverviewCardsButton extends StatelessWidget {
  const EditOverviewCardsButton({super.key, required this.layout});

  final OverviewLayoutController layout;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: () => unawaited(
          showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            showDragHandle: true,
            builder: (context) => SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: OverviewCardsSheet(layout: layout),
              ),
            ),
          ),
        ),
        icon: const Icon(Icons.dashboard_customize_outlined),
        label: Text(l10n.overviewEditCards),
      ),
    );
  }
}

/// Every Overview card with a switch to show it and a handle to move it
/// (OV-06). Each change applies at once and is saved; a card switched
/// off is hidden on every server, and switched on again it returns to
/// its place.
class OverviewCardsSheet extends StatelessWidget {
  const OverviewCardsSheet({super.key, required this.layout});

  final OverviewLayoutController layout;

  Future<void> _set(BuildContext context, OverviewLayout next) async {
    final overlay = Overlay.of(context, rootOverlay: true);
    final l10n = AppLocalizations.of(context);
    try {
      await layout.setLayout(next);
    } on OverviewLayoutNotSavedException catch (error) {
      debugPrint(error.toString());
      if (overlay.mounted) {
        showTopToast(overlay, message: l10n.overviewCardsNotSaved);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: layout,
      builder: (context, _) {
        final current = layout.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.overviewCardsTitle, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(l10n.overviewCardsHint, style: theme.textTheme.bodySmall),
            const SizedBox(height: 8),
            Flexible(
              child: ReorderableListView(
                shrinkWrap: true,
                // Each edit builds on the layout as it is then, not as the
                // last build saw it, so two edits in one frame both stay.
                onReorderItem: (from, to) {
                  final now = layout.value;
                  final order = [...now.order];
                  order.insert(to, order.removeAt(from));
                  unawaited(
                    _set(
                      context,
                      OverviewLayout(order: order, hidden: now.hidden),
                    ),
                  );
                },
                children: [
                  for (final card in current.order)
                    SwitchListTile(
                      key: ValueKey(card),
                      contentPadding: const EdgeInsetsDirectional.only(end: 40),
                      title: Text(overviewCardTitle(l10n, card)),
                      value: !current.hidden.contains(card),
                      onChanged: (shown) {
                        final now = layout.value;
                        unawaited(
                          _set(
                            context,
                            OverviewLayout(
                              order: now.order,
                              hidden: shown
                                  ? ({...now.hidden}..remove(card))
                                  : {...now.hidden, card},
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: TextButton(
                onPressed: current == OverviewLayout.standard
                    ? null
                    : () => unawaited(_set(context, OverviewLayout.standard)),
                child: Text(l10n.overviewCardsReset),
              ),
            ),
          ],
        );
      },
    );
  }
}
