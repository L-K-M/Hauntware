import 'package:flutter/foundation.dart';
import 'package:planchette_editor/planchette_editor.dart' show EditorLigatures;

/// The built-in editor's font on this device: a family as Settings →
/// Appearance stores it ('Fira Code', or empty for the editor's default)
/// and whether its ligatures draw. Device-local like the text size, never
/// synced.
@immutable
final class EditorFont {
  const EditorFont({this.family = '', this.ligatures = EditorLigatures.on});

  /// A new install's font, and what a missing or damaged stored one is.
  static const standard = EditorFont();

  final String family;
  final EditorLigatures ligatures;

  /// The family to draw in, or null for the editor's default.
  String? get chosenFamily {
    final trimmed = family.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  EditorFont copyWith({String? family, EditorLigatures? ligatures}) =>
      EditorFont(
        family: family ?? this.family,
        ligatures: ligatures ?? this.ligatures,
      );

  @override
  bool operator ==(Object other) =>
      other is EditorFont &&
      other.family == family &&
      other.ligatures == ligatures;

  @override
  int get hashCode => Object.hash(family, ligatures);
}
