import 'package:flutter/foundation.dart';

/// Saves the shown columns by name, in order:
/// `DeviceSettingsStore.setContainerColumns`.
typedef SaveContainerColumns = Future<void> Function(List<String> names);

/// The Containers tab's columns as the user chose them on this device
/// (CTR-08): the shown ones by name, in order, or null for the tab's
/// default. The composition root restores the choice from
/// `settings.json` and saves each change there; without [save], as in
/// tests, it is held in memory only. The tab reads the names against its
/// own columns, so a name it does not know is skipped.
final class ContainerColumnChoice extends ChangeNotifier {
  ContainerColumnChoice({List<String>? stored, this._save})
    : _names = stored == null ? null : List.unmodifiable(stored);

  List<String>? _names;
  final SaveContainerColumns? _save;

  /// The shown columns by name, in order; null for the default.
  List<String>? get names => _names;

  /// Makes [names] the shown columns, at once, and saves them. A save
  /// that fails rethrows, and the choice holds until the app quits, so
  /// the caller can say it was not kept.
  Future<void> setNames(List<String> names) async {
    _names = List.unmodifiable(names);
    notifyListeners();
    await _save?.call(names);
  }
}
