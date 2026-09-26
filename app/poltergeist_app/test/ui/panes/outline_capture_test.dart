import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/test_panes.dart';

/// Real-font captures of folders opened in place (02 §2.5) for visual
/// review. The widget-test default font renders hollow boxes, so the
/// capture loads a real face when the host provides one — set
/// POLTERGEIST_CAPTURE_FONT_DIR or rely on the DejaVu fallback. The PNGs
/// land in tasks/outline/ at the repo root (or
/// POLTERGEIST_CAPTURE_DIR), gated on POLTERGEIST_CAPTURE=1 like the
/// other captures, so an ordinary test run writes nothing.
final _captureDir =
    Platform.environment['POLTERGEIST_CAPTURE_DIR'] ?? '../../tasks/outline';

Future<ByteData> _fontBytes(String path) async {
  final bytes = File(path).readAsBytesSync();
  return ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes);
}

/// Registers a readable face under the names the theme resolves: the
/// default family name for body text plus the mono fallback chain the
/// row metrics style reaches for.
Future<void> _loadRealFonts() async {
  final dir =
      Platform.environment['POLTERGEIST_CAPTURE_FONT_DIR'] ??
      '${Platform.environment['HOME']}/.local/share/fonts';
  final sans = File('$dir/DejaVuSans.ttf');
  final sansBold = File('$dir/DejaVuSans-Bold.ttf');
  final mono = File('$dir/DejaVuSansMono.ttf');
  if (!sans.existsSync()) return; // boxes are still a usable capture
  final loader = FontLoader('DejaVu Sans')..addFont(_fontBytes(sans.path));
  if (sansBold.existsSync()) loader.addFont(_fontBytes(sansBold.path));
  await loader.load();
  if (mono.existsSync()) {
    final monoLoader = FontLoader('DejaVu Sans Mono')
      ..addFont(_fontBytes(mono.path));
    await monoLoader.load();
  }
  // Kind glyphs are MaterialIcons codepoints: without the icon font they
  // rasterize as tofu boxes. It ships inside the Flutter SDK.
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}'
    '/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (icons.existsSync()) {
    final iconsLoader = FontLoader('MaterialIcons')
      ..addFont(_fontBytes(icons.path));
    await iconsLoader.load();
  }
}

RemoteFileEntry _entry(
  String parent,
  String name, {
  RemoteFileType type = RemoteFileType.file,
  int? size,
}) => RemoteFileEntry(
  path: '$parent/$name',
  name: name,
  type: type,
  size: size,
  modifiedAt: DateTime(2026, 9, 20, 14, 5),
);

void main() {
  testWidgets('captures folders opened in place, with nested selections', (
    tester,
  ) async {
    await tester.runAsync(_loadRealFonts);
    // Desktop rows: touch rows (the test host's default) never expand.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await _captureOutline(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

Future<void> _captureOutline(WidgetTester tester) async {
  const home = '/Users/lukas';
  final lanes = controller_test.FakePaneLanes();
  final channel = controller_test.FakePaneChannel(home);
  const dir = RemoteFileType.directory;
  channel.listings[home] = [
    _entry(home, '.cache', type: dir),
    _entry(home, '.cargo', type: dir),
    _entry(home, '.claude', type: dir),
    _entry(home, '.docker', type: dir),
    _entry(home, 'Downloads', type: dir),
    _entry(home, 'Trash', type: dir),
    _entry(home, '.claude.json', size: 18230),
    _entry(home, '.zsh_history', size: 94012),
    _entry(home, 'notes.txt', size: 640),
  ];
  channel.listings['$home/.cache'] = [
    _entry('$home/.cache', 'codex-runtimes', type: dir),
    _entry('$home/.cache', 'gh', type: dir),
    _entry('$home/.cache', 'pip.log', size: 4210),
  ];
  channel.listings['$home/.cache/codex-runtimes'] = [
    _entry('$home/.cache/codex-runtimes', 'node-22', type: dir),
    _entry('$home/.cache/codex-runtimes', 'manifest.json', size: 812),
  ];
  lanes.nextLocalChannel = channel;

  final left = PaneController(paneTabId: 'pane.left', lanes: lanes);
  final right = PaneController(paneTabId: 'pane.right', lanes: lanes);
  final workspace = WorkspaceController(
    left: testPaneStrip(left),
    right: testPaneStrip(right),
  );
  addTearDown(workspace.dispose);
  final leftNode = FocusNode();
  addTearDown(leftNode.dispose);

  await left.openLocalHome();
  await tester.pump();
  left.showHidden = true;

  tester.view.physicalSize = const Size(620, 330);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final base = buildPoltergeistTheme(Brightness.light);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: 'DejaVu Sans'),
    primaryTextTheme: base.primaryTextTheme.apply(fontFamily: 'DejaVu Sans'),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: RepaintBoundary(
          key: const ValueKey('capture.pane'),
          child: PaneView(
            controller: left,
            pane: workspace.left,
            workspace: workspace,
            focusNode: leftNode,
            onSwapFocus: () {},
            onCancelRecovery: () {},
            clock: () => DateTime(2026, 9, 26, 12),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  leftNode.requestFocus();
  await tester.pump();

  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('capture.pane')),
  );
  final captureOn = Platform.environment['POLTERGEIST_CAPTURE'] == '1';
  final outDir = Directory(_captureDir);
  if (captureOn) outDir.createSync(recursive: true);

  Future<void> capture(String name) async {
    if (!captureOn) return;
    await tester.pump(const Duration(milliseconds: 200));
    final bytes = (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    }))!;
    File('${outDir.path}/$name.png').writeAsBytesSync(bytes);
  }

  int rowOf(String name) => left.entries.indexWhere((e) => e.name == name);

  await capture('outline-closed');

  left.expandAt(rowOf('.cache'));
  await tester.pump();
  left.expandAt(rowOf('codex-runtimes'));
  await tester.pump();

  // The owner's second screenshot: .docker, .cache and a row inside
  // .cache selected — the inner row rides with its folder.
  left.setCursorIndex(rowOf('.cache'));
  left.setCursorIndex(rowOf('.docker'), update: SelectionUpdate.toggle);
  left.setCursorIndex(rowOf('codex-runtimes'), update: SelectionUpdate.toggle);
  expect([for (final e in left.selectedRoots) e.name], ['.cache', '.docker']);
  await capture('outline-folder-and-child-selected');

  // The third: .docker and the inner row, .cache not selected — both
  // are roots.
  left.setCursorIndex(rowOf('.docker'));
  left.setCursorIndex(rowOf('codex-runtimes'), update: SelectionUpdate.toggle);
  expect(
    [for (final e in left.selectedRoots) e.name],
    ['codex-runtimes', '.docker'],
  );
  await capture('outline-child-selected');
}
