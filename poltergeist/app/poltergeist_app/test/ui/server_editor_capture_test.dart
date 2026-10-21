import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/server_editor.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Real-font captures of the server editor as Poltergeist raises it,
/// worded in ARB, in both brightnesses, for comparing its pixels across
/// the move into ghost_servers (docs/design/ghost-servers-part2.md,
/// section 7): a new server with agent auth, an edit with a referenced
/// key, a password with the sync switch, and the appearance section with
/// a custom colour.
///
/// Nothing is written unless POLTERGEIST_CAPTURE=1; the PNGs then land in
/// POLTERGEIST_CAPTURE_DIR (default `build/server-editor-captures`). The
/// scenes are still pumped and checked on every run.
final _captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    'build/server-editor-captures';

const _fontFamily = 'DejaVu Sans';

const _nowMs = 1780000000000;

Future<void> _loadRealFonts() async {
  Future<ByteData> bytes(File file) async =>
      ByteData.sublistView(file.readAsBytesSync());

  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  final icons = File(
    '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (flutterRoot != null && icons.existsSync()) {
    await (FontLoader('MaterialIcons')..addFont(bytes(icons))).load();
  }
  await loadBundledMonoFonts();
  final dir =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      '/usr/share/fonts/truetype/dejavu';
  final regular = File('$dir/DejaVuSans.ttf');
  if (!regular.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader(_fontFamily)..addFont(bytes(regular));
  final bold = File('$dir/DejaVuSans-Bold.ttf');
  if (bold.existsSync()) loader.addFont(bytes(bold));
  await loader.load();
}

ThemeData _theme(Brightness brightness) {
  // The house capture convention: the loaded family must be requested by
  // the theme; FontLoader alone cannot reach default-styled text.
  final base = buildPoltergeistTheme(
    brightness,
    platform: TargetPlatform.linux,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _fontFamily),
  );
}

ServerConfig _server({
  AuthMethod authMethod = AuthMethod.agent,
  String? secretRef,
  String? identityFilePath,
  bool syncSecret = false,
  String? group,
  String? customColor,
}) => ServerConfig(
  id: 'srv-build',
  label: 'build',
  host: 'build.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: authMethod,
  secretRef: secretRef,
  identityFilePath: identityFilePath,
  syncSecret: syncSecret,
  group: group,
  customColor: customColor,
  createdAt: _nowMs,
  updatedAt: _nowMs,
);

/// The application layer the editor writes through, reduced to what the
/// scenes read back.
final class _Delegate extends ServerEditorDelegate {
  _Delegate({this.configured = false, this.storedSecret});

  final bool configured;
  final Secret? storedSecret;
  (ServerConfig, Secret?)? saved;

  @override
  List<ServerConfig> get servers => const [];

  @override
  bool get syncConfigured => configured;

  @override
  Color get themeSeed => const Color(0xFF335577);

  @override
  Future<String?> pickIdentityFile() async => null;

  @override
  Future<Secret?> readSecret(String secretId) async => storedSecret;

  @override
  Future<void> save(ServerConfig config, {Secret? secret}) async {
    saved = (config, secret);
  }

  @override
  TransferConcurrency get defaultTransferConcurrency =>
      const TransferConcurrency.automatic();

  @override
  TransferConcurrency? transferConcurrencyFor(String serverId) => null;

  @override
  Future<void> saveTransferConcurrency(
    String serverId,
    TransferConcurrency? value,
  ) async {}

  @override
  Future<ConnectionTestResult> testConnection(
    ServerConfig config, {
    String? draftPassword,
    String? draftPrivateKey,
    String? draftKeyPassphrase,
    SshConnectionLog? log,
  }) async =>
      const ConnectionTestResult(ok: true, summary: 'Connected.', log: '');
}

void main() {
  setUpAll(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(_loadRealFonts);
  });

  Finder field(String label) => find.widgetWithText(TextFormField, label);

  /// Opens the editor over [existing], lets [answer] act on it, writes
  /// the capture, then lets [close] end it and check what it saved.
  Future<void> captureEditor(
    WidgetTester tester, {
    required Brightness brightness,
    required String name,
    required _Delegate delegate,
    ServerConfig? existing,
    Future<void> Function()? answer,
    required Future<void> Function() close,
  }) async {
    // Tall enough that the whole form shows without scrolling.
    tester.view.physicalSize = const Size(720, 1900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      // The boundary wraps the app: the dialog renders on the Navigator's
      // overlay, a sibling of `home`.
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(brightness),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showServerEditor(context, delegate, existing),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    if (answer != null) await answer();
    await tester.pumpAndSettle();

    final title = existing == null ? 'Add server' : 'Edit server';
    expect(find.text(title), findsOneWidget);

    if (_captureOn) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      final png = (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        try {
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          return data!.buffer.asUint8List();
        } finally {
          image.dispose();
        }
      }))!;
      // Sync I/O: awaiting real file futures can strand the fake-async zone.
      Directory(_captureDir).createSync(recursive: true);
      File('$_captureDir/$name.png').writeAsBytesSync(png);
    }

    await close();
    expect(find.text(title), findsNothing);
  }

  Future<void> saves(WidgetTester tester) async {
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    final tone = brightness.name;

    testWidgets('captures a new server with agent auth ($tone)', (
      tester,
    ) async {
      final delegate = _Delegate();
      await captureEditor(
        tester,
        brightness: brightness,
        name: 'server-editor-add-agent-$tone',
        delegate: delegate,
        answer: () async {
          await tester.enterText(field('Label'), 'web-3');
          await tester.enterText(field('Host'), 'web-3.example.com');
          await tester.enterText(field('Username'), 'deploy');
        },
        close: () async {
          await saves(tester);
          final (config, secret) = delegate.saved!;
          expect(config.label, 'web-3');
          expect(config.port, 22);
          expect(config.authMethod, AuthMethod.agent);
          expect(secret, isNull);
        },
      );
    });

    testWidgets('captures an edit with a referenced key ($tone)', (
      tester,
    ) async {
      final delegate = _Delegate();
      await captureEditor(
        tester,
        brightness: brightness,
        name: 'server-editor-referenced-key-$tone',
        delegate: delegate,
        existing: _server(
          authMethod: AuthMethod.privateKey,
          secretRef: 'srv-build',
          identityFilePath: '~/.ssh/id_ed25519',
        ),
        answer: () async {
          final path = tester.widget<TextFormField>(
            field('Identity file path'),
          );
          expect(path.controller?.text, '~/.ssh/id_ed25519');
        },
        close: () async {
          await saves(tester);
          final (config, _) = delegate.saved!;
          expect(config.authMethod, AuthMethod.privateKey);
          expect(config.identityFilePath, '~/.ssh/id_ed25519');
        },
      );
    });

    testWidgets('captures a password with the sync switch ($tone)', (
      tester,
    ) async {
      final delegate = _Delegate(configured: true);
      await captureEditor(
        tester,
        brightness: brightness,
        name: 'server-editor-password-sync-$tone',
        delegate: delegate,
        existing: _server(authMethod: AuthMethod.password),
        answer: () async {
          await tester.enterText(field('Password'), 'hunter2');
          await tester.tap(find.text('Allow this credential to sync'));
        },
        close: () async {
          await saves(tester);
          final (config, secret) = delegate.saved!;
          expect(config.authMethod, AuthMethod.password);
          expect(config.syncSecret, isTrue);
          expect(secret?.value, 'hunter2');
        },
      );
    });

    testWidgets('captures the appearance section with a custom colour '
        '($tone)', (tester) async {
      final delegate = _Delegate();
      await captureEditor(
        tester,
        brightness: brightness,
        name: 'server-editor-custom-colour-$tone',
        delegate: delegate,
        existing: _server(group: 'prod', customColor: '#3A7BD5'),
        answer: () async {
          expect(find.text('prod'), findsOneWidget);
        },
        close: () async {
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(delegate.saved, isNull);
        },
      );
    });
  }
}
