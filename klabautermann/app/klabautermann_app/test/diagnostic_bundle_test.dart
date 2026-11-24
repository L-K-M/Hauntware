// CN-18: the diagnostic bundle, read on the server's samplers and exported
// through LOG-10's sheet, redacted unless secrets are included.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/diagnostic_bundle.dart';
import 'package:klabautermann_app/ui/logs/log_export.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/logs/host_queries.dart'
    show maskDiagnosticBundle;

import 'support/fake_engine.dart';

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

const _bundle = DiagnosticBundle(
  [
    DiagnosticSection(collector: 'probe_clock', status: 'ok', text: 'epoch=1'),
    DiagnosticSection(collector: 'fs', status: 'missing', text: 'a\nb'),
  ],
  missing: ['gpu'],
);

void main() {
  test('the bundle reads as fixtures do: each section under its ### line', () {
    expect(diagnosticBundleLines(_bundle, DateTime.utc(2026, 10, 26, 12)), [
      '# Klabautermann diagnostic bundle (HWS/1), read '
          '2026-10-26T12:00:00.000Z',
      '### probe_clock ok',
      'epoch=1',
      '### fs missing',
      'a',
      'b',
      '# no answer: gpu',
    ]);
  });

  late FakeEngineClient engine;
  late _ExportHost host;

  Future<HostQuery> openBundle(WidgetTester tester) async {
    engine = FakeEngineClient();
    final monitoring = MonitoringController(engine);
    final safety = SafetyController(apply: (_) {});
    host = _ExportHost();
    addTearDown(() async {
      monitoring.dispose();
      safety.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SafetyScope(
          safety: safety,
          child: LogExportScope(
            host: host,
            child: Scaffold(
              body: Center(
                child: ServerSafetyMenu(
                  serverId: 'srv-1',
                  serverName: 'web-1',
                  monitoring: monitoring,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Safety'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Diagnostic bundle…'));
    // The sheet slides in while the read waits; its spinner never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('Reading each collector once…'), findsOne);
    return engine.sentOfType<HostQuery>().single as HostQuery;
  }

  testWidgets('the Safety menu reads the bundle and saves it through the '
      "engine's redactor", (tester) async {
    final query = await openBundle(tester);
    expect(query.serverId, 'srv-1');
    expect(query.query, isA<DiagnosticBundleQuery>());

    engine.emit(
      HostResult(serverId: 'srv-1', queryId: query.queryId, payload: _bundle),
    );
    await tester.pumpAndSettle();
    expect(find.text('Diagnostic bundle for web-1: 2 sections'), findsOne);
    expect(find.textContaining('read it before you share it'), findsOne);
    // What the file carries beyond processes and mounts.
    expect(find.textContaining('host name and machine ID'), findsOne);
    expect(find.textContaining('crontab entries'), findsOne);
    expect(find.textContaining('command lines of its processes'), findsOne);
    expect(find.textContaining('No answer from: gpu'), findsOne);

    await tester.tap(find.text('Save…'));
    await tester.pump();
    final redact = engine.sentOfType<RedactLines>().single as RedactLines;
    expect(redact.lines.skip(1), [
      '### probe_clock ok',
      'epoch=1',
      '### fs missing',
      'a',
      'b',
      '# no answer: gpu',
    ]);
    engine.emit(RedactedLines(redact.requestId, 'redacted'));
    await tester.pumpAndSettle();
    expect(host.saved, [('diagnostics.txt', 'redacted\n')]);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets('the exported text carries no command-line secret, with '
      'secrets included or not (UIA-01)', (tester) async {
    String cmdline(int pid, List<String> argv) =>
        '==> $pid/cmdline <==\n${argv.map((a) => '$a\x1f').join()}\n';
    // As the engine answers the query: masked before it crosses.
    final bundle = maskDiagnosticBundle(
      DiagnosticBundle([
        DiagnosticSection(
          collector: 'procs',
          status: 'ok',
          text: [
            '== meta ==\ntotal=5\n== rows ==\n== cmdline ==',
            cmdline(1234, ['mysql', '-uroot', '-phunter2', 'db']),
            cmdline(1235, ['curl', '-u', 'admin:hunter2', 'https://x']),
            cmdline(1236, ['redis-cli', '-a', 'hunter2']),
            cmdline(1237, ['app', '--password', 'hunter2']),
            cmdline(1239, ['psql', 'postgres://bob:hunter2@db/x']),
          ].join('\n'),
        ),
        const DiagnosticSection(
          collector: 'cron',
          status: 'ok',
          text:
              '== crontab_meta ==\nrc=0\n== crontab ==\n'
              '0 3 * * * mysqldump -phunter2 db | gzip\n'
              '0 4 * * * sshpass -p hunter2 ssh h\n'
              '0 5 * * * PGPASSWORD=hunter2 pg_dump\n'
              '0 6 * * * docker login -p hunter2 reg\n'
              '0 7 * * * app --password=hunter2',
        ),
      ]),
    );
    const exported = [
      '### procs ok',
      '== meta ==',
      'total=5',
      '== rows ==',
      '== cmdline ==',
      '==> 1234/cmdline <==',
      'mysql\x1f-uroot\x1f-p********\x1fdb\x1f',
      '',
      '==> 1235/cmdline <==',
      'curl\x1f-u\x1fadmin:********\x1fhttps://x\x1f',
      '',
      '==> 1236/cmdline <==',
      'redis-cli\x1f-a\x1f********\x1f',
      '',
      '==> 1237/cmdline <==',
      'app\x1f--password\x1f********\x1f',
      '',
      '==> 1239/cmdline <==',
      'psql\x1fpostgres://bob:********@db/x\x1f',
      '',
      '### cron ok',
      '== crontab_meta ==',
      'rc=0',
      '== crontab ==',
      '0 3 * * * mysqldump -p******** db | gzip',
      '0 4 * * * sshpass -p ******** ssh h',
      '0 5 * * * PGPASSWORD=******** pg_dump',
      '0 6 * * * docker login -p ******** reg',
      '0 7 * * * app --password=********',
    ];

    final query = await openBundle(tester);
    engine.emit(
      HostResult(serverId: 'srv-1', queryId: query.queryId, payload: bundle),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('also when you include secrets'), findsOne);

    // Redacted: these are the lines the engine's redactor gets.
    await tester.tap(find.text('Save…'));
    await tester.pump();
    final redact = engine.sentOfType<RedactLines>().single as RedactLines;
    expect(redact.lines.skip(1), exported);
    expect(redact.lines.join('\n'), isNot(contains('hunter2')));
    engine.emit(RedactedLines(redact.requestId, redact.lines.join('\n')));
    await tester.pumpAndSettle();

    // With secrets included, the file is the lines as they crossed.
    final again = await openBundle(tester);
    engine.emit(
      HostResult(serverId: 'srv-1', queryId: again.queryId, payload: bundle),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Include secrets'));
    await tester.pump();
    await tester.tap(find.text('Save…'));
    await tester.pumpAndSettle();
    final (name, text) = host.saved.single;
    expect(name, 'diagnostics.txt');
    expect(text.split('\n').skip(1), [...exported, '']);
    expect(text, isNot(contains('hunter2')));
  });

  testWidgets('a server that is not connected says so', (tester) async {
    final query = await openBundle(tester);
    engine.emit(
      HostResult(
        serverId: 'srv-1',
        queryId: query.queryId,
        payload: const HostQueryFailed(HostQueryFailure.noLink),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Klabautermann is not reading this server right now, so its '
        'collectors cannot be read. Open the server while it is connected '
        'and try again.',
      ),
      findsOne,
    );
    expect(find.text('Save…'), findsNothing);
  });
}
