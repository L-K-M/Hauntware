import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/window');
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final startErrors = <Object>[];

  setUp(startErrors.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  MacosToolbarBandChannel newBand() => MacosToolbarBandChannel(
    channelName: channel.name,
    onStartError: (error, _) => startErrors.add(error),
  );

  /// Plays one runner-to-Dart call and returns the raw reply envelope.
  Future<ByteData?> fromRunner(String method, Object? arguments) async {
    ByteData? reply;
    await messenger.handlePlatformMessage(
      channel.name,
      codec.encodeMethodCall(MethodCall(method, arguments)),
      (data) => reply = data,
    );
    return reply;
  }

  test('starts windowed and follows the runner\'s switches', () async {
    final band = newBand();
    addTearDown(band.dispose);
    expect(band.value, isTrue);

    await fromRunner('toolbarBandChanged', false);
    expect(band.value, isFalse);

    await fromRunner('toolbarBandChanged', true);
    expect(band.value, isTrue);
  });

  test('start adopts a window restored straight into full screen', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'isToolbarBandVisible');
      return false;
    });
    final band = newBand();
    addTearDown(band.dispose);

    await band.start();
    expect(band.value, isFalse);
    expect(startErrors, isEmpty);
  });

  test('no runner side keeps the windowed layout quietly', () async {
    // No mock handler: the query throws MissingPluginException.
    final band = newBand();
    addTearDown(band.dispose);

    await band.start();
    expect(band.value, isTrue);
    expect(startErrors, isEmpty);
  });

  for (final (name, reply, error)
      in <(String, Future<Object?> Function(), Matcher)>[
        (
          'an error',
          () async => throw PlatformException(code: 'BOOM'),
          isA<PlatformException>(),
        ),
        ('a non-bool reply', () async => 'yes', isA<TypeError>()),
      ]) {
    test('a query that answers with $name is reported, not thrown', () async {
      messenger.setMockMethodCallHandler(channel, (call) => reply());
      final band = newBand();
      addTearDown(band.dispose);

      await band.start();
      expect(band.value, isTrue);
      expect(startErrors, [error]);
    });
  }

  test('a malformed switch is refused and changes nothing', () async {
    final band = newBand();
    addTearDown(band.dispose);

    final reply = await fromRunner('toolbarBandChanged', 'no');
    expect(
      () => codec.decodeEnvelope(reply!),
      throwsA(isA<PlatformException>()),
    );
    expect(band.value, isTrue);
  });

  test('dispose detaches the runner switch handler', () async {
    final band = newBand();
    await fromRunner('toolbarBandChanged', false);
    expect(band.value, isFalse);

    band.dispose();
    await fromRunner('toolbarBandChanged', true);
    expect(band.value, isFalse);
  });
}
