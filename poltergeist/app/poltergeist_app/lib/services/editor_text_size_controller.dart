import 'package:flutter/foundation.dart';
import 'package:planchette_editor/planchette_editor.dart' show EditorTextSize;

import 'settings_models.dart';

/// The built-in editor's text size in the app's isolate: what every editor
/// window and route draws in, and the model Settings → Appearance and
/// View › Zoom write through.
///
/// Applies a change before persisting it, like [AppearanceController]:
/// the slider writes through as it moves, and editors resizing only after
/// the disk caught up would make each step lag by a save. A failed write
/// keeps the size on screen and throws; the next write carries it.
final class EditorTextSizeController extends ChangeNotifier
    implements EditorTextSizeModel {
  EditorTextSizeController({int initial = EditorTextSize.standard, this._save})
    : _value = EditorTextSize.clamp(initial);

  int _value;
  final Future<void> Function(int size)? _save;

  @override
  int get value => _value;

  @override
  Future<void> setTextSize(int size) async {
    final next = EditorTextSize.clamp(size);
    if (next == _value) return;
    _value = next;
    notifyListeners();
    await _save?.call(next);
  }
}
