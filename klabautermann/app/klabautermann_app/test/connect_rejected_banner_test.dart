import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';

const _phone = Size(390, 844);
const _desktop = Size(1280, 800);

const _noLoginName =
    "You can't connect to this server yet: your SSH config names no user "
    'for it or for a jump host it goes through, and your login name could '
    'not be read from this device. Add a User line to your SSH config, then '
    'import it again.';
const _addressOnly =
    "You can't connect to this server yet: it comes from an earlier import "
    'that kept only its address. Import your SSH config again to connect.';

/// Opens web-1 on a surface of [size]: the desktop workspace or the
/// phone's pushed screen, whose first view sends `Connect`.
Future<AppHarness> _openWeb(WidgetTester tester, Size size) async {
  final harness = await pumpApp(tester, size: size, servers: twoServers);
  await tester.tap(find.text('web-1'));
  await tester.pumpAndSettle();
  expect(
    harness.engine.sentOfType<Connect>().cast<Connect>().last.serverId,
    'srv-1',
  );
  return harness;
}

void main() {
  for (final (name, size) in [('desktop', _desktop), ('phone', _phone)]) {
    for (final (reason, words) in [
      (ConnectRejectedReason.noLoginName, _noLoginName),
      (ConnectRejectedReason.addressOnlyImport, _addressOnly),
    ]) {
      testWidgets('the $name server view says why the engine rejected its '
          'Connect: ${reason.name}', (tester) async {
        final harness = await _openWeb(tester, size);
        expect(find.text(words), findsNothing);

        // Another server's rejection is not this view's.
        harness.engine.emit(ConnectRejected('srv-2', reason));
        await tester.pumpAndSettle();
        expect(find.text(words), findsNothing);

        harness.engine.emit(ConnectRejected('srv-1', reason));
        await tester.pumpAndSettle();
        expect(find.text(words), findsOneWidget);
        expect(
          tester.getSemantics(find.text(words)),
          isSemantics(label: words, isLiveRegion: true),
        );
      });
    }
  }

  testWidgets('a rejection while links are off shows nothing', (tester) async {
    final harness = await _openWeb(tester, _desktop);

    harness.engine.emit(
      const RequestRejected('Connect', 'links are off in this engine'),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining("You can't connect"), findsNothing);
  });

  // A11Y-09: past its share of the screen the banner scrolls, so the
  // panel under it keeps its room on a small or landscape phone.
  for (final size in [_phone, const Size(360, 640), const Size(568, 320)]) {
    testWidgets('fits at 200 % text on a ${size.width.round()} x '
        '${size.height.round()} phone', (tester) async {
      final harness = await _openWeb(tester, size);
      harness.engine.emit(
        const ConnectRejected('srv-1', ConnectRejectedReason.noLoginName),
      );
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();

      expect(find.text(_noLoginName), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
