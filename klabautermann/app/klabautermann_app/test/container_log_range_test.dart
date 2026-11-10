// CTX-03: the container logs' time range, chosen in a dialog.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/log_streams.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/docker/container_log_range.dart';
import 'package:klabautermann_app/ui/logs/logs_panel_controller.dart';

import 'support/fake_engine.dart';

void main() {
  testWidgets('the range dialog scrolls at 300 % text on a phone', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeEngineClient();
    final panel = LogsPanelController(
      streams: LogStreams(engine),
      serverId: 'srv-1',
      now: () => DateTime.utc(2026, 10, 15, 12),
    );
    addTearDown(() async {
      panel.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ContainerLogRangeButton(
            panel: panel,
            now: () => DateTime.utc(2026, 10, 15, 12),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose start and end…'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsOneWidget);

    // The text grows while the dialog shows. The page behind it may
    // overflow at this size; the dialog may not, so the errors are
    // collected.
    final reported = <String>[];
    final onError = FlutterError.onError;
    FlutterError.onError = (details) =>
        reported.add(details.toDiagnosticsNode().toStringDeep());
    tester.platformDispatcher.textScaleFactorTestValue = 3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpAndSettle();
    FlutterError.onError = onError;
    expect(
      reported.where((error) => error.contains('container_log_range')),
      isEmpty,
    );
  });
}
