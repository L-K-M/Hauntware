import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/confirm.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

Widget _host(Widget child, {double scale = 1}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: MediaQuery(
    data: MediaQueryData(
      size: const Size(320, 640),
      textScaler: TextScaler.linear(scale),
    ),
    child: Scaffold(
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: child,
      ),
    ),
  ),
);

void main() {
  testWidgets('a held Enter or Space does not confirm an acknowledge tier', (
    tester,
  ) async {
    var confirmed = 0;
    await tester.pumpWidget(
      _host(
        ActionConfirm(
          tier: ConfirmationTier.acknowledge,
          targetName: 'web',
          onConfirm: (_) => confirmed++,
          onCancel: () {},
        ),
      ),
    );
    await tester.pump();

    await simulateKeyRepeatEvent(LogicalKeyboardKey.enter);
    await simulateKeyRepeatEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(confirmed, 0);

    // A deliberate press still confirms.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(confirmed, 1);
  });

  for (final scale in [2.0, 3.0]) {
    testWidgets('the buttons wrap at ${scale}x text on a 320 px phone', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _host(
          scale: scale,
          ActionConfirm(
            tier: ConfirmationTier.acknowledge,
            targetName: 'web',
            onConfirm: (_) {},
            onCancel: () {},
          ),
        ),
      );
      expect(tester.takeException(), isNull);
    });
  }
}
