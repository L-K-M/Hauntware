import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/android_documents.dart';
import 'package:planchette_app/services/document_store.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_core/planchette_core.dart';

import 'document_workspace_test.dart' show FakeDialogs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('planchette/documents');
  const path = '/documents/provider/config.txt';
  late AndroidDocuments documents;
  late Uint8List providerBytes;
  late List<MethodCall> writes;
  PlatformException? writeError;
  Uint8List? failedWriteBytes;

  setUp(() {
    documents = AndroidDocuments();
    providerBytes = Uint8List.fromList([
      0xef,
      0xbb,
      0xbf,
      ...utf8.encode('a\r\nb\r\n'),
    ]);
    writes = [];
    writeError = null;
    failedWriteBytes = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          switch (call.method) {
            case 'open':
              return [path];
            case 'create':
              return path;
            case 'read':
              return providerBytes;
            case 'readOnly':
              return false;
            case 'stat':
              return {'size': providerBytes.length, 'modified': 1};
            case 'digest':
              return (await documents.load(path)).sha256;
            case 'write':
              writes.add(call);
              if (writeError != null) {
                if (failedWriteBytes != null) providerBytes = failedWriteBytes!;
                throw writeError!;
              }
              providerBytes = (call.arguments as Map)['bytes'] as Uint8List;
              return null;
          }
          throw StateError('Unexpected method: ${call.method}');
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'provider documents retain their identity, BOM, and line endings',
    () async {
      expect(await documents.pickOpenFiles(), [path]);
      final original = await documents.load(path);
      expect(original.file.path, path);
      expect(original.text, 'a\nb\n');
      expect(original.hasUtf8Bom, isTrue);
      expect(original.lineEnding, LineEnding.crlf);

      final saved = await documents.write(
        path: path,
        text: 'changed\n',
        source: original,
        expectedSha256: original.sha256,
      );
      expect(providerBytes, [0xef, 0xbb, 0xbf, ...utf8.encode('changed\r\n')]);
      expect(
        (writes.single.arguments as Map)['expectedSha256'],
        original.sha256,
      );
      expect(saved.file.path, path);
      expect((await documents.load(path)).sha256, saved.sha256);
    },
  );

  test('invalid input never reaches the document provider', () async {
    providerBytes = Uint8List.fromList([0xff]);
    await expectLater(
      documents.load(path),
      throwsA(isA<TextDocumentException>()),
    );
    for (final text in [
      'binary\u0000text',
      'x' * (textDocumentMaximumBytes + 1),
    ]) {
      await expectLater(
        documents.write(
          path: path,
          text: text,
          source: null,
          expectedSha256: null,
        ),
        throwsA(isA<TextDocumentException>()),
      );
    }
    expect(writes, isEmpty);
  });

  test(
    'managed copies cannot be published through a document provider',
    () async {
      final original = await documents.load(
        path,
        symlinkPolicy: SymlinkPolicy.reject,
      );
      await expectLater(
        documents.write(
          path: path,
          text: 'remote content',
          source: original,
          expectedSha256: original.sha256,
          target: DocumentWriteTarget.managedRemote,
        ),
        throwsA(isA<TextDocumentException>()),
      );
      expect(writes, isEmpty);
      expect((await documents.load(path)).sha256, original.sha256);
    },
  );

  test(
    'provider failures retain the dirty buffer and saved baseline',
    () async {
      final workspace = DocumentWorkspace(
        store: documents,
        dialogs: FakeDialogs(),
      );
      addTearDown(workspace.dispose);
      await workspace.openAll([path]);
      final tab = workspace.active!;
      final baseline = tab.baseline;
      tab.editor.text.text = 'unsaved';
      writeError = PlatformException(
        code: 'document_error',
        message: 'Provider disconnected',
      );

      expect(await workspace.save(tab), isFalse);
      expect(tab.editor.text.text, 'unsaved');
      expect(tab.editor.isDirty, isTrue);
      expect(tab.baseline, same(baseline));
      expect(workspace.error, contains('Provider disconnected'));
    },
  );

  test('partial provider writes keep recovery instructions visible', () async {
    final workspace = DocumentWorkspace(
      store: documents,
      dialogs: FakeDialogs(),
    );
    addTearDown(workspace.dispose);
    await workspace.openAll([path]);
    final tab = workspace.active!;
    final baseline = tab.baseline;
    tab.editor.text.text = 'unsaved edits';
    failedWriteBytes = Uint8List.fromList(utf8.encode('partial write'));
    writeError = PlatformException(
      code: 'document_recovery',
      message:
          'Restart Planchette to open the recovery copy, then use Save As.',
    );

    expect(await workspace.save(tab), isFalse);
    expect(tab.disk, DiskState.changed);
    expect(tab.editor.isDirty, isTrue);
    expect(tab.baseline, same(baseline));
    expect(workspace.error, contains('Restart Planchette'));
  });
}
