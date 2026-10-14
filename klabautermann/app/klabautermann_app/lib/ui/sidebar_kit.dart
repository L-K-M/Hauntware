import 'package:ghost_ui/ghost_ui.dart';

import '../l10n/app_localizations.dart';

export 'package:ghost_ui/ghost_ui.dart'
    show
        SidebarKitDensity,
        SidebarKitLayout,
        SidebarKitScope,
        SidebarKitStrings,
        SidebarMenuAction,
        SidebarMenuEntry,
        SidebarRow,
        SidebarDotStyle,
        SidebarStatusDot,
        SidebarSyncChipData,
        SidebarSyncTone,
        SidebarActivation,
        SidebarBottomBar,
        SidebarSectionHeader,
        SidebarThemeTokens;

/// The kit's string bag from Klabautermann's ARB (03 §10.10's adapter-file
/// convention: shared packages keep their strings host-supplied).
SidebarKitStrings klabautermannSidebarStrings(AppLocalizations l10n) {
  return SidebarKitStrings(
    sectionSemantics: (title, count) =>
        l10n.sidebarSectionSemantics(title, l10n.serversCount(count)),
    showSection: l10n.sidebarShowSection,
    hideSection: l10n.sidebarHideSection,
    filterHint: l10n.sidebarFilterHint,
    filterClear: l10n.sidebarFilterClear,
    addMenu: l10n.sidebarAddMenu,
    settings: l10n.openSettings,
    rowMenu: l10n.sidebarRowMenu,
    compactRows: l10n.sidebarCompactRows,
    comfortableRows: l10n.sidebarComfortableRows,
  );
}
