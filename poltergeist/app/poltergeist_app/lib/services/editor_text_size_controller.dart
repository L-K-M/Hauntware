import 'package:planchette_editor/planchette_editor.dart' show EditorTextSize;

import 'persisted_value_controller.dart';
import 'settings_models.dart';

/// The built-in editor's text size in the app's isolate: what every editor
/// window and route draws in, and the model Settings → Appearance and
/// View › Zoom write through.
///
/// The slider writes through as it moves, so a change shows before it is
/// saved ([PersistedValueController]).
final class EditorTextSizeController extends PersistedValueController<int>
    implements EditorTextSizeModel {
  EditorTextSizeController({
    int initial = EditorTextSize.standard,
    Future<void> Function(int size)? save,
  }) : super(EditorTextSize.clamp(initial), save);

  @override
  Future<void> setTextSize(int size) => write(EditorTextSize.clamp(size));
}
