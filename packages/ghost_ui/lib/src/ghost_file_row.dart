import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;

import 'family_hues.dart';
import 'ghost_file_columns.dart';
import 'ghost_file_format.dart';
import 'ghost_file_item.dart';
import 'ghost_file_kinds.dart';
import 'ghost_file_theme.dart';

/// A folder row's disclosure state (02 §2.5, folders expand in place).
///
/// Ported from Poltergeist's `PaneDisclosure`
/// (`services/pane_controller.dart`), decoupled from the controller.
enum GhostFileDisclosure {
  /// Not expandable: a file, a symbolic link, or anything else the
  /// listing does not type as a directory (02 §2.3 never stats a link).
  none,

  /// A folder shown closed.
  collapsed,

  /// Opened, its own listing still in flight.
  loading,

  /// Opened, its children shown below it.
  expanded,
}

/// The file rows' caller-supplied strings — everything the shared
/// widgets announce or render that is not a technical literal. Both the
/// desktop [GhostFileRow] and the touch [GhostFileCompactRow] read from
/// it; hosts with a localization contract (Poltergeist's ARB) construct
/// one from their own strings, and the [GhostFileRowStrings.english]
/// constructor gives hosts without one (Séance) the same copy the source
/// app ships.
@immutable
class GhostFileRowStrings {
  const GhostFileRowStrings({
    required this.kindLabel,
    required this.semanticsLabel,
    required this.flaggedSemanticsLabel,
    required this.flaggedTooltip,
    required this.renameLabel,
    required this.expandLabel,
    required this.collapseLabel,
    required this.todayText,
    required this.yesterdayText,
    required this.folderLabel,
    required this.linkLabel,
    required this.detailsText,
    required this.actionsTooltip,
  });

  /// The strings as the hosts' English copy spells them.
  factory GhostFileRowStrings.english() => GhostFileRowStrings(
    kindLabel: (type) => switch (type) {
      GhostFileNodeType.file => 'file',
      GhostFileNodeType.directory => 'folder',
      GhostFileNodeType.symbolicLink => 'symbolic link',
      GhostFileNodeType.other => 'item',
    },
    semanticsLabel: (name, kind, size, modified) =>
        '$name, $kind, $size, $modified',
    flaggedSemanticsLabel: (name, kind, size, modified) =>
        '$name, $kind, $size, $modified — name not valid UTF-8',
    flaggedTooltip: 'Name is not valid UTF-8 — shown approximately',
    renameLabel: 'Rename',
    expandLabel: 'Expand',
    collapseLabel: 'Collapse',
    todayText: (time) => 'Today at $time',
    yesterdayText: (time) => 'Yesterday at $time',
    folderLabel: 'Folder',
    linkLabel: 'Link',
    detailsText: (size, date) => '$size · $date',
    actionsTooltip: (name) => 'Actions for $name',
  );

  /// A row's announced kind by node type ("file", "folder", …) —
  /// assistive tech hears the type, never a glyph guess.
  final String Function(GhostFileNodeType type) kindLabel;

  /// The row's composed semantics label — Name-Kind-Size-Date order.
  final String Function(String name, String kind, String size, String modified)
  semanticsLabel;

  /// [semanticsLabel] with the flagged-name reason spelled out.
  final String Function(String name, String kind, String size, String modified)
  flaggedSemanticsLabel;

  /// The warning badge's tooltip on a flagged row.
  final String flaggedTooltip;

  /// The rename action's label (a custom semantics action).
  final String renameLabel;

  /// The disclosure triangle's tooltips.
  final String expandLabel;
  final String collapseLabel;

  /// [ghostFormatFileModified]'s relative labels, each taking the
  /// formatted time.
  final String Function(String time) todayText;
  final String Function(String time) yesterdayText;

  /// The compact row's size slot for a directory / symbolic link.
  final String folderLabel;
  final String linkLabel;

  /// The compact row's detail line from the size slot and the modified
  /// text.
  final String Function(String sizeSlot, String date) detailsText;

  /// The compact row's trailing ⋮ button tooltip.
  final String Function(String name) actionsTooltip;
}

/// One dense listing row (D32 §6): kind glyph, 13 px name, and the size
/// and date columns in the secondary tone with tabular figures. The
/// ACTIVE pane's selection paints the accent fill with on-accent text;
/// an inactive selection is neutral grey. Desktop rows select on
/// pointer-down (the host pane owns the double-click window); touch
/// rows open on tap and select on long-press.
///
/// Ported verbatim from Poltergeist's `_PaneRow`
/// (`ui/panes/pane_view.dart`): the row is presentation only — it owns
/// no drag payload, no selection model, and no strings of its own.
/// Hosts wrap it in their `Draggable`/`MenuController`/drop surfaces
/// unchanged, size it with [scaledGhostFileRowExtent] as the list's
/// `itemExtent`, and describe it through [GhostFileRowStrings].
class GhostFileRow extends StatefulWidget {
  const GhostFileRow({
    super.key,
    required this.item,
    this.outline = false,
    this.depth = 0,
    this.disclosure = GhostFileDisclosure.none,
    this.onDisclosurePointerDown,
    this.onToggleDisclosure,
    this.highlighted = false,
    this.cursorRing = false,
    required this.selected,
    this.renaming = false,
    this.dropTargeted = false,
    this.active = true,
    this.clock = DateTime.now,
    this.localeName,
    this.strings,
    this.touch = false,
    required this.onPointerDown,
    required this.onPointerMove,
    required this.onPointerUp,
    required this.onTap,
    required this.onLongPress,
    required this.onOpen,
    this.onRename,
    this.trailing,
  });

  /// The entry the row renders — a host-projected [GhostFileItem].
  final GhostFileItem item;

  /// Whether the row reserves the disclosure column (desktop rows; 02
  /// §2.5), and how deeply it is nested below the location.
  final bool outline;
  final int depth;

  /// The folder's disclosure state; [GhostFileDisclosure.none] draws no
  /// triangle, only its column.
  final GhostFileDisclosure disclosure;

  /// A press on the triangle (the pane toggles the folder and keeps the
  /// press from selecting the row).
  final ValueChanged<PointerDownEvent>? onDisclosurePointerDown;

  /// Assistive tech's Expand/Collapse action; null for rows that do not
  /// expand.
  final VoidCallback? onToggleDisclosure;

  /// Whether the cursor is on this row.
  final bool highlighted;

  /// Whether the cursor's shape marker shows (a subtle ring) — the
  /// cursor must stay identifiable inside a multi-selection by shape,
  /// not tint alone (02 §2.5).
  final bool cursorRing;

  /// The inline editor is open over this row: the editor shows the name
  /// in place, so the label itself steps aside rather than peeking out
  /// past the field.
  final bool renaming;

  /// Whether this row is in the selection (02 §2.5).
  final bool selected;

  /// Whether a live drag hover names this folder row its destination
  /// (02 §5.1's target highlight) — a ring distinct from both cursor
  /// and selection.
  final bool dropTargeted;

  /// Whether this row's pane is the active one.
  final bool active;

  /// The host's clock for relative date formatting.
  final DateTime Function() clock;

  /// The locale dates format in — defaults to the ambient
  /// [Localizations] locale. Hosts with an explicit locale pass it so
  /// row text never drifts from the rest of the surface.
  final String? localeName;

  /// The row's strings; defaults to the hosts' shared English copy.
  final GhostFileRowStrings? strings;

  /// Touch rows swap the raw-pointer recognizer for tap/long-press —
  /// the compact listing's gesture contract — while keeping the same
  /// row content.
  final bool touch;

  final ValueChanged<PointerDownEvent> onPointerDown;
  final ValueChanged<PointerMoveEvent> onPointerMove;
  final ValueChanged<PointerUpEvent> onPointerUp;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  /// The row's primary verb for assistive tech: open.
  final VoidCallback onOpen;

  /// §13's rename affordance on the row's semantics node (keyboard/AT
  /// parity with Enter/F2). Null when rename is unavailable — verbs
  /// gated off or a flagged name.
  final VoidCallback? onRename;

  /// Host actions trail the name, before metadata, so variable-width
  /// badges and menus never shift the columns away from their headers.
  final Widget? trailing;

  @override
  State<GhostFileRow> createState() => _GhostFileRowState();
}

class _GhostFileRowState extends State<GhostFileRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final widget = this.widget;
    final strings = widget.strings ?? GhostFileRowStrings.english();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final fileTheme = GhostFileTheme.of(context);
    final metrics = GhostFileColumnMetrics.of(context);
    final platform = theme.platform;

    final size = ghostFormatFileSize(
      widget.item.type == GhostFileNodeType.directory ? null : widget.item.size,
      platform: platform,
    );
    final modified = ghostFormatFileModified(
      widget.item.modifiedAt,
      now: widget.clock(),
      localeName:
          widget.localeName ?? Localizations.localeOf(context).toString(),
      today: strings.todayText,
      yesterday: strings.yesterdayText,
    );

    // D32 §3: the accent selection belongs to the pane that decides
    // transfers; an inactive pane's selection drops to neutral grey.
    final accentSelected = widget.selected && widget.active;
    final Color? fill = accentSelected
        ? fileTheme.selectionFill
        : widget.selected
        ? fileTheme.inactiveSelectionFill
        : (widget.dropTargeted || _hovered)
        ? fileTheme.hoverFill
        : null;
    final foreground = accentSelected
        ? fileTheme.onSelection
        : colors.onSurface;
    final secondary = accentSelected
        ? fileTheme.onSelection
        : fileTheme.secondaryText;
    final captionStyle = theme.textTheme.bodySmall?.copyWith(
      color: secondary,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final (glyph, hue) = ghostFileKindGlyph(ghostFileKind(widget.item));
    final tint = FamilyPalette.of(context).glyph(hue);

    // 02 §5.1's folder-row target ring outranks the cursor ring; both
    // paint in the foreground so they never shift the row's layout.
    final Border? ring = widget.dropTargeted
        ? Border.all(color: colors.primary, width: 2)
        : widget.cursorRing
        ? Border.all(
            color: widget.active
                ? (accentSelected
                      ? fileTheme.onSelection.withValues(alpha: 0.7)
                      : fileTheme.activePaneIndicator)
                : fileTheme.secondaryText.withValues(alpha: 0.6),
          )
        : null;

    // 02 §13: the row's kind is part of the announced label
    // (Name-Kind-Size-Date order); the glyph carries it only visually.
    final kind = strings.kindLabel(widget.item.type);

    // 02 §13's flagged-name rule: a U+FFFD name is undecodable — the
    // row keeps a warning badge + tooltip visually and spells the
    // reason into the semantics label; the host withholds rename.
    final flagged = ghostFileNameIsFlagged(widget.item.name);

    Widget content = DecoratedBox(
      decoration: BoxDecoration(color: fill),
      position: DecorationPosition.background,
      child: DecoratedBox(
        decoration: BoxDecoration(border: ring),
        position: DecorationPosition.foreground,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(
            start: GhostFileColumnMetrics.startPadding,
            end: GhostFileColumnMetrics.endPadding,
          ),
          child: Row(
            children: [
              if (widget.outline) ...[
                if (widget.depth > 0)
                  SizedBox(
                    width: widget.depth * GhostFileColumnMetrics.depthIndent,
                  ),
                SizedBox(
                  width: GhostFileColumnMetrics.disclosureWidth,
                  child: widget.disclosure == GhostFileDisclosure.none
                      ? null
                      : _DisclosureTriangle(
                          state: widget.disclosure,
                          color: secondary,
                          expandTooltip: strings.expandLabel,
                          collapseTooltip: strings.collapseLabel,
                          onPointerDown: widget.onDisclosurePointerDown,
                        ),
                ),
              ],
              Icon(
                glyph,
                size: GhostFileColumnMetrics.glyphSize,
                color: accentSelected ? fileTheme.onSelection : tint,
              ),
              const SizedBox(width: GhostFileColumnMetrics.glyphGap),
              Expanded(
                child: widget.renaming
                    ? const SizedBox.shrink()
                    : Text(
                        widget.item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: foreground,
                        ),
                      ),
              ),
              // 02 §13's flagged-name marker: the name already shows
              // U+FFFD; the badge + tooltip say why.
              if (flagged)
                Tooltip(
                  message: strings.flaggedTooltip,
                  child: Padding(
                    padding: const EdgeInsetsDirectional.only(start: 4),
                    child: Icon(
                      Icons.warning_amber_outlined,
                      size: 14,
                      color: accentSelected
                          ? fileTheme.onSelection
                          : colors.error,
                    ),
                  ),
                ),
              ?widget.trailing,
              if (metrics.showsSize) ...[
                const SizedBox(width: GhostFileColumnMetrics.columnGap),
                SizedBox(
                  width: metrics.sizeWidth,
                  child: Text(
                    size,
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: captionStyle,
                  ),
                ),
              ],
              const SizedBox(width: GhostFileColumnMetrics.columnGap),
              SizedBox(
                width: metrics.modifiedWidth,
                child: Text(
                  modified,
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: captionStyle,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    content = widget.touch
        ? GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            onLongPress: widget.onLongPress,
            child: content,
          )
        : MouseRegion(
            onEnter: (_) => setState(() => _hovered = true),
            onExit: (_) => setState(() => _hovered = false),
            child: Listener(
              // Raw presses, never a tap recognizer: the row selects the
              // moment the button goes down, and the pane state times
              // the double-click itself (D32 §6).
              behavior: HitTestBehavior.opaque,
              onPointerDown: widget.onPointerDown,
              onPointerMove: widget.onPointerMove,
              onPointerUp: widget.onPointerUp,
              child: content,
            ),
          );

    return Semantics(
      label: flagged
          ? strings.flaggedSemanticsLabel(
              widget.item.name,
              kind,
              size,
              modified,
            )
          : strings.semanticsLabel(widget.item.name, kind, size, modified),
      // The composed label replaces the child text's own semantics —
      // without this, screen readers announce the name twice. The
      // excluded child no longer provides the tap action either, so
      // activation is exposed here.
      excludeSemantics: true,
      // AT activation opens the row: a screen reader's activate gesture
      // is the row's primary verb here (the cursor-set single click is
      // a sighted-user convention; Enter covers it for keyboards).
      onTap: widget.onOpen,
      // Announced membership follows the actual selection (02 §13),
      // never the cursor: a plain move single-selects its row, so the
      // cursor is announced selected except in the one state where it
      // is not selected — a toggled-off row.
      selected: widget.selected,
      // 02 §2.5: an expandable folder announces whether it is open.
      expanded: switch (widget.disclosure) {
        GhostFileDisclosure.none => null,
        GhostFileDisclosure.collapsed => false,
        GhostFileDisclosure.loading || GhostFileDisclosure.expanded => true,
      },
      // §13's open/rename action pair: open rides onTap; rename is a
      // custom action, absent when the row cannot take one. Folders
      // that expand in place add Expand or Collapse.
      customSemanticsActions: {
        if (widget.onRename != null)
          CustomSemanticsAction(label: strings.renameLabel): widget.onRename!,
        if (widget.onToggleDisclosure != null)
          CustomSemanticsAction(
            label: widget.disclosure == GhostFileDisclosure.collapsed
                ? strings.expandLabel
                : strings.collapseLabel,
          ): widget.onToggleDisclosure!,
      },
      child: content,
    );
  }
}

/// A folder row's disclosure triangle (02 §2.5): points along the text
/// direction while closed and turns down when open; a small spinner
/// stands in while the folder's listing is in flight. The press is its
/// own, reported before the row's.
///
/// Ported verbatim from Poltergeist's `_DisclosureTriangle`
/// (`ui/panes/pane_view.dart`); tooltips stay caller-supplied.
class _DisclosureTriangle extends StatelessWidget {
  const _DisclosureTriangle({
    required this.state,
    required this.color,
    required this.expandTooltip,
    required this.collapseTooltip,
    required this.onPointerDown,
  });

  final GhostFileDisclosure state;
  final Color color;
  final String expandTooltip;
  final String collapseTooltip;
  final ValueChanged<PointerDownEvent>? onPointerDown;

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final Widget glyph = state == GhostFileDisclosure.loading
        ? SizedBox.square(
            dimension: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
          )
        : AnimatedRotation(
            turns: state == GhostFileDisclosure.expanded
                ? (rtl ? -0.25 : 0.25)
                : 0,
            duration: const Duration(milliseconds: 120),
            child: Icon(
              rtl ? Icons.arrow_left : Icons.arrow_right,
              size: GhostFileColumnMetrics.disclosureWidth,
              color: color,
            ),
          );
    return Tooltip(
      message: state == GhostFileDisclosure.collapsed
          ? expandTooltip
          : collapseTooltip,
      waitDuration: const Duration(milliseconds: 600),
      excludeFromSemantics: true,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: onPointerDown,
        child: Center(child: glyph),
      ),
    );
  }
}
