import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/open_documents.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('planchette/documents');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'startup handshake drains Finder files and argv without losing spaces',
    () async {
      final seen = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'ready');
        return ['/cold launch/one.txt'];
      });
      final intake = OpenDocuments(open: (path) async => seen.add(path));
      await intake.start(['/command line/two.txt'], macOS: true);
      expect(seen, ['/cold launch/one.txt', '/command line/two.txt']);
      intake.dispose();
    },
  );

  test(
    'batches wait for preceding documents and ignore malformed entries',
    () async {
      final seen = <String>[];
      final gate = Completer<void>();
      final intake = OpenDocuments(
        open: (path) async {
          seen.add(path);
          if (path == 'one') await gate.future;
        },
      );
      final first = intake.accept(['one', 42, '', 'two']);
      final second = intake.accept(['three']);
      await Future<void>.delayed(Duration.zero);
      expect(seen, ['one']);
      gate.complete();
      await Future.wait([first, second]);
      expect(seen, ['one', 'two', 'three']);
      intake.dispose();
    },
  );

  test('non-macOS argv does not require the native document channel', () async {
    final seen = <String>[];
    final intake = OpenDocuments(open: (path) async => seen.add(path));
    await intake.start(['--flag', '/document.txt'], macOS: false);
    expect(seen, ['/document.txt']);
    intake.dispose();
  });
  test(
    'an unexpected callback failure does not poison the next batch',
    () async {
      final seen = <String>[];
      final intake = OpenDocuments(
        open: (path) async {
          if (path == 'bad') throw StateError('unexpected failure');
          seen.add(path);
        },
      );
      await expectLater(intake.accept(['bad']), throwsStateError);
      await intake.accept(['good']);
      expect(seen, ['good']);
      intake.dispose();
    },
  );
}
