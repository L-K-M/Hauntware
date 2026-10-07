import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:poltergeist_app/services/directory_grouping_controller.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/view_preferences.dart';
import 'package:poltergeist_app/services/view_preferences_store.dart';
import 'package:poltergeist_core/poltergeist_core.dart' show DirectoryGrouping;

/// The app's side of "Keep folders on top": what every pane sorts by, and
/// what Settings → General writes through to the view defaults.
void main() {
  DirectoryGroupingController controller({
    DirectoryGrouping initial = DirectoryGrouping.first,
    Future<void> Function(DirectoryGrouping grouping)? save,
  }) {
    final created = DirectoryGroupingController(initial: initial, save: save);
    addTearDown(created.dispose);
    return created;
  }

  test('re-sorts, then saves; the same value does nothing', () async {
    final events = <String>[];
    late DirectoryGroupingController grouping;
    grouping = controller(
      save: (value) async => events.add('save ${grouping.value.name}'),
    );
    grouping.addListener(() => events.add('notify'));

    await grouping.setGrouping(DirectoryGrouping.first);
    await grouping.setGrouping(DirectoryGrouping.mixed);

    expect(events, ['notify', 'save mixed']);
  });

  test('a failed write keeps the change and throws', () async {
    final grouping = controller(
      save: (_) async => throw StateError('disk full'),
    );

    await expectLater(
      grouping.setGrouping(DirectoryGrouping.mixed),
      throwsStateError,
    );
    expect(grouping.value, DirectoryGrouping.mixed);
  });

  group('over the view defaults', () {
    late Directory temporaryDirectory;
    late SettingsStore settings;
    late ViewPreferencesStore store;

    setUp(() async {
      temporaryDirectory = await Directory.systemTemp.createTemp(
        'poltergeist_directory_grouping_test_',
      );
      settings = SettingsStore(
        path: p.join(temporaryDirectory.path, 'settings.json'),
      );
      store = ViewPreferencesStore(store: settings);
    });

    tearDown(() => temporaryDirectory.delete(recursive: true));

    test('loads folders on top when nothing is stored', () async {
      expect(
        await DirectoryGroupingController.load(store, onError: (_, _) {}),
        DirectoryGrouping.first,
      );
    });

    test('saves into the defaults, keeping their other options', () async {
      await store.saveDefaults(
        ViewPreferences(hiddenFiles: HiddenFiles.shown),
      );

      await DirectoryGroupingController.saveTo(store)(DirectoryGrouping.mixed);

      final defaults = await store.loadDefaults();
      expect(defaults.directories, DirectoryGrouping.mixed);
      expect(defaults.hiddenFiles, HiddenFiles.shown);
      expect(
        await DirectoryGroupingController.load(store, onError: (_, _) {}),
        DirectoryGrouping.mixed,
      );
    });

    test('an unreadable schema opens with folders on top and says why',
        () async {
      await settings.set('view.preferences', {'version': 99});
      final errors = <Object>[];

      final loaded = await DirectoryGroupingController.load(
        store,
        onError: (error, _) => errors.add(error),
      );

      expect(loaded, DirectoryGrouping.first);
      expect(errors.single, isA<FormatException>());
    });
  });
}
