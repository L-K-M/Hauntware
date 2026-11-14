import 'package:flutter/foundation.dart';

/// One app-wide preference in the app's isolate: the value everything
/// draws from, and what its Settings section writes through.
///
/// Applies a change before persisting it: lists re-sort, editors redraw
/// and the theme repaints at once, and a section that writes on every
/// slider step or corner drag must not lag by a save each time. A failed
/// write keeps the change on screen and throws, so the section can say it
/// was not saved; the next write carries it.
abstract base class PersistedValueController<T> extends ChangeNotifier
    implements ValueListenable<T> {
  PersistedValueController(this._value, this._save);

  T _value;
  final Future<void> Function(T value)? _save;

  @override
  T get value => _value;

  /// Shows [next] and saves it; an unchanged value neither notifies nor
  /// writes.
  @protected
  Future<void> write(T next) async {
    if (next == _value) return;
    _value = next;
    notifyListeners();
    await _save?.call(next);
  }
}
