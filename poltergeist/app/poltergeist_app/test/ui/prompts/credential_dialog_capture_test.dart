import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/identity_file_reader.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/prompts/credential_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Real-font captures of the connect-time credential prompt as Poltergeist
/// raises it, worded in ARB, in both brightnesses, for comparing the
/// dialog's pixels across a refactor: a typed password, the vault offer
/// ticked, the unavailable-vault banner, a prefilled identity file, a
/// failed read, an empty path and the spinner of a read in flight.
///
/// Nothing is written unless POLTERGEIST_CAPTURE=1; the PNGs then land in
/// POLTERGEIST_CAPTURE_DIR (default `build/credential-captures`). The
/// scenes are still pumped and checked on every run.
final _captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    'build/credential-captures';

const _fontFamily = 'DejaVu Sans';

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
  // the theme; FontLoader alone cannot reach default-styled text. The
  // desktop dialog title carries a style of its own.
  final base = buildPoltergeistTheme(
    brightness,
    platform: TargetPlatform.linux,
  );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _fontFamily),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: base.dialogTheme.titleTextStyle?.apply(
        fontFamily: _fontFamily,
      ),
    ),
  );
}

const _endpoint = 'deploy@build-server.internal.example.com:2222';

const _password = CredentialPromptData(
  host: 'build-server.internal.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.password,
);

const _passwordWithRef = CredentialPromptData(
  host: 'build-server.internal.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.password,
  secretRef: 'build-server',
);

const _identityFile = CredentialPromptData(
  host: 'build-server.internal.example.com',
  port: 2222,
  username: 'deploy',
  authMethod: AuthMethod.privateKey,
  identityFilePath: '~/.ssh/id_ed25519',
  secretRef: 'build-server',
);

Future<String> _readsKey(String path) async => 'PEM';

/// Every field's input flags; pixels cannot show them.
void _expectSecretFieldsPrivate(WidgetTester tester) {
  final secrets = tester
      .widgetList<TextField>(find.byType(TextField))
      .where((field) => field.obscureText);
  expect(secrets, isNotEmpty);
  for (final field in secrets) {
    expect(field.autocorrect, isFalse);
    expect(field.enableSuggestions, isFalse);
    expect(field.enableIMEPersonalizedLearning, isFalse);
  }
}

void main() {
  setUpAll(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(_loadRealFonts);
  });

  /// Opens the prompt for [data], lets [answer] act on it, checks the
  /// common face, writes the capture, then lets [close] end the dialog and
  /// check the answer it produced.
  Future<void> captureDialog(
    WidgetTester tester, {
    required Brightness brightness,
    required CredentialPromptData data,
    required String name,
    Future<String> Function(String path) readKeyFile = _readsKey,
    bool vaultUnavailable = false,
    Future<void> Function()? answer,
    required Future<void> Function(Future<CredentialDialogResult?> result)
    close,
  }) async {
    tester.view.physicalSize = const Size(720, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Future<CredentialDialogResult?> result;
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
                onPressed: () => result = showCredentialDialog(
                  context,
                  data,
                  readKeyFile: readKeyFile,
                  vaultUnavailable: vaultUnavailable,
                ),
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

    expect(find.text('Authentication required'), findsOneWidget);
    expect(find.text(_endpoint), findsOneWidget);
    _expectSecretFieldsPrivate(tester);

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

    await close(result);
    expect(find.text('Authentication required'), findsNothing);
  }

  Future<void> cancels(
    WidgetTester tester,
    Future<CredentialDialogResult?> result,
  ) async {
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await result, isNull);
  }

  for (final brightness in Brightness.values) {
    final tone = brightness.name;

    testWidgets('captures a typed password ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _password,
        name: 'credential-password-$tone',
        answer: () async {
          await tester.enterText(find.byType(TextField), 'hunter2');
          await tester.pumpAndSettle();
          expect(find.byType(CheckboxListTile), findsNothing);
        },
        close: (result) async {
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          final answer = (await result)!;
          expect(answer.password, 'hunter2');
          expect(answer.privateKeyPem, isNull);
          expect(answer.keyPassphrase, isNull);
          expect(answer.saveToVault, isFalse);
        },
      );
    });

    testWidgets('captures the vault offer ticked ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _passwordWithRef,
        name: 'credential-password-save-$tone',
        answer: () async {
          await tester.enterText(find.byType(TextField), 'hunter2');
          await tester.tap(find.byType(CheckboxListTile));
          await tester.pumpAndSettle();
        },
        close: (result) async {
          await tester.tap(find.text('Connect'));
          await tester.pumpAndSettle();
          final answer = (await result)!;
          expect(answer.password, 'hunter2');
          expect(answer.saveToVault, isTrue);
        },
      );
    });

    testWidgets('captures an unavailable vault ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _passwordWithRef,
        vaultUnavailable: true,
        name: 'credential-vault-unavailable-$tone',
        answer: () async {
          expect(
            find.textContaining('Saved secrets are unavailable.'),
            findsOneWidget,
          );
          expect(find.byType(CheckboxListTile), findsNothing);
        },
        close: (result) => cancels(tester, result),
      );
    });

    testWidgets('captures a prefilled identity file ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _identityFile,
        name: 'credential-key-$tone',
        answer: () async {
          expect(find.text('~/.ssh/id_ed25519'), findsOneWidget);
          await tester.enterText(
            find.widgetWithText(TextField, 'Passphrase'),
            'open sesame',
          );
          await tester.pumpAndSettle();
        },
        close: (result) async {
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          final answer = (await result)!;
          expect(answer.password, isNull);
          expect(answer.privateKeyPem, 'PEM');
          expect(answer.keyPassphrase, 'open sesame');
          expect(answer.saveToVault, isFalse);
        },
      );
    });

    testWidgets('captures a failed identity file read ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _identityFile,
        name: 'credential-key-error-$tone',
        readKeyFile: (path) async => throw IdentityFileReadException(
          path,
          FileSystemException('No such file', path),
        ),
        answer: () async {
          await tester.tap(find.text('Connect'));
          await tester.pumpAndSettle();
          expect(
            find.text(
              'Could not read the key file: No such file (~/.ssh/id_ed25519)',
            ),
            findsOneWidget,
          );
        },
        close: (result) => cancels(tester, result),
      );
    });

    testWidgets('captures an empty identity file path ($tone)', (tester) async {
      var reads = 0;
      await captureDialog(
        tester,
        brightness: brightness,
        data: _identityFile,
        name: 'credential-key-required-$tone',
        readKeyFile: (path) async {
          reads++;
          return 'PEM';
        },
        answer: () async {
          await tester.enterText(
            find.widgetWithText(TextField, 'Key file'),
            '',
          );
          await tester.tap(find.text('Connect'));
          await tester.pumpAndSettle();
          expect(find.text('Choose a key file.'), findsOneWidget);
          expect(reads, 0);
        },
        close: (result) => cancels(tester, result),
      );
    });

    testWidgets('captures a read in flight ($tone)', (tester) async {
      final read = Completer<String>();
      await captureDialog(
        tester,
        brightness: brightness,
        data: _identityFile,
        name: 'credential-key-reading-$tone',
        readKeyFile: (path) => read.future,
        answer: () async {
          await tester.tap(find.text('Connect'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          expect(find.text('Connect'), findsNothing);
          final connect = tester.widget<FilledButton>(
            find.byType(FilledButton),
          );
          expect(connect.onPressed, isNull);
        },
        close: (result) async {
          read.complete('PEM');
          await tester.pumpAndSettle();
          final answer = (await result)!;
          expect(answer.privateKeyPem, 'PEM');
          expect(answer.keyPassphrase, isNull);
        },
      );
    });
  }
}
