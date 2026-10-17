import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/logs/log_query.dart';
import 'package:klabautermann_app/ui/logs/log_view.dart';
import 'package:klabautermann_app/ui/logs/logs_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../support/charts.dart'
    show chartTheme, goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import '../support/fake_engine.dart';
import '../support/harness.dart';

const _wide = Size(1280, 800);
const _phone = Size(390, 800);

final class _Panel {
  _Panel(this.engine);

  final FakeEngineClient engine;

  List<OpenLogStream> get opens =>
      engine.sentOfType<OpenLogStream>().cast<OpenLogStream>();

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  /// A running follow that delivered [_entries], on a server whose
  /// account sees only its own journal entries.
  Future<void> running(WidgetTester tester) async {
    final id = opens.last.streamId;
    await emit(tester, HostProfileChanged('srv-1', _limited));
    await emit(tester, LogStreamState(id, const LogStreamRunning()));
    await emit(tester, LogBatch(streamId: id, records: _entries));
  }
}

final _limited = HostProfile.fromJson({
  'uid': 1000,
  'groups': ['users'],
  'tools': {'journalctl': '/usr/bin/journalctl'},
  'areaStatuses': {'identity': 'ok'},
});

final _entries = [
  for (final (n, unit, priority, message) in [
    (1, 'nginx.service', 6, 'GET /healthz 200'),
    (2, 'nginx.service', 4, 'upstream timed out, retrying'),
    (3, 'sshd.service', 6, 'Accepted publickey for deploy'),
    (4, 'backup.service', 3, 'rsync: connection unexpectedly closed'),
  ])
    JournalRecord(
      cursor: 's=$n',
      fields: {
        '_SYSTEMD_UNIT': unit,
        '_PID': '${100 + n}',
        'PRIORITY': '$priority',
        'MESSAGE': message,
      },
    ),
];

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  double textScale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine);
  addTearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: chartTheme(brightness, fontFamily: goldenFontFamily),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: LogsPanel(
            monitoring: monitoring,
            serverId: 'srv-1',
            visible: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine);
}

Finder _chip(String word) =>
    find.descendant(of: find.byType(FilterChip), matching: find.text(word));

Finder _row(String text) => find.textContaining(text, findRichText: true);

const _notice = 'Only your own journal entries';

/// 03 §10.4 and §10.8's Logs panel: LOG-01 to LOG-05 and LOG-22 over the
/// protocol's log streams (K16b), before the engine serves them.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  testWidgets('the workspace\'s Logs tab follows only while selected', (
    tester,
  ) async {
    final harness = await pumpApp(tester, servers: twoServers);
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();
    final open = harness.engine.sentOfType<OpenLogStream>().single;
    expect((open as OpenLogStream).spec.serverId, 'srv-1');

    await tester.tap(find.text('Overview'));
    await tester.pumpAndSettle();
    final close = harness.engine.sentOfType<CloseStream>().single;
    expect((close as CloseStream).streamId, open.streamId);
  });

  testWidgets('says the engine did not open the log, and retries', (
    tester,
  ) async {
    final panel = await _pump(tester);
    expect(_chip('Connecting'), findsOneWidget);
    expect(find.text('Opening the log…'), findsOneWidget);

    await panel.emit(
      tester,
      const RequestRejected('OpenLogStream', 'not implemented yet'),
    );
    expect(_chip('Unavailable'), findsOneWidget);
    expect(find.text('The engine did not open this log.'), findsOneWidget);
    expect(find.textContaining('not implemented'), findsNothing);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    await panel.emit(
      tester,
      LogStreamState(
        panel.opens.last.streamId,
        const LogStreamWaiting(LogStreamWaitReason.link),
      ),
    );
    expect(_chip('Disconnected'), findsOneWidget);
    expect(
      find.text('Waiting for the connection to the server.'),
      findsOneWidget,
    );
  });

  testWidgets('says lines may be missing when a file follow runs again '
      'after it waited', (tester) async {
    const gap =
        'Following again. Lines written while it was paused or '
        'disconnected may be missing.';
    final panel = await _pump(tester);
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Common paths'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/var/log/nginx/error.log'));
    await tester.pumpAndSettle();
    final id = panel.opens.last.streamId;

    await panel.emit(tester, LogStreamState(id, const LogStreamRunning()));
    expect(find.text(gap), findsNothing);
    await panel.emit(
      tester,
      LogStreamState(id, const LogStreamRunning(continuity: LogContinuity.gap)),
    );
    expect(_chip('Live'), findsOneWidget);
    expect(find.text(gap), findsOneWidget);
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.text('Retry'), findsNothing);

    await panel.emit(
      tester,
      LogStreamState(id, const LogStreamWaiting(LogStreamWaitReason.link)),
    );
    expect(find.text(gap), findsNothing);
  });

  testWidgets('shows journal rows with LOG-04\'s notice, searches them and '
      'pauses on the Live chip', (tester) async {
    final panel = await _pump(tester);
    expect(find.textContaining(_notice), findsNothing);
    await panel.running(tester);
    expect(_chip('Live'), findsOneWidget);
    expect(_row('upstream timed out'), findsOneWidget);
    expect(find.textContaining(_notice), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'nginx');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));
    expect(find.text('2 matches'), findsOneWidget);
    await tester.tap(find.byTooltip('Next match'));
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOneWidget);

    await tester.tap(_chip('Live'));
    await tester.pumpAndSettle();
    expect(_chip('Paused'), findsOneWidget);
    expect(panel.engine.sentOfType<CloseStream>(), hasLength(1));
    expect(_row('upstream timed out'), findsOneWidget);
    await tester.tap(_chip('Paused'));
    await tester.pumpAndSettle();
    expect(panel.opens.last.spec.afterCursor, 's=4');

    // The notice is the journal's; a file is read with the file's rights.
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(find.textContaining(_notice), findsNothing);
  });

  testWidgets('says the journal hides kernel messages from a limited account', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.emit(tester, HostProfileChanged('srv-1', _limited));
    await tester.tap(find.text('Kernel'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Kernel messages may be missing'), findsOne);

    await panel.emit(
      tester,
      LogStreamState(
        panel.opens.last.streamId,
        const LogStreamEnded(LogStreamEndReason.oldestReached),
      ),
    );
    expect(find.text('No entries are visible to your account.'), findsOne);
    expect(find.text('This log has no entries.'), findsNothing);
  });

  testWidgets('tells the source and case matching by more than colour', (
    tester,
  ) async {
    await _pump(tester);
    expect(
      find.descendant(
        of: find.byType(SegmentedButton<LogSourceKind>),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );

    final toggle = find.widgetWithIcon(IconButton, Icons.text_fields);
    Material surface() => tester.widget<Material>(
      find.descendant(of: toggle, matching: find.byType(Material)).first,
    );
    BorderSide edge() => (surface().shape! as OutlinedBorder).side;
    expect(surface().color, Colors.transparent);
    expect(edge().style, BorderStyle.solid);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(surface().color!.a, 1);
    expect(edge(), BorderSide.none);
  });

  testWidgets('names the search field once it holds text', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester);
    await tester.enterText(find.byType(TextField).last, 'abc');
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    final field = tester.getSemantics(
      find.bySemanticsLabel(RegExp('Search loaded entries')),
    );
    expect(field.value, 'abc');
    semantics.dispose();
  });

  testWidgets('says why nothing shows: no entries, or none that match', (
    tester,
  ) async {
    final panel = await _pump(tester);
    Future<void> ended() => panel.emit(
      tester,
      LogStreamState(
        panel.opens.last.streamId,
        const LogStreamEnded(LogStreamEndReason.oldestReached),
      ),
    );

    await tester.tap(find.text('Kernel'));
    await tester.pumpAndSettle();
    await ended();
    expect(find.text('This log has no entries.'), findsOneWidget);

    await tester.tap(find.text('Journal'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Unit'),
      'nginx.service',
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    await ended();
    expect(find.text('No entries match these filters.'), findsOneWidget);
  });

  testWidgets('applies the journal filters', (tester) async {
    final panel = await _pump(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Unit'),
      'nginx.service',
    );
    await tester.tap(find.text('Any priority'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Warning and above').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Current boot only'));
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    final source = panel.opens.last.spec.source as JournalLogSource;
    expect(source.unit, 'nginx.service');
    expect(source.priority, LogPriority.warning);
    expect(source.currentBootOnly, isTrue);
  });

  testWidgets('keeps the keyboard focus where it was after applying', (
    tester,
  ) async {
    final panel = await _pump(tester);
    bool focused(Finder finder) =>
        Focus.of(tester.element(finder)).hasPrimaryFocus;

    final apply = find.text('Apply');
    Focus.of(tester.element(apply)).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(panel.opens, hasLength(2));
    expect(focused(apply), isTrue);

    final unit = find.widgetWithText(TextField, 'Unit');
    await tester.enterText(unit, 'nginx.service');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(panel.opens, hasLength(3));
    expect(
      tester
          .widget<EditableText>(
            find.descendant(of: unit, matching: find.byType(EditableText)),
          )
          .focusNode
          .hasPrimaryFocus,
      isTrue,
    );
  });

  testWidgets('a file path must be absolute; a common path opens at once', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(
      find.text('Choose or type the absolute path of a file to tail.'),
      findsOneWidget,
    );
    expect(_chip('Stopped'), findsOneWidget);
    final sent = panel.opens.length;

    final path = find.widgetWithText(TextField, 'File path');
    await tester.enterText(path, 'var/log/syslog');
    await tester.pump();
    expect(
      find.text('Enter an absolute path that starts with /.'),
      findsOneWidget,
    );
    await tester.enterText(path, '/var/log/../secure');
    await tester.pump();
    expect(
      find.text('Remove the . and .. parts from the path.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(panel.opens, hasLength(sent));

    await tester.tap(find.byTooltip('Common paths'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('/var/log/nginx/error.log'));
    await tester.pumpAndSettle();
    final tail = panel.opens.last.spec.source as FileLogSource;
    expect(tail.path, '/var/log/nginx/error.log');

    await panel.emit(
      tester,
      LogStreamState(
        panel.opens.last.streamId,
        const LogStreamEnded(
          LogStreamEndReason.denied,
          detail: 'tail: cannot open: Permission denied',
        ),
      ),
    );
    expect(find.text('The server denied access to this log.'), findsOneWidget);
    expect(find.text('tail: cannot open: Permission denied'), findsOneWidget);
  });

  testWidgets('on a phone, the source and filters open bottom sheets', (
    tester,
  ) async {
    final panel = await _pump(tester, size: _phone);
    await tester.tap(find.text('Journal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Kernel'));
    await tester.pumpAndSettle();
    expect(panel.opens.last.spec.source, isA<KernelLogSource>());
    expect(find.textContaining('Filters'), findsNothing);

    await tester.tap(find.text('Kernel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Journal').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filters'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Identifier'),
      'CRON',
    );
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Filters (1)'), findsOneWidget);
    final source = panel.opens.last.spec.source as JournalLogSource;
    expect(source.identifier, 'CRON');
  });

  for (final size in [_wide, const Size(800, 800), _phone]) {
    testWidgets('lays out without overflow at 200 % text at $size', (
      tester,
    ) async {
      final panel = await _pump(tester, size: size, textScale: 2);
      await panel.running(tester);
      expect(tester.takeException(), isNull);
      if (size == _wide) return;

      await tester.tap(find.textContaining('Filters'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('keeps the log in sight at 200 % text on a small phone with '
      'the notice and a refusal', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final harness = await pumpApp(
      tester,
      size: const Size(375, 667),
      servers: twoServers,
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Logs'));
    await tester.pumpAndSettle();

    harness.engine
      ..emit(HostProfileChanged('srv-1', _limited))
      ..emit(const RequestRejected('OpenLogStream', 'not implemented yet'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining(_notice), findsOneWidget);
    expect(
      tester.getSize(find.byType(LogView)).height,
      greaterThanOrEqualTo(tester.getSize(find.byType(LogsPanel)).height / 2),
    );
  });

  group('golden', () {
    for (final brightness in Brightness.values) {
      for (final (name, size) in [('desktop', _wide), ('phone', _phone)]) {
        testWidgets('$name, ${brightness.name}', (tester) async {
          final panel = await _pump(tester, size: size, brightness: brightness);
          await panel.running(tester);
          await expectLater(
            find.byType(LogsPanel),
            matchesGoldenFile(
              'goldens/logs_panel_${name}_${brightness.name}.png',
            ),
          );
        }, skip: !goldensCompareHere);
      }
    }
  });
}
