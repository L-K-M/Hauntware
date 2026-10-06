import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

/// The strip's own fill and rule, painted behind its tabs.
BoxDecoration _stripBackground(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find
                  .descendant(
                    of: find.byType(TerminalTabStrip),
                    matching: find.byWidgetPredicate(
                      (w) =>
                          w is DecoratedBox &&
                          w.position == DecorationPosition.background,
                    ),
                  )
                  .first,
            )
            .decoration
        as BoxDecoration;

void main() {
  testWidgets('a single session keeps tab actions reachable at phone width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    final tab = TerminalSession(
      id: 'tab',
      serverId: config.id,
      config: config,
      engine: engine,
      connecting: false,
    );
    var newTabCalls = 0;
    var generateCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () => newTabCalls++,
            onGenerateCommand: () => generateCalls++,
          ),
        ),
      ),
    );

    expect(find.text('Session 1'), findsOneWidget);
    expect(find.byTooltip('New tab'), findsOneWidget);
    expect(find.byTooltip('Generate command'), findsOneWidget);

    await tester.tap(find.byTooltip('New tab'));
    await tester.tap(find.byTooltip('Generate command'));
    expect(newTabCalls, 1);
    expect(generateCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('same-place tabs get disambiguating suffixes', (tester) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    TerminalSession tab(String id) {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final t = TerminalSession(
        id: id,
        serverId: config.id,
        config: config,
        engine: engine,
        connecting: false,
        initialMetadata: const SessionMetadata(workingDirectory: '/home/user'),
      );
      addTearDown(t.dispose);
      return t;
    }

    final a = tab('a');
    final b = tab('b');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [a, b],
            activeTabId: a.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
          ),
        ),
      ),
    );

    expect(find.text('user \u00b71'), findsOneWidget);
    expect(find.text('user \u00b72'), findsOneWidget);

    // One tab moves elsewhere: both suffixes disappear on their own.
    b.metadata.value = const SessionMetadata(workingDirectory: '/var/log');
    await tester.pump();
    expect(find.text('user'), findsOneWidget);
    expect(find.text('log'), findsOneWidget);
  });

  testWidgets('an editor tab sits beside terminal tabs in the strip', (
    tester,
  ) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    final terminal = TerminalSession(
      id: 'term',
      serverId: config.id,
      config: config,
      engine: engine,
      connecting: false,
    );
    addTearDown(terminal.dispose);
    final editor = EditorTab(
      id: 'edit',
      serverId: config.id,
      config: config,
      remotePath: '/etc/nginx/nginx.conf',
      localPath: 'nginx.conf',
      ownerEditSessionId: terminal.editSessionId,
    );
    var closed = '';
    var focused = '';

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [terminal, editor],
            activeTabId: editor.id,
            onFocus: (id) => focused = id,
            onClose: (id) => closed = id,
            onNewTab: () {},
            onGenerateCommand: () {},
          ),
        ),
      ),
    );

    // The file's basename labels the tab; the shell keeps its own name.
    expect(find.text('nginx.conf'), findsOneWidget);
    expect(find.text('Session 1'), findsOneWidget);

    // The editor chip's close button doubles as the unsaved marker once the
    // buffer is dirty (the terminal's status dot is also a circle, so the
    // finders are scoped to the editor's chip).
    final editorChip = find.ancestor(
      of: find.text('nginx.conf'),
      matching: find.byType(InkWell),
    );
    expect(
      find.descendant(of: editorChip, matching: find.byIcon(Icons.close)),
      findsOneWidget,
    );
    editor.dirty.value = true;
    await tester.pump();
    expect(
      find.descendant(of: editorChip, matching: find.byIcon(Icons.circle)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: editorChip, matching: find.byIcon(Icons.close)),
      findsNothing,
    );

    // Taps still focus and close by tab id.
    await tester.tap(find.text('Session 1'));
    expect(focused, terminal.id);
    await tester.tap(
      find.descendant(of: editorChip, matching: find.byType(IconButton)),
    );
    expect(closed, editor.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('editor tabs do not consume terminal ordinals', (tester) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      port: 22,
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    TerminalSession term(String id) {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final t = TerminalSession(
        id: id,
        serverId: config.id,
        config: config,
        engine: engine,
        connecting: false,
      );
      addTearDown(t.dispose);
      return t;
    }

    final first = term('term-1');
    final second = term('term-2');
    final editor = EditorTab(
      id: 'edit',
      serverId: config.id,
      config: config,
      remotePath: '/etc/motd',
      localPath: 'motd',
      ownerEditSessionId: first.editSessionId,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            // Terminal, editor, terminal: the editor sits between them in
            // the strip but must not shift the second shell's ordinal.
            tabs: [first, editor, second],
            activeTabId: second.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
          ),
        ),
      ),
    );

    expect(find.text('Session 1'), findsOneWidget);
    expect(find.text('Session 2'), findsOneWidget);
    expect(find.text('Session 3'), findsNothing);
    expect(find.text('motd'), findsOneWidget);
  });

  testWidgets('the server accent rules the strip\'s top edge', (tester) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    final tab = TerminalSession(
      id: 'tab',
      serverId: config.id,
      config: config,
      engine: engine,
      connecting: false,
    );
    addTearDown(tab.dispose);

    Container strip() => tester.widget<Container>(
      find
          .descendant(
            of: find.byType(TerminalTabStrip),
            matching: find.byType(Container),
          )
          .first,
    );
    BorderSide hairline() => _stripBackground(tester).border!.bottom;
    BorderSide? accentLine() =>
        (strip().foregroundDecoration as BoxDecoration?)?.border?.top;

    Future<void> pump(Color? accent) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [tab],
            activeTabId: tab.id,
            onFocus: (_) {},
            onClose: (_) {},
            onNewTab: () {},
            onGenerateCommand: () {},
            accent: accent,
          ),
        ),
      ),
    );

    await pump(null);
    expect(accentLine(), isNull);
    expect(
      hairline().width,
      1,
      reason: 'an uncoloured server keeps the hairline',
    );
    final plainHairline = hairline();
    final plainLabel = tester.getRect(find.text('Session 1'));

    // Over the tabs' top edge, as Poltergeist marks its active pane; the
    // hairline still separates the tabs from the terminal, and the line
    // takes no height from the tabs.
    await pump(const Color(0xFFE03131));
    expect(accentLine()?.color, const Color(0xFFE03131));
    expect(accentLine()?.width, 2);
    expect(hairline(), plainHairline);
    expect(tester.getRect(find.text('Session 1')), plainLabel);
  });
  testWidgets('tabs take Poltergeist\'s pane-tab shape', (tester) async {
    // Disposed at the end of the body: flutter_test checks for live
    // handles before teardowns run, so addTearDown would be too late.
    final semantics = tester.ensureSemantics();
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    TerminalSession session(String id) {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final tab = TerminalSession(
        id: id,
        serverId: config.id,
        config: config,
        engine: engine,
        connecting: false,
      );
      addTearDown(tab.dispose);
      return tab;
    }

    final active = session('one');
    final other = session('two');
    final editor = EditorTab(
      id: 'edit',
      serverId: config.id,
      config: config,
      remotePath: '/etc/motd',
      localPath: 'motd',
      ownerEditSessionId: active.editSessionId,
    )..dirty.value = true;
    final closed = <String>[];
    final theme = SeanceTheme.dark();
    final chrome = theme.extension<SeanceChrome>()!;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: TerminalTabStrip(
            tabs: [active, other, editor],
            activeTabId: active.id,
            onFocus: (_) {},
            onClose: closed.add,
            onNewTab: () {},
            onGenerateCommand: () {},
          ),
        ),
      ),
    );

    expect(_stripBackground(tester).color, chrome.headerBackground);
    BoxDecoration chip(String label) =>
        tester
                .widget<Container>(
                  find
                      .ancestor(
                        of: find.text(label),
                        matching: find.byType(Container),
                      )
                      .first,
                )
                .decoration!
            as BoxDecoration;
    Finder inChip(String label, Finder matching) => find.descendant(
      of: find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
      matching: matching,
    );
    bool closeShown(String label) => tester
        .widget<Visibility>(inChip(label, find.byType(Visibility)))
        .visible;

    // Flat chips, a hairline after each, and no underline: the open tab
    // takes the pane's surface and shows its close button.
    for (final label in ['Session 1', 'Session 2', 'motd']) {
      final border = chip(label).border! as BorderDirectional;
      expect(border.end.color, chrome.separator, reason: label);
      expect(border.bottom, BorderSide.none, reason: label);
    }
    expect(chip('Session 1').color, chrome.paneBackground);
    expect(chip('Session 2').color, isNull);
    // The label colours the contrast test below measures.
    Color? labelColor(String label) =>
        tester.widget<Text>(find.text(label)).style?.color;
    expect(labelColor('Session 1'), theme.colorScheme.onSurface);
    expect(labelColor('Session 2'), chrome.secondaryText);
    expect(closeShown('Session 1'), isTrue);
    expect(closeShown('Session 2'), isFalse);
    // An unsaved file keeps its dot, which is still the close button.
    expect(closeShown('motd'), isTrue);
    expect(inChip('motd', find.byIcon(Icons.circle)), findsOneWidget);

    // Pointing at a tab fills it and offers its close button; the dot
    // turns into the cross.
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('Session 2')));
    await tester.pump();
    expect(chip('Session 2').color, chrome.hoverFill);
    expect(closeShown('Session 2'), isTrue);
    final dotted = tester.getSize(find.text('motd'));
    final chipWidth = tester
        .getSize(
          find.ancestor(of: find.text('motd'), matching: find.byType(InkWell)),
        )
        .width;
    await mouse.moveTo(tester.getCenter(find.text('motd')));
    await tester.pump();
    expect(closeShown('Session 2'), isFalse);
    expect(inChip('motd', find.byIcon(Icons.close)), findsOneWidget);
    // The swap keeps the button's footprint, so the strip does not reflow.
    expect(tester.getSize(find.text('motd')), dotted);
    expect(
      tester
          .getSize(
            find.ancestor(
              of: find.text('motd'),
              matching: find.byType(InkWell),
            ),
          )
          .width,
      chipWidth,
    );

    // So does keyboard focus, and the button stays while focus moves on
    // to it.
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    final tab = Focus.of(tester.element(find.text('Session 2')));
    tab.requestFocus();
    await tester.pump();
    expect(closeShown('Session 2'), isTrue);
    tab.nextFocus();
    await tester.pump();
    expect(
      Focus.of(
        tester.element(inChip('Session 2', find.byIcon(Icons.close))),
      ).hasPrimaryFocus,
      isTrue,
    );
    expect(closeShown('Session 2'), isTrue);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(closeShown('Session 2'), isFalse);

    // A screen reader, which never hovers, closes a tab whose button is
    // hidden through the tab itself.
    tester.semantics.customAction(
      find.semantics.byLabel('Session 2'),
      const CustomSemanticsAction(label: 'Close tab'),
    );
    expect(closed, [other.id]);
    semantics.dispose();
  });

  testWidgets('the open tab joins the pane below the rule', (tester) async {
    final config = ServerConfig(
      id: 'server',
      label: 'Server',
      host: 'example.com',
      username: 'user',
      authMethod: AuthMethod.password,
      createdAt: 0,
      updatedAt: 0,
    );
    TerminalSession session(String id) {
      final engine = XtermTerminalEngine();
      addTearDown(engine.dispose);
      final tab = TerminalSession(
        id: id,
        serverId: config.id,
        config: config,
        engine: engine,
        connecting: false,
      );
      addTearDown(tab.dispose);
      return tab;
    }

    final open = session('one');
    final other = session('two');
    final theme = SeanceTheme.dark();
    final chrome = theme.extension<SeanceChrome>()!;
    final captured = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: RepaintBoundary(
            key: captured,
            child: TerminalTabStrip(
              tabs: [open, other],
              activeTabId: open.id,
              onFocus: (_) {},
              onClose: (_) {},
              onNewTab: () {},
            ),
          ),
        ),
      ),
    );

    // The strip's last pixel row as painted: the rule between the tabs
    // and the pane.
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captured),
    );
    final (pixels, width) = (await tester.runAsync(() async {
      final image = await boundary.toImage();
      try {
        return ((await image.toByteData())!, image.width);
      } finally {
        image.dispose();
      }
    }))!;
    final bottom = boundary.size.height.round() - 1;
    Color pixelAt(Offset global) {
      final x = boundary.globalToLocal(global).dx.round();
      final i = (bottom * width + x) * 4;
      return Color.fromARGB(
        pixels.getUint8(i + 3),
        pixels.getUint8(i),
        pixels.getUint8(i + 1),
        pixels.getUint8(i + 2),
      );
    }

    Offset chipCenter(String label) => tester.getCenter(
      find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
    );

    // The open tab paints over the rule, so it runs on into the pane; the
    // rest of the strip, other tabs and the empty end alike, keeps it.
    expect(pixelAt(chipCenter('Session 1')), chrome.paneBackground);
    expect(pixelAt(chipCenter('Session 2')), chrome.separator);
    expect(
      pixelAt(
        tester.getTopLeft(find.byTooltip('New tab')) - const Offset(8, 0),
      ),
      chrome.separator,
    );
  });
  test('tab labels keep 4.5:1 on the strip, hovered or open', () {
    double contrast(Color a, Color b) {
      final first = a.computeLuminance() + 0.05;
      final second = b.computeLuminance() + 0.05;
      return first > second ? first / second : second / first;
    }

    for (final theme in [SeanceTheme.light(), SeanceTheme.dark()]) {
      final chrome = theme.extension<SeanceChrome>()!;
      final strip = chrome.headerBackground;
      for (final (state, text, background) in [
        ('at rest', chrome.secondaryText, strip),
        (
          'hovered',
          chrome.secondaryText,
          Color.alphaBlend(chrome.hoverFill, strip),
        ),
        ('open', theme.colorScheme.onSurface, chrome.paneBackground),
      ]) {
        expect(
          contrast(text, background),
          greaterThanOrEqualTo(4.5), // WCAG AA for text
          reason: '$state label (${theme.brightness.name})',
        );
      }
    }
  });
}
