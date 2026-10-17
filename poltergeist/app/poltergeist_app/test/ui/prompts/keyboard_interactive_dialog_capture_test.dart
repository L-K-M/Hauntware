import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/prompts/keyboard_interactive_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Real-font captures of the keyboard-interactive prompt as Poltergeist
/// raises it, worded in ARB, in both brightnesses, for comparing the
/// dialog's pixels across a refactor: a server message over two masked
/// answers, an instruction alone over typed answers with one revealed, and
/// a bare IPv6 host with no server message.
///
/// Nothing is written unless POLTERGEIST_CAPTURE=1; the PNGs then land in
/// POLTERGEIST_CAPTURE_DIR (default `build/keyboard-interactive-captures`).
/// The scenes are still pumped and checked on every run.
final _captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    'build/keyboard-interactive-captures';

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

const _withMessage = KeyboardInteractivePromptData(
  host: 'build-server.internal.example.com',
  port: 2222,
  username: 'deploy',
  name: 'Duo Security',
  instruction: 'Enter the code from your authenticator.',
  prompts: ['Password:', 'Verification code:'],
);

const _instructionOnly = KeyboardInteractivePromptData(
  host: 'build-server.internal.example.com',
  port: 2222,
  username: 'deploy',
  name: '',
  instruction: 'Two answers are required.',
  prompts: ['Password:', 'Verification code:'],
);

const _ipv6 = KeyboardInteractivePromptData(
  host: '2001:db8::1',
  port: 2222,
  username: 'deploy',
  name: '',
  instruction: '',
  prompts: ['Password:'],
);

void main() {
  setUpAll(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(_loadRealFonts);
  });

  Future<void> captureDialog(
    WidgetTester tester, {
    required Brightness brightness,
    required KeyboardInteractivePromptData data,
    required String name,
    required Future<void> Function() answer,
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
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showKeyboardInteractiveDialog(context, data),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await answer();

    expect(find.text('Authentication'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(data.prompts.length));
    final hasMessage = data.name.isNotEmpty || data.instruction.isNotEmpty;
    expect(
      find.text('Server message'),
      hasMessage ? findsOneWidget : findsNothing,
    );
    // Pixels cannot show it: Enter advances through the answers and
    // submits from the last.
    final actions = [
      for (final field in tester.widgetList<TextField>(find.byType(TextField)))
        field.textInputAction,
    ];
    expect(actions.last, TextInputAction.done);
    expect(
      actions.sublist(0, actions.length - 1),
      everyElement(TextInputAction.next),
    );

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

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  }

  for (final brightness in Brightness.values) {
    final tone = brightness.name;

    testWidgets('captures a server message over masked answers ($tone)', (
      tester,
    ) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _withMessage,
        name: 'keyboard-message-$tone',
        answer: () async {
          expect(
            find.text('deploy@build-server.internal.example.com:2222'),
            findsOneWidget,
          );
        },
      );
    });

    testWidgets('captures typed answers with one revealed ($tone)', (
      tester,
    ) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _instructionOnly,
        name: 'keyboard-revealed-$tone',
        answer: () async {
          await tester.enterText(find.byType(TextField).at(0), 'hunter2');
          await tester.enterText(find.byType(TextField).at(1), '493017');
          await tester.tap(find.byTooltip('Show answer').at(1));
          await tester.pumpAndSettle();

          final fields = tester
              .widgetList<TextField>(find.byType(TextField))
              .toList();
          expect(fields.map((field) => field.obscureText), [true, false]);
        },
      );
    });

    testWidgets('captures a bracketed IPv6 endpoint ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _ipv6,
        name: 'keyboard-ipv6-$tone',
        answer: () async {
          expect(find.text('deploy@[2001:db8::1]:2222'), findsOneWidget);
        },
      );
    });
  }
}
