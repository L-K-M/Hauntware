import 'editor_font.dart';
import 'persisted_value_controller.dart';
import 'settings_models.dart';

/// The built-in editor's font in the app's isolate: what every editor
/// window, route and compare view draws in, and the model Settings →
/// Appearance writes through.
/// Editors redraw at once ([PersistedValueController]).
final class EditorFontController extends PersistedValueController<EditorFont>
    implements EditorFontModel {
  EditorFontController({
    EditorFont initial = EditorFont.standard,
    Future<void> Function(EditorFont font)? save,
  }) : super(initial, save);

  @override
  Future<void> setFont(EditorFont font) => write(font);
}
