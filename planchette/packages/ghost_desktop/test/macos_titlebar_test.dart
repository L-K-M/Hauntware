import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

/// The integrated macOS titlebar: the install, its fallback to the
/// standard titlebar, and the band's state over the host's window channel.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channelName = 'test/window';
  const channel = MethodChannel(channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  void answerBandQuery(Object? Function(MethodCall call) answer) {
    messenger.setMockMethodCallHandler(channel, (call) async => answer(call));
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  test('returns the band and asks the runner for its state', () async {
    final calls = <String>[];
    answerBandQuery((call) {
      calls.add(call.method);
      return false;
    });
    final adapter = _FakeTitlebar();

    final band = await installMacosTitlebar(
      channelName: channelName,
      adapter: adapter,
    );
    addTearDown(() => band?.dispose());

    expect(adapter.calls, ['install']);
    expect(band, isNotNull);
    expect(calls, ['isToolbarBandVisible']);
    // A window restored straight into full screen has no band.
    expect(band!.value, isFalse);
  });

  test('keeps the windowed layout when no runner answers', () async {
    // An empty reply is how a channel without a handler answers.
    messenger.setMockMessageHandler(channelName, (_) async => null);
    addTearDown(() => messenger.setMockMessageHandler(channelName, null));

    final band = await installMacosTitlebar(
      channelName: channelName,
      adapter: _FakeTitlebar(),
    );
    addTearDown(() => band?.dispose());

    expect(band?.value, isTrue);
  });

  // The band is cosmetic and the install runs before the window is shown,
  // so a runner that fails the query must not stop the launch.
  for (final (name, reply) in <(String, Object? Function(MethodCall))>[
    ('an error', (_) => throw PlatformException(code: 'BOOM')),
    ('a non-bool reply', (_) => 'yes'),
  ]) {
    test('a band query that answers with $name keeps the band', () async {
      answerBandQuery(reply);
      final adapter = _FakeTitlebar();

      final band = await installMacosTitlebar(
        channelName: channelName,
        adapter: adapter,
      );
      addTearDown(() => band?.dispose());

      // The titlebar is installed, so the band stays reserved in the
      // windowed layout.
      expect(band?.value, isTrue);
      expect(adapter.calls, ['install']);
    });
  }

  test('follows the runner into and out of full screen', () async {
    answerBandQuery((_) => true);
    final band = await installMacosTitlebar(
      channelName: channelName,
      adapter: _FakeTitlebar(),
    );
    addTearDown(() => band?.dispose());

    Future<void> runnerSays(bool visible) => messenger.handlePlatformMessage(
      channelName,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('toolbarBandChanged', visible),
      ),
      (_) {},
    );

    await runnerSays(false);
    expect(band!.value, isFalse);
    await runnerSays(true);
    expect(band.value, isTrue);
  });

  test('puts the standard titlebar back when the install fails', () async {
    final adapter = _FakeTitlebar()..failInstall = true;

    final band = await installMacosTitlebar(
      channelName: channelName,
      adapter: adapter,
    );

    expect(band, isNull, reason: 'nothing reserves a band');
    expect(adapter.calls, ['install', 'reset']);
  });

  test('survives a failed reset too', () async {
    final adapter = _FakeTitlebar()
      ..failInstall = true
      ..failReset = true;

    expect(
      await installMacosTitlebar(channelName: channelName, adapter: adapter),
      isNull,
    );
    expect(adapter.calls, ['install', 'reset']);
  });
}

final class _FakeTitlebar implements MacosTitlebarAdapter {
  final calls = <String>[];
  bool failInstall = false;
  bool failReset = false;

  @override
  Future<void> install() async {
    calls.add('install');
    if (failInstall) throw PlatformException(code: 'NO_WINDOW');
  }

  @override
  Future<void> reset() async {
    calls.add('reset');
    if (failReset) throw PlatformException(code: 'NO_WINDOW');
  }
}
