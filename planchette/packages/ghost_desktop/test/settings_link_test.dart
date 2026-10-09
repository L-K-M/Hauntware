import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

// One engine in a test, so the two ends of the link get a channel each and a
// relay between them stands in for the runners' byte-for-byte forwarding.
const _appLink = MethodChannel('test/settings_link/app');
const _windowLink = MethodChannel('test/settings_link/window');
const _control = MethodChannel('test/settings_window');

enum _Tab { general, sync, files }

/// A product's app side: one value the window shows, a write that sets it,
/// an echo that returns its argument, and a write that fails.
final class _App extends ChangeNotifier {
  int value = 1;

  /// Snapshot content that no listener announces.
  String quiet = 'a';

  Map<String, Object?> snapshot() => {'value': value, 'quiet': quiet};

  bool get listened => hasListeners;

  Future<Object?> handleCall(String method, Object? argument) async {
    switch (method) {
      case 'setValue':
        value = argument! as int;
        notifyListeners();
        return null;
      case 'echo':
        return argument;
      case 'fail':
        throw StateError('disk full');
    }
    throw MissingPluginException('No method $method');
  }

  GhostSettingsSections sections() => GhostSettingsSections(
    snapshot: snapshot,
    handleCall: handleCall,
    changes: [this],
  );
}

/// The product's typed error, rebuilt in the window.
final class _LinkError implements Exception {
  const _LinkError(this.code, this.message);

  final String code;
  final String? message;
}

/// What the product's window throws when no app answers.
final class _Lost implements Exception {
  const _Lost();
}

/// A product's window side: the copy of the app's value, and the snapshots
/// it applied.
final class _Window extends GhostSettingsWindowClient<_Tab> {
  _Window()
    : super(
        link: _windowLink,
        tabs: _Tab.values,
        decodeError: (error) => _LinkError(error.code, error.message),
        lostError: () => const _Lost(),
      );

  static Future<_Window> connect() async {
    final window = _Window();
    await window.connectToApp();
    return window;
  }

  final applied = <Map<String, Object?>>[];

  /// Set to make the next snapshot fail to apply.
  bool failNextApply = false;

  int get value => applied.last['value']! as int;

  @override
  void applySnapshot(Map<String, Object?> snapshot) {
    if (failNextApply) {
      failNextApply = false;
      throw StateError('could not apply');
    }
    applied.add(snapshot);
  }

  Future<Object?> run(String method, [Object? argument]) =>
      invoke(method, argument);
}

/// The Settings window's link end to end: [GhostSettingsWindowHost] in the
/// app, [GhostSettingsWindowClient] in the window, the runner's relay
/// between them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late _App app;
  late GhostSettingsWindowHost<_Tab> host;
  late List<String> controlCalls;
  late List<Object> reported;

  /// Deliver what one end sends to the other end's handler, and its reply
  /// back: what the runners do between the two engines.
  void relay(MethodChannel from, MethodChannel to) {
    messenger.setMockMessageHandler(from.name, (message) {
      final reply = Completer<ByteData?>();
      ServicesBinding.instance.channelBuffers.push(
        to.name,
        message,
        reply.complete,
      );
      return reply.future;
    });
  }

  /// One end stops answering: its messages find no handler.
  void cut(MethodChannel from) =>
      messenger.setMockMessageHandler(from.name, (_) async => null);

  /// What the runner says when the user closes the window.
  Future<void> nativeClosed() async {
    final reply = Completer<void>();
    ServicesBinding.instance.channelBuffers.push(
      _control.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('closed')),
      (_) => reply.complete(),
    );
    await reply.future;
  }

  GhostSettingsWindowHost<_Tab> newHost({
    PlatformException Function(Object error)? encodeError,
    Future<AppExitResponse> Function()? requestAppExit,
  }) => GhostSettingsWindowHost(
    control: _control,
    link: _appLink,
    initialTab: _Tab.general,
    sections: app.sections(),
    encodeError: encodeError,
    requestAppExit: requestAppExit ?? () async => AppExitResponse.cancel,
  );

  setUp(() {
    app = _App();
    relay(_appLink, _windowLink);
    relay(_windowLink, _appLink);
    controlCalls = [];
    messenger.setMockMethodCallHandler(_control, (call) async {
      controlCalls.add(call.method);
      return null;
    });
    reported = [];
    final onError = FlutterError.onError;
    FlutterError.onError = (details) => reported.add(details.exception);
    addTearDown(() => FlutterError.onError = onError);
    host = newHost();
  });

  tearDown(() {
    host.dispose();
    app.dispose();
    for (final channel in [_appLink, _windowLink]) {
      messenger.setMockMessageHandler(channel.name, null);
    }
    messenger.setMockMethodCallHandler(_control, null);
  });

  /// Open Settings on [tab] and start the window's side, as the runner does
  /// on the first open.
  Future<_Window> openWindow([_Tab tab = _Tab.general]) async {
    expect(await host.open(tab), isTrue);
    final window = await _Window.connect();
    addTearDown(window.dispose);
    return window;
  }

  test('hello brings the first snapshot and the tab asked for', () async {
    app.value = 7;
    final window = await openWindow(_Tab.sync);

    expect(controlCalls, ['open']);
    expect(host.connected, isTrue);
    expect(host.visible, isTrue);
    expect(window.page.value?.tab, _Tab.sync);
    expect(window.page.value?.generation, 0);
    expect(window.value, 7);
  });

  test('a call runs in the app and its answer crosses back', () async {
    final window = await openWindow();

    expect(
      await window.run('echo', {
        'list': [1, 'two'],
        'nested': {'x': null},
      }),
      {
        'list': [1, 'two'],
        'nested': {'x': null},
      },
    );
    expect(await window.run('echo'), isNull);
  });

  test('a failure in the app is reported there and decoded here', () async {
    final window = await openWindow();

    await expectLater(
      window.run('fail'),
      throwsA(
        isA<_LinkError>()
            .having((e) => e.code, 'code', 'settings-failed')
            .having((e) => e.message, 'message', contains('disk full')),
      ),
    );
    expect(reported.single, isA<StateError>());
  });

  test('the product encodes its own errors', () async {
    host.dispose();
    host = newHost(
      encodeError: (error) => PlatformException(code: 'typed', details: 42),
    );
    final window = await openWindow();

    await expectLater(
      window.run('fail'),
      throwsA(isA<_LinkError>().having((e) => e.code, 'code', 'typed')),
    );
  });

  test('a method the product does not know is missing, unreported', () async {
    final window = await openWindow();

    await expectLater(window.run('nope'), throwsA(isA<_Lost>()));
    expect(reported, isEmpty);
  });

  test('window-bound methods never reach the product', () async {
    final seen = <String>[];
    host.attach(
      GhostSettingsSections(
        snapshot: app.snapshot,
        handleCall: (method, argument) async {
          seen.add(method);
          return null;
        },
      ),
    );
    final window = await openWindow();

    for (final method in ['snapshot', 'selectTab', 'hidden', 'show']) {
      await expectLater(window.run(method), throwsA(isA<_Lost>()));
    }
    expect(seen, isEmpty);
  });

  test('a write sends one snapshot; an unchanged one is not resent', () async {
    final window = await openWindow();
    var notified = 0;
    window.addListener(() => notified++);

    await window.run('setValue', 3);
    await pumpEventQueue();
    expect(window.value, 3);
    expect(notified, 1);

    // A burst coalesces into one snapshot.
    app
      ..value = 4
      ..notifyListeners()
      ..value = 5
      ..notifyListeners();
    await pumpEventQueue();
    expect(window.applied.map((s) => s['value']), [1, 3, 5]);

    // A change that moves nothing the window shows is not sent.
    app.notifyListeners();
    await pumpEventQueue();
    expect(notified, 2);
  });

  test('a change no listener announces is sent when told', () async {
    final window = await openWindow();

    app.quiet = 'b';
    host.snapshotChanged();
    await pumpEventQueue();

    expect(window.applied.last['quiet'], 'b');
  });

  test('a snapshot the window failed to apply is sent again', () async {
    final window = await openWindow();

    window.failNextApply = true;
    app
      ..value = 2
      ..notifyListeners();
    await pumpEventQueue();
    expect(window.value, 1);

    // Nothing else changed, but the dedupe forgot what never arrived.
    host.snapshotChanged();
    await pumpEventQueue();
    expect(window.value, 2);
  });

  test('closing hides the screen; opening again shows a fresh one', () async {
    final window = await openWindow();
    final first = window.page.value!;

    await nativeClosed();
    await pumpEventQueue();
    expect(host.visible, isFalse);
    expect(host.connected, isTrue);
    expect(window.page.value, isNull);

    // Nothing is sent to a hidden window…
    app
      ..value = 9
      ..notifyListeners();
    await pumpEventQueue();
    expect(window.value, isNot(9));

    // …and showing it again carries the settings as they are by then.
    expect(await host.open(_Tab.files), isTrue);
    expect(controlCalls, ['open', 'open']);
    expect(host.visible, isTrue);
    final second = window.page.value!;
    expect(second.tab, _Tab.files);
    expect(second.generation, isNot(first.generation));
    expect(window.value, 9);

    await nativeClosed();
    expect(await host.open(_Tab.general), isTrue);
    expect(window.page.value?.generation, isNot(second.generation));
  });

  test('opening a showing window switches its tab', () async {
    final window = await openWindow();
    final tabs = <_Tab>[];
    final subscription = window.tabRequests.listen(tabs.add);
    addTearDown(subscription.cancel);

    expect(await host.open(_Tab.files), isTrue);
    await pumpEventQueue();

    expect(tabs, [_Tab.files]);
    expect(window.page.value?.generation, 0);
  });

  test('rebinding swaps the sections and their listeners', () async {
    final window = await openWindow();
    final next = _App()..value = 20;
    addTearDown(next.dispose);

    host.attach(next.sections());
    await pumpEventQueue();
    expect(window.value, 20);
    expect(app.listened, isFalse);

    // The old sections no longer move the window.
    app
      ..value = 2
      ..notifyListeners();
    await pumpEventQueue();
    expect(window.value, 20);

    next
      ..value = 21
      ..notifyListeners();
    await pumpEventQueue();
    expect(window.value, 21);

    host.dispose();
    expect(next.listened, isFalse);
    host = newHost();
  });

  test("a request to quit is the app's to answer", () async {
    final window = await openWindow();

    expect(await window.requestAppExit(), AppExitResponse.cancel);
    expect(window.lost, isFalse);

    // With no app left to ask, quitting is not held up, and the window
    // says it lost the app.
    var notified = 0;
    window.addListener(() => notified++);
    cut(_windowLink);
    expect(await window.requestAppExit(), AppExitResponse.exit);
    expect(window.lost, isTrue);
    expect(notified, 1);
  });

  test('a window with no app to answer fails to connect', () async {
    cut(_windowLink);

    await expectLater(_Window.connect(), throwsA(isA<_Lost>()));
  });

  test('a window that failed to connect stops listening', () async {
    cut(_windowLink);
    await expectLater(_Window.connect(), throwsA(isA<_Lost>()));

    // A message for the window finds no handler: a null reply.
    var replied = false;
    ByteData? reply;
    await messenger.handlePlatformMessage(
      _windowLink.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('hidden')),
      (data) {
        replied = true;
        reply = data;
      },
    );
    expect(replied, isTrue);
    expect(reply, isNull);
  });

  test('closing a window that stopped answering disconnects quietly', () async {
    await openWindow();
    final sent = <String>[];
    messenger.setMockMessageHandler(_appLink.name, (message) async {
      sent.add(const StandardMethodCodec().decodeMethodCall(message).method);
      return null;
    });

    // The close finds the engine gone.
    await nativeClosed();
    expect(sent, ['hidden']);
    expect(host.connected, isFalse);
    expect(host.visible, isFalse);

    // A second close has no engine to tell.
    await nativeClosed();
    expect(sent, ['hidden']);
  });

  test('a window that stopped answering is opened anew', () async {
    final window = await openWindow();
    await nativeClosed();
    await pumpEventQueue();

    cut(_appLink);
    expect(await host.open(_Tab.sync), isTrue);
    expect(host.connected, isFalse);
    expect(host.visible, isFalse);
    expect(window.page.value, isNull);

    // The runner's new engine says hello and opens on the tab asked for.
    relay(_appLink, _windowLink);
    final fresh = await _Window.connect();
    addTearDown(fresh.dispose);
    expect(fresh.page.value?.tab, _Tab.sync);
    expect(host.visible, isTrue);
  });

  test(
    'a runner without the window reports it, for the in-app fallback',
    () async {
      messenger.setMockMethodCallHandler(_control, null);

      expect(await host.open(_Tab.general), isFalse);
    },
  );

  test('a runner that could not create the window reports it', () async {
    messenger.setMockMethodCallHandler(_control, (call) async {
      throw PlatformException(code: 'open_failed');
    });

    expect(await host.open(_Tab.general), isFalse);
  });
}
