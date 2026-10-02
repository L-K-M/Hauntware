import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'ghost_file_format.dart' show ghostFormatFileModified;
import 'ghost_file_theme.dart';

/// The listing's column geometry (D32 §6), shared by the column header,
/// the rows, and the inline-rename editor's insets: one table, so a
/// header cell always sits over the cells it sorts. Widths scale with
/// the text scale (D20), the paddings do not.
///
/// Ported verbatim from Poltergeist's `PaneColumnMetrics`
/// (`ui/panes/pane_column_header.dart`), decoupled from that host's
/// `FileSortKey`: the header reports [GhostFileColumn] taps and hosts
/// map them to their own sort vocabulary.
@immutable
class GhostFileColumnMetrics {
  const GhostFileColumnMetrics._({
    required this.sizeWidth,
    required this.modifiedWidth,
  });

  /// The metrics for a listing [width] wide: below
  /// [_sizeColumnBreakpoint] the Size column folds away (Finder drops
  /// columns right-to-left of the name rather than starving it), so a
  /// narrow pane still shows readable names and dates.
  ///
  /// [modifiedWidth] is the Date Modified column's measured width
  /// ([modifiedWidthIn]); without one the column takes its floor. The
  /// column never takes more than [_modifiedShare] of the pane beyond
  /// that floor, so a narrow pane keeps its names and an ellipsis only
  /// returns to the longest dates there.
  factory GhostFileColumnMetrics.forWidth(
    double width,
    TextScaler scaler, {
    double? modifiedWidth,
  }) {
    final showSize = width >= scaler.scale(_sizeColumnBreakpoint);
    final floor = scaler.scale(_modifiedColumnWidth);
    return GhostFileColumnMetrics._(
      sizeWidth: showSize ? scaler.scale(_sizeColumnWidth) : 0,
      modifiedWidth: modifiedWidth == null
          ? floor
          : math.min(modifiedWidth, math.max(floor, width * _modifiedShare)),
    );
  }

  /// The Date Modified column's width in [context]: the widest date a
  /// row can print ("Today at", "Yesterday at" or a full date, each at
  /// a two-digit month, day and hour) in the rows' style, locale and
  /// text scale, and never below the spec's 116 px. A fixed width cut
  /// most full dates to an ellipsis on Linux's default font.
  ///
  /// [today]/[yesterday] are the host's localized label builders and
  /// [localeName] its locale (defaulting to the ambient one), matching
  /// what [ghostFormatFileModified] is given at row level.
  static double modifiedWidthIn(
    BuildContext context, {
    required String Function(String time) today,
    required String Function(String time) yesterday,
    String? localeName,
  }) {
    final locale = localeName ?? Localizations.localeOf(context).toString();
    final scaler = MediaQuery.textScalerOf(context);
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final now = DateTime(2026, 12, 29, 23);
    var widest = 0.0;
    for (final sample in [
      DateTime(2026, 12, 29, 22, 58),
      DateTime(2026, 12, 28, 22, 58),
      DateTime(2025, 12, 28, 22, 58),
    ]) {
      final text = ghostFormatFileModified(
        sample,
        now: now,
        localeName: locale,
        today: today,
        yesterday: yesterday,
      );
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      widest = math.max(widest, painter.width);
      painter.dispose();
    }
    return math.max(scaler.scale(_modifiedColumnWidth), widest.ceilToDouble());
  }

  /// The metrics the nearest [GhostFileColumnMetricsScope] provides —
  /// the pane surface measures its width once for the header and every
  /// row. Outside a scope (a lone row in a test) the full column set
  /// applies.
  factory GhostFileColumnMetrics.of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<GhostFileColumnMetricsScope>();
    return scope?.metrics ??
        GhostFileColumnMetrics.forWidth(
          double.infinity,
          MediaQuery.textScalerOf(context),
        );
  }

  static const _sizeColumnWidth = 60.0;
  static const _modifiedColumnWidth = 116.0;
  static const _modifiedShare = 0.35;
  static const _sizeColumnBreakpoint = 360.0;

  /// Leading inset of every row, before the kind glyph.
  static const startPadding = 8.0;

  /// Trailing inset after the last column.
  static const endPadding = 10.0;

  static const glyphSize = 16.0;
  static const glyphGap = 6.0;

  /// The disclosure triangle's column before the kind glyph (02 §2.5):
  /// reserved on every desktop row, folder or not, so names line up.
  static const disclosureWidth = 16.0;

  /// How far each level of an expanded folder's rows steps in.
  static const depthIndent = 16.0;

  /// The space a desktop row at [depth] puts before its kind glyph,
  /// past [startPadding]; nothing on touch rows, which never expand.
  static double outlineInset({required bool outline, required int depth}) =>
      outline ? disclosureWidth + depth * depthIndent : 0;

  /// Space between the name, size, and date columns.
  static const columnGap = 12.0;

  /// Zero while the pane is too narrow for the Size column.
  final double sizeWidth;
  final double modifiedWidth;

  bool get showsSize => sizeWidth > 0;

  /// Where the name text starts inside a row.
  double get nameStart => startPadding + glyphSize + glyphGap;

  /// The space the trailing columns take after the name column.
  double get trailingExtent =>
      (showsSize ? columnGap + sizeWidth : 0) +
      columnGap +
      modifiedWidth +
      endPadding;

  @override
  bool operator ==(Object other) =>
      other is GhostFileColumnMetrics &&
      other.sizeWidth == sizeWidth &&
      other.modifiedWidth == modifiedWidth;

  @override
  int get hashCode => Object.hash(sizeWidth, modifiedWidth);
}

/// Hands one listing's measured [GhostFileColumnMetrics] to its column
/// header and rows.
class GhostFileColumnMetricsScope extends InheritedWidget {
  const GhostFileColumnMetricsScope({
    super.key,
    required this.metrics,
    required super.child,
  });

  final GhostFileColumnMetrics metrics;

  @override
  bool updateShouldNotify(GhostFileColumnMetricsScope oldWidget) =>
      metrics != oldWidget.metrics;
}

/// The columns a listing can sort by from its header — the shared
/// vocabulary hosts map onto their own sort enums (Poltergeist's
/// `FileSortKey`, Séance's `RemoteSortField`).
enum GhostFileColumn { name, size, modified }

enum GhostFileSortDirection { ascending, descending }

/// The column header's caller-supplied strings — labels, sort-state
/// announcements, and the click hint. English defaults match the hosts'
/// source copy; hosts with ARB supply their own.
@immutable
class GhostFileColumnStrings {
  const GhostFileColumnStrings({
    required this.nameLabel,
    required this.sizeLabel,
    required this.modifiedLabel,
    required this.sortedAscending,
    required this.sortedDescending,
    required this.sortHint,
  });

  /// The strings as the hosts' English copy spells them.
  const GhostFileColumnStrings.english()
    : nameLabel = 'Name',
      sizeLabel = 'Size',
      modifiedLabel = 'Date Modified',
      sortedAscending = 'Sorted ascending',
      sortedDescending = 'Sorted descending',
      sortHint = 'Sort by this column';

  final String nameLabel;
  final String sizeLabel;
  final String modifiedLabel;
  final String sortedAscending;
  final String sortedDescending;
  final String sortHint;
}

/// D32 §6's column header: Name | Size | Date Modified over the listing,
/// 22 px, click to sort with a chevron on the sorted column. It sits
/// OUTSIDE the listing's scroll view so the drop zone's row math (the
/// list's origin is row 0) never has to subtract it.
///
/// Ported from Poltergeist's `PaneColumnHeader`
/// (`ui/panes/pane_column_header.dart`); sort state and clicks report
/// [GhostFileColumn] so no host sort enum leaks into the shared layer.
class GhostFileColumnHeader extends StatelessWidget {
  const GhostFileColumnHeader({
    super.key,
    required this.listId,
    this.sortColumn,
    required this.sortDirection,
    required this.onSort,
    this.strings = const GhostFileColumnStrings.english(),
    this.enabled = true,
  });

  /// Keys the cells (`<listId>.column.<key>`) for tests and the
  /// localization contract.
  final String listId;

  /// The column the listing currently sorts on, or null when the active
  /// sort key has no column (Séance's type sort lives in its ⋮ menu) —
  /// no cell then carries the sorted weight or chevron.
  final GhostFileColumn? sortColumn;
  final GhostFileSortDirection sortDirection;
  final ValueChanged<GhostFileColumn> onSort;

  /// The header's labels and sort announcements.
  final GhostFileColumnStrings strings;

  /// False while the listing is inert (connection lost, restored,
  /// disowned rows): the header stays visible but takes no clicks.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final fileTheme = GhostFileTheme.of(context);
    final metrics = GhostFileColumnMetrics.of(context);
    final height = MediaQuery.textScalerOf(context).scale(22);
    return IgnorePointer(
      ignoring: !enabled,
      child: Container(
        key: ValueKey('$listId.columns'),
        height: height,
        decoration: BoxDecoration(
          color: fileTheme.paneBackground,
          border: Border(bottom: BorderSide(color: fileTheme.separator)),
        ),
        padding: const EdgeInsetsDirectional.only(
          start: GhostFileColumnMetrics.startPadding,
          end: GhostFileColumnMetrics.endPadding,
        ),
        child: Row(
          children: [
            Expanded(
              child: _cell(
                context,
                GhostFileColumn.name,
                strings.nameLabel,
                TextAlign.start,
              ),
            ),
            if (metrics.showsSize) ...[
              const SizedBox(width: GhostFileColumnMetrics.columnGap),
              SizedBox(
                width: metrics.sizeWidth,
                child: _cell(
                  context,
                  GhostFileColumn.size,
                  strings.sizeLabel,
                  TextAlign.end,
                ),
              ),
            ],
            const SizedBox(width: GhostFileColumnMetrics.columnGap),
            SizedBox(
              width: metrics.modifiedWidth,
              child: _cell(
                context,
                GhostFileColumn.modified,
                strings.modifiedLabel,
                TextAlign.end,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _cell(
    BuildContext context,
    GhostFileColumn column,
    String label,
    TextAlign align,
  ) {
    final fileTheme = GhostFileTheme.of(context);
    final sorted = column == sortColumn;
    final ascending = sortDirection == GhostFileSortDirection.ascending;
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: sorted
          ? Theme.of(context).colorScheme.onSurface
          : fileTheme.secondaryText,
      fontWeight: sorted ? FontWeight.w600 : FontWeight.w500,
    );
    final text = Flexible(
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: align,
        style: style,
      ),
    );
    final chevron = sorted
        ? Icon(
            ascending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
            size: 14,
            color: fileTheme.secondaryText,
          )
        : const SizedBox(width: 14);
    return Semantics(
      button: true,
      label: label,
      value: sorted
          ? (ascending ? strings.sortedAscending : strings.sortedDescending)
          : null,
      hint: strings.sortHint,
      excludeSemantics: true,
      onTap: () => onSort(column),
      child: InkWell(
        key: ValueKey('$listId.column.${column.name}'),
        onTap: () => onSort(column),
        hoverColor: fileTheme.hoverFill,
        child: Row(
          mainAxisAlignment: align == TextAlign.end
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          children: align == TextAlign.end
              ? [chevron, text]
              : [
                  // The name column's label starts over the row's name
                  // text, past the kind glyph (Finder's alignment) and,
                  // on desktop, the disclosure column (02 §2.5).
                  SizedBox(
                    width:
                        GhostFileColumnMetrics.outlineInset(
                          outline: ghostIsDesktopPlatform(
                            Theme.of(context).platform,
                          ),
                          depth: 0,
                        ) +
                        GhostFileColumnMetrics.glyphSize +
                        GhostFileColumnMetrics.glyphGap,
                  ),
                  text,
                  chevron,
                ],
        ),
      ),
    );
  }
}
