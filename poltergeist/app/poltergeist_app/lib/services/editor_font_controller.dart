import 'package:flutter/foundation.dart';

import 'editor_font.dart';
import 'settings_models.dart';

/// The built-in editor's font in the app's isolate: what every editor
/// window, route and compare view draws in, and the model Settings →
/// Appearance writes through.
///
/// Applies a change before persisting it, like [EditorTextSizeController]:
/// editors redraw at once, and a failed write keeps the font on screen and
/// throws; the next write carries it.
final class EditorFontController extends ChangeNotifier
    implements EditorFontModel {
  EditorFontController({EditorFont initial = EditorFont.standard, this._save})
    : _value = initial;

  EditorFont _value;
  final Future<void> Function(EditorFont font)? _save;

  @override
  EditorFont get value => _value;

  @override
  Future<void> setFont(EditorFont font) async {
    if (font == _value) return;
    _value = font;
    notifyListeners();
    await _save?.call(font);
  }
}
