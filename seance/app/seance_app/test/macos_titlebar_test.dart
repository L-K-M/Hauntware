import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/macos_titlebar.dart';

class _FakeTitlebar implements MacosTitlebarAdapter {
  _FakeTitlebar({this.failInstall = false});

  final bool failInstall;
  int installs = 0;
  int resets = 0;

  @override
  Future<void> install() async {
    installs++;
    if (failInstall) throw PlatformException(code: 'NO_WINDOW');
  }

  @override
  Future<void> reset() async => resets++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/seance-window');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('install', () {
    test('an installed titlebar reports its band', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'isToolbarBandVisible');
        return true;
      });
      final adapter = _FakeTitlebar();
      final band = await MacosTitlebar.install(
        adapter: adapter,
        channelName: channel.name,
      );
      addTearDown(() => band?.dispose());
      expect(adapter.installs, 1);
      expect(adapter.resets, 0);
      expect(band, isNotNull);
      expect(band!.value, isTrue);
    });

    test(
      'a window restored into full screen starts without the band',
      () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'isToolbarBandVisible');
          return false;
        });
        final band = await MacosTitlebar.install(
          adapter: _FakeTitlebar(),
          channelName: channel.name,
        );
        addTearDown(() => band?.dispose());
        expect(band!.value, isFalse);
      },
    );

    // The band is cosmetic and install runs in main() before the window is
    // shown, so a runner that fails the query must not stop the launch.
    for (final (name, reply) in <(String, Future<Object?> Function())>[
      ('an error', () async => throw PlatformException(code: 'BOOM')),
      ('a non-bool reply', () async => 'yes'),
    ]) {
      test('a band query that answers with $name keeps the band', () async {
        messenger.setMockMethodCallHandler(channel, (call) => reply());
        final adapter = _FakeTitlebar();
        final band = await MacosTitlebar.install(
          adapter: adapter,
          channelName: channel.name,
        );
        addTearDown(() => band?.dispose());
        // The titlebar is installed, so the band stays reserved in the
        // windowed layout.
        expect(band, isNotNull);
        expect(band!.value, isTrue);
        expect(adapter.resets, 0);
      });
    }

    test('a failed install puts the standard titlebar back', () async {
      final adapter = _FakeTitlebar(failInstall: true);
      final band = await MacosTitlebar.install(
        adapter: adapter,
        channelName: channel.name,
      );
      // No band: nothing in the app reserves one or draws the header.
      expect(band, isNull);
      expect(adapter.resets, 1);
    });
  });
}
