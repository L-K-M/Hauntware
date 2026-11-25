import 'package:ghost_ui/ghost_ui.dart' show PersistedSetting;
import 'package:planchette_editor/planchette_editor.dart' show EditorTextSize;

import 'settings_models.dart';

/// The built-in editor's text size in the app's isolate: what every editor
/// window and route draws in, and the model Settings → Appearance and
/// View › Zoom write through.
///
/// The slider writes through as it moves, so a change shows before it is
/// saved ([PersistedSetting]).
final class EditorTextSizeController extends PersistedSetting<int>
    implements EditorTextSizeModel {
  EditorTextSizeController({
    int initial = EditorTextSize.standard,
    Future<void> Function(int size)? save,
  }) : _persist = save,
       super(EditorTextSize.clamp(initial));

  final Future<void> Function(int size)? _persist;

  @override
  Future<void>? save(int value) => _persist?.call(value);

  @override
  Future<void> setTextSize(int size) => change(EditorTextSize.clamp(size));
}
