import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/mac_commands.dart';

/// The Dart end of the menu channel: it sends only what changed, and a
/// send that failed goes again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(macMenuChannel, null));

  test('the Dock badge goes once, and again after a failed send', () async {
    final sent = <Object?>[];
    var failNext = true;
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async {
      sent.add(call.arguments);
      if (failNext) {
        failNext = false;
        throw PlatformException(code: 'not-ready');
      }
      return null;
    });
    final bridge = MacCommandBridge();

    await bridge.setDockBadge('2');
    await bridge.setDockBadge('2');
    await bridge.setDockBadge('2');
    expect(sent, ['2', '2'], reason: 'resent once after the failure only');

    await bridge.setDockBadge(null);
    expect(sent, ['2', '2', null]);
  });

  test('no badge to start with needs no send', () async {
    final sent = <Object?>[];
    messenger.setMockMethodCallHandler(macMenuChannel, (call) async {
      sent.add(call.arguments);
      return null;
    });
    await MacCommandBridge().setDockBadge(null);
    expect(sent, isEmpty);
  });
}
