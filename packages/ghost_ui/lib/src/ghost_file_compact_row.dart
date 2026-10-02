import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import 'family_hues.dart';
import 'ghost_file_format.dart';
import 'ghost_file_item.dart';
import 'ghost_file_kinds.dart';
import 'ghost_file_row.dart' show GhostFileRowStrings;
import 'ghost_file_theme.dart';

/// D32 §9's row: 56 dp, two lines (name; size · date). Scaled with the
/// text scale so larger type grows the row instead of clipping (D20),
/// and fixed per build so the list keeps its fixed-extent layout.
const double ghostCompactFileRowExtent = 56;

/// The touch listing's fixed row extent for [context] — [ghostCompactFileRowExtent]
/// at the ambient text scale, for a `ListView`'s `itemExtent`.
double scaledGhostCompactFileRowExtent(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(ghostCompactFileRowExtent);

/// D32 §9's 56 dp two-line row: a 40 dp kind badge (a check while
/// selected), the name over `size · date`, and a trailing ⋮ for the
/// item's action sheet. Outside selection mode a tap opens; inside it a
/// tap toggles and the ⋮ steps aside (the host's bottom bar owns the
/// verbs).
///
/// Ported verbatim from Poltergeist's `_CompactRow` and `_KindBadge`
/// (`ui/compact/compact_listing.dart`): the row is presentation only —
/// selection mode, the action sheet, and the dialog-based rename stay
/// host-owned, and the caller projects its entries into [GhostFileItem].
class GhostFileCompactRow extends StatelessWidget {
  const GhostFileCompactRow({
    super.key,
    required this.item,
    required this.selected,
    required this.selecting,
    this.clock = DateTime.now,
    this.localeName,
    this.strings,
    required this.onTap,
    required this.onLongPress,
    required this.onActions,
    this.onRename,
    this.trailing,
  });

  /// The entry the row renders — a host-projected [GhostFileItem].
  final GhostFileItem item;

  /// Whether this row is in the selection.
  final bool selected;

  /// Whether the listing is in selection mode — unselected rows take
  /// the empty ring, the ⋮ keeps its slot but goes inert.
  final bool selecting;

  /// The host's clock for relative date formatting.
  final DateTime Function() clock;

  /// The locale dates format in — defaults to the ambient
  /// [Localizations] locale.
  final String? localeName;

  /// The row's strings; defaults to the hosts' shared English copy.
  final GhostFileRowStrings? strings;

  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// The trailing ⋮'s press: the item's action sheet.
  final VoidCallback onActions;

  /// The rename affordance on the row's semantics node — dialog-based
  /// at touch size, so the host owns the session and passes its
  /// availability here.
  final VoidCallback? onRename;

  /// An optional host widget between the text column and the ⋮ (a
  /// pending-changes badge and the like).
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final strings = this.strings ?? GhostFileRowStrings.english();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fileTheme = GhostFileTheme.of(context);
    final platform = theme.platform;
    final directory = item.type == GhostFileNodeType.directory;
    final size = ghostFormatFileSize(
      directory ? null : item.size,
      platform: platform,
    );
    final modified = ghostFormatFileModified(
      item.modifiedAt,
      now: clock(),
      localeName: localeName ?? Localizations.localeOf(context).toString(),
      today: strings.todayText,
      yesterday: strings.yesterdayText,
    );
    final sizeSlot = switch (item.type) {
      GhostFileNodeType.directory => strings.folderLabel,
      GhostFileNodeType.symbolicLink => strings.linkLabel,
      _ => size,
    };
    final kind = strings.kindLabel(item.type);
    final flagged = ghostFileNameIsFlagged(item.name);
    final (glyph, hue) = ghostFileKindGlyph(ghostFileKind(item));
    final tint = FamilyPalette.of(context).glyph(hue);

    final label = flagged
        ? strings.flaggedSemanticsLabel(item.name, kind, size, modified)
        : strings.semanticsLabel(item.name, kind, size, modified);

    final main = Semantics(
      container: true,
      button: true,
      selected: selected,
      label: label,
      onTap: onTap,
      onLongPress: onLongPress,
      customSemanticsActions: {
        CustomSemanticsAction(label: strings.renameLabel): ?onRename,
      },
      excludeSemantics: true,
      child: Row(
        children: [
          _KindBadge(
            glyph: glyph,
            tint: tint,
            selected: selected,
            selecting: selecting,
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                    if (flagged)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 4),
                        child: Icon(
                          Icons.warning_amber_outlined,
                          size: 16,
                          color: colors.error,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  strings.detailsText(sizeSlot, modified),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: fileTheme.secondaryText,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final fill = selected
        ? Color.alphaBlend(
            colors.primary.withValues(alpha: 0.14),
            fileTheme.paneBackground,
          )
        : Colors.transparent;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: fill,
      child: InkWell(
        // The Semantics node above owns tap/long-press for assistive
        // tech; the ink stays purely visual.
        excludeFromSemantics: true,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16, end: 4),
          child: Row(
            children: [
              Expanded(child: main),
              ?trailing,
              // The ⋮ keeps its slot in selection mode (hidden, inert)
              // so the text column never reflows when the mode flips.
              Visibility.maintain(
                visible: !selecting,
                child: IconButton(
                  key: ValueKey(('ghostFileRow.more', item.name)),
                  tooltip: strings.actionsTooltip(item.name),
                  onPressed: selecting ? null : onActions,
                  icon: Icon(Icons.more_vert, color: fileTheme.secondaryText),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The row's 40 dp leading badge: the kind glyph on a tinted disc,
/// which turns into the accent check while selected (Material's
/// list-selection idiom) and into an empty ring for unselected rows in
/// selection mode.
///
/// Ported verbatim from Poltergeist's `_KindBadge`.
class _KindBadge extends StatelessWidget {
  const _KindBadge({
    required this.glyph,
    required this.tint,
    required this.selected,
    required this.selecting,
  });

  final IconData glyph;
  final Color tint;
  final bool selected;
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final Widget face = selected
        ? DecoratedBox(
            key: const ValueKey('ghostFileRow.check'),
            decoration: BoxDecoration(
              color: colors.primary,
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.check, size: 22, color: colors.onPrimary),
          )
        : DecoratedBox(
            key: ValueKey(glyph),
            decoration: BoxDecoration(
              color: tint.withValues(alpha: FamilyPalette.discWashAlpha),
              shape: BoxShape.circle,
              border: selecting
                  ? Border.all(color: colors.outline, width: 1.5)
                  : null,
            ),
            child: Icon(glyph, size: 22, color: tint),
          );
    return SizedBox.square(
      dimension: 40,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 180),
        switchInCurve: Curves.easeOutBack,
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: SizedBox.expand(key: face.key, child: face),
      ),
    );
  }
}
