import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// Whether host keys the user confirms are shared with the account's other
/// devices (D15, FL-22, M5 plan M07): [release] is the Séance release the
/// assertion names, null while none is offered, and [asserted] whether this
/// device holds the assertion for it.
@immutable
final class PinPublication {
  const PinPublication({this.release, this.asserted = false});

  final String? release;
  final bool asserted;

  @override
  bool operator ==(Object other) =>
      other is PinPublication &&
      other.release == release &&
      other.asserted == asserted;

  @override
  int get hashCode => Object.hash(release, asserted);
}

/// What Settings reads and changes of the pin publication assertion, apart
/// from where it runs: [PinPublicationController] in the app, and a copy
/// kept over the settings link in the desktop settings window.
abstract interface class PinPublicationSettings
    implements ValueListenable<PinPublication> {
  /// Asserts the offered release, or withdraws the assertion; a no-op when
  /// [asserted] is already in force. Throws when the change did not take,
  /// and while no release is offered.
  Future<void> setAsserted(bool asserted);
}

/// An assertion change the engine refused or did not keep.
final class PinPublicationNotChangedException implements Exception {
  const PinPublicationNotChangedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The engine's pin publication state, from [initial]
/// ([EngineReady.pinPublication]) and [PinPublicationState] events, and the
/// requests that change it. The engine stores the assertion in its
/// enrollment file, so this holds nothing of its own; it offers nothing
/// until the engine names a release.
final class PinPublicationController extends ChangeNotifier
    implements PinPublicationSettings {
  PinPublicationController(this._engine, {PinPublicationState? initial})
    : _value = PinPublication(
        release: initial?.release,
        asserted: initial?.asserted ?? false,
      ) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  PinPublication _value;

  /// Requests answered in order by the engine's next state or refusal.
  final List<Completer<void>> _pending = [];

  @override
  PinPublication get value => _value;

  @override
  Future<void> setAsserted(bool asserted) async {
    if (_value.release == null) {
      throw const PinPublicationNotChangedException(
        'No release is offered for pin publication',
      );
    }
    if (asserted == _value.asserted) return;
    final answered = Completer<void>();
    _pending.add(answered);
    try {
      _engine.send(SetPinPublication(asserted: asserted));
    } on StateError {
      _pending.remove(answered);
      throw const PinPublicationNotChangedException('The engine stopped');
    }
    await answered.future;
    if (_value.asserted != asserted) {
      throw const PinPublicationNotChangedException(
        'The pin publication assertion was not saved',
      );
    }
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case PinPublicationState(:final release, :final asserted):
        final value = PinPublication(release: release, asserted: asserted);
        if (value != _value) {
          _value = value;
          notifyListeners();
        }
        if (_pending.isNotEmpty) _pending.removeAt(0).complete();
      case RequestRejected(:final requestName, :final reason)
          when requestName == 'SetPinPublication':
        if (_pending.isNotEmpty) {
          _pending
              .removeAt(0)
              .completeError(PinPublicationNotChangedException(reason));
        }
      case _:
    }
  }

  void _onEngineDone() {
    for (final answered in _pending) {
      answered.completeError(
        const PinPublicationNotChangedException('The engine stopped'),
      );
    }
    _pending.clear();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
    super.dispose();
  }
}
