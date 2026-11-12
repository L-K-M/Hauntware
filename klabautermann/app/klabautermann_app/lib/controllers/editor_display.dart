import 'package:flutter/foundation.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show EditorLigatures, EditorTextSize;

import 'persisted_setting.dart';

/// The file editors' font on this device: a family as Settings →
/// Appearance stores it (empty for the editor's default), whether its
/// ligatures draw, and the text size in logical pixels. Device-local like
/// the log display, never synced.
@immutable
final class EditorDisplay {
  /// [textSize] is clamped to [EditorTextSize.minimum]..
  /// [EditorTextSize.maximum].
  EditorDisplay({
    this.family = '',
    this.ligatures = EditorLigatures.on,
    int textSize = EditorTextSize.standard,
  }) : textSize = EditorTextSize.clamp(textSize);

  /// A new install's display, and what a missing or damaged stored one is.
  static final EditorDisplay standard = EditorDisplay();

  final String family;
  final EditorLigatures ligatures;
  final int textSize;

  /// The family to draw in, or null for the editor's default.
  String? get chosenFamily {
    final trimmed = family.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  EditorDisplay copyWith({
    String? family,
    EditorLigatures? ligatures,
    int? textSize,
  }) => EditorDisplay(
    family: family ?? this.family,
    ligatures: ligatures ?? this.ligatures,
    textSize: textSize ?? this.textSize,
  );

  @override
  bool operator ==(Object other) =>
      other is EditorDisplay &&
      other.family == family &&
      other.ligatures == ligatures &&
      other.textSize == textSize;

  @override
  int get hashCode => Object.hash(family, ligatures, textSize);
}

/// What Settings reads and changes of the editor display, apart from where
/// it runs: [EditorDisplayController] in the app, and a copy kept over the
/// settings link in the desktop settings window.
abstract interface class EditorDisplaySettings
    implements ValueListenable<EditorDisplay> {
  /// Picks [display]; a no-op when it is in force and saved. A change
  /// applied but not saved throws [EditorDisplayNotSavedException], in the
  /// app and, over the link, in the window; any other throw means it did
  /// not apply.
  Future<void> setEditorDisplay(EditorDisplay display);
}

/// An editor display that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class EditorDisplayNotSavedException implements Exception {
  const EditorDisplayNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's editor display: the composition root restores it from
/// `settings.json` and saves every change there; without a save callback,
/// as in most tests, it is held in memory only. A change applies before it
/// is saved, as the log display does.
final class EditorDisplayController extends PersistedSetting<EditorDisplay>
    implements EditorDisplaySettings {
  EditorDisplayController({EditorDisplay? display, this._save})
    : super(display ?? EditorDisplay());

  final Future<void> Function(
    String? family,
    EditorLigatures ligatures,
    int textSize,
  )?
  _save;

  @override
  Future<void> setEditorDisplay(EditorDisplay display) => change(display);

  @override
  Future<void>? save(EditorDisplay display) =>
      _save?.call(display.chosenFamily, display.ligatures, display.textSize);

  @override
  Exception notSaved(Object error) => EditorDisplayNotSavedException(
    'The editor display was not saved: $error',
  );
}
