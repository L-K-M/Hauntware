import 'package:flutter/foundation.dart';

/// A device setting the composition root restores from `settings.json`
/// and saves there on every change. A change applies before it is saved,
/// as the appearance does, and one applied but not saved throws
/// [notSaved]'s exception and lasts until the app restarts unless a later
/// save carries it. Without a save, as in most tests, the setting is held
/// in memory only.
abstract class PersistedSetting<T> extends ChangeNotifier
    implements ValueListenable<T> {
  PersistedSetting(T value) : _value = value, _saved = value;

  T _value;

  /// The value last known to be in `settings.json`: after a failed save,
  /// picking the same value again tries the save again.
  T _saved;

  @override
  T get value => _value;

  /// Saves [value]; null when there is nowhere to save it.
  @protected
  Future<void>? save(T value);

  /// The setting's own exception for a save that failed with [error].
  @protected
  Exception notSaved(Object error);

  /// Picks [next]; a no-op when it is in force and saved.
  @protected
  Future<void> change(T next) async {
    if (next == _value && next == _saved) return;
    if (next != _value) {
      _value = next;
      notifyListeners();
    }
    try {
      await save(next);
      _saved = next;
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(notSaved(error), stackTrace);
    }
  }
}
