import 'package:flutter/foundation.dart';

import 'persisted_setting.dart';

/// Which zone the app shows a server's times in (A11Y-07).
enum TimeDisplay {
  /// This device's zone, as the system clock shows it.
  device,

  /// The server's zone, as its probe last read it (03 §5.2): a fixed
  /// offset, so a time across a daylight-saving change from that reading
  /// shows the offset of the reading's side. Until a server's zone is
  /// read, its times show in the device's zone.
  server,
}

/// What Settings reads and changes of the time display, apart from where
/// it runs: [TimeDisplayController] in the app, and a copy kept over the
/// settings link in the desktop settings window.
abstract interface class TimeDisplaySettings
    implements ValueListenable<TimeDisplay> {
  /// Picks [display]; a no-op when it is in force and saved. A change
  /// applied but not saved throws [TimeDisplayNotSavedException], in the
  /// app and, over the link, in the window; any other throw means it did
  /// not apply.
  Future<void> setTimeDisplay(TimeDisplay display);
}

/// A time display that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class TimeDisplayNotSavedException implements Exception {
  const TimeDisplayNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's time display (A11Y-07): the composition root restores it
/// from `settings.json` and saves every change there; without a save
/// callback, as in most tests, it is held in memory only. A change applies
/// before it is saved, as the log display does.
final class TimeDisplayController extends PersistedSetting<TimeDisplay>
    implements TimeDisplaySettings {
  TimeDisplayController({TimeDisplay display = TimeDisplay.device, this._save})
    : super(display);

  final Future<void> Function(bool serverTimes)? _save;

  /// The last change's apply and save: a change waits for the one before
  /// it, so overlapping saves land in order and the file ends with the
  /// last one.
  Future<void> _changes = Future<void>.value();

  @override
  Future<void> setTimeDisplay(TimeDisplay display) {
    final queued = _changes.then((_) => change(display));
    // A failed save leaves the queue running; its caller sees the error.
    _changes = queued.then<void>((_) {}, onError: (Object _) {});
    return queued;
  }

  @override
  Future<void>? save(TimeDisplay display) =>
      _save?.call(display == TimeDisplay.server);

  @override
  Exception notSaved(Object error) =>
      TimeDisplayNotSavedException('The time display was not saved: $error');
}
