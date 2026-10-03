import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show FileSortDirection, FileSortKey;

import '../../l10n/app_localizations.dart';

/// The listing's column geometry (D32 §6): the header, the rows, and
/// the inline-rename editor's insets share one table so a header cell
/// always sits over the cells it sorts. The implementation moved to
/// `package:ghost_ui` (`GhostFileColumnMetrics`); the aliases keep the
/// pane vocabulary for the surfaces that read it.
typedef PaneColumnMetrics = GhostFileColumnMetrics;

/// Hands one pane's measured [PaneColumnMetrics] to its column header
/// and rows — the shared scope type, so the ghost rows see it too.
typedef PaneColumnMetricsScope = GhostFileColumnMetricsScope;

/// The sortable header columns the shared header renders, in the app's
/// own sort vocabulary: the listing offers only these three (02 §2.3's
/// column set), while [FileSortKey] itself names every sortable field.
GhostFileColumn? _ghostColumn(FileSortKey key) => switch (key) {
  FileSortKey.name => GhostFileColumn.name,
  FileSortKey.size => GhostFileColumn.size,
  FileSortKey.modified => GhostFileColumn.modified,
  // The header renders no cell for the metadata sorts; one can only
  // arrive through a foreign preference file, since no sort surface
  // offers it.
  _ => null,
};

/// D32 §6's column header: Name | Size | Date Modified over the Details
/// listing, 22 px, click to sort with a chevron on the sorted column.
/// It sits OUTSIDE the listing's scroll view so the drop zone's row
/// math (the list's origin is row 0) never has to subtract it.
///
/// The rendering lives in `package:ghost_ui`'s [GhostFileColumnHeader];
/// this adapter translates the app's [FileSortKey]/[FileSortDirection]
/// and its ARB strings.
class PaneColumnHeader extends StatelessWidget {
  const PaneColumnHeader({
    super.key,
    required this.paneTabId,
    required this.sortKey,
    required this.sortDirection,
    required this.onSort,
    this.enabled = true,
  });

  /// Keys the cells (`<paneTabId>.column.<key>`) for tests and the
  /// localization contract.
  final String paneTabId;
  final FileSortKey sortKey;
  final FileSortDirection sortDirection;
  final ValueChanged<FileSortKey> onSort;

  /// False while the listing is inert (connection lost, restored,
  /// disowned rows): the header stays visible but takes no clicks.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return GhostFileColumnHeader(
      listId: paneTabId,
      sortColumn: _ghostColumn(sortKey),
      sortDirection: sortDirection == FileSortDirection.ascending
          ? GhostFileSortDirection.ascending
          : GhostFileSortDirection.descending,
      onSort: (column) => onSort(switch (column) {
        GhostFileColumn.name => FileSortKey.name,
        GhostFileColumn.size => FileSortKey.size,
        GhostFileColumn.modified => FileSortKey.modified,
      }),
      strings: GhostFileColumnStrings(
        nameLabel: l10n.paneColumnName,
        sizeLabel: l10n.paneColumnSize,
        modifiedLabel: l10n.paneColumnModified,
        sortedAscending: l10n.paneColumnSortedAscending,
        sortedDescending: l10n.paneColumnSortedDescending,
        sortHint: l10n.paneColumnSortHint,
      ),
      enabled: enabled,
    );
  }
}
