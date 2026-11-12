import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
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

  group('toolbar band widgets', () {
    /// Pumps a MaterialApp composed like a host's, with the band's scope
    /// and reservation in its builder and an optional claim below it, and
    /// reports the top padding the home page sees.
    Future<(double, double)> pumpBand(
      WidgetTester tester, {
      TargetPlatform platform = TargetPlatform.macOS,
      ValueListenable<bool>? band,
      bool claim = false,
      bool windowedWithoutScope = false,
      bool useWithMacosToolbarBand = false,
    }) async {
      (double, double) seen = (-1, -1);
      Widget probe = Builder(
        builder: (context) {
          seen = (
            MediaQuery.of(context).padding.top,
            MediaQuery.of(context).viewPadding.top,
          );
          return const SizedBox.expand();
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          builder: (context, child) {
            if (useWithMacosToolbarBand) {
              return withMacosToolbarBand(
                band,
                windowedWithoutScope: windowedWithoutScope,
                child: child!,
              );
            }
            Widget wrapped = ReserveMacosToolbarBand(
              windowedWithoutScope: windowedWithoutScope,
              child: child!,
            );
            if (band != null) {
              wrapped = MacosToolbarBandScope(band: band, child: wrapped);
            }
            return wrapped;
          },
          home: claim
              ? ClaimMacosToolbarBand(
                  windowedWithoutScope: windowedWithoutScope,
                  child: probe,
                )
              : probe,
        ),
      );
      // Lets the theme settle, so a changed platform is not still animating.
      await tester.pumpAndSettle();
      return seen;
    }

    testWidgets('the reservation adds the band on macOS and drops it in '
        'full screen and off macOS', (tester) async {
      final band = ValueNotifier<bool>(true);
      addTearDown(band.dispose);

      expect(await pumpBand(tester, band: band), (
        macosToolbarBandHeight,
        macosToolbarBandHeight,
      ));

      band.value = false;
      expect(await pumpBand(tester, band: band), (0.0, 0.0));

      band.value = true;
      expect(
        await pumpBand(tester, platform: TargetPlatform.android, band: band),
        (0.0, 0.0),
      );
    });

    testWidgets('the claim takes the reservation back out', (tester) async {
      final band = ValueNotifier<bool>(true);
      addTearDown(band.dispose);

      expect(await pumpBand(tester, band: band, claim: true), (0.0, 0.0));
      expect(await pumpBand(tester, band: band), (
        macosToolbarBandHeight,
        macosToolbarBandHeight,
      ));
    });

    testWidgets('without a scope the host\'s no-scope default answers', (
      tester,
    ) async {
      expect(await pumpBand(tester), (0.0, 0.0));
      expect(await pumpBand(tester, windowedWithoutScope: true), (
        macosToolbarBandHeight,
        macosToolbarBandHeight,
      ));
      expect(await pumpBand(tester, claim: true, windowedWithoutScope: true), (
        0,
        0,
      ));
      expect(
        await pumpBand(
          tester,
          platform: TargetPlatform.android,
          windowedWithoutScope: true,
        ),
        (0.0, 0.0),
      );
    });

    testWidgets('withMacosToolbarBand scopes and reserves, or leaves the '
        'child alone', (tester) async {
      final band = ValueNotifier<bool>(true);
      addTearDown(band.dispose);

      expect(
        await pumpBand(tester, band: band, useWithMacosToolbarBand: true),
        (macosToolbarBandHeight, macosToolbarBandHeight),
      );
      expect(await pumpBand(tester, useWithMacosToolbarBand: true), (0.0, 0.0));
      expect(
        await pumpBand(
          tester,
          windowedWithoutScope: true,
          useWithMacosToolbarBand: true,
        ),
        (macosToolbarBandHeight, macosToolbarBandHeight),
      );
    });

    testWidgets('unifiedToolbarOf follows the scope, not the band', (
      tester,
    ) async {
      final band = ValueNotifier<bool>(false);
      addTearDown(band.dispose);
      bool? unified;
      Widget home() => Builder(
        builder: (context) {
          unified = MacosToolbarBandScope.unifiedToolbarOf(context);
          return const SizedBox.expand();
        },
      );

      Future<void> pump(TargetPlatform platform) => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: platform),
          builder: (context, child) => MacosToolbarBandScope(
            band: band,
            child: ReserveMacosToolbarBand(child: child!),
          ),
          home: home(),
        ),
      );

      await pump(TargetPlatform.macOS);
      expect(unified, isTrue);
      await pump(TargetPlatform.linux);
      // The theme animates between the two platforms.
      await tester.pumpAndSettle();
      expect(unified, isFalse);
    });
  });
}
