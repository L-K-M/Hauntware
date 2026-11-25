import 'package:ghost_ui/ghost_ui.dart' show PersistedSetting;
import 'package:poltergeist_core/poltergeist_core.dart' show DirectoryGrouping;

import 'settings_models.dart';
import 'view_preferences_store.dart';

/// Whether file lists keep folders on top, in the app's isolate: what every
/// pane sorts by and the model Settings → General writes through.
///
/// It is the global default of 02 §2.4's directories-first view option, so it
/// persists as [ViewPreferencesStore]'s default rather than as a preference of
/// its own; per-folder overrides do not exist yet.
///
/// Open lists re-sort at once ([PersistedSetting]).
final class DirectoryGroupingController
    extends PersistedSetting<DirectoryGrouping>
    implements DirectoryGroupingModel {
  DirectoryGroupingController({
    DirectoryGrouping initial = DirectoryGrouping.first,
    Future<void> Function(DirectoryGrouping grouping)? save,
  }) : _persist = save,
       super(initial);

  final Future<void> Function(DirectoryGrouping grouping)? _persist;

  @override
  Future<void>? save(DirectoryGrouping value) => _persist?.call(value);

  /// The stored default, or [DirectoryGrouping.first] when [store] cannot be
  /// read: a damaged or newer view schema must not stop the app opening.
  /// [onError] hears why.
  static Future<DirectoryGrouping> load(
    ViewPreferencesStore store, {
    required void Function(Object error, StackTrace stackTrace) onError,
  }) async {
    try {
      return (await store.loadDefaults()).directories;
    } on Object catch (error, stackTrace) {
      onError(error, stackTrace);
      return DirectoryGrouping.first;
    }
  }

  /// Writes [grouping] as [store]'s default, leaving its other options alone.
  static Future<void> Function(DirectoryGrouping grouping) saveTo(
    ViewPreferencesStore store,
  ) =>
      (grouping) => store.updateDefaults(
        (defaults) => defaults.copyWith(directories: grouping),
      );

  @override
  Future<void> setGrouping(DirectoryGrouping grouping) => change(grouping);
}
