import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/window_host.dart';

final class _Listener implements WindowHostListener {
  final activated = <int>[];
  final closeRequested = <int>[];

  @override
  void onWindowActivated(int viewId) => activated.add(viewId);

  @override
  void onWindowCloseRequested(int viewId) => closeRequested.add(viewId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = documentWindowsChannel;
  const codec = StandardMethodCodec();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  setUp(() => calls = []);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  void answer(Object? Function(MethodCall call) reply) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return reply(call);
    });
  }

  Future<void> fromNative(String method, Object? arguments) =>
      messenger.handlePlatformMessage(
        channel.name,
        codec.encodeMethodCall(MethodCall(method, arguments)),
        (_) {},
      );

  test('asks the runner, and reads no runner as one window', () async {
    final host = MethodChannelWindowHost(engineId: () => 7);
    expect(await host.isAvailable(), isFalse);

    answer((_) => true);
    expect(await host.isAvailable(), isTrue);
    expect(calls.single.method, WindowHostMethod.isAvailable.name);
  });

  test('create sends the engine id and answers the view id', () async {
    answer((_) => 3);
    final host = MethodChannelWindowHost(engineId: () => 12345678901);

    expect(await host.create(), 3);
    expect(calls.single.method, WindowHostMethod.create.name);
    expect(calls.single.arguments, {WindowHostKey.engineId.name: 12345678901});
  });

  test(
    'document create passes its filename as the native window title',
    () async {
      answer((_) => 3);
      final host = MethodChannelWindowHost(engineId: () => 7);
      expect(await host.create(title: 'config.txt'), 3);
      expect(calls.single.arguments, {'engineId': 7, 'title': 'config.txt'});
    },
  );

  test('a failed or missing create is a WindowHostException', () async {
    final host = MethodChannelWindowHost(engineId: () => 1);
    await expectLater(host.create(), throwsA(isA<WindowHostException>()));

    answer((_) => throw PlatformException(code: 'CREATE_FAILED'));
    await expectLater(host.create(), throwsA(isA<WindowHostException>()));

    answer((_) => null);
    await expectLater(host.create(), throwsA(isA<WindowHostException>()));
  });

  test('every other call names the window by its view id', () async {
    answer((call) => call.method == WindowHostMethod.isFullScreen.name);
    final host = MethodChannelWindowHost(engineId: () => 1);

    await host.destroy(2);
    await host.activate(0);
    await host.hide(0);
    await host.setTitle(2, 'draft.txt — Planchette');
    expect(await host.isFullScreen(2), isTrue);
    await host.setFullScreen(2, fullScreen: true);

    expect(
      [for (final call in calls) call.method],
      [
        WindowHostMethod.destroy.name,
        WindowHostMethod.activate.name,
        WindowHostMethod.hide.name,
        WindowHostMethod.setTitle.name,
        WindowHostMethod.isFullScreen.name,
        WindowHostMethod.setFullScreen.name,
      ],
    );
    expect(calls.first.arguments, {WindowHostKey.viewId.name: 2});
    expect(calls[3].arguments, {
      WindowHostKey.viewId.name: 2,
      WindowHostKey.title.name: 'draft.txt — Planchette',
    });
    expect(calls.last.arguments, {
      WindowHostKey.viewId.name: 2,
      WindowHostKey.fullScreen.name: true,
    });
  });

  test('pickers name their owning window and shape their arguments', () async {
    answer(
      (call) => switch (call.method) {
        'pickOpenFiles' => ['/tmp/a.txt', '/tmp/b.txt'],
        'pickSavePath' => '/tmp/out.html',
        _ => null,
      },
    );
    final host = MethodChannelWindowHost(engineId: () => 1);

    expect(await host.pickOpenFiles(4), ['/tmp/a.txt', '/tmp/b.txt']);
    expect(
      await host.pickSavePath(
        4,
        suggestedName: 'out.html',
        initialDirectory: '/tmp',
      ),
      '/tmp/out.html',
    );

    expect(calls[0].method, WindowHostMethod.pickOpenFiles.name);
    expect(calls[0].arguments, {WindowHostKey.viewId.name: 4});
    expect(calls[1].method, WindowHostMethod.pickSavePath.name);
    expect(calls[1].arguments, {
      WindowHostKey.viewId.name: 4,
      WindowHostKey.suggestedName.name: 'out.html',
      WindowHostKey.initialDirectory.name: '/tmp',
    });
  });

  test('picker answers that are not a list are a host failure', () async {
    answer((_) => 'not a list');
    final host = MethodChannelWindowHost(engineId: () => 1);
    await expectLater(
      host.pickOpenFiles(1),
      throwsA(isA<WindowHostException>()),
    );
  });

  test("the runner's reports reach the listener until it is cleared", () async {
    final host = MethodChannelWindowHost(engineId: () => 1);
    final listener = _Listener();
    host.listener = listener;

    await fromNative(WindowHostEvent.activated.name, {
      WindowHostKey.viewId.name: 0,
    });
    await fromNative(WindowHostEvent.closeRequested.name, {
      WindowHostKey.viewId.name: 4,
    });
    // Malformed reports are dropped.
    await fromNative(WindowHostEvent.activated.name, null);
    await fromNative(WindowHostEvent.activated.name, {'viewId': 'four'});

    expect(listener.activated, [0]);
    expect(listener.closeRequested, [4]);

    host.listener = null;
    await fromNative(WindowHostEvent.activated.name, {
      WindowHostKey.viewId.name: 1,
    });
    expect(listener.activated, [0]);
  });
}
