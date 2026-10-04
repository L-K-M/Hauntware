import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/sidebar/sidebar_kit.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

void main() {
  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.windows,
  ]) {
    for (final scale in [1.0, 2.0, 4.0]) {
      testWidgets('workspace footers align on $platform at $scale×', (
        tester,
      ) async {
        final engine = XtermTerminalEngine();
        addTearDown(engine.dispose);
        final config = ServerConfig(
          id: 'server',
          label: 'Production',
          host: '192.168.1.5',
          username: 'truenas_admin',
          createdAt: 0,
          updatedAt: 0,
        );
        final session = TerminalSession(
          id: 'session',
          serverId: config.id,
          config: config,
          engine: engine,
          connecting: false,
        );
        addTearDown(session.dispose);
        await tester.binding.setSurfaceSize(const Size(1600, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: SeanceTheme.dark(platform: platform),
            home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: Row(
                  children: [
                    SizedBox(
                      width: 400,
                      child: Column(
                        children: [
                          const Expanded(child: SizedBox.shrink()),
                          SidebarKitScope(
                            strings: SidebarKitStrings(
                              sectionSemantics: (title, count) => title,
                              showSection: 'Show',
                              hideSection: 'Hide',
                              filterHint: 'Filter',
                              filterClear: 'Clear',
                              addMenu: 'Add',
                              settings: 'Settings',
                              rowMenu: 'More',
                              compactRows: 'Compact',
                              comfortableRows: 'Comfortable',
                            ),
                            child: SidebarBottomBar(
                              addEntries: () => [],
                              sync: const SidebarSyncChipData(
                                label: 'Synced · 4 min',
                                tone: SidebarSyncTone.normal,
                              ),
                              onSettings: () {},
                              onDensityChanged: (_) {},
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          const Expanded(child: SizedBox.shrink()),
                          SessionStatusBar(session: session),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );

        expect(tester.takeException(), isNull);
        final sidebar = tester.getRect(find.byType(SidebarBottomBar));
        final terminal = tester.getRect(find.byType(SessionStatusBar));
        expect(terminal.height, sidebar.height);
        expect(terminal.top, sidebar.top);
        expect(terminal.bottom, sidebar.bottom);
      });
    }
  }

  testWidgets('short targets leave the remaining width for cwd', (tester) async {
    final engine = XtermTerminalEngine();
    addTearDown(engine.dispose);
    final cwd = '/srv/${'segment/' * 8}application';
    final config = ServerConfig(
      id: 'server', label: 'Database', host: 'db01', username: 'ops',
      createdAt: 0, updatedAt: 0,
    );
    final session = TerminalSession(
      id: 'session', serverId: config.id, config: config, engine: engine,
      connecting: false,
      initialMetadata: SessionMetadata(workingDirectory: cwd),
    );
    addTearDown(session.dispose);
    await tester.binding.setSurfaceSize(const Size(1200, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: Center(child: SessionStatusBar(session: session)),
    )));

    expect(tester.takeException(), isNull);
    expect(find.text('ops@db01:22'), findsOneWidget);
    expect(find.text(cwd), findsOneWidget);
  });

  for (final width in [240.0, 320.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final cwd in <String?>[null, '/srv/production/application/logs']) {
        testWidgets('footer fits $width px at $scale× with cwd=$cwd', (
          tester,
        ) async {
          final engine = XtermTerminalEngine();
          addTearDown(engine.dispose);
          final config = ServerConfig(
            id: 'server',
            label: 'Production',
            host: 'production-application.eu-west-1.internal.example.com',
            username: 'deployment-operator',
            authMethod: AuthMethod.password,
            createdAt: 0,
            updatedAt: 0,
          );
          final session = TerminalSession(
            id: 'session',
            serverId: config.id,
            config: config,
            engine: engine,
            connecting: false,
            initialMetadata: SessionMetadata(workingDirectory: cwd),
          );
          addTearDown(session.dispose);
          final target = '${config.username}@${config.host}:${config.port}';

          await tester.pumpWidget(
            MaterialApp(
              home: MediaQuery(
                data: MediaQueryData(textScaler: TextScaler.linear(scale)),
                child: Scaffold(
                  body: Center(
                    child: SizedBox(
                      width: width,
                      child: SessionStatusBar(session: session),
                    ),
                  ),
                ),
              ),
            ),
          );

          expect(tester.takeException(), isNull);
          expect(find.byTooltip(target), findsOneWidget);
          final visibleTarget = tester.widget<Text>(find.descendant(
            of: find.byTooltip(target),
            matching: find.byType(Text),
          ));
          expect(visibleTarget.data, contains('…'));
          final parts = visibleTarget.data!.split('…');
          expect(parts, hasLength(2));
          expect(parts.every((part) => part.isNotEmpty), isTrue);
          expect(target, startsWith(parts.first));
          expect(target, endsWith(parts.last));
          expect(find.bySemanticsLabel(target), findsOneWidget);
          if (scale > 1) {
            expect(
              tester.getSize(find.byType(SessionStatusBar)).height,
              greaterThan(24),
            );
          }
          if (cwd != null) {
            expect(find.bySemanticsLabel(cwd), findsOneWidget);
          }
        }, semanticsEnabled: true);
      }
    }
  }
}
