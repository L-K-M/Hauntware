import 'package:flutter/foundation.dart';

/// What Settings reads and changes of A11Y-15's switch, apart from where
/// it runs: [AnnouncementController] in the app, and a copy kept over the
/// settings link in the desktop settings window. [value] is whether
/// screen readers hear a server's values cross into or out of a warning
/// or critical band (D60).
abstract interface class AnnouncementSettings implements ValueListenable<bool> {
  /// Turns the announcements on or off; a no-op when [announce] is already
  /// in force. A change applied but not saved throws
  /// [AnnouncementNotSavedException], in the app and, over the link, in
  /// the window; any other throw means it did not apply.
  Future<void> setAnnounceThresholdBands(bool announce);
}

/// An announcement setting that applied but was not saved: it lasts until
/// the app restarts unless a later save carries it. [message] is what the
/// failed save printed.
final class AnnouncementNotSavedException implements Exception {
  const AnnouncementNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's A11Y-15 concern (03 §10.1): whether threshold-band changes
/// are announced. The composition root restores it from `settings.json`
/// and saves every change there; without a save callback, as in most
/// tests, it is held in memory only. A change applies before it is saved,
/// as the appearance does.
final class AnnouncementController extends ChangeNotifier
    implements AnnouncementSettings {
  AnnouncementController({bool announceThresholdBands = true, this._save})
    : _value = announceThresholdBands;

  bool _value;
  final Future<void> Function(bool announce)? _save;

  @override
  bool get value => _value;

  @override
  Future<void> setAnnounceThresholdBands(bool announce) async {
    if (announce == _value) return;
    _value = announce;
    notifyListeners();
    try {
      await _save?.call(announce);
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        AnnouncementNotSavedException(
          'The announcement setting was not saved: $error',
        ),
        stackTrace,
      );
    }
  }
}
