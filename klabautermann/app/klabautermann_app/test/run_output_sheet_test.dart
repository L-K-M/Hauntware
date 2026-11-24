// JOB-08's run output (03 §7.7): the sheet says what its read is doing
// and why it stopped, with a Retry, instead of an empty box.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/run_output_sheet.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

void main() {
  testWidgets("a run's output says what its read is doing, and why it "
      'stopped', (tester) async {
    final engine = FakeEngineClient();
    final monitoring = MonitoringController(engine);
    addTearDown(() async {
      monitoring.dispose();
      await engine.close();
    });

    late BuildContext host;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            host = context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );

    unawaited(
      showRunOutput(
        host,
        monitoring: monitoring,
        serverId: 'srv-1',
        unit: 'backup.service',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Output of backup.service'), findsOneWidget);
    expect(find.text('Opening the log…'), findsOneWidget);

    engine.emit(const RequestRejected('OpenLogStream', 'no such unit'));
    await tester.pumpAndSettle();
    expect(find.text('The engine did not open this log.'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Retry'), findsOneWidget);
  });
}
