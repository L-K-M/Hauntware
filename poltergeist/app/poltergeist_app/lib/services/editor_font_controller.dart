import 'package:ghost_ui/ghost_ui.dart' show PersistedSetting;

import 'editor_font.dart';
import 'settings_models.dart';

/// The built-in editor's font in the app's isolate: what every editor
/// window, route and compare view draws in, and the model Settings →
/// Appearance writes through.
/// Editors redraw at once ([PersistedSetting]).
final class EditorFontController extends PersistedSetting<EditorFont>
    implements EditorFontModel {
  EditorFontController({
    EditorFont initial = EditorFont.standard,
    Future<void> Function(EditorFont font)? save,
  }) : _persist = save,
       super(initial);

  final Future<void> Function(EditorFont font)? _persist;

  @override
  Future<void>? save(EditorFont value) => _persist?.call(value);

  @override
  Future<void> setFont(EditorFont font) => change(font);
}
