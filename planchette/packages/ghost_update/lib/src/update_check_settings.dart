import 'package:flutter/foundation.dart';

/// What a host's Settings reads and changes of the update check
/// (Poltergeist 00 D19/D23, 07 §3.10, 01 §6): [UpdateCheckController]
/// implements it, and a host's settings window keeps a copy over its link.
/// [enabled] is whether the launch check may run.
abstract interface class UpdateCheckSettings implements Listenable {
  /// Whether the launch check may run; on unless the user turned it off.
  bool get enabled;

  /// Turns the switch on or off; a no-op when [enabled] is already in
  /// force. A change that did not apply throws.
  Future<void> setEnabled(bool enabled);
}
