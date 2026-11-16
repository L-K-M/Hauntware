import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_editors/ghost_editors.dart';

const _channel = MethodChannel('test/files');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('ghost_editors'));
  tearDown(() {
    debugEditorHostPlatform = null;
    messenger.setMockMethodCallHandler(_channel, null);
    temp.deleteSync(recursive: true);
  });

  File executable(String name) {
    final file = File('${temp.path}/$name')..writeAsStringSync('#!/bin/sh\n');
    if (!Platform.isWindows) {
      Process.runSync('chmod', ['755', file.path]);
    }
    return file;
  }

  group('openWith', () {
    test('macOS asks the runner channel with the bundle identifier', () async {
      debugEditorHostPlatform = () => EditorHostPlatform.macos;
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(_channel, (call) async {
        calls.add(call);
        return null;
      });

      await const GhostEditorLauncher(channel: _channel).openWith(
        '/tmp/a.txt',
        const ExternalEditorDefinition(
          id: 'code',
          displayName: 'Code',
          platform: EditorHostPlatform.macos,
          launchTarget: 'com.example.code',
        ),
      );

      expect(calls.single.method, 'openWithApplication');
      expect(calls.single.arguments, {
        'path': '/tmp/a.txt',
        'bundleIdentifier': 'com.example.code',
      });
    });

    test('an editor for another platform is refused', () async {
      debugEditorHostPlatform = () => EditorHostPlatform.linux;
      expect(
        const GhostEditorLauncher(channel: _channel).openWith(
          '/tmp/a.txt',
          const ExternalEditorDefinition(
            id: 'code',
            displayName: 'Code',
            platform: EditorHostPlatform.macos,
            launchTarget: 'com.example.code',
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('Linux starts the executable with the path as its only argument, '
        'never through a shell', () async {
      debugEditorHostPlatform = () => EditorHostPlatform.linux;
      final editor = executable('editor');
      final started = <(String, List<String>)>[];
      await GhostEditorLauncher(
        channel: _channel,
        processStarter: (exe, arguments) async {
          started.add((exe, arguments));
          return Process.start('true', const []);
        },
      ).openWith(
        '/tmp/a b.txt',
        ExternalEditorDefinition(
          id: 'editor',
          displayName: 'Editor',
          platform: EditorHostPlatform.linux,
          launchTarget: editor.path,
        ),
      );

      expect(started.single.$1, editor.path);
      expect(started.single.$2, ['/tmp/a b.txt']);
    }, testOn: 'linux');

    test('a missing executable names where it was expected', () async {
      debugEditorHostPlatform = () => EditorHostPlatform.linux;
      await expectLater(
        const GhostEditorLauncher(channel: _channel).openWith(
          '/tmp/a.txt',
          ExternalEditorDefinition(
            id: 'editor',
            displayName: 'Editor',
            platform: EditorHostPlatform.linux,
            launchTarget: '${temp.path}/gone',
          ),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('no longer installed'),
          ),
        ),
      );
    }, testOn: 'linux');
  });

  group('pickEditor', () {
    test('macOS passes the title and builds a definition', () async {
      debugEditorHostPlatform = () => EditorHostPlatform.macos;
      MethodCall? call;
      messenger.setMockMethodCallHandler(_channel, (received) async {
        call = received;
        return {'bundleIdentifier': 'com.example.code', 'displayName': 'Code'};
      });

      final picked = await const GhostEditorLauncher(
        channel: _channel,
      ).pickEditor(dialogTitle: 'Pick one');

      expect(call!.method, 'pickApplication');
      expect(call!.arguments, {'title': 'Pick one'});
      expect(picked!.displayName, 'Code');
      expect(picked.launchTarget, 'com.example.code');
      expect(picked.platform, EditorHostPlatform.macos);
      expect(
        picked.id,
        matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab]')),
      );
    });

    test('Linux validates the picked executable', () async {
      debugEditorHostPlatform = () => EditorHostPlatform.linux;
      final editor = executable('my-editor');
      String? title;
      final picked = await GhostEditorLauncher(
        channel: _channel,
        executablePicker: (platform, dialogTitle) async {
          title = dialogTitle;
          return editor.path;
        },
      ).pickEditor(dialogTitle: 'Pick one');

      expect(title, 'Pick one');
      expect(picked!.displayName, 'my-editor');
      expect(picked.launchTarget, editor.path);

      final plain = File('${temp.path}/plain')..writeAsStringSync('');
      expect(
        GhostEditorLauncher(
          channel: _channel,
          executablePicker: (_, _) async => plain.path,
        ).pickEditor(dialogTitle: 'Pick one'),
        throwsStateError,
      );
    }, testOn: 'linux');

    test('a host without desktop editors picks nothing', () async {
      debugEditorHostPlatform = () => null;
      expect(
        await const GhostEditorLauncher(
          channel: _channel,
        ).pickEditor(dialogTitle: 'Pick one'),
        isNull,
      );
    });
  });
}
