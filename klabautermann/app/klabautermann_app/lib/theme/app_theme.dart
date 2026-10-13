import 'package:flutter/material.dart';
import 'package:ghost_ui/ghost_ui.dart';

/// The M1a minimal theme (04 M1's allowed path until `ghost_theme` lands
/// with F4b): Material defaults plus the shared `ghost_ui` theme
/// extensions, so the sidebar kit reads the same tokens the siblings hand
/// it (03 §10.2, §10.9).
ThemeData klabautermannTheme(Brightness brightness, TargetPlatform platform) {
  final base = brightness == Brightness.dark
      ? ThemeData.dark(useMaterial3: true)
      : ThemeData.light(useMaterial3: true);
  return base.copyWith(
    extensions: <ThemeExtension<dynamic>>[
      SidebarThemeTokens.fallback(brightness, platform),
      FamilyPalette.forBrightness(brightness),
      KlabautermannStatusColors.forBrightness(brightness),
    ],
  );
}

/// The four status colours behind the fleet's shared dot vocabulary
/// (03 §10.3). Colour is never the only carrier: a row folds its state
/// word into its semantics label, and the `HealthMark` overlay lands with
/// the fleet view's real rows.
@immutable
final class KlabautermannStatusColors
    extends ThemeExtension<KlabautermannStatusColors> {
  const KlabautermannStatusColors({
    required this.connected,
    required this.connecting,
    required this.failed,
    required this.unknown,
  });

  /// The sibling tables' light values; the dark row keeps the same hues
  /// lightened for a dark surface (03 §10.9's MVP palette).
  factory KlabautermannStatusColors.forBrightness(Brightness brightness) {
    return brightness == Brightness.dark
        ? const KlabautermannStatusColors(
            connected: Color(0xFF7FC98B),
            connecting: Color(0xFFD9A74A),
            failed: Color(0xFFF28B82),
            unknown: Color(0xFF9AA0A6),
          )
        : const KlabautermannStatusColors(
            connected: Color(0xFF2F7A3A),
            connecting: Color(0xFF915C00),
            failed: Color(0xFFB3261E),
            unknown: Color(0xFF6E665A),
          );
  }

  /// A live link or a probe-confirmed host (solid / ring per row).
  final Color connected;

  /// A link still opening.
  final Color connecting;

  /// A link failure; `blocked` draws the same colour in the kit's
  /// barred-dot style (03 §10.3).
  final Color failed;

  /// Nothing observed yet.
  final Color unknown;

  static KlabautermannStatusColors of(BuildContext context) {
    final theme = Theme.of(context);
    return theme.extension<KlabautermannStatusColors>() ??
        KlabautermannStatusColors.forBrightness(theme.brightness);
  }

  @override
  KlabautermannStatusColors copyWith({
    Color? connected,
    Color? connecting,
    Color? failed,
    Color? unknown,
  }) {
    return KlabautermannStatusColors(
      connected: connected ?? this.connected,
      connecting: connecting ?? this.connecting,
      failed: failed ?? this.failed,
      unknown: unknown ?? this.unknown,
    );
  }

  @override
  KlabautermannStatusColors lerp(KlabautermannStatusColors? other, double t) {
    if (other == null) return this;
    return KlabautermannStatusColors(
      connected: Color.lerp(connected, other.connected, t)!,
      connecting: Color.lerp(connecting, other.connecting, t)!,
      failed: Color.lerp(failed, other.failed, t)!,
      unknown: Color.lerp(unknown, other.unknown, t)!,
    );
  }
}
