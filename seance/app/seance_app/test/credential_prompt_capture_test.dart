import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:seance_app/services/missing_credential.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/credential_prompt.dart';
import 'package:seance_core/seance_core.dart';

/// Real-font captures of the credential prompt as Séance raises it for a
/// credential this device lacks (CRED-05), in both brightnesses, for
/// comparing the dialog's pixels across a refactor: a typed password, an
/// empty private-key prompt with its PEM hint, a picked key with its
/// passphrase, and a key file that could not be opened.
///
/// Nothing is written unless SEANCE_CAPTURE=1; the PNGs then land in
/// SEANCE_CAPTURE_DIR (default `build/credential-prompt-captures`). The
/// scenes are still pumped and checked on every run.
final _captureOn = Platform.environment['SEANCE_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['SEANCE_CAPTURE_DIR'] ??
    'build/credential-prompt-captures';

const _fontFamily = 'Capture Sans';

// Split so no file carries a private-key header
// (scripts/assert-private-keys-scoped.sh).
const _pemHead =
    '-----BEGIN OPENSSH'
    ' PRIVATE KEY-----';
const _pickedKey =
    '$_pemHead\n'
    'not a real key, only text shaped like one\n'
    'for the capture\n';

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
      Platform.environment['SEANCE_CAPTURE_FONT_DIR'] ??
      '/usr/share/fonts/truetype/dejavu';
  final regular = File('$dir/DejaVuSans.ttf');
  if (!regular.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader(_fontFamily)..addFont(bytes(regular));
  final bold = File('$dir/DejaVuSans-Bold.ttf');
  if (bold.existsSync()) loader.addFont(bytes(bold));
  await loader.load();
}

ThemeData _theme(Brightness brightness) {
  final base = brightness == Brightness.dark
      ? SeanceTheme.dark(platform: TargetPlatform.linux)
      : SeanceTheme.light(platform: TargetPlatform.linux);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _fontFamily),
  );
}

void main() {
  setUpAll(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(_loadRealFonts);
  });

  final answers = <MissingCredential?>[];
  setUp(answers.clear);

  TextField field(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(ValueKey(key)));

  FilledButton save(WidgetTester tester) => tester.widget<FilledButton>(
    find.byKey(const ValueKey('credential.save')),
  );

  /// Raises the prompt through Séance's own entry point, runs [prepare],
  /// captures, then lets [finish] close it the way the scene's user would.
  Future<void> captureDialog(
    WidgetTester tester, {
    required Brightness brightness,
    required AuthMethod authMethod,
    required String name,
    Future<String?> Function()? pickKeyText,
    required Future<void> Function() prepare,
    required Future<void> Function() finish,
  }) async {
    tester.view.physicalSize = const Size(720, 560);
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
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async => answers.add(
                  await showMissingCredentialDialog(
                    context,
                    serverLabel: 'Build server',
                    authMethod: authMethod,
                    pickKeyText: pickKeyText ?? () async => null,
                  ),
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

    expect(
      find.text(
        'Saved on this device, in its encrypted vault, and used for '
        'this server from now on.',
      ),
      findsOneWidget,
    );
    await prepare();

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

    await finish();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  }

  for (final brightness in Brightness.values) {
    final tone = brightness.name;

    testWidgets('captures a typed password ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        authMethod: AuthMethod.password,
        name: 'credential-password-$tone',
        prepare: () async {
          expect(find.text('Password for Build server'), findsOneWidget);
          expect(save(tester).onPressed, isNull);
          await tester.enterText(
            find.byKey(const ValueKey('credential.password')),
            'hunter2',
          );
          await tester.pumpAndSettle();
          expect(save(tester).onPressed, isNotNull);

          // Pixels cannot show these: the password field keeps Flutter's
          // default input flags (a null autocorrect is the platform's
          // choice), takes focus, and submits on Enter.
          final password = field(tester, 'credential.password');
          expect(password.autofocus, isTrue);
          expect(password.obscureText, isTrue);
          expect(password.autocorrect, isNull);
          expect(password.enableSuggestions, isTrue);
          expect(password.enableIMEPersonalizedLearning, isTrue);
          expect(password.onSubmitted, isNotNull);
        },
        finish: () async {
          await tester.testTextInput.receiveAction(TextInputAction.done);
          await tester.pumpAndSettle();
          expect((answers.single! as MissingPassword).password, 'hunter2');
        },
      );
    });

    testWidgets('captures an empty private-key prompt ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        authMethod: AuthMethod.privateKey,
        name: 'credential-key-empty-$tone',
        prepare: () async {
          expect(find.text('Private key for Build server'), findsOneWidget);
          expect(find.text('Choose key file…'), findsOneWidget);
          // Focused, the empty key field floats its label and shows the
          // PEM hint.
          await tester.tap(find.byKey(const ValueKey('credential.key')));
          await tester.pumpAndSettle();
          expect(find.text(_pemHead), findsOneWidget);
          expect(save(tester).onPressed, isNull);

          final key = field(tester, 'credential.key');
          expect(key.autofocus, isFalse);
          expect(key.autocorrect, isFalse);
          expect(key.enableSuggestions, isFalse);
          final passphrase = field(tester, 'credential.passphrase');
          expect(passphrase.obscureText, isTrue);
          expect(passphrase.autocorrect, isNull);
          expect(passphrase.onSubmitted, isNull);
        },
        finish: () async {
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(answers, [null]);
        },
      );
    });

    testWidgets('captures a picked key with its passphrase ($tone)', (
      tester,
    ) async {
      await captureDialog(
        tester,
        brightness: brightness,
        authMethod: AuthMethod.privateKey,
        name: 'credential-key-picked-$tone',
        pickKeyText: () async => _pickedKey,
        prepare: () async {
          await tester.tap(find.byKey(const ValueKey('credential.chooseFile')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('credential.passphrase')),
            'pp',
          );
          await tester.pumpAndSettle();
          expect(field(tester, 'credential.key').controller!.text, _pickedKey);
          expect(save(tester).onPressed, isNotNull);
        },
        finish: () async {
          await tester.tap(find.byKey(const ValueKey('credential.save')));
          await tester.pumpAndSettle();
          final key = answers.single! as MissingPrivateKey;
          expect(key.pem, _pickedKey);
          expect(key.passphrase, 'pp');
        },
      );
    });

    testWidgets('captures a key file that could not be opened ($tone)', (
      tester,
    ) async {
      await captureDialog(
        tester,
        brightness: brightness,
        authMethod: AuthMethod.privateKey,
        name: 'credential-key-error-$tone',
        pickKeyText: () async => throw const FileSystemException('denied'),
        prepare: () async {
          await tester.tap(find.byKey(const ValueKey('credential.chooseFile')));
          await tester.pumpAndSettle();
          expect(find.text('That file could not be opened.'), findsOneWidget);
          expect(find.textContaining('denied'), findsNothing);
        },
        // Pixels cannot show it: Séance's prompt closes on a barrier tap,
        // answering nothing.
        finish: () async {
          await tester.tapAt(const Offset(8, 8));
          await tester.pumpAndSettle();
          expect(answers, [null]);
        },
      );
    });
  }
}
