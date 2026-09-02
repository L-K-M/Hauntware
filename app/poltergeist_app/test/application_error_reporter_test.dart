import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/app_preferences.dart';
import 'package:poltergeist_app/services/application_error_reporter.dart';
import 'package:poltergeist_app/services/settings_store.dart';

import 'support/memory_settings_file_system.dart';

void main() {
  test('reports an observed pane-ratio write failure once', () async {
    final errors = <Object>[];
    final files = MemorySettingsFileSystem()..failWrites = true;
    final reporter = ApplicationErrorReporter(
      sink: (error, _) => errors.add(error),
    );
    final preferences = AppPreferences(
      store: SettingsStore(
        path: '/support/settings.json',
        fileSystem: files,
        onError: reporter.report,
      ),
    );

    reporter.observe(preferences.savePaneRatio(0.6));
    await files.firstWriteStarted.future;
    await Future<void>.delayed(Duration.zero);

    expect(errors, [isA<StateError>()]);
  });

  test('contains failures raised by the reporting sink', () async {
    final reporter = ApplicationErrorReporter(
      sink: (_, _) => throw StateError('sink failed'),
    );

    reporter.observe(Future<void>.error(StateError('operation failed')));
    await Future<void>.delayed(Duration.zero);
  });
}
