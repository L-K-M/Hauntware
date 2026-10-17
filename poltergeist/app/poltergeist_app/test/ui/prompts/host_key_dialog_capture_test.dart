import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/prompts/host_key_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

/// Real-font captures of the host-key prompt as Poltergeist raises it,
/// worded in ARB: first use and a changed key, in both brightnesses, for
/// comparing the dialog's pixels across a refactor.
///
/// Nothing is written unless POLTERGEIST_CAPTURE=1; the PNGs then land in
/// POLTERGEIST_CAPTURE_DIR (default `build/host-key-captures`). The scenes
/// are still pumped and checked on every run.
final _captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ??
    'build/host-key-captures';

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

const _firstUse = HostKeyPromptData(
  host: 'build-server.internal.example.com',
  port: 2222,
  keyType: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8',
);

const _changed = HostKeyPromptData(
  host: 'build-server.internal.example.com',
  port: 2222,
  keyType: 'ssh-ed25519',
  fingerprintSha256: 'SHA256:nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8',
  pinnedFingerprintSha256: 'SHA256:br9jFZiF8YHDvV7cGqJ2Wk9mPq3xLz5tNo4vXaQwR2s',
);

void main() {
  setUpAll(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(_loadRealFonts);
  });

  Future<void> captureDialog(
    WidgetTester tester, {
    required Brightness brightness,
    required HostKeyPromptData data,
    required String name,
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
                onPressed: () => showHostKeyDialog(context, data),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final changed = data.pinnedFingerprintSha256 != null;
    expect(
      find.text(changed ? 'HOST KEY CHANGED' : 'Unknown host key'),
      findsOneWidget,
    );
    expect(find.text('build-server.internal.example.com:2222'), findsOneWidget);
    expect(find.textContaining('ssh-ed25519'), findsNWidgets(changed ? 2 : 1));

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

    testWidgets('captures the first-use prompt ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _firstUse,
        name: 'host-key-first-use-$tone',
      );
    });

    testWidgets('captures the changed-key review ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        data: _changed,
        name: 'host-key-changed-$tone',
      );
    });
  }
}
