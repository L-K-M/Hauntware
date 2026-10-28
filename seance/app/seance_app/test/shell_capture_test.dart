import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/adaptive_shell.dart';
import 'package:seance_app/ui/app_menus.dart';
import 'package:seance_app/ui/header_toolbar.dart';
import 'package:seance_app/ui/macos_toolbar_band.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Real-font captures of the whole wide window for visual review: the same
/// shell on Linux, Windows and macOS, with both side panes, with each
/// hidden, light and dark. The macOS scenes draw under the toolbar band,
/// whose traffic lights are native and so not in the picture.
///
/// Nothing is written unless SEANCE_CAPTURE=1; the PNGs then land in
/// SEANCE_CAPTURE_DIR (default `build/shell-captures`). The scenes are
/// still pumped and checked on every run.
final _captureOn = Platform.environment['SEANCE_CAPTURE'] == '1';
final _captureDir =
    Platform.environment['SEANCE_CAPTURE_DIR'] ?? 'build/shell-captures';

const _fontFamily = 'Capture Sans';

/// A prompt and a short listing, for a terminal that looks in use.
const _output =
    '\x1b[1;32mdeploy@box\x1b[0m:\x1b[1;34m~/site\x1b[0m\$ ls\r\n'
    '\x1b[1;34mconfig\x1b[0m  \x1b[1;32mdeploy.sh\x1b[0m  README.md  '
    '\x1b[36mcurrent\x1b[0m\r\n'
    '\x1b[1;32mdeploy@box\x1b[0m:\x1b[1;34m~/site\x1b[0m\$ ';

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

ThemeData _theme(Brightness brightness, TargetPlatform platform) {
  final base = brightness == Brightness.dark
      ? SeanceTheme.dark(platform: platform)
      : SeanceTheme.light(platform: platform);
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: _fontFamily),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: _fontFamily),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  setUpAll(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(_loadRealFonts);
  });

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  ServerConfig server(String id, {int port = 22}) => ServerConfig(
    id: id,
    label: id,
    host: '$id.example.com',
    port: port,
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  Future<void> capture(
    WidgetTester tester, {
    required String name,
    required TargetPlatform platform,
    required Brightness brightness,
    PaneVisibility list = PaneVisibility.shown,
    PaneVisibility utility = PaneVisibility.shown,
  }) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-capture-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory!.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server('web', port: 2222));
      for (final id in ['db', 'cache', 'build', 'backup']) {
        await state!.saveServer(server(id));
      }
    });
    final engine = XtermTerminalEngine();
    engine.feed(Uint8List.fromList(utf8.encode(_output)));
    state!
      ..tabs.add(
        TerminalSession(
            id: 'a',
            serverId: 'web',
            config: server('web', port: 2222),
            engine: engine,
          )
          ..session = _OpenSshSession(engine)
          ..connecting = false,
      )
      ..activeTabId = 'a';
    // Set without a save: the scene only reads them.
    services!.settings
      ..sidebarHidden = list == PaneVisibility.hidden
      ..inspectorHidden = utility == PaneVisibility.hidden;

    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ValueListenable<bool>? band = platform == TargetPlatform.macOS
        ? ValueNotifier(true)
        : null;
    await tester.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: _theme(brightness, platform),
          builder: (context, child) => AppScope(
            state: state!,
            child: withMacosToolbarBand(band, child: child!),
          ),
          home: const AppMenus(child: AdaptiveShell()),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(find.byType(HeaderToolbar), findsOneWidget);
    expect(
      find.byKey(AdaptivePaneLayout.listPaneKey),
      list == PaneVisibility.shown ? findsOneWidget : findsNothing,
    );
    if (_captureOn) {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byType(RepaintBoundary).first,
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
    // Lets the passthrough views' debounce timers run out on macOS.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 50));
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.windows,
    TargetPlatform.macOS,
  ]) {
    for (final brightness in Brightness.values) {
      final scene = '${platform.name}-${brightness.name}';
      testWidgets('captures the window ($scene)', (tester) async {
        await capture(
          tester,
          name: 'shell-$scene',
          platform: platform,
          brightness: brightness,
        );
      });
    }
    testWidgets('captures the window without its sidebar (${platform.name})', (
      tester,
    ) async {
      await capture(
        tester,
        name: 'shell-${platform.name}-no-sidebar',
        platform: platform,
        brightness: Brightness.light,
        list: PaneVisibility.hidden,
      );
    });
    testWidgets('captures the window with the terminal alone '
        '(${platform.name})', (tester) async {
      await capture(
        tester,
        name: 'shell-${platform.name}-terminal-only',
        platform: platform,
        brightness: Brightness.dark,
        list: PaneVisibility.hidden,
        utility: PaneVisibility.hidden,
      );
    });
  }
}

/// Just enough of a live SSH session for the terminal to count as connected.
class _OpenSshSession implements SshSession {
  _OpenSshSession(this.engine);

  @override
  final TerminalEngine engine;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => engine.dispose();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
