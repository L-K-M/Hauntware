import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/third_party_bookmark_import_setup.dart';
import 'package:poltergeist_app/ui/import/third_party_bookmark_import_command.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/shell_commands.dart';
import '../../support/shell_menus.dart';

final _fixedNow = DateTime.utc(2026, 10, 1, 12);

const _winScpExport = r'''
[Sessions\Production]
HostName=prod.example.com
PortNumber=2222
UserName=deploy
FSProtocol=2
PublicKeyFile=~/.ssh/id_ed25519
RemoteDirectory=/srv/app
''';

const _fileZillaExport = '''
<?xml version="1.0" encoding="UTF-8"?>
<FileZilla3>
  <Servers>
    <Server>
      <Host>prod.example.com</Host>
      <Port>2222</Port>
      <Protocol>1</Protocol>
      <User>deploy</User>
      <Name>Production</Name>
    </Server>
  </Servers>
</FileZilla3>
''';

const _unknownFileZillaProtocolExport = '''
<FileZilla3><Servers><Server>
  <Host>unknown.example.com</Host><Protocol>99</Protocol><Name>Unknown</Name>
</Server></Servers></FileZilla3>
''';

const _winScpPpkExport = r'''
[Sessions\PuTTY]
HostName=putty.example.com
UserName=deploy
FSProtocol=2
PublicKeyFile=C:%5Ckeys%5Cid_ed25519.ppk
''';

String _cyberduckExport(String host, String path) =>
    '''
<plist><dict>
  <key>Protocol</key><string>sftp</string>
  <key>Hostname</key><string>$host</string>
  <key>Path</key><string>$path</string>
</dict></plist>
''';

class _FakeBookmarkStore implements BookmarkRepository {
  _FakeBookmarkStore([Iterable<Bookmark> seed = const []]) {
    for (final bookmark in seed) {
      _bookmarks[bookmark.id] = bookmark;
    }
  }

  final _bookmarks = <String, Bookmark>{};

  @override
  Future<List<Bookmark>> load() async => List.unmodifiable(_bookmarks.values);

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {
    for (final bookmark in bookmarks) {
      _bookmarks[bookmark.id] = bookmark;
    }
  }
}

class _LoadFailingBookmarkStore implements BookmarkRepository {
  @override
  Future<List<Bookmark>> load() async {
    throw const FileSystemException('unreadable');
  }

  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {}
}

class _SaveFailingBookmarkStore extends _FakeBookmarkStore {
  @override
  Future<void> upsertAll(Iterable<Bookmark> bookmarks) async {
    throw const FileSystemException('unwritable');
  }
}

Bookmark _existing() => Bookmark(
  id: 'saved-prod',
  kind: BookmarkKind.remotePath,
  label: 'Saved production',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'prod.example.com',
      port: 2222,
      username: 'deploy',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/',
  sortKey: 'saved-prod',
  createdAt: _fixedNow,
  updatedAt: _fixedNow,
);

void main() {
  late _FakeBookmarkStore store;
  late List<ThirdPartyBookmarkFormat> picks;
  var nextId = 0;

  setUp(() {
    store = _FakeBookmarkStore();
    picks = [];
    nextId = 0;
  });

  ThirdPartyBookmarkImportSetup setup({
    BookmarkRepository? bookmarks,
    Future<List<ThirdPartyBookmarkImportFile>?> Function(
      ThirdPartyBookmarkFormat format,
    )?
    pickFiles,
  }) {
    final service = ThirdPartyBookmarkImportService(
      mintId: () => 'import-${nextId++}',
    );

    return ThirdPartyBookmarkImportSetup(
      bookmarks: bookmarks ?? store,
      pickFiles:
          pickFiles ??
          (format) async {
            picks.add(format);
            return [
              ThirdPartyBookmarkImportFile(
                switch (format) {
                  ThirdPartyBookmarkFormat.fileZilla => 'sitemanager.xml',
                  ThirdPartyBookmarkFormat.winScp => 'WinSCP.ini',
                  ThirdPartyBookmarkFormat.cyberduck => 'site.duck',
                },
                utf8.encode(
                  format == ThirdPartyBookmarkFormat.fileZilla
                      ? _fileZillaExport
                      : _winScpExport,
                ),
              ),
            ];
          },
      startPreview:
          ({
            required format,
            required files,
            required existingBookmarks,
          }) async => ThirdPartyBookmarkPreviewTask.fromFuture(
            Future.value(
              service.loadPreview(
                format: format,
                files: files,
                existingBookmarks: existingBookmarks,
              ),
            ),
          ),
    );
  }

  Future<void> pumpApp(
    WidgetTester tester, {
    ThirdPartyBookmarkImportSetup? wiring,
  }) async {
    tester.view.physicalSize = const Size(1180, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(PoltergeistApp(thirdPartyBookmarkImport: wiring));
    await tester.pump();
  }

  testWidgets('registers one menu command with all three sources', (
    tester,
  ) async {
    await pumpApp(tester);
    expect(
      shellCommandRegistered(tester, kThirdPartyBookmarkImportCommandId),
      isFalse,
    );

    await pumpApp(tester, wiring: setup());
    final command = shellCommand(tester, kThirdPartyBookmarkImportCommandId);
    final l10n = AppLocalizations.of(
      tester.element(find.byType(WorkspaceShell)),
    );
    expect(command.menuPlacement?.menu, AppMenuId.server);
    expect(
      [for (final item in command.submenuItems!(l10n)) item.label(l10n)],
      ['FileZilla', 'WinSCP', 'Cyberduck'],
    );

    await openShellMenu(tester, AppMenuId.server);
    expect(find.text(l10n.bookmarkImportCommandLabel), findsOneWidget);
  });

  testWidgets('palette route chooses a source, previews, and persists', (
    tester,
  ) async {
    await pumpApp(tester, wiring: setup());

    await runShellCommand(
      tester,
      kThirdPartyBookmarkImportCommandId,
      settle: false,
    );
    await tester.pumpAndSettle();
    expect(find.text('Import from another app'), findsOneWidget);

    await tester.tap(find.text('WinSCP'));
    await tester.pumpAndSettle();

    expect(picks, [ThirdPartyBookmarkFormat.winScp]);
    expect(find.text('Import from WinSCP'), findsOneWidget);
    expect(find.text('prod.example.com:2222'), findsOneWidget);
    expect(find.text('Key: ~/.ssh/id_ed25519'), findsOneWidget);
    expect(find.text('Start folder: /srv/app'), findsOneWidget);
    expect(find.text('Import 1'), findsOneWidget);

    await tester.tap(find.text('Import 1'));
    await tester.pumpAndSettle();

    final persisted = await store.load();
    expect(persisted, hasLength(1));
    final bookmark = persisted.single;
    expect(bookmark.label, 'Production');
    expect(bookmark.remotePath, '/srv/app');
    expect(bookmark.server!.identity!.authMethod, AuthMethod.privateKey);
    expect(find.text('Imported 1 favorite'), findsOneWidget);
  });

  testWidgets('persisted endpoint duplicates start skipped', (tester) async {
    store = _FakeBookmarkStore([_existing()]);
    await pumpApp(tester, wiring: setup());

    await runShellCommand(
      tester,
      kThirdPartyBookmarkImportCommandId,
      settle: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('FileZilla'));
    await tester.pumpAndSettle();

    expect(
      find.text('Duplicate of bookmark “Saved production”'),
      findsOneWidget,
    );
    expect(find.text('Password prompt'), findsOneWidget);
    expect(
      find.text('Saved password is not imported; Poltergeist will ask'),
      findsOneWidget,
    );
    final checkbox = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(checkbox.value, isFalse);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Import'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('unsupported PuTTY keys stay visible but disabled', (
    tester,
  ) async {
    await pumpApp(
      tester,
      wiring: setup(
        pickFiles: (_) async => [
          ThirdPartyBookmarkImportFile(
            'WinSCP.ini',
            utf8.encode(_winScpPpkExport),
          ),
        ],
      ),
    );

    final command = shellCommand(tester, kThirdPartyBookmarkImportCommandId);
    final context = tester.element(find.byType(WorkspaceShell));
    unawaited(
      command
          .submenuItems!(
            AppLocalizations.of(context),
          )[ThirdPartyBookmarkFormat.winScp.index]
          .run(context),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Cannot import: choose an OpenSSH private key instead'),
      findsOneWidget,
    );
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('unknown protocol copy is localized', (tester) async {
    await pumpApp(
      tester,
      wiring: setup(
        pickFiles: (_) async => [
          ThirdPartyBookmarkImportFile(
            'sitemanager.xml',
            utf8.encode(_unknownFileZillaProtocolExport),
          ),
        ],
      ),
    );

    final command = shellCommand(tester, kThirdPartyBookmarkImportCommandId);
    final context = tester.element(find.byType(WorkspaceShell));
    unawaited(
      command.submenuItems!(AppLocalizations.of(context)).first.run(context),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cannot import: protocol is unknown'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNull);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('picker failures are explicit', (tester) async {
    await pumpApp(
      tester,
      wiring: setup(
        pickFiles: (_) async => throw const FileSystemException('picker'),
      ),
    );
    final command = shellCommand(tester, kThirdPartyBookmarkImportCommandId);
    final context = tester.element(find.byType(WorkspaceShell));
    await command.submenuItems!(AppLocalizations.of(context)).first.run(
      context,
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not read the selected file.'), findsOneWidget);
    expect(tester.takeException(), isA<FileSystemException>());
  });

  testWidgets('parse failures explain the cause and allow reselecting', (
    tester,
  ) async {
    var pickerCalls = 0;
    await pumpApp(
      tester,
      wiring: setup(
        pickFiles: (_) async {
          pickerCalls++;
          if (pickerCalls == 1) {
            return [
              ThirdPartyBookmarkImportFile(
                'broken.xml',
                utf8.encode('<FileZilla3>'),
              ),
            ];
          }

          return [
            ThirdPartyBookmarkImportFile(
              'sitemanager.xml',
              utf8.encode(_fileZillaExport),
            ),
          ];
        },
      ),
    );
    final command = shellCommand(tester, kThirdPartyBookmarkImportCommandId);
    final context = tester.element(find.byType(WorkspaceShell));
    unawaited(
      command.submenuItems!(AppLocalizations.of(context)).first.run(context),
    );
    await tester.pumpAndSettle();

    expect(find.text('Could not parse broken.xml.'), findsOneWidget);
    await tester.tap(find.text('Choose another file…'));
    await tester.pumpAndSettle();

    expect(pickerCalls, 2);
    expect(find.text('prod.example.com:2222'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('multi-file previews identify each source file', (tester) async {
    await pumpApp(
      tester,
      wiring: setup(
        pickFiles: (_) async => [
          ThirdPartyBookmarkImportFile(
            'production.duck',
            utf8.encode(_cyberduckExport('one.example.com', '/one')),
          ),
          ThirdPartyBookmarkImportFile(
            'staging.duck',
            utf8.encode(_cyberduckExport('two.example.com', '/two')),
          ),
        ],
      ),
    );
    final command = shellCommand(tester, kThirdPartyBookmarkImportCommandId);
    final context = tester.element(find.byType(WorkspaceShell));
    unawaited(
      command.submenuItems!(AppLocalizations.of(context)).last.run(context),
    );
    await tester.pumpAndSettle();

    expect(find.text('Start folder: /one'), findsOneWidget);
    expect(find.text('Source: production.duck'), findsOneWidget);
    expect(find.text('Start folder: /two'), findsOneWidget);
    expect(find.text('Source: staging.duck'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });

  testWidgets('bookmark store failures are explicit', (tester) async {
    await pumpApp(
      tester,
      wiring: setup(bookmarks: _LoadFailingBookmarkStore()),
    );
    final failingCommand = shellCommand(
      tester,
      kThirdPartyBookmarkImportCommandId,
    );
    final failingContext = tester.element(find.byType(WorkspaceShell));
    await failingCommand
        .submenuItems!(AppLocalizations.of(failingContext))
        .first
        .run(failingContext);
    await tester.pumpAndSettle();
    expect(find.text('Could not read the favorites file.'), findsOneWidget);
    expect(tester.takeException(), isA<FileSystemException>());
  });

  testWidgets('save failures do not report success', (tester) async {
    final failingStore = _SaveFailingBookmarkStore();
    await pumpApp(tester, wiring: setup(bookmarks: failingStore));
    final command = shellCommand(tester, kThirdPartyBookmarkImportCommandId);
    final context = tester.element(find.byType(WorkspaceShell));
    unawaited(
      command.submenuItems!(AppLocalizations.of(context)).first.run(context),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Import 1'));
    await tester.pumpAndSettle();

    expect(find.text('Could not save the imported favorites.'), findsOneWidget);
    expect(find.text('Imported 1 favorite'), findsNothing);
    expect(await failingStore.load(), isEmpty);
    expect(tester.takeException(), isA<FileSystemException>());
  });

  testWidgets('late picker completion does not use a disposed context', (
    tester,
  ) async {
    final picker = Completer<List<ThirdPartyBookmarkImportFile>?>();
    await pumpApp(tester, wiring: setup(pickFiles: (_) => picker.future));
    final command = shellCommand(tester, kThirdPartyBookmarkImportCommandId);
    final context = tester.element(find.byType(WorkspaceShell));
    unawaited(
      command.submenuItems!(AppLocalizations.of(context)).first.run(context),
    );
    await tester.pump();

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    picker.complete([
      ThirdPartyBookmarkImportFile(
        'sitemanager.xml',
        utf8.encode(_fileZillaExport),
      ),
    ]);
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Import from FileZilla'), findsNothing);
  });
}
