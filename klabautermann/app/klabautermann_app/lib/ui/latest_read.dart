import 'dart:async';

import 'package:flutter/widgets.dart';

/// The newest answer of a sequence of reads.
///
/// A read started later replaces an earlier one: when an older answer
/// lands after a newer read began, or the owner is gone, it is dropped,
/// so only the newest read's answer reaches [value].
class LatestRead<T> {
  LatestRead({
    required void Function(VoidCallback) setState,
    required bool Function() mounted,
  }) {
    _setState = setState;
    _mounted = mounted;
  }

  late final void Function(VoidCallback) _setState;
  late final bool Function() _mounted;

  var _ticket = 0;
  T? _value;
  var _reading = false;

  /// The newest read's answer; null until one lands or [reset].
  T? get value => _value;

  /// Whether the newest read is out.
  bool get reading => _reading;

  /// Forgets the answer and drops any read still out.
  void reset() {
    _ticket++;
    _value = null;
    _reading = false;
  }

  /// Reads, keeping the answer only while this call is the newest and
  /// the owner is mounted. A read that throws clears [reading]; the
  /// error still reaches the caller, as it did before this existed.
  Future<void> run(Future<T> Function() read) async {
    final ticket = ++_ticket;
    if (!_reading) _setState(() => _reading = true);
    var applied = false;
    try {
      final value = await read();
      if (!_mounted() || ticket != _ticket) return;
      applied = true;
      _setState(() {
        _value = value;
        _reading = false;
      });
    } finally {
      // The newest read failed: leave no reading state behind for it.
      if (!applied && _mounted() && ticket == _ticket) {
        _setState(() => _reading = false);
      }
    }
  }
}
