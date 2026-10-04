import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart' show AppLocalizations;
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/services/recent_locations.dart';
import 'package:poltergeist_app/services/settings_store.dart';
import 'package:poltergeist_app/services/ssh_config_import_setup.dart';
import 'package:poltergeist_app/services/third_party_bookmark_import_setup.dart';
import 'package:poltergeist_app/services/uuid.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/import/third_party_bookmark_import_command.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/engine_session_test.dart' as session_test;
import '../support/fake_bookmark_store.dart';
import '../support/fake_ssh_config_source.dart';
import '../support/shell_commands.dart';
import '../support/shell_menus.dart';

/// Real-font captures of the M9 surfaces (02 §8.4 / D22): the Quick
/// Open palette over the live registry — all three sections, shortcut
/// gutter and disabled reason. Historical M9 captures stay in
/// tasks/run3-task93/ and regenerate only when POLTERGEIST_CAPTURE_DIR is
/// explicit; current shared-import captures use the D22 folder. Both are
/// gated on POLTERGEIST_CAPTURE=1 like the menu captures.
final _m9CaptureDir = Platform.environment['POLTERGEIST_CAPTURE_DIR'];
final _d22CaptureDir =
    Platform.environment['POLTERGEIST_D22_CAPTURE_DIR'] ??
    '../../tasks/d22-third-party-importers';

// The same real-font loader the menu captures use (private there).
Future<ByteData> _fontBytes(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.sublistView(bytes);
}

Future<void> _loadRealFonts() async {
  final home = Platform.environment['HOME'];
  final dir = Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      (home == null ? '' : '$home/.local/share/fonts');
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
  if (!sans.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader('DejaVu Sans')
    ..addFont(_fontBytes(sans.path));
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
  if (mono.existsSync()) {
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
    // The import dialog styles cells with the generic 'monospace'
    // alias — register the same face under it so captures show text.
    final aliasLoader = FontLoader('monospace')
      ..addFont(_fontBytes(mono.path));
    await aliasLoader.load();
  }
}

const _home = '/home/tester';
const _configPath = '$_home/.ssh/config';
final _fixedNow = DateTime.utc(2026, 9, 22, 12);

const _sampleConfig = '''
Host web
  HostName web.example.com
  Port 2222
  User deploy
  IdentityFile ~/.ssh/id_ed25519

Host other
  HostName other.example.com
  User root
''';

const _fileZillaExport = '''
<?xml version="1.0" encoding="UTF-8"?>
<FileZilla3>
  <Servers>
    <Server>
      <Host>archive.example.com</Host>
      <Port>22</Port>
      <Protocol>1</Protocol>
      <User>curator</User>
      <Logontype>5</Logontype>
      <Keyfile>~/.ssh/archive_ed25519</Keyfile>
      <RemoteDir>1 0 3 srv 7 archive</RemoteDir>
      <Name>Archive</Name>
    </Server>
  </Servers>
</FileZilla3>
''';

Bookmark _favorite(String id, String label) => Bookmark(
  id: id,
  kind: BookmarkKind.remotePath,
  label: label,
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '$label.example.com',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/srv/$label',
  sortKey: 'f-$label',
  createdAt: _fixedNow,
  updatedAt: _fixedNow,
);

void main() {
  testWidgets('captures the Quick Open palette and the ssh_config '
      'import preview', (tester) async {
    await tester.runAsync(_loadRealFonts);

    final engine = session_test.FakeAppEngine();
    for (final names in [
      ['left.txt', 'docs'],
      ['right.txt'],
    ]) {
      engine.localChannels.add(
        session_test.FakeAppBrowseChannel(homePath: '/home/tester')
          ..listings['/home/tester'] = [
            for (final name in names)
              RemoteFileEntry(
                path: '/home/tester/$name',
                name: name,
                type: RemoteFileType.file,
                size: 10,
              ),
          ],
      );
    }
    addTearDown(engine.close);

    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-m9-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final bookmarks = FakeBookmarkStore([
      _favorite('fav-web', 'web'),
      _favorite('fav-logs', 'logs'),
    ]);
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      bookmarks: bookmarks,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);

    // One remote + one local recent so all three palette sections
    // render in the capture.
    final recents = RecentLocationsStore(
      store: SettingsStore(
        path: '${supportDir.path}/settings.json',
        atomicWriter: (target, contents) async =>
            target.writeAsString(contents),
      ),
    );
    addTearDown(recents.dispose);
    recents.recordLocation(
      const LocalPaneLocation('/home/tester/docs'),
    );
    recents.recordLocation(
      const RemotePaneLocation('fav-web', '/srv/web'),
      remoteBookmark: _favorite('fav-web', 'web'),
    );

    final base = buildPoltergeistTheme(Brightness.dark);
    final theme = base.copyWith(
      textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
      primaryTextTheme: base.primaryTextTheme.apply(
        fontFamily: 'DejaVu Sans',
      ),
    );
    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture.shell'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          navigatorKey: navigatorKey,
          home: WorkspaceShell(
            bookmarks: bookmarks,
            engineSession: session,
            recentLocations: recents,
            sshConfigImport: SshConfigImportSetup(
              service: SshConfigImportService(
                homeDirectory: _home,
                source: FakeSshConfigSource(
                  const {_configPath: _sampleConfig},
                ),
                mintId: uuidV4,
              ),
              bookmarks: bookmarks,
              configPath: _configPath,
            ),
            thirdPartyBookmarkImport: ThirdPartyBookmarkImportSetup(
              bookmarks: bookmarks,
              pickFiles: (_) async => [
                ThirdPartyBookmarkImportFile(
                  'sitemanager.xml',
                  utf8.encode(_fileZillaExport),
                ),
              ],
              startPreview:
                  ({
                    required format,
                    required files,
                    required existingBookmarks,
                  }) async => ThirdPartyBookmarkPreviewTask.fromFuture(
                    Future.value(
                      ThirdPartyBookmarkImportService(
                        mintId: uuidV4,
                      ).loadPreview(
                        format: format,
                        files: files,
                        existingBookmarks: existingBookmarks,
                      ),
                    ),
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('capture.shell')),
    );
    final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
    Future<void> capture(String? directory, String name) async {
      if (!captureOn) return;
      if (directory == null) {
        // ignore: avoid_print
        print('skipped $name.png: set POLTERGEIST_CAPTURE_DIR for M9');
        return;
      }

      final bytes = (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final data = await image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          return data!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
      final outDir = Directory(directory);
      outDir.createSync(recursive: true);
      final file = File('${outDir.path}/$name.png');
      // ignore: avoid_print
      print('capture: ${file.absolute.path}');
      file.writeAsBytesSync(bytes);
    }

    // The palette via its registered chord (Ctrl+Shift+P — the test
    // platform is Linux). Assertions prove the dialog is up before the
    // capture, the same posture the menu captures take.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyP);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('quickOpen.field')),
      findsOneWidget,
    );
    await capture(_m9CaptureDir, 'quick-open');

    // A filtered view: one query over commands + favorites + recents.
    await tester.enterText(
      find.byKey(const ValueKey('quickOpen.field')),
      'web',
    );
    await tester.pumpAndSettle();
    await capture(_m9CaptureDir, 'quick-open-filtered');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('quickOpen.field')), findsNothing);

    // The import preview via the Server menu command (D22; D32 moved
    // it from File) — the launcher offer is covered in
    // quick_connect_test; the capture only needs the dialog itself.
    final l10n = AppLocalizations.of(
      tester.element(find.byType(WorkspaceShell)),
    );
    await openShellMenu(tester, AppMenuId.server);
    await tester.tap(
      find.ancestor(
        of: find.text(l10n.sshImportCommandLabel),
        matching: find.byType(MenuItemButton),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Import servers from ssh config'),
      findsOneWidget,
    );
    await capture(_d22CaptureDir, 'ssh-import-preview');

    await tester.tap(find.text(l10n.sshImportCancel));
    await tester.pumpAndSettle();

    // The palette route uses the parent command's source chooser; choosing
    // FileZilla reaches the same preview widget as ssh_config.
    await runShellCommand(
      tester,
      kThirdPartyBookmarkImportCommandId,
      settle: false,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.bookmarkImportFileZilla));
    await tester.pumpAndSettle();
    expect(find.text('Import from FileZilla'), findsOneWidget);
    expect(find.text('archive.example.com:22'), findsOneWidget);
    await capture(_d22CaptureDir, 'filezilla-import-preview');
  });
}
