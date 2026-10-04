import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

/// The chrome tokens the sidebar kit paints with — the adoption seam
/// between the shared kit and each app's own theme system.
///
/// The kit reads ONLY these fields (plus [corner]). Hosts supply their
/// existing resolved chrome — a field-for-field copy from the app's own
/// extension, so the kit and the app's native sidebar cannot drift:
///
/// ```dart
/// SidebarThemeTokens(
///   sidebarBackground: chrome.sidebarBackground,
///   separator: chrome.separator,
///   hoverFill: chrome.hoverFill,
///   capsuleFill: chrome.capsuleFill,
///   inactiveSelectionFill: chrome.inactiveSelectionFill,
///   secondaryText: chrome.secondaryText,
///   sidebarRowExtent: chrome.sidebarRowExtent,
///   cornerScale: chrome.cornerScale,
/// )
/// ```
///
/// The names are identical in `PoltergeistChrome` and `SeanceChrome` on
/// purpose — the adapter is mechanical in both. Add the result to the
/// host theme's `ThemeData.extensions`.
///
/// [of] falls back to [fallback] when a theme carries no extension — a
/// dialog subtree or a test harness — resolving to the slate/Finder
/// neutrals both apps' chrome defaults already produce, so a host that
/// never installs the extension draws exactly what its old `Chrome.of`
/// fallback did.
@immutable
final class SidebarThemeTokens extends ThemeExtension<SidebarThemeTokens> {
  const SidebarThemeTokens({
    required this.sidebarBackground,
    required this.separator,
    required this.hoverFill,
    required this.capsuleFill,
    required this.inactiveSelectionFill,
    required this.secondaryText,
    required this.sidebarRowExtent,
    this.cornerScale = 1,
  });

  /// The full-height sidebar column behind the rows (Finder's
  /// source-list tint), unless [SidebarKitScope.background] overrides it.
  final Color sidebarBackground;

  /// The bottom bar's top hairline and the density switch's outline.
  final Color separator;

  /// Pointer hover on rows and headers, and the drop-into fill.
  final Color hoverFill;

  /// The filter field's fill.
  final Color capsuleFill;

  /// The selected row's pill and the density switch's chosen half.
  final Color inactiveSelectionFill;

  /// Captions: item counts, chevrons, subtitles, icons at rest.
  final Color secondaryText;

  /// A compact row's extent before text scaling (26 px desktop in both
  /// apps; the comfortable and list extents are the kit's own).
  final double sidebarRowExtent;

  /// The theme's corner multiplier, for what the kit draws by hand.
  final double cornerScale;

  /// A [base] corner radius as the theme scales it.
  double corner(double base) => base * cornerScale;

  /// The tokens for [context]'s theme, or [fallback] when the theme
  /// carries none.
  static SidebarThemeTokens of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<SidebarThemeTokens>() ??
        fallback(theme.brightness, theme.platform);
  }

  /// The shared chrome defaults: the same neutrals both sibling themes
  /// resolve their chrome from, so a theme with no extension draws the
  /// rail both apps shipped. A desktop [platform] gets the 26 px compact
  /// row; touch gets 40.
  static SidebarThemeTokens fallback(
    Brightness brightness,
    TargetPlatform platform,
  ) {
    final dark = brightness == Brightness.dark;
    return SidebarThemeTokens(
      sidebarBackground: dark
          ? const Color(0xFF2A313B)
          : const Color(0xFFF1F2F4),
      separator: dark ? const Color(0xFF3A424E) : const Color(0xFFDADDE3),
      hoverFill: (dark ? const Color(0xFFE7EAEF) : const Color(0xFF1C1F24))
          .withValues(alpha: 0.06),
      capsuleFill: dark ? const Color(0xFF353D49) : const Color(0xFFEBECEF),
      inactiveSelectionFill: dark
          ? const Color(0xFF3B4452)
          : const Color(0xFFE2E5EA),
      secondaryText: dark ? const Color(0xFFB4BCC8) : const Color(0xFF596170),
      sidebarRowExtent: _desktopPlatform(platform) ? 26 : 40,
    );
  }

  /// The same desktop/touch split the kit's row metrics make.
  static bool _desktopPlatform(TargetPlatform platform) => switch (platform) {
    TargetPlatform.macOS ||
    TargetPlatform.linux ||
    TargetPlatform.windows => true,
    _ => false,
  };

  @override
  SidebarThemeTokens copyWith({
    Color? sidebarBackground,
    Color? separator,
    Color? hoverFill,
    Color? capsuleFill,
    Color? inactiveSelectionFill,
    Color? secondaryText,
    double? sidebarRowExtent,
    double? cornerScale,
  }) {
    return SidebarThemeTokens(
      sidebarBackground: sidebarBackground ?? this.sidebarBackground,
      separator: separator ?? this.separator,
      hoverFill: hoverFill ?? this.hoverFill,
      capsuleFill: capsuleFill ?? this.capsuleFill,
      inactiveSelectionFill:
          inactiveSelectionFill ?? this.inactiveSelectionFill,
      secondaryText: secondaryText ?? this.secondaryText,
      sidebarRowExtent: sidebarRowExtent ?? this.sidebarRowExtent,
      cornerScale: cornerScale ?? this.cornerScale,
    );
  }

  @override
  SidebarThemeTokens lerp(SidebarThemeTokens? other, double t) {
    if (other == null) return this;
    return SidebarThemeTokens(
      sidebarBackground: Color.lerp(
        sidebarBackground,
        other.sidebarBackground,
        t,
      )!,
      separator: Color.lerp(separator, other.separator, t)!,
      hoverFill: Color.lerp(hoverFill, other.hoverFill, t)!,
      capsuleFill: Color.lerp(capsuleFill, other.capsuleFill, t)!,
      inactiveSelectionFill: Color.lerp(
        inactiveSelectionFill,
        other.inactiveSelectionFill,
        t,
      )!,
      secondaryText: Color.lerp(secondaryText, other.secondaryText, t)!,
      // Linear like the colours: a stepped extent would snap mid-way
      // through MaterialApp's theme animation while everything fades.
      sidebarRowExtent: lerpDouble(
        sidebarRowExtent,
        other.sidebarRowExtent,
        t,
      )!,
      cornerScale: lerpDouble(cornerScale, other.cornerScale, t)!,
    );
  }
}
