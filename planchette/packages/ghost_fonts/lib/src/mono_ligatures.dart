import 'dart:ui' show FontFeature;

import 'bundled_mono_font.dart';

/// Shared by previews, editors and terminals. Off also disables the
/// font-specific stylistic sets used for programming ligatures.
enum MonoLigatures {
  off,
  on;

  /// Features for the stored or package-qualified [family]. Unrelated
  /// stylistic alternates are left alone.
  List<FontFeature> featuresFor(String? family) {
    final font = BundledMonoFont.named(family?.split('/').last ?? '');
    final sets = switch (font) {
      BundledMonoFont.monaspaceNeon ||
      BundledMonoFont.monaspaceArgon ||
      BundledMonoFont.monaspaceXenon ||
      BundledMonoFont.monaspaceRadon ||
      BundledMonoFont.monaspaceKrypton => _monaspaceLigatures,
      BundledMonoFont.geistMono => const ['ss11'],
      BundledMonoFont.intelOneMono => const ['ss01'],
      BundledMonoFont.commitMono => const ['ss01', 'ss02'],
      _ => const <String>[],
    };
    return [
      // Shaping already enables calt/liga. Only opt-in sets need adding;
      // off explicitly overrides both defaults and those sets.
      for (final tag in [
        if (this == off) ...['calt', 'liga'],
        ...sets,
      ])
        FontFeature(tag, this == on ? 1 : 0),
    ];
  }
}

// Monaspace 1.400 separates coding ligatures from texture healing (calt).
const _monaspaceLigatures = [
  'ss01',
  'ss02',
  'ss03',
  'ss04',
  'ss05',
  'ss06',
  'ss07',
  'ss08',
  'ss09',
  'ss10',
];
