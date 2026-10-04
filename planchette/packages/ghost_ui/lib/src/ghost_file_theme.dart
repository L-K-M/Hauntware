import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// The file-listing presentation tokens the shared rows, kind badges,
/// and column header consume — a focused subset of each host's chrome
/// (Poltergeist's `PoltergeistChrome` is the reference shape,
/// `theme/app_theme.dart`). Hosts supply the extension; a subtree
/// without one falls back to Material-derivable defaults so a lone row
/// in a test harness still renders.
class GhostFileTheme extends ThemeExtension<GhostFileTheme> {
  const GhostFileTheme({
    required this.paneBackground,
    required this.separator,
    required this.hoverFill,
    required this.selectionFill,
    required this.onSelection,
    required this.inactiveSelectionFill,
    required this.activePaneIndicator,
    required this.secondaryText,
    this.rowExtent = 22,
  });

  /// The listing surface's colour: the header's fill and the base the
  /// compact row's selected tint blends onto.
  final Color paneBackground;

  /// The 1 px header-bottom separator.
  final Color separator;

  /// Pointer hover on desktop rows and the header cells' ink.
  final Color hoverFill;

  /// Selected rows in the ACTIVE pane — accent fill, on-accent text.
  final Color selectionFill;
  final Color onSelection;

  /// Selected rows while their pane is inactive.
  final Color inactiveSelectionFill;

  /// The cursor ring's accent — the active pane's marker.
  final Color activePaneIndicator;

  /// Size/date captions, kind text, and the header's unsorted labels.
  final Color secondaryText;

  /// Desktop listing row extent before text scaling (Poltergeist D32:
  /// 22 px); hosts supply it so the shared layer hardcodes nothing.
  final double rowExtent;

  /// The theme for [context]'s file listing, deriving Material
  /// defaults when a host theme carries no extension.
  static GhostFileTheme of(BuildContext context) {
    final theme = Theme.of(context);
    final provided = theme.extension<GhostFileTheme>();
    if (provided != null) return provided;
    final colors = theme.colorScheme;
    return GhostFileTheme(
      paneBackground: colors.surface,
      separator: colors.outlineVariant,
      hoverFill: colors.onSurface.withValues(alpha: 0.08),
      selectionFill: colors.primary,
      onSelection: colors.onPrimary,
      inactiveSelectionFill: colors.surfaceContainerHighest,
      activePaneIndicator: colors.primary,
      secondaryText: colors.onSurfaceVariant,
    );
  }

  @override
  GhostFileTheme copyWith({
    Color? paneBackground,
    Color? separator,
    Color? hoverFill,
    Color? selectionFill,
    Color? onSelection,
    Color? inactiveSelectionFill,
    Color? activePaneIndicator,
    Color? secondaryText,
    double? rowExtent,
  }) {
    return GhostFileTheme(
      paneBackground: paneBackground ?? this.paneBackground,
      separator: separator ?? this.separator,
      hoverFill: hoverFill ?? this.hoverFill,
      selectionFill: selectionFill ?? this.selectionFill,
      onSelection: onSelection ?? this.onSelection,
      inactiveSelectionFill:
          inactiveSelectionFill ?? this.inactiveSelectionFill,
      activePaneIndicator: activePaneIndicator ?? this.activePaneIndicator,
      secondaryText: secondaryText ?? this.secondaryText,
      rowExtent: rowExtent ?? this.rowExtent,
    );
  }

  @override
  GhostFileTheme lerp(GhostFileTheme? other, double t) {
    if (other == null) return this;
    return GhostFileTheme(
      paneBackground: Color.lerp(paneBackground, other.paneBackground, t)!,
      separator: Color.lerp(separator, other.separator, t)!,
      hoverFill: Color.lerp(hoverFill, other.hoverFill, t)!,
      selectionFill: Color.lerp(selectionFill, other.selectionFill, t)!,
      onSelection: Color.lerp(onSelection, other.onSelection, t)!,
      inactiveSelectionFill: Color.lerp(
        inactiveSelectionFill,
        other.inactiveSelectionFill,
        t,
      )!,
      activePaneIndicator: Color.lerp(
        activePaneIndicator,
        other.activePaneIndicator,
        t,
      )!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      rowExtent: lerpDouble(rowExtent, other.rowExtent, t)!,
    );
  }
}

/// Whether [platform] gets the desktop density tokens (13 px text, the
/// dense listing rows) — touch platforms keep the comfortable rows.
///
/// Ported from Poltergeist's `isDesktopPlatform`
/// (`theme/app_theme.dart`).
bool ghostIsDesktopPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => true,
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => false,
};

/// The desktop listing's fixed row extent for [context] — the host's
/// `GhostFileTheme.rowExtent` at the ambient text scale.
///
/// Ported from Poltergeist's `scaledPaneRowExtent`
/// (`ui/panes/pane_view.dart`); the list wraps it in `itemExtent` so
/// larger type grows rows instead of clipping them (D20).
double scaledGhostFileRowExtent(BuildContext context) =>
    MediaQuery.textScalerOf(
      context,
    ).scale(GhostFileTheme.of(context).rowExtent);
