import 'package:flutter/foundation.dart';

/// Whether the Docker tab still shows SAF-08's root-equivalence notice
/// on this device (03 §8.4, M3's M12): until the user dismisses it once.
/// The composition root restores it from `settings.json` and saves the
/// dismissal there; without a save callback, as in most tests, it is
/// held in memory only. Like the coverage card's, it outlives an engine
/// run.
final class DockerNoticeController extends ChangeNotifier {
  DockerNoticeController({this._dismissed = false, this._saveDismissal});

  bool _dismissed;
  final Future<void> Function()? _saveDismissal;

  bool get showsNotice => !_dismissed;

  /// Hides the notice, at once, and saves that it was dismissed. A save
  /// that fails rethrows, and the notice stays hidden until the app
  /// restarts, so the caller can say it was not kept. A no-op once
  /// dismissed.
  Future<void> dismiss() async {
    if (_dismissed) return;
    _dismissed = true;
    notifyListeners();
    await _saveDismissal?.call();
  }
}
