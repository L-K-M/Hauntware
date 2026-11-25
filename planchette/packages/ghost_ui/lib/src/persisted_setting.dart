import 'package:flutter/foundation.dart';

/// What a [PersistedSetting] does when the value already in force is
/// written again after its save failed.
enum FailedSaves {
  /// The repeated write is a no-op: a failed save surfaces once, with the
  /// save's own error, and only a different value writes again
  /// (Poltergeist's settings).
  surfaceOnce,

  /// The setting remembers the last saved value and tries the save again;
  /// a failed save throws the setting's own [PersistedSetting.notSaved]
  /// error (Klabautermann's settings).
  retry,
}

/// A value the composition root restores from the device's settings and
/// saves there on every change. A change applies before it is saved: lists
/// re-sort, editors redraw and themes repaint at once, and a section that
/// writes on every slider step must not lag by a save each time. A failed
/// save keeps the change on screen and throws, so the section can say it
/// was not saved; the next write carries it.
///
/// [failedSaves] picks what a later write of the value already in force
/// does after a failed save; see [FailedSaves].
abstract class PersistedSetting<T> extends ChangeNotifier
    implements ValueListenable<T> {
  PersistedSetting(T value, {this.failedSaves = FailedSaves.surfaceOnce})
    : _value = value,
      _saved = value;

  T _value;

  /// The value last known to be saved: after a failed save, picking the
  /// same value again tries the save again.
  T _saved;

  /// What a repeated write does after a failed save.
  final FailedSaves failedSaves;

  @override
  T get value => _value;

  /// Saves [value]; null when there is nowhere to save it.
  @protected
  Future<void>? save(T value);

  /// The error a failed save throws under [FailedSaves.retry]; defaults
  /// to the save's own error.
  @protected
  Object notSaved(Object error) => error;

  /// Picks [next]; a no-op when it is in force and, with retries on,
  /// already saved.
  @protected
  Future<void> change(T next) async {
    if (failedSaves == FailedSaves.surfaceOnce) {
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
