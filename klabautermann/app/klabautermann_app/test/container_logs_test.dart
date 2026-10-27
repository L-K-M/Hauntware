import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart' show loadBundledMonoFonts;
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/docker/container_details.dart';
import 'package:klabautermann_app/ui/docker/container_logs.dart';
import 'package:klabautermann_app/ui/docker/containers_panel.dart';
import 'package:klabautermann_app/ui/docker/docker_panel.dart';
import 'package:klabautermann_app/ui/logs/log_export.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';

/// Saves what an export would write, by file name.
final class _ExportHost implements LogExportHost {
  final saved = <(String, String)>[];

  @override
  bool get canShare => false;

  @override
  Future<bool> save(String fileName, Uint8List bytes) async {
    saved.add((fileName, utf8.decode(bytes)));
    return true;
  }

  @override
  Future<void> share(String fileName, Uint8List bytes, {Rect? origin}) async {}
}

const _id = 'b7e9d0c1a2f3';

const _desktop = Size(1100, 900);
const _phone = Size(390, 800);

final _now = DateTime(2026, 10, 15, 14, 30);

final _row = dockerContainer(
  _id,
  name: 'web-db',
  project: 'web',
  image: 'postgres:16',
);

/// A database's lines, one of them on stderr and one coloured by SGR.
final _lines = [
  containerLine(
    'listening on IPv4 address "0.0.0.0", port 5432',
    at: DateTime(2026, 10, 15, 14, 29, 58),
  ),
  containerLine(
    '\x1b[33mWARNING\x1b[0m:  checkpoints are occurring too frequently',
    at: DateTime(2026, 10, 15, 14, 29, 59),
  ),
  containerLine(
    'FATAL:  password authentication failed for user "app"',
    stream: ContainerLogStream.stderr,
    at: DateTime(2026, 10, 15, 14, 30, 1),
  ),
  containerLine(
    'connection received: host=172.18.0.4 port=51234',
    at: DateTime(2026, 10, 15, 14, 30, 2),
  ),
];

const _gap =
    'Following again. Lines written while it was paused or disconnected '
    'may be missing.';

final class _Harness {
  _Harness(this.engine, this.visible, this.logs);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;
  final ValueNotifier<InspectedContainer?> logs;

  List<OpenLogStream> get opens => containerLogOpens(engine.sent, _id);

  List<String> get closed => [
    for (final close in engine.sentOfType<CloseStream>().cast<CloseStream>())
      close.streamId,
  ];

  String get streamId => opens.last.streamId;

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  Future<void> status(WidgetTester tester, LogStreamStatus status) =>
      emit(tester, LogStreamState(streamId, status));

  /// A running follow that delivered [_lines].
  Future<void> running(WidgetTester tester) async {
    await status(tester, const LogStreamRunning());
    await emit(tester, containerLogBatch(streamId, _lines));
  }
}

ThemeData _theme(Brightness brightness) {
  final base = brightness == Brightness.light
      ? GhostTheme.light(
          klabautermannThemeStyle,
          platform: TargetPlatform.linux,
        )
      : GhostTheme.dark(
          klabautermannThemeStyle,
          platform: TargetPlatform.linux,
        );
  return base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: goldenFontFamily),
  );
}

/// The Docker tab beside an inspector, as the desktop shell holds them,
/// or on a [phone] the Containers sub-tab alone, whose rows push the
/// details; [runtime] names the engine.
Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = _desktop,
  bool phone = false,
  EngineRuntime runtime = EngineRuntime.docker,
  _ExportHost? exportHost,
}) async {
  tester.view.physicalSize = phone ? _phone : size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _now);
  final inspection = ValueNotifier<InspectedContainer?>(null);
  final logs = ValueNotifier<InspectedContainer?>(null);
  final visible = ValueNotifier(true);
  addTearDown(() async {
    monitoring.dispose();
    inspection.dispose();
    logs.dispose();
    visible.dispose();
    await engine.close();
  });

  final Widget body = phone
      ? ContainersPanel(
          monitoring: monitoring,
          serverId: _serverId,
          visible: true,
        )
      : ContainerInspectionScope(
          inspection: inspection,
          child: ContainerLogsScope(
            logs: logs,
            child: Row(
              children: [
                Expanded(
                  child: ValueListenableBuilder(
                    valueListenable: visible,
                    builder: (context, shows, _) => DockerPanel(
                      monitoring: monitoring,
                      serverId: _serverId,
                      visible: shows,
                    ),
                  ),
                ),
                SizedBox(
                  width: 300,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: ValueListenableBuilder(
                      valueListenable: inspection,
                      builder: (context, inspected, _) => inspected == null
                          ? const SizedBox.expand()
                          : ContainerInspectorBody(
                              key: ValueKey(inspected.container.id),
                              monitoring: monitoring,
                              inspected: inspected,
                              onClose: () => inspection.value = null,
                            ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: LogExportScope(
        host: exportHost ?? _ExportHost(),
        child: Scaffold(body: body),
      ),
    ),
  );
  final harness = _Harness(engine, visible, logs);
  await harness.emit(tester, dockerReady(_serverId, runtime: runtime));
  await harness.emit(
    tester,
    dockerContainerList(_serverId, [
      _row,
      dockerContainer('a1f3c2e4b5d6', name: 'web-frontend', project: 'web'),
    ], at: _now),
  );
  return harness;
}

/// Opens web-db's details from its row, then its logs from the details.
Future<void> _openLogs(WidgetTester tester) async {
  await tester.tap(find.text('web-db').first);
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Show logs'));
  await tester.pumpAndSettle();
}

/// A log row whose text on screen contains [text]: the stream marks'
/// spoken names stay out.
Finder _line(String text) => find.byWidgetPredicate(
  (widget) =>
      widget is RichText &&
      widget.text.toPlainText(includeSemanticsLabels: false).contains(text),
);

Finder _chip(String word) =>
    find.descendant(of: find.byType(FilterChip), matching: find.text(word));

/// 03 §7.12 CTX-01 and CTX-02: a container's logs, followed and searched
/// in the desktop Docker tab's pane or a phone's bottom sheet.
void main() {
  setUpAll(() async {
    if (!goldensCompareHere) return;
    await loadGoldenFonts();
    // The lines draw in the bundled monospace family, as the container
    // details' goldens do, so the golden shows their text.
    await loadBundledMonoFonts();
  });

  testWidgets('the details open the logs in the Docker tab, which follow '
      'the container with each stream marked', (tester) async {
    final harness = await _pump(tester);
    expect(harness.opens, isEmpty);

    await _openLogs(tester);
    expect(harness.logs.value?.container.id, _id);
    expect(find.byType(ContainerLogsPane), findsOne);
    final spec = harness.opens.single.spec;
    expect(spec.serverId, _serverId);
    expect(spec.follow, isTrue);
    expect(spec.window, 500);
    expect(spec.afterCursor, isNull);
    expect(find.text('Opening the log…'), findsOne);

    await harness.running(tester);
    expect(_chip('Live'), findsOne);
    expect(find.text('Opening the log…'), findsNothing);
    // Each row starts with its time and stream; SGR escapes are dropped.
    expect(
      _line(
        '2026-10-15 14:29:58 stdout listening on IPv4 address "0.0.0.0", '
        'port 5432',
      ),
      findsOne,
    );
    expect(
      _line(
        '2026-10-15 14:29:59 stdout WARNING:  checkpoints are occurring too '
        'frequently',
      ),
      findsOne,
    );
    expect(_line('2026-10-15 14:30:01 stderr FATAL:'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stderr is marked by its word and colour, and spoken', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final harness = await _pump(tester);
    await _openLogs(tester);
    await harness.running(tester);

    // A screen reader hears the stream's name for its mark, after the
    // level the line names of itself (CTX-05).
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Error\s+2026-10-15 14:30:01 standard error FATAL:'),
      ),
      findsOne,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(r'^2026-10-15 14:29:58 standard output listening'),
      ),
      findsOne,
    );

    // On screen the mark is the stream's own word, the stderr one in
    // another colour than stdout's, while the line keeps its own.
    TextSpan markOf(String text) {
      final paragraph = tester.widget<RichText>(_line(text));
      final spans = (paragraph.text as TextSpan).children!.cast<TextSpan>();
      return spans.firstWhere(
        (span) => span.text == 'stderr' || span.text == 'stdout',
      );
    }

    final stderr = markOf('FATAL:');
    final stdout = markOf('listening');
    expect(stderr.text, 'stderr');
    expect(stderr.semanticsLabel, 'standard error');
    expect(stdout.semanticsLabel, 'standard output');
    expect(stderr.style?.color, isNot(stdout.style?.color));
    semantics.dispose();
  });

  testWidgets('a container row\'s menu opens its logs', (tester) async {
    final harness = await _pump(tester);

    await tester.tap(find.byIcon(Icons.more_horiz).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show logs').last);
    await tester.pumpAndSettle();
    expect(harness.logs.value?.container.id, _id);
    expect(harness.opens, hasLength(1));
    // The details stay closed.
    expect(find.byType(ContainerInspectorBody), findsNothing);
  });

  testWidgets('Live follows with the connection chip, says when lines may '
      'be missing, and keeps the lines when turned off', (tester) async {
    final harness = await _pump(tester);
    await _openLogs(tester);
    await harness.running(tester);

    await harness.status(
      tester,
      const LogStreamWaiting(LogStreamWaitReason.link),
    );
    expect(_chip('Disconnected'), findsOne);
    expect(find.text('Waiting for the connection to the server.'), findsOne);

    // The engine reads on after the newest line; a resume it could not
    // make whole says so.
    await harness.status(
      tester,
      const LogStreamRunning(continuity: LogContinuity.gap),
    );
    expect(_chip('Live'), findsOne);
    expect(find.text(_gap), findsOne);
    await harness.status(tester, const LogStreamRunning());
    expect(find.text(_gap), findsNothing);

    // Off closes the follow and keeps its lines.
    final follow = harness.streamId;
    await tester.tap(_chip('Live'));
    await tester.pumpAndSettle();
    expect(harness.closed, [follow]);
    expect(harness.opens, hasLength(1));
    expect(_chip('Paused'), findsOne);
    expect(_line('FATAL:'), findsOne);

    // On again starts over: a container's follow has no cursor.
    await tester.tap(_chip('Paused'));
    await tester.pumpAndSettle();
    expect(harness.opens, hasLength(2));
    expect(harness.opens.last.spec.afterCursor, isNull);
    expect(_line('FATAL:'), findsNothing);
  });

  testWidgets('a JSON line shows its keys beneath it on a tap (CTX-05)', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await _openLogs(tester);
    await harness.status(tester, const LogStreamRunning());
    await harness.emit(
      tester,
      containerLogBatch(harness.streamId, [
        containerLine(
          '{"level":"error","msg":"boom","http":{"status":500}}',
          at: DateTime(2026, 10, 15, 14, 30, 3),
        ),
      ]),
    );
    expect(_line('msg=boom'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOne);

    await tester.tap(_line('"msg":"boom"'));
    await tester.pumpAndSettle();
    expect(_line('msg=boom'), findsOne);
    expect(_line('http.status=500'), findsOne);
  });

  testWidgets('a time range reads anew: a span back from now follows, a '
      'chosen start and end reads once and cannot follow', (tester) async {
    final harness = await _pump(tester);
    await _openLogs(tester);
    await harness.running(tester);
    final source = harness.opens.single.spec.source as ContainerLogSource;
    expect((source.since, source.until), (null, null));

    await tester.tap(find.widgetWithText(OutlinedButton, 'Any time'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Last hour').last);
    await tester.pumpAndSettle();
    expect(harness.opens, hasLength(2));
    final spanned = harness.opens.last.spec;
    expect(spanned.follow, isTrue);
    final since = (spanned.source as ContainerLogSource).since!;
    expect(
      DateTime.now().difference(since).inMinutes,
      inInclusiveRange(59, 61),
    );
    expect(_line('FATAL:'), findsNothing);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Last hour'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose start and end…'));
    await tester.pumpAndSettle();
    expect(find.text('Time range'), findsOne);
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(harness.opens, hasLength(3));
    final chosen = harness.opens.last.spec;
    final range = chosen.source as ContainerLogSource;
    expect(chosen.follow, isFalse);
    expect(range.until!.difference(range.since!), const Duration(hours: 1));
    expect(_chip('Stopped'), findsOne);
    final live = tester.widget<FilterChip>(
      find.ancestor(of: _chip('Stopped'), matching: find.byType(FilterChip)),
    );
    expect(live.onSelected, isNull);
    expect(live.tooltip, 'A range with an end has no new lines to follow.');
  });

  testWidgets('Export saves the held lines as the container\'s log file '
      '(CTX-06)', (tester) async {
    final host = _ExportHost();
    final harness = await _pump(tester, exportHost: host);
    await _openLogs(tester);
    await harness.running(tester);

    await tester.tap(find.byTooltip('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Include secrets'), findsOne);
    await tester.tap(find.text('Include secrets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save…'));
    await tester.pumpAndSettle();

    final (name, text) = host.saved.single;
    expect(name, 'web-db.log');
    expect(text, contains('stderr FATAL:  password authentication failed'));
  });

  testWidgets('Export is redacted unless Include secrets is on (SAF-07)', (
    tester,
  ) async {
    final host = _ExportHost();
    final harness = await _pump(tester, exportHost: host);
    await _openLogs(tester);
    await harness.running(tester);

    await tester.tap(find.byTooltip('Export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save…'));
    await tester.pump();

    final redaction = harness.engine
        .sentOfType<RedactLines>()
        .cast<RedactLines>()
        .single;
    expect(
      redaction.lines,
      contains(contains('stderr FATAL:  password authentication failed')),
    );
    await harness.emit(
      tester,
      RedactedLines(redaction.requestId, 'redacted by the engine'),
    );
    await tester.pumpAndSettle();

    expect(host.saved.single, ('web-db.log', 'redacted by the engine\n'));
  });

  testWidgets('lines the engine dropped show as one row', (tester) async {
    final harness = await _pump(tester);
    await _openLogs(tester);
    await harness.status(tester, const LogStreamRunning());
    await harness.emit(tester, containerLogBatch(harness.streamId, _lines));
    await harness.emit(
      tester,
      containerLogBatch(harness.streamId, [
        containerLine('checkpoint complete'),
      ], dropped: 1200),
    );

    expect(find.text('1,200 lines dropped here'), findsOne);
    // A line without a time keeps the marks in line.
    expect(_line('${' ' * 19} stdout checkpoint complete'), findsOne);
  });

  testWidgets('search finds text and stream marks, and steps', (tester) async {
    final harness = await _pump(tester);
    await _openLogs(tester);
    await harness.running(tester);

    final field = find.widgetWithText(TextField, 'Search loaded entries');
    await tester.enterText(field, 'stderr');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1 match'), findsOne);

    await tester.enterText(field, 'port');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2 matches'), findsOne);
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('1 of 2'), findsOne);
    await tester.tap(find.byTooltip('Next match'));
    await tester.pumpAndSettle();
    expect(find.text('2 of 2'), findsOne);
    // Stepping pauses following, so the Follow button shows.
    expect(find.text('Follow'), findsOne);
  });

  group('the driver notice (CTX-01)', () {
    for (final (name, runtime, driver, text) in [
      (
        'a remote driver without the cache',
        EngineRuntime.docker,
        'splunk',
        'Docker cannot read this container\'s logs: driver splunk, cache '
            'disabled. Docker reads another driver\'s logs only through its '
            'local cache.',
      ),
      (
        'Podman\'s unread driver',
        EngineRuntime.podman,
        'syslog',
        'Podman cannot read this container\'s logs: driver syslog. Podman '
            'reads only the json-file, k8s-file and journald drivers.',
      ),
      (
        'the none driver',
        EngineRuntime.docker,
        'none',
        'This container keeps no logs: driver none.',
      ),
      (
        'a driver the engine could not name',
        EngineRuntime.docker,
        null,
        'Docker cannot read this container\'s logs: its logging driver '
            'keeps none it can read.',
      ),
    ]) {
      testWidgets('names $name, without a retry', (tester) async {
        final harness = await _pump(tester, runtime: runtime);
        await _openLogs(tester);
        await harness.status(
          tester,
          LogStreamEnded(
            LogStreamEndReason.logDriverUnreadable,
            detail: driver,
          ),
        );

        expect(find.text(text), findsOne);
        expect(find.text('Reading the log failed.'), findsNothing);
        expect(find.text('Retry'), findsNothing);
        expect(find.text('This container has no log lines.'), findsNothing);
        expect(_chip('Stopped'), findsOne);
      });
    }

    testWidgets('other ends keep the log wording and retry', (tester) async {
      final harness = await _pump(tester);
      await _openLogs(tester);
      await harness.status(
        tester,
        const LogStreamEnded(
          LogStreamEndReason.missing,
          detail: 'No such container: b7e9d0c1a2f3',
        ),
      );
      expect(find.text('The server has no such file or log tool.'), findsOne);
      expect(find.text('No such container: b7e9d0c1a2f3'), findsOne);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(harness.opens, hasLength(2));
      await harness.status(
        tester,
        const LogStreamEnded(LogStreamEndReason.failed, detail: 'HTTP 500'),
      );
      expect(find.text('Reading the log failed.'), findsOne);
    });

    testWidgets('a read that ended empty says so', (tester) async {
      final harness = await _pump(tester);
      await _openLogs(tester);
      await harness.status(
        tester,
        const LogStreamEnded(LogStreamEndReason.oldestReached),
      );
      expect(find.text('This container has no log lines.'), findsOne);
    });
  });

  testWidgets('the pane follows only while the tab shows; Escape and the '
      'close button close it', (tester) async {
    final harness = await _pump(tester);
    await _openLogs(tester);
    await harness.running(tester);
    final first = harness.streamId;

    harness.visible.value = false;
    await tester.pumpAndSettle();
    expect(harness.closed, [first]);

    // Shown again, the follow starts over.
    harness.visible.value = true;
    await tester.pumpAndSettle();
    expect(harness.opens, hasLength(2));
    expect(_line('FATAL:'), findsNothing);

    // Its close button takes focus as it opens, and Escape closes it.
    final second = harness.streamId;
    await tester.tap(find.text('web-frontend').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show logs'));
    await tester.pumpAndSettle();
    expect(harness.closed, [first, second], reason: 'another container');
    final third =
        (harness.engine.sent.whereType<OpenLogStream>().last).streamId;
    final close = tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('Close logs'),
        matching: find.byType(IconButton),
      ),
    );
    expect(close.focusNode, FocusManager.instance.primaryFocus);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(harness.logs.value, isNull);
    expect(find.byType(ContainerLogsPane), findsNothing);
    expect(harness.closed, [first, second, third]);

    // The close button closes it too.
    await tester.tap(find.byTooltip('Show logs'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close logs'));
    await tester.pumpAndSettle();
    expect(find.byType(ContainerLogsPane), findsNothing);
    expect(harness.closed, hasLength(4));
  });

  testWidgets('a phone opens the logs from the details in a bottom sheet, '
      'whose close ends the stream', (tester) async {
    final harness = await _pump(tester, phone: true);
    await tester.tap(find.text('web-db').first);
    await tester.pumpAndSettle();
    expect(find.byType(ContainerDetailsPage), findsOne);

    await tester.tap(find.byTooltip('Show logs'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOne);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('web-db'),
      ),
      findsOne,
    );
    expect(harness.opens, hasLength(1));
    await harness.running(tester);
    expect(_line('stderr FATAL:'), findsOne);
    // The search takes a row of its own at a phone's width.
    expect(find.text('Search loaded entries'), findsOne);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Close logs'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(harness.closed, [harness.opens.single.streamId]);
    expect(find.byType(ContainerDetailsPage), findsOne);
  });

  testWidgets('Back closes the phone\'s sheet and its stream', (tester) async {
    final harness = await _pump(tester, phone: true);
    await tester.tap(find.text('web-db').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Show logs'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsNothing);
    expect(harness.closed, [harness.opens.single.streamId]);
  });

  group('golden', () {
    for (final brightness in Brightness.values) {
      testWidgets('desktop log pane, ${brightness.name}', (tester) async {
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
        final harness = await _pump(tester, size: const Size(1100, 760));
        await _openLogs(tester);
        await harness.running(tester);
        await harness.emit(
          tester,
          containerLogBatch(harness.streamId, [
            containerLine(
              'FATAL:  password authentication failed for user "app"',
              stream: ContainerLogStream.stderr,
              at: DateTime(2026, 10, 15, 14, 30, 4),
            ),
          ], dropped: 12),
        );
        await harness.status(
          tester,
          const LogStreamRunning(continuity: LogContinuity.gap),
        );
        final field = find.widgetWithText(TextField, 'Search loaded entries');
        await tester.enterText(field, 'password');
        await tester.pump(const Duration(milliseconds: 250));
        // The pane is focused from its close button; drop the focus so
        // the golden shows no caret.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();

        // The whole window: the pane under the Docker tab's list, beside
        // the inspector, over the scaffold's background.
        await expectLater(
          find.byType(MaterialApp),
          matchesGoldenFile(
            'goldens/container_logs_desktop_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
