import 'package:flutter/foundation.dart';

/// A value the composition root restores from the device's settings and
/// saves there on every change. A change applies before it is saved: lists
/// re-sort, editors redraw and themes repaint at once, and a section that
/// writes on every slider step must not lag by a save each time. A failed
/// save keeps the change on screen and throws, so the section can say it
/// was not saved; the next write carries it.
///
/// [retryFailedSaves] picks what a later write of the value already in
/// force does after a failed save. With it, the base remembers the last
/// saved value and tries the save again when the same value is picked;
/// this is Klabautermann's behaviour, where the setting's own exception
/// says what failed. Without it, a repeated write is a no-op, which is
/// Poltergeist's behaviour: a failed save surfaces once and only a
/// different value writes again. The save's own error propagates.
abstract class PersistedSetting<T> extends ChangeNotifier
    implements ValueListenable<T> {
  PersistedSetting(T value, {bool retryFailedSaves = false})
    : _value = value,
      _saved = value,
      _retriesFailedSaves = retryFailedSaves;

  T _value;

  /// The value last known to be saved: after a failed save, picking the
  /// same value again tries the save again.
  T _saved;
  final bool _retriesFailedSaves;

  @override
  T get value => _value;

  /// Saves [value]; null when there is nowhere to save it.
  @protected
  Future<void>? save(T value);

  /// The error a failed save throws when [retryFailedSaves] is on;
  /// defaults to the save's own error.
  @protected
  Object notSaved(Object error) => error;

  /// Picks [next]; a no-op when it is in force and, with retries on,
  /// already saved.
  @protected
  Future<void> change(T next) async {
    if (!_retriesFailedSaves) {
      if (next == _value) return;
      _value = next;
      notifyListeners();
      await save(next);
      _saved = next;
      return;
    }

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
