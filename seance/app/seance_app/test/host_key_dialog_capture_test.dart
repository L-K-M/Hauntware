import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/host_key_dialog.dart';
import 'package:seance_core/seance_core.dart';

/// Real-font captures of the host-key prompt as Séance raises it: first use
/// and a changed key, in both brightnesses, for comparing the dialog's
/// pixels across a refactor. The changed key's pinned type differs from the
/// presented one, so the review labels each fingerprint with its own type.
///
/// Nothing is written unless SEANCE_CAPTURE=1; the PNGs then land in
/// SEANCE_CAPTURE_DIR (default `build/host-key-captures`). The scenes are
/// still pumped and checked on every run.
final _captureOn = Platform.environment['SEANCE_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['SEANCE_CAPTURE_DIR'] ?? 'build/host-key-captures';

const _fontFamily = 'Capture Sans';

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

HostKey _key(String type, String fingerprint) => HostKey(
  host: 'build-server.internal.example.com',
  port: 22,
  type: type,
  fingerprintSha256: 'SHA256:$fingerprint',
  pinnedAt: 0,
);

final _presented = _key(
  'ssh-ed25519',
  'nThbg6kXUpJWGl7E1IGOCspRomTxdCARLviKw6E5SY8',
);
final _pinned = _key('ssh-rsa', 'br9jFZiF8YHDvV7cGqJ2Wk9mPq3xLz5tNo4vXaQwR2s');

void main() {
  setUpAll(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(_loadRealFonts);
  });

  Future<void> captureDialog(
    WidgetTester tester, {
    required Brightness brightness,
    required HostKeyDecision decision,
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
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showHostKeyDialog(context, decision),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    if (decision.isChanged) {
      expect(find.text('HOST KEY CHANGED'), findsOneWidget);
      expect(find.textContaining('ssh-rsa'), findsOneWidget);
    } else {
      expect(find.text('Unknown host key'), findsOneWidget);
      expect(find.textContaining('ssh-rsa'), findsNothing);
    }
    expect(find.textContaining('ssh-ed25519'), findsOneWidget);

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
        decision: HostKeyDecision(
          verdict: HostKeyVerdict.firstUse,
          presented: _presented,
        ),
        name: 'host-key-first-use-$tone',
      );
    });

    testWidgets('captures the changed-key review ($tone)', (tester) async {
      await captureDialog(
        tester,
        brightness: brightness,
        decision: HostKeyDecision(
          verdict: HostKeyVerdict.changed,
          presented: _presented,
          pinned: _pinned,
        ),
        name: 'host-key-changed-$tone',
      );
    });
  }
}
