import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/theme/theme_presets.dart';
import 'package:seance_app/ui/terminal_appearance.dart';
import 'package:seance_app/ui/terminal_keyboard_bar.dart';
import 'package:seance_core/seance_core.dart';
import 'package:xterm/xterm.dart' show TerminalView;

/// Real-font captures of the terminal as Séance draws it (03 D3; the
/// `seance_terminal` move, docs/design/seance-terminal.md 9.2): a
/// `TerminalView` over an engine fed fixed ANSI output, in the built-in
/// dark and light palettes and a theme's own palette, with ligatures on
/// and off, under the keyboard bar with Ctrl armed and not. Run on the
/// old code and on the new, the PNGs make a before/after pair.
///
/// Nothing is written unless SEANCE_CAPTURE=1; the PNGs then land in
/// SEANCE_CAPTURE_DIR (default `build/terminal-captures`), each name
/// prefixed with SEANCE_CAPTURE_PREFIX. The scenes are still pumped and
/// checked on every run.
final _captureOn = Platform.environment['SEANCE_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['SEANCE_CAPTURE_DIR'] ?? 'build/terminal-captures';
final _prefix = Platform.environment['SEANCE_CAPTURE_PREFIX'] ?? '';

const _fontFamily = 'Capture Sans';

/// A prompt, a coloured listing, bold and underlined text, and ligature
/// candidates (`->`, `=>`, `!=`), the cursor left after the prompt.
const _output =
    '\x1b[1;32mada@build\x1b[0m:\x1b[1;34m~/src\x1b[0m\$ ls --color\r\n'
    '\x1b[1;34mbin\x1b[0m  \x1b[1;32mdeploy.sh\x1b[0m  README.md  '
    '\x1b[31mcore.dump\x1b[0m  \x1b[36mlink\x1b[0m\r\n'
    '\x1b[1mbold\x1b[0m \x1b[4munderlined\x1b[0m \x1b[7minverse\x1b[0m '
    '\x1b[33myellow\x1b[0m \x1b[35mmagenta\x1b[0m \x1b[90mgrey\x1b[0m\r\n'
    'a -> b => c != d <= e >= f\r\n'
    '\x1b[1;32mada@build\x1b[0m:\x1b[1;34m~/src\x1b[0m\$ ';

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

  Future<void> captureTerminal(
    WidgetTester tester, {
    required String name,
    required Brightness brightness,
    required TerminalPalette palette,
    required TerminalLigatures ligatures,
    bool themeColors = false,
    bool ctrlArmed = false,
  }) async {
    tester.view.physicalSize = const Size(720, 360);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = XtermTerminalEngine(initialSize: const TerminalSize(80, 12));
    addTearDown(engine.dispose);
    engine.feed(Uint8List.fromList(utf8.encode(_output)));
    if (ctrlArmed) engine.toggleCtrl();

    final appearance = TerminalAppearance.of(
      fontSize: kDefaultTerminalFontSize,
      fontFamily: '',
      ligatures: ligatures,
      palette: palette,
      themeColors: themeColors ? ThemePresets.paper.terminal : null,
      brightness: brightness,
    );

    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(brightness),
          home: Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: TerminalView(
                    engine.terminal,
                    textStyle: appearance.style,
                    theme: appearance.theme,
                    keyboardAppearance: appearance.brightness,
                    shortcuts: const <ShortcutActivator, Intent>{},
                    padding: const EdgeInsets.all(6),
                  ),
                ),
                TerminalKeyboardBar(engine: engine),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(engine.terminal.buffer.lines[3].toString(), startsWith('a -> b'));
    expect(engine.ctrlArmed.value, ctrlArmed);
    expect(find.byType(TerminalKeyboardBar), findsOneWidget);

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
      File('$_captureDir/$_prefix$name.png').writeAsBytesSync(png);
    }
  }

  for (final brightness in Brightness.values) {
    final tone = brightness.name;

    testWidgets('captures the built-in palette ($tone)', (tester) async {
      await captureTerminal(
        tester,
        name: 'terminal-built-in-$tone',
        brightness: brightness,
        palette: TerminalPalette.followApp,
        ligatures: TerminalLigatures.on,
      );
    });

    testWidgets('captures ligatures off ($tone)', (tester) async {
      await captureTerminal(
        tester,
        name: 'terminal-no-ligatures-$tone',
        brightness: brightness,
        palette: TerminalPalette.followApp,
        ligatures: TerminalLigatures.off,
      );
    });

    testWidgets('captures Ctrl armed ($tone)', (tester) async {
      await captureTerminal(
        tester,
        name: 'terminal-ctrl-armed-$tone',
        brightness: brightness,
        palette: TerminalPalette.followApp,
        ligatures: TerminalLigatures.on,
        ctrlArmed: true,
      );
    });
  }

  testWidgets('captures a theme palette', (tester) async {
    await captureTerminal(
      tester,
      name: 'terminal-theme-paper',
      brightness: Brightness.light,
      palette: TerminalPalette.followApp,
      ligatures: TerminalLigatures.on,
      themeColors: true,
    );
  });

  testWidgets('captures a pinned dark palette in a light app', (tester) async {
    await captureTerminal(
      tester,
      name: 'terminal-always-dark',
      brightness: Brightness.light,
      palette: TerminalPalette.alwaysDark,
      ligatures: TerminalLigatures.on,
    );
  });
}
