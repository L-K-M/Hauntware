import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_keepalive/ghost_keepalive.dart';

class _Strings implements KeepAliveStrings {
  const _Strings();

  @override
  String get channelId => 'app.keepalive';

  @override
  String get channelName => 'App keep-alive';

  @override
  String get channelDescription => 'Shown while work is kept alive.';

  @override
  String get notificationTitle => 'App';

  @override
  String notificationText(int count) => 'Keeping $count items alive.';

  @override
  String get smallIconResourceName => 'ic_stat_keep_alive';
}

void main() {
  // The backend gates on defaultTargetPlatform (not dart:io), so the test
  // binding decides the host. Pin the channel name by listening here: a
  // backend talking anywhere else never reaches this handler and fails
  // the expectations below.
  const channel = MethodChannel('ghost_keepalive');
  final calls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.ensureInitialized().defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
    calls.clear();
  });

  test('activate marshals the count and every app string', () async {
    const backend = MethodChannelBackgroundKeepAliveBackend(
      strings: _Strings(),
    );

    await backend.activate(3);

    expect(calls.single.method, 'activate');
    expect(calls.single.arguments, <String, Object?>{
      'count': 3,
      'channelId': 'app.keepalive',
      'channelName': 'App keep-alive',
      'channelDescription': 'Shown while work is kept alive.',
      'notificationTitle': 'App',
      'notificationText': 'Keeping 3 items alive.',
      'smallIconResourceName': 'ic_stat_keep_alive',
    });
  });

  test('countChanged marshals the same keys with the new count', () async {
    const backend = MethodChannelBackgroundKeepAliveBackend(
      strings: _Strings(),
    );

    await backend.countChanged(1);

    expect(calls.single.method, 'countChanged');
    final arguments = calls.single.arguments as Map<Object?, Object?>;
    expect(arguments['count'], 1);
    expect(arguments['notificationText'], 'Keeping 1 items alive.');
  });

  test('deactivate carries no arguments', () async {
    const backend = MethodChannelBackgroundKeepAliveBackend(
      strings: _Strings(),
    );

    await backend.deactivate();

    expect(calls.single.method, 'deactivate');
    expect(calls.single.arguments, isNull);
  });

  test('off Android the channel is never touched', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    const backend = MethodChannelBackgroundKeepAliveBackend(
      strings: _Strings(),
    );

    await backend.activate(1);
    await backend.countChanged(2);
    await backend.deactivate();

    expect(calls, isEmpty);
  });
}
