import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/ssh_config_source.dart';
import 'package:klabautermann_app/ui/startup_issue_notice.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_ssh_config.dart';
import 'support/harness.dart';

const _entryLabel = 'Import from ~/.ssh/config';
const _desktop = Size(1280, 800);
const _phone = Size(390, 800);

const _config = 'Host web-1\n  HostName web-1.example\nHost db-1\n';

final _imported = CatalogReplaced(const [
  FleetEntry(
    serverId: 'ssh-config:web-1',
    label: 'web-1',
    host: 'web-1.example',
    port: kSshDefaultPort,
    origin: FleetEntryOrigin.sshConfig,
  ),
  FleetEntry(
    serverId: 'ssh-config:db-1',
    label: 'db-1',
    host: 'db-1',
    port: 2222,
    user: 'admin',
    origin: FleetEntryOrigin.sshConfig,
  ),
]);

/// Opens the desktop rail's add menu and picks the import.
Future<void> _chooseImportFromRail(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Add'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(_entryLabel));
  await tester.pumpAndSettle();
}

/// FL-02: the desktop-only ssh_config import, from the entry to the rail.
void main() {
  testWidgets('the desktop rail\'s add menu imports into the rail', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      size: _desktop,
      sshConfig: FakeSshConfigSource.text(_config),
    );
    expect(find.text('No servers yet'), findsOneWidget);

    await _chooseImportFromRail(tester);

    // The app sends the text; parsing is the engine isolate's (CN-19).
    final request = harness.engine.sentOfType<ImportSshConfig>().single;
    expect((request as ImportSshConfig).text, _config);

    harness.engine
      ..emit(_imported)
      ..emit(
        const SshConfigImported(importedCount: 2, skippedCount: 0, saved: true),
      );
    await tester.pumpAndSettle();

    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('web-1.example'), findsOneWidget);
    expect(find.text('db-1'), findsOneWidget);
    expect(find.text('admin@db-1:2222'), findsOneWidget);
    expect(find.text('Imported 2 servers from ~/.ssh/config.'), findsOneWidget);
    // Pull-only (D14): the import is the only request the drive produced.
    expect(harness.engine.sent, hasLength(1));
  });

  // A phone's or tablet's composition root gets no ssh_config source
  // (sshConfigSourceFor), so the harness's default null stands in for one.
  testWidgets('a phone offers no import', (tester) async {
    await pumpApp(tester, size: _phone, servers: twoServers);

    expect(find.byTooltip('Add server'), findsOneWidget);
    expect(find.byTooltip(_entryLabel), findsNothing);
    expect(find.text(_entryLabel), findsNothing);
  });

  testWidgets('a tablet in the desktop shell offers no import', (tester) async {
    await pumpApp(tester, size: _desktop, servers: twoServers);

    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();
    expect(find.text('Add server'), findsOneWidget);
    expect(find.text(_entryLabel), findsNothing);
  });

  testWidgets('a narrow desktop window keeps the import in the app bar', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      size: _phone,
      sshConfig: FakeSshConfigSource.text(_config),
    );

    await tester.tap(find.byTooltip(_entryLabel));
    await tester.pumpAndSettle();

    expect(harness.engine.sentOfType<ImportSshConfig>(), hasLength(1));
  });

  testWidgets('the entry is disabled while an import runs', (tester) async {
    final source = FakeSshConfigSource.text(_config)..gate = Completer();
    final harness = await pumpApp(tester, size: _desktop, sshConfig: source);

    await _chooseImportFromRail(tester);
    await tester.tap(find.byTooltip('Add'));
    await tester.pumpAndSettle();

    final entry = tester.widget<MenuItemButton>(
      find.widgetWithText(MenuItemButton, _entryLabel),
    );
    expect(entry.onPressed, isNull);

    source.gate!.complete();
    await tester.pumpAndSettle();
    harness.engine.emit(
      const SshConfigImported(importedCount: 0, skippedCount: 0, saved: true),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<MenuItemButton>(
            find.widgetWithText(MenuItemButton, _entryLabel),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('skipped hosts and an empty config are reported', (tester) async {
    final harness = await pumpApp(
      tester,
      size: _desktop,
      sshConfig: FakeSshConfigSource.text(_config),
    );

    await _chooseImportFromRail(tester);
    harness.engine.emit(
      const SshConfigImported(importedCount: 1, skippedCount: 2, saved: true),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Imported 1 server from ~/.ssh/config. 2 hosts were skipped '
        'because of settings Klabautermann cannot follow as ssh would, '
        'such as a ProxyCommand, Include or Match block.',
      ),
      findsOneWidget,
    );

    // The first toast times out (4 s) before the second import.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.textContaining('Imported 1 server'), findsNothing);
    await _chooseImportFromRail(tester);
    harness.engine.emit(
      const SshConfigImported(importedCount: 0, skippedCount: 0, saved: true),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Your ~/.ssh/config names no hosts to import.'),
      findsOneWidget,
    );
  });

  testWidgets('an import that skips every host does not contradict itself', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      size: _desktop,
      sshConfig: FakeSshConfigSource.text(_config),
    );

    await _chooseImportFromRail(tester);
    harness.engine.emit(
      const SshConfigImported(importedCount: 0, skippedCount: 2, saved: true),
    );
    await tester.pumpAndSettle();

    expect(
      find.text(
        'No hosts were imported from ~/.ssh/config. 2 hosts were skipped '
        'because of settings Klabautermann cannot follow as ssh would, '
        'such as a ProxyCommand, Include or Match block.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('names no hosts'), findsNothing);
  });

  testWidgets('an import the engine could not save says it will not be '
      'kept', (tester) async {
    final harness = await pumpApp(
      tester,
      size: _desktop,
      sshConfig: FakeSshConfigSource.text(_config),
    );

    await _chooseImportFromRail(tester);
    harness.engine
      ..emit(_imported)
      ..emit(
        const SshConfigImported(
          importedCount: 2,
          skippedCount: 0,
          saved: false,
        ),
      );
    await tester.pumpAndSettle();

    // The counts stay true, and a second toast says they will not last.
    expect(find.text('web-1'), findsOneWidget);
    expect(find.text('Imported 2 servers from ~/.ssh/config.'), findsOneWidget);
    expect(
      find.text(
        'This import could not be saved, so it will not be kept after a '
        'restart.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('a saved import says nothing about saving', (tester) async {
    final harness = await pumpApp(
      tester,
      size: _desktop,
      sshConfig: FakeSshConfigSource.text(_config),
    );

    await _chooseImportFromRail(tester);
    harness.engine
      ..emit(_imported)
      ..emit(
        const SshConfigImported(importedCount: 2, skippedCount: 0, saved: true),
      );
    await tester.pumpAndSettle();

    expect(find.textContaining('could not be saved'), findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  group('the import store at startup (03 §4.10)', () {
    const keptAs = 'ssh_config_imports.json.corrupt-20261014T093005250Z';

    testWidgets('a damaged store is reported once, naming the kept '
        'copy', (tester) async {
      await pumpApp(
        tester,
        size: _desktop,
        sshConfig: FakeSshConfigSource.text(_config),
        importStoreIssue: const ImportStoreIssue(
          ImportStoreIssueKind.recovered,
          preservedAs: '/support/$keptAs',
        ),
      );

      expect(
        find.text(
          'Your imported servers could not be read and were cleared. The '
          'old file is kept as $keptAs. Import ~/.ssh/config again to '
          'bring them back.',
        ),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
      expect(find.textContaining(keptAs), findsNothing);
    });

    testWidgets('a settings issue and a store issue both show', (tester) async {
      await pumpApp(
        tester,
        size: _desktop,
        settingsIssue: const DeviceSettingsIssue(
          DeviceSettingsIssueKind.notSaved,
        ),
        importStoreIssue: const ImportStoreIssue(
          ImportStoreIssueKind.newerVersion,
        ),
      );

      expect(find.textContaining('Your settings could not be saved'), findsOne);
      expect(
        find.textContaining('saved by a newer version of Klabautermann'),
        findsOne,
      );
      await tester.pump(const Duration(seconds: 11));
      await tester.pumpAndSettle();
    });

    test('every store issue has its own sentence', () {
      final l10n = lookupAppLocalizations(const Locale('en'));
      final messages = {
        for (final kind in ImportStoreIssueKind.values)
          kind: importStoreIssueMessage(
            l10n,
            ImportStoreIssue(kind, preservedAs: '/support/$keptAs'),
          ),
      };

      expect(messages[ImportStoreIssueKind.recovered], contains(keptAs));
      // Only a file this run may replace invites a new import to restore.
      expect(messages[ImportStoreIssueKind.recovered], contains('again'));
      for (final kind in [
        ImportStoreIssueKind.leftAsIs,
        ImportStoreIssueKind.newerVersion,
      ]) {
        expect(messages[kind], contains('will not be kept after a restart'));
      }
      expect(messages.values.toSet(), hasLength(messages.length));
    });
  });

  const failureMessages = {
    SshConfigReadFailure.missing: 'There is no ~/.ssh/config on this computer.',
    SshConfigReadFailure.unreadable:
        'Your ~/.ssh/config could not be read. Check that it is a regular '
        'file you can open.',
    SshConfigReadFailure.tooLarge: 'Your ~/.ssh/config is too large to import.',
  };
  for (final MapEntry(key: failure, value: message)
      in failureMessages.entries) {
    testWidgets('a ${failure.name} config shows a message, not a crash', (
      tester,
    ) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        sshConfig: FakeSshConfigSource.failing(failure),
      );

      await _chooseImportFromRail(tester);

      expect(find.text(message), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(harness.engine.sent, isEmpty);
      expect(find.text('No servers yet'), findsOneWidget);
    });
  }

  testWidgets('an engine that refuses the import shows a message', (
    tester,
  ) async {
    final harness = await pumpApp(
      tester,
      size: _desktop,
      sshConfig: FakeSshConfigSource.text(_config),
    );

    await _chooseImportFromRail(tester);
    harness.engine.emit(const RequestRejected('ImportSshConfig', 'boom'));
    await tester.pumpAndSettle();

    expect(
      find.text(
        'The import from ~/.ssh/config failed. Try again, and restart the '
        'app if it keeps failing.',
      ),
      findsOneWidget,
    );
  });
}
