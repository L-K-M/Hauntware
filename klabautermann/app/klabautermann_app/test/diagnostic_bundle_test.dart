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
        'The server is not connected, so its collectors cannot be read.',
      ),
      findsOne,
    );
    expect(find.text('Save…'), findsNothing);
  });
}
