import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart'
    show
        FamilyPalette,
        GhostFileTheme,
        GhostMenuTheme,
        SidebarThemeTokens,
        ThemeModePreference,
        compositeOver,
        contrastRatio,
        legibleOn,
        surfaceBrightness;

import 'app_appearance.dart';
import 'ghost_theme_neutrals.dart';
import 'ghost_theme_presets.dart';
import 'ghost_theme_style.dart';
import 'theme_palette.dart';

const Color _white = Color(0xFFFFFFFF);
const Color _black = Color(0xFF000000);

/// How far each Automatic shade is mixed from a palette's own surface
/// toward its text (or, for secondary text, from the text toward the
/// surface). Measured against the dark table: mixed from its own surface
/// and text, these land within 6 units per channel of its container ladder
/// and lines, and within 18 of its secondary text and outline, which the
/// table tints bluer than a straight mix can — so a palette that brings a
/// surface of its own gets a ladder shaped like the one it replaces.
const double _sidebarMix = 0.04;
const double _raisedMix = 0.06;
const double _highMix = 0.05;
const double _highestMix = 0.08;
const double _secondaryTextMix = 0.3;
const double _outlineMix = 0.45;
const double _hairlineMix = 0.14;
const double _secondaryContainerMix = 0.22;
const double _lowestMix = 0.2;

/// The WCAG AA ratio for body text, which a derived selection pill keeps
/// under white text.
const double _textContrast = 4.5;

/// Material's own corner radii, which [ThemePalette.cornerScale] scales:
/// the M3 defaults, except the menu's and the tooltip's, which the sibling
/// apps set themselves. A button's is half its standard 40 px height, where
/// Material draws a stadium. Only the dialog's is a per-app style value.
const double _cardRadius = 12;
const double _menuRadius = 8;
const double _popupMenuRadius = 4;
const double _tooltipRadius = 6;
const double _inputRadius = 4;
const double _buttonRadius = 20;
const double _chipRadius = 8;
const double _bottomSheetRadius = 28;
const double _snackBarRadius = 4;

/// Whether [platform] gets the desktop density tokens (13 px text, 22 px
/// rows) — touch platforms keep Material's touch-sized defaults.
bool isGhostDesktopPlatform(TargetPlatform platform) => switch (platform) {
  TargetPlatform.macOS ||
  TargetPlatform.linux ||
  TargetPlatform.windows => true,
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.fuchsia => false,
};

Color _mix(Color from, Color to, double t) => Color.lerp(from, to, t)!;

/// The brightness [palette] is drawn at when Automatic colours follow
/// [brightness]: see [resolveBrightness].
Brightness _drawnAt(ThemePalette palette, Brightness brightness) {
  final surface = palette.surface;
  return surface == null ? brightness : surfaceBrightness(surface);
}

/// The neutrals [palette] draws with at [brightness] (already resolved by
/// [_drawnAt]): the style's table for that brightness, with every slot the
/// palette sets laid over it.
///
/// An Automatic slot is the table's while the surface is the table's too.
/// Once the palette brings a surface of its own, the Automatic slots are
/// mixed from that surface and the palette's text instead: the table's
/// slate rail beside a Solarized pane would be neither theme. The default
/// palette sets nothing, so it gets the tables unchanged.
GhostThemeNeutrals _neutralsFor(
  GhostThemeStyle style,
  ThemePalette palette,
  Brightness brightness,
) {
  final table = brightness == Brightness.dark ? style.dark : style.light;
  final ownSurface = palette.surface != null;
  final surface = palette.surface ?? table.surface;
  final text = palette.text ?? table.onSurface;
  Color auto(Color fromTable, Color mixed) => ownSurface ? mixed : fromTable;

  // The rest of the container ladder hangs off the raised colour, so a
  // palette that sets only that still gets high and highest ordered above
  // it rather than the table's, which may sit below it.
  final container =
      palette.raised ?? auto(table.container, _mix(surface, text, _raisedMix));
  final ownContainer = ownSurface || palette.raised != null;

  final containerLow =
      palette.sidebar ??
      auto(table.containerLow, _mix(surface, text, _sidebarMix));

  // The table's primary family is the hand-tuned rendering of the seed (a
  // lighter shade on dark, a deeper one on light, each clearing its
  // surface), so the seed keeps it. Any other accent is drawn as picked,
  // which is what the colour well promises; its containers come from
  // Material's scheme for it.
  final tuned = palette.accent == style.seed;
  final seeded = tuned
      ? null
      : ColorScheme.fromSeed(seedColor: palette.accent, brightness: brightness);
  final primary = tuned ? table.primary : palette.accent;

  final ownSelection = palette.selection != null || !tuned;
  final selection =
      palette.selection ??
      (tuned ? table.selection : _selectionFor(palette.accent));
  // A selection label is chosen against the surface it paints over: the
  // rail a host composites over, or the listing. A host may pin the tuned
  // table's instead (Poltergeist's hand-tuned white).
  final labelSurface = style.selectionLabel == GhostSelectionLabel.overRail
      ? containerLow
      : surface;

  return GhostThemeNeutrals(
    surface: surface,
    containerLowest: auto(
      table.containerLowest,
      _mix(
        surface,
        brightness == Brightness.dark ? _black : _white,
        _lowestMix,
      ),
    ),
    containerLow: containerLow,
    container: container,
    containerHigh: ownContainer
        ? _mix(container, text, _highMix)
        : table.containerHigh,
    containerHighest: ownContainer
        ? _mix(container, text, _highestMix)
        : table.containerHighest,
    onSurface: text,
    onSurfaceVariant:
        palette.secondaryText ??
        auto(table.onSurfaceVariant, _mix(text, surface, _secondaryTextMix)),
    outline: auto(table.outline, _mix(surface, text, _outlineMix)),
    outlineVariant:
        palette.hairline ??
        auto(table.outlineVariant, _mix(surface, text, _hairlineMix)),
    inverseSurface: auto(table.inverseSurface, text),
    onInverseSurface: auto(table.onInverseSurface, surface),
    primary: primary,
    onPrimary: seeded == null ? table.onPrimary : legibleOn(primary),
    primaryContainer: seeded?.primaryContainer ?? table.primaryContainer,
    onPrimaryContainer: seeded?.onPrimaryContainer ?? table.onPrimaryContainer,
    secondaryContainer: auto(
      table.secondaryContainer,
      _mix(surface, primary, _secondaryContainerMix),
    ),
    onSecondaryContainer: auto(table.onSecondaryContainer, text),
    selection: selection,
    onSelection: !ownSelection
        ? table.onSelection
        : legibleOn(compositeOver(selection, labelSurface)),
    error: table.error,
    errorContainer: table.errorContainer,
    onErrorContainer: table.onErrorContainer,
    connected: table.connected,
    connecting: table.connecting,
    failed: table.failed,
    unknown: table.unknown,
  );
}

/// An Automatic selection pill for an accent other than the seed: the
/// accent's own hue, darkened until white text on it clears 4.5:1 — the
/// convention the tables' violet pill keeps. The accent itself when it
/// already does.
Color _selectionFor(Color accent) {
  const steps = 20;
  for (var step = 0; step < steps; step++) {
    final candidate = _mix(accent, _black, step / steps);
    if (contrastRatio(_white, candidate) >= _textContrast) return candidate;
  }
  return _black;
}

/// The status dots' colours a palette resolves to over [n]: the palette's
/// own, or the table's per-brightness fallbacks.
({Color online, Color offline, Color connecting, Color unknown}) _statusFor(
  ThemePalette palette,
  GhostThemeNeutrals n,
) => (
  online: palette.online ?? n.connected,
  offline: palette.offline ?? n.failed,
  connecting: palette.connecting ?? n.connecting,
  unknown: palette.unknown ?? n.unknown,
);

/// The chrome tokens the shell regions paint — Séance's fields plus the
/// four status colours Poltergeist keeps beside them (its ledger's design:
/// status belongs where it is held to the same contrast floor).
@immutable
class GhostChrome extends ThemeExtension<GhostChrome> {
  const GhostChrome({
    required this.sidebarBackground,
    required this.headerBackground,
    required this.paneBackground,
    required this.inspectorBackground,
    required this.separator,
    required this.hoverFill,
    required this.capsuleFill,
    required this.selectionFill,
    required this.onSelection,
    required this.inactiveSelectionFill,
    required this.activePaneIndicator,
    required this.secondaryText,
    required this.statusConnected,
    required this.statusConnecting,
    required this.statusFailed,
    required this.statusUnknown,
    required this.headerHeight,
    required this.rowExtent,
    required this.sidebarRowExtent,
    this.cornerScale = 1,
  });

  final Color sidebarBackground;
  final Color headerBackground;
  final Color paneBackground;
  final Color inspectorBackground;
  final Color separator;
  final Color hoverFill;
  final Color capsuleFill;
  final Color selectionFill;
  final Color onSelection;
  final Color inactiveSelectionFill;
  final Color activePaneIndicator;
  final Color secondaryText;

  /// The one "connected" status colour (server dots, tab chips, probe
  /// dots): a per-theme green that keeps the non-text contrast floor on the
  /// rail's selection pill as well as its resting and hover rows.
  final Color statusConnected;

  /// The rail's "connecting" dot: an amber per theme, held to the same
  /// floor as [statusConnected].
  final Color statusConnecting;

  /// A failed connection's dot, the blocked host key's no-entry dot, and
  /// the unreachable ring: the palette's `offline`, or the table's failure
  /// red.
  final Color statusFailed;

  /// An unknown or idle server's dot: the palette's `unknown`, or the
  /// table's grey.
  final Color statusUnknown;

  final double headerHeight;
  final double rowExtent;
  final double sidebarRowExtent;

  /// The theme's corner multiplier ([ThemePalette.cornerScale]), for what
  /// the app draws by hand: Material's components take it through their
  /// own themes, and a hand-drawn pill opts in with [corner].
  final double cornerScale;

  /// A [base] corner radius as the theme scales it.
  double corner(double base) => base * cornerScale;

  /// The chrome a context's theme carries, falling back to the style's
  /// brand palette when a host theme (a test harness, a dialog subtree)
  /// carries none.
  static GhostChrome of(BuildContext context, GhostThemeStyle style) {
    final theme = Theme.of(context);
    return theme.extension<GhostChrome>() ??
        _chromeFor(
          style,
          GhostThemePresets(style).brand,
          theme.brightness,
          theme.platform,
        );
  }

  @override
  GhostChrome copyWith({
    Color? sidebarBackground,
    Color? headerBackground,
    Color? paneBackground,
    Color? inspectorBackground,
    Color? separator,
    Color? hoverFill,
    Color? capsuleFill,
    Color? selectionFill,
    Color? onSelection,
    Color? inactiveSelectionFill,
    Color? activePaneIndicator,
    Color? secondaryText,
    Color? statusConnected,
    Color? statusConnecting,
    Color? statusFailed,
    Color? statusUnknown,
    double? headerHeight,
    double? rowExtent,
    double? sidebarRowExtent,
    double? cornerScale,
  }) {
    return GhostChrome(
      sidebarBackground: sidebarBackground ?? this.sidebarBackground,
      headerBackground: headerBackground ?? this.headerBackground,
      paneBackground: paneBackground ?? this.paneBackground,
      inspectorBackground: inspectorBackground ?? this.inspectorBackground,
      separator: separator ?? this.separator,
      hoverFill: hoverFill ?? this.hoverFill,
      capsuleFill: capsuleFill ?? this.capsuleFill,
      selectionFill: selectionFill ?? this.selectionFill,
      onSelection: onSelection ?? this.onSelection,
      inactiveSelectionFill:
          inactiveSelectionFill ?? this.inactiveSelectionFill,
      activePaneIndicator: activePaneIndicator ?? this.activePaneIndicator,
      secondaryText: secondaryText ?? this.secondaryText,
      statusConnected: statusConnected ?? this.statusConnected,
      statusConnecting: statusConnecting ?? this.statusConnecting,
      statusFailed: statusFailed ?? this.statusFailed,
      statusUnknown: statusUnknown ?? this.statusUnknown,
      headerHeight: headerHeight ?? this.headerHeight,
      rowExtent: rowExtent ?? this.rowExtent,
      sidebarRowExtent: sidebarRowExtent ?? this.sidebarRowExtent,
      cornerScale: cornerScale ?? this.cornerScale,
    );
  }

  /// Everything blends, metrics included: they differ by platform rather
  /// than brightness, so a light/dark switch never moves them, and a
  /// platform switch that does fades them with the rest rather than
  /// snapping half-way. Corners blend like Material's own shapes, which are
  /// lerped through the same animation.
  @override
  GhostChrome lerp(GhostChrome? other, double t) {
    if (other == null) return this;
    return GhostChrome(
      sidebarBackground: Color.lerp(
        sidebarBackground,
        other.sidebarBackground,
        t,
      )!,
      headerBackground: Color.lerp(
        headerBackground,
        other.headerBackground,
        t,
      )!,
      paneBackground: Color.lerp(paneBackground, other.paneBackground, t)!,
      inspectorBackground: Color.lerp(
        inspectorBackground,
        other.inspectorBackground,
        t,
      )!,
      separator: Color.lerp(separator, other.separator, t)!,
      hoverFill: Color.lerp(hoverFill, other.hoverFill, t)!,
      capsuleFill: Color.lerp(capsuleFill, other.capsuleFill, t)!,
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
      statusConnected: Color.lerp(statusConnected, other.statusConnected, t)!,
      statusConnecting: Color.lerp(
        statusConnecting,
        other.statusConnecting,
        t,
      )!,
      statusFailed: Color.lerp(statusFailed, other.statusFailed, t)!,
      statusUnknown: Color.lerp(statusUnknown, other.statusUnknown, t)!,
      headerHeight: lerpDouble(headerHeight, other.headerHeight, t)!,
      rowExtent: lerpDouble(rowExtent, other.rowExtent, t)!,
      sidebarRowExtent: lerpDouble(
        sidebarRowExtent,
        other.sidebarRowExtent,
        t,
      )!,
      cornerScale: lerpDouble(cornerScale, other.cornerScale, t)!,
    );
  }
}

/// The chrome the style's tables and [status] paint on [platform].
GhostChrome _chromeOver(
  GhostThemeNeutrals n,
  ({Color online, Color offline, Color connecting, Color unknown}) status,
  TargetPlatform platform, {
  required double cornerScale,
}) {
  final desktop = isGhostDesktopPlatform(platform);
  return GhostChrome(
    sidebarBackground: n.containerLow,
    headerBackground: n.container,
    paneBackground: n.surface,
    inspectorBackground: n.containerLow,
    separator: n.outlineVariant,
    hoverFill: n.onSurface.withValues(alpha: 0.06),
    capsuleFill: n.containerHigh,
    selectionFill: n.selection,
    onSelection: n.onSelection,
    inactiveSelectionFill: n.containerHighest,
    activePaneIndicator: n.primary,
    secondaryText: n.onSurfaceVariant,
    statusConnected: status.online,
    statusConnecting: status.connecting,
    statusFailed: status.offline,
    statusUnknown: status.unknown,
    headerHeight: platform == TargetPlatform.macOS ? 52 : (desktop ? 44 : 56),
    rowExtent: desktop ? 22 : 48,
    sidebarRowExtent: desktop ? 26 : 40,
    cornerScale: cornerScale,
  );
}

/// The chrome [palette] paints on [platform] when its Automatic colours
/// follow [brightness].
GhostChrome _chromeFor(
  GhostThemeStyle style,
  ThemePalette palette,
  Brightness brightness,
  TargetPlatform platform,
) {
  final n = _neutralsFor(style, palette, _drawnAt(palette, brightness));
  return _chromeOver(
    n,
    _statusFor(palette, n),
    platform,
    cornerScale: palette.cornerScale,
  );
}

/// Desktop type ramp (13 px body, 11 px captions — the macOS system sizes);
/// touch platforms keep Material's defaults.
TextTheme _desktopText(TextTheme base) => base.copyWith(
  titleLarge: base.titleLarge?.copyWith(
    fontSize: 17,
    fontWeight: FontWeight.w600,
  ),
  titleMedium: base.titleMedium?.copyWith(
    fontSize: 14,
    fontWeight: FontWeight.w600,
  ),
  titleSmall: base.titleSmall?.copyWith(
    fontSize: 13,
    fontWeight: FontWeight.w600,
  ),
  bodyLarge: base.bodyLarge?.copyWith(fontSize: 14),
  bodyMedium: base.bodyMedium?.copyWith(fontSize: 13),
  bodySmall: base.bodySmall?.copyWith(fontSize: 12),
  labelLarge: base.labelLarge?.copyWith(fontSize: 13),
  labelMedium: base.labelMedium?.copyWith(fontSize: 12),
  labelSmall: base.labelSmall?.copyWith(fontSize: 11, letterSpacing: 0.2),
);

/// A host's theme, built from its [GhostThemeStyle] and a [ThemePalette].
///
/// This is Séance's `SeanceTheme`, moved general: the neutrals tables, the
/// selection and status helpers, the desktop type ramp and the component
/// tweaks are the style's, so a second host binds its own values rather
/// than porting the builder.
abstract final class GhostTheme {
  /// The style's brand-preset themes, the Automatic palette at each
  /// brightness. [platform] overrides the host platform the type ramp and
  /// row extents are chosen for — tests and captures render the desktop
  /// rail and the phone home from one host.
  static ThemeData light(GhostThemeStyle style, {TargetPlatform? platform}) =>
      build(
        style,
        GhostThemePresets(style).brand,
        Brightness.light,
        platform: platform,
      );
  static ThemeData dark(GhostThemeStyle style, {TargetPlatform? platform}) =>
      build(
        style,
        GhostThemePresets(style).brand,
        Brightness.dark,
        platform: platform,
      );

  /// The three theme arguments of a MaterialApp drawn in [appearance].
  ///
  /// A palette with its own surface is one theme, at that surface's
  /// brightness, whatever the system or the mode says; otherwise a light
  /// and a dark one, picked between by the mode.
  static ({ThemeData theme, ThemeData darkTheme, ThemeMode themeMode})
  forAppearance(
    GhostThemeStyle style,
    AppAppearance appearance, {
    TargetPlatform? platform,
  }) {
    final palette = appearance.palette;
    if (palette.surface != null) {
      final theme = build(style, palette, Brightness.light, platform: platform);
      return (theme: theme, darkTheme: theme, themeMode: ThemeMode.light);
    }
    return (
      theme: build(style, palette, Brightness.light, platform: platform),
      darkTheme: build(style, palette, Brightness.dark, platform: platform),
      themeMode: switch (appearance.mode) {
        ThemeModePreference.system => ThemeMode.system,
        ThemeModePreference.light => ThemeMode.light,
        ThemeModePreference.dark => ThemeMode.dark,
      },
    );
  }

  /// What every slot of [palette] draws as when its Automatic colours
  /// follow [brightness] — the colour an Automatic slot stands for right
  /// now, which is where the Appearance tab starts a slot that stops being
  /// Automatic, and what a preset's swatch shows.
  static Map<ThemeSlot, Color> resolvedSlots(
    GhostThemeStyle style,
    ThemePalette palette,
    Brightness brightness,
  ) {
    final drawnAt = _drawnAt(palette, brightness);
    final n = _neutralsFor(style, palette, drawnAt);
    final status = _statusFor(palette, n);
    return {
      ThemeSlot.surface: n.surface,
      ThemeSlot.sidebar: n.containerLow,
      ThemeSlot.raised: n.container,
      ThemeSlot.text: n.onSurface,
      ThemeSlot.secondaryText: n.onSurfaceVariant,
      ThemeSlot.hairline: n.outlineVariant,
      ThemeSlot.selection: n.selection,
      ThemeSlot.online: status.online,
      ThemeSlot.offline: status.offline,
      ThemeSlot.connecting: status.connecting,
      ThemeSlot.unknown: status.unknown,
    };
  }

  /// [palette] as a theme. [brightness] is what its Automatic colours
  /// follow — the system's, or the mode's; a palette that sets its own
  /// surface is drawn at that surface's brightness instead (see
  /// [resolveBrightness]).
  static ThemeData build(
    GhostThemeStyle style,
    ThemePalette palette,
    Brightness brightness, {
    TargetPlatform? platform,
  }) {
    final drawnAt = _drawnAt(palette, brightness);
    final n = _neutralsFor(style, palette, drawnAt);
    final ownSurface = palette.surface != null;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: drawnAt,
        ).copyWith(
          surface: n.surface,
          surfaceContainerLowest: n.containerLowest,
          surfaceContainerLow: n.containerLow,
          surfaceContainer: n.container,
          surfaceContainerHigh: n.containerHigh,
          surfaceContainerHighest: n.containerHighest,
          // The seed's own dim and bright stay with the tables, as they
          // always have; a surface of its own takes its ladder's ends.
          surfaceDim: ownSurface
              ? (drawnAt == Brightness.dark ? n.surface : n.containerHighest)
              : null,
          surfaceBright: ownSurface
              ? (drawnAt == Brightness.dark ? n.containerHighest : n.surface)
              : null,
          onSurface: n.onSurface,
          onSurfaceVariant: n.onSurfaceVariant,
          outline: n.outline,
          outlineVariant: n.outlineVariant,
          inverseSurface: n.inverseSurface,
          onInverseSurface: n.onInverseSurface,
          primary: n.primary,
          onPrimary: n.onPrimary,
          primaryContainer: n.primaryContainer,
          onPrimaryContainer: n.onPrimaryContainer,
          secondaryContainer: n.secondaryContainer,
          onSecondaryContainer: n.onSecondaryContainer,
          // Null leaves the seed's error family (Séance); set pins it
          // (Poltergeist).
          error: n.error,
          errorContainer: n.errorContainer,
          onErrorContainer: n.onErrorContainer,
        );
    final resolvedPlatform = platform ?? defaultTargetPlatform;
    final desktop = isGhostDesktopPlatform(resolvedPlatform);
    final base = ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      platform: platform,
      // Null leaves the platform's own face, as before themes existed.
      fontFamily: palette.fontFamily,
    );
    final scale = palette.cornerScale;
    RoundedRectangleBorder rounded(double radius) => RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius * scale),
    );
    // At the designed scale every component keeps Material's own shape
    // (its stadium buttons included), so the default theme is exactly what
    // it was before corners could change. Any other scale replaces each
    // with a rounded rectangle of its scaled radius.
    final scaled = scale != 1;
    final buttonShape = rounded(_buttonRadius);
    final chrome = _chromeOver(
      n,
      _statusFor(palette, n),
      resolvedPlatform,
      cornerScale: scale,
    );
    final theme = base.copyWith(
      visualDensity: style.visualDensity,
      scaffoldBackgroundColor: scheme.surface,
      dividerColor: scheme.outlineVariant,
      focusColor: style.focusColorOpacity == null
          ? null
          : scheme.primary.withValues(alpha: style.focusColorOpacity!),
      hoverColor: n.onSurface.withValues(alpha: 0.06),
      textTheme: desktop ? _desktopText(base.textTheme) : base.textTheme,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      // The sibling apps' menus (the sidebar kit's context menus): 8 px
      // corners like every other surface. On desktop GhostMenuTheme.apply
      // below overlays the shared compact skin (26 px rows, 13 px type)
      // rather than touch-height items in a pointer menu.
      menuTheme: MenuThemeData(
        style: MenuStyle(shape: WidgetStatePropertyAll(rounded(_menuRadius))),
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        textStyle: style.tooltipUsesInterfaceFont
            ? TextStyle(
                // A tooltip's style replaces the text theme's rather than
                // merging with it, so the interface font is named here too.
                fontFamily: palette.fontFamily,
                fontSize: desktop ? 12 : 14,
                color: scheme.onInverseSurface,
              )
            : null,
        decoration: BoxDecoration(
          color: scheme.inverseSurface,
          borderRadius: BorderRadius.circular(_tooltipRadius * scale),
        ),
      ),
      // At the designed scale a host that shapes its dialog only for other
      // scales leaves Material's shape; one that always shapes it (its
      // dialog is not Material's) sets [GhostThemeStyle.scalesDialogAlways].
      dialogTheme: (scaled || style.scalesDialogAlways)
          ? DialogThemeData(
              shape: rounded(style.dialogRadius),
              titleTextStyle: style.dialogTitleOnDesktop && desktop
                  ? _desktopText(
                      base.textTheme,
                    ).titleLarge?.copyWith(color: scheme.onSurface)
                  : null,
            )
          : null,
      cardTheme: scaled ? CardThemeData(shape: rounded(_cardRadius)) : null,
      popupMenuTheme: scaled
          ? PopupMenuThemeData(shape: rounded(_popupMenuRadius))
          : null,
      // The underline Material draws by default, with its filled corners
      // scaled: an outline here would restyle every field in the app.
      inputDecorationTheme: scaled
          ? InputDecorationThemeData(
              border: UnderlineInputBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(_inputRadius * scale),
                ),
              ),
            )
          : null,
      filledButtonTheme: scaled
          ? FilledButtonThemeData(
              style: FilledButton.styleFrom(shape: buttonShape),
            )
          : null,
      floatingActionButtonTheme: scaled && style.fabRadius != null
          ? FloatingActionButtonThemeData(shape: rounded(style.fabRadius!))
          : null,
      outlinedButtonTheme: scaled
          ? OutlinedButtonThemeData(
              style: OutlinedButton.styleFrom(shape: buttonShape),
            )
          : null,
      textButtonTheme: scaled
          ? TextButtonThemeData(style: TextButton.styleFrom(shape: buttonShape))
          : null,
      segmentedButtonTheme: scaled
          ? SegmentedButtonThemeData(
              style: ButtonStyle(shape: WidgetStatePropertyAll(buttonShape)),
            )
          : null,
      chipTheme: scaled ? ChipThemeData(shape: rounded(_chipRadius)) : null,
      bottomSheetTheme: scaled
          ? BottomSheetThemeData(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.vertical(
                  top: Radius.circular(_bottomSheetRadius * scale),
                ),
              ),
            )
          : null,
      snackBarTheme: scaled
          ? SnackBarThemeData(shape: rounded(_snackBarRadius))
          : null,
      extensions: [
        chrome,
        FamilyPalette.forBrightness(drawnAt),
        SidebarThemeTokens(
          sidebarBackground: chrome.sidebarBackground,
          separator: chrome.separator,
          hoverFill: chrome.hoverFill,
          capsuleFill: chrome.capsuleFill,
          inactiveSelectionFill: chrome.inactiveSelectionFill,
          secondaryText: chrome.secondaryText,
          sidebarRowExtent: chrome.sidebarRowExtent,
          cornerScale: chrome.cornerScale,
        ),
        GhostFileTheme(
          paneBackground: chrome.paneBackground,
          separator: chrome.separator,
          hoverFill: chrome.hoverFill,
          selectionFill: chrome.selectionFill,
          onSelection: chrome.onSelection,
          inactiveSelectionFill: chrome.inactiveSelectionFill,
          activePaneIndicator: chrome.activePaneIndicator,
          secondaryText: chrome.secondaryText,
          rowExtent: chrome.rowExtent,
        ),
      ],
    );
    // The compact pointer-menu skin shared through ghost_ui: it rewrites
    // the menu, menuButton and popupMenu themes on desktop and returns the
    // theme untouched on touch platforms.
    return GhostMenuTheme.apply(theme, cornerScale: scale);
  }
}
