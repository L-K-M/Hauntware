import 'dart:async';

import 'package:flutter/widgets.dart';

/// How long a revealed masked value shows before it is masked again
/// (SAF-07: a reveal is temporary).
const Duration kRevealDuration = Duration(seconds: 30);

/// The key of a view that reveals all its masked values at once.
enum RevealScope { all }

/// The masked values (03 §8.9) a view shows revealed, by [K]. Each is
/// masked again after [kRevealDuration], when the app turns inactive,
/// and when the view goes ([dispose]). Inactive precedes hidden on the
/// way to the background, while a frame can still draw the mask before
/// an app switcher's snapshot. It holds only which keys show, so a
/// revealed value lives in the view's own state, and nothing here sends,
/// stores or logs it (SAF-07).
///
/// Create it in `initState`, where the lifecycle listener can start.
final class TimedReveals<K> {
  /// [onChanged] runs after every reveal or mask this makes, so the view
  /// can redraw; [discard] alone does not call it.
  TimedReveals({required this._onChanged}) {
    _lifecycle = AppLifecycleListener(onInactive: maskAll);
  }

  final VoidCallback _onChanged;
  late final AppLifecycleListener _lifecycle;

  /// The revealed keys, each with the timer that masks it.
  final Map<K, Timer> _revealed = {};

  bool get isEmpty => _revealed.isEmpty;

  bool isRevealed(K key) => _revealed.containsKey(key);

  /// Masks [key] when it shows, or reveals it for [kRevealDuration].
  void toggle(K key) {
    final timer = _revealed.remove(key);
    if (timer != null) {
      timer.cancel();
    } else {
      _revealed[key] = Timer(kRevealDuration, () {
        _revealed.remove(key);
        _onChanged();
      });
    }
    _onChanged();
  }

  /// Masks everything revealed.
  void maskAll() {
    if (_revealed.isEmpty) return;

    discard();
    _onChanged();
  }

  /// Masks the keys [where] picks, or all, without calling `onChanged`:
  /// for a view that redraws anyway, such as one starting a new read.
  void discard({bool Function(K key)? where}) {
    _revealed.removeWhere((key, timer) {
      if (where != null && !where(key)) return false;
      timer.cancel();
      return true;
    });
  }

  void dispose() {
    _lifecycle.dispose();
    for (final timer in _revealed.values) {
      timer.cancel();
    }
    _revealed.clear();
  }
}
