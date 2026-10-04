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
      final intake = OpenDocuments(open: (paths) async => seen.addAll(paths));
      await intake.start(['/command line/two.txt'], macOS: true);
      expect(seen, ['/cold launch/one.txt', '/command line/two.txt']);
      intake.dispose();
    },
  );

  test(
    'batches wait for preceding documents and ignore malformed entries',
    () async {
      final gate = Completer<void>();
      final seen = <List<String>>[];
      final intake = OpenDocuments(
        open: (paths) async {
          if (paths.contains('one')) await gate.future;
          seen.add(paths);
        },
      );
      final first = intake.accept(['one', 42, '', 'two']);
      final second = intake.accept(['three']);
      await Future<void>.delayed(Duration.zero);
      expect(seen, isEmpty);
      gate.complete();
      await Future.wait([first, second]);
      expect(seen, [
        ['one', 'two'],
        ['three'],
      ]);
      intake.dispose();
    },
  );

  // Which paths exist decides whether a dash-led entry is a file or an
  // option, so each test states it.
  bool Function(String) existing(Set<String> files) => files.contains;

  test('non-macOS argv does not require the native document channel', () async {
    final seen = <String>[];
    final intake = OpenDocuments(
      open: (paths) async => seen.addAll(paths),
      pathExists: existing({'-draft.txt', '/document.txt'}),
    );
    // A dash-named file that exists is a document, not an option.
    await intake.start(['-draft.txt', '/document.txt'], macOS: false);
    expect(seen, ['-draft.txt', '/document.txt']);
    intake.dispose();
  });

  test('options are not opened as documents', () async {
    final seen = <String>[];
    final intake = OpenDocuments(
      open: (paths) async => seen.addAll(paths),
      pathExists: existing({'/document.txt'}),
    );
    await intake.start(['--help', '/document.txt', '--version'], macOS: false);
    expect(seen, ['/document.txt']);
    intake.dispose();
  });

  test('everything after a bare -- is a document', () async {
    final seen = <String>[];
    final intake = OpenDocuments(
      open: (paths) async => seen.addAll(paths),
      pathExists: existing({}),
    );
    await intake.start(['--', '-new.txt', '--help'], macOS: false);
    expect(seen, ['-new.txt', '--help']);
    intake.dispose();
  });

  test('macOS argv skips only the Finder process-serial argument', () async {
    final seen = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final intake = OpenDocuments(
      open: (paths) async => seen.addAll(paths),
      pathExists: existing({'-draft.txt'}),
    );
    await intake.start(['-psn_0_12345', '-draft.txt'], macOS: true);
    expect(seen, ['-draft.txt']);
    intake.dispose();
  });

  test('macOS argv keeps a file whose name only resembles a serial', () async {
    final seen = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final intake = OpenDocuments(
      open: (paths) async => seen.addAll(paths),
      pathExists: existing({'-psn_notes.txt'}),
    );
    await intake.start(['-psn_notes.txt'], macOS: true);
    expect(seen, ['-psn_notes.txt']);
    intake.dispose();
  });

  test('macOS argv drops injected defaults with their values', () async {
    final seen = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final intake = OpenDocuments(
      open: (paths) async => seen.addAll(paths),
      pathExists: existing({'/document.txt', '-draft.txt'}),
    );
    // Xcode's Document Versions option, a scheme's language override and
    // legacy state restoration, each with its value.
    await intake.start([
      '-NSDocumentRevisionsDebugMode',
      'YES',
      '/document.txt',
      '-AppleLanguages',
      '(de)',
      '-ApplePersistenceIgnoreState',
      'NO',
      '-draft.txt',
    ], macOS: true);
    expect(seen, ['/document.txt', '-draft.txt']);
    intake.dispose();
  });

  test('macOS argv keeps a file after a valueless injected option', () async {
    final seen = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final intake = OpenDocuments(
      open: (paths) async => seen.addAll(paths),
      pathExists: existing({'-draft.txt', 'notes.txt'}),
    );
    // Neither a dash-led entry nor an existing file is taken as a value.
    await intake.start([
      '-ApplePersistenceIgnoreState',
      '-draft.txt',
      '-NSQuitAlwaysKeepsWindows',
      'notes.txt',
    ], macOS: true);
    expect(seen, ['-draft.txt', 'notes.txt']);
    intake.dispose();
  });

  test('macOS argv drops an injected option at the end', () async {
    final seen = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async => null);
    final intake = OpenDocuments(
      open: (paths) async => seen.addAll(paths),
      pathExists: existing({'/document.txt'}),
    );
    await intake.start([
      '/document.txt',
      '-NSDocumentRevisionsDebugMode',
    ], macOS: true);
    expect(seen, ['/document.txt']);
    intake.dispose();
  });

  test(
    'an unexpected callback failure does not poison the next batch',
    () async {
      final seen = <String>[];
      final intake = OpenDocuments(
        open: (paths) async {
          if (paths.contains('bad')) throw StateError('unexpected failure');
          seen.addAll(paths);
        },
      );
      await expectLater(intake.accept(['bad']), throwsStateError);
      await intake.accept(['good']);
      expect(seen, ['good']);
      intake.dispose();
    },
  );
}
