import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/document_store.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_core/planchette_core.dart';

import 'document_workspace_test.dart' show FakeDialogs;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory folder;
  late DocumentWorkspace workspace;
  late FakeDialogs dialogs;

  setUp(() async {
    folder = await Directory.systemTemp.createTemp('planchette-metadata-');
    dialogs = FakeDialogs();
    workspace = DocumentWorkspace(
      store: LocalDocumentStore(),
      dialogs: dialogs,
    );
  });
  tearDown(() async {
    workspace.dispose();
    await folder.delete(recursive: true);
  });

  test('untitled choices write exact bytes and Save As retains them', () async {
    final tab = workspace.newDocument()!;
    tab.editor.text.text = 'é\nx';
    tab.editor.setMetadata(
      const TextDocumentMetadata(
        lineEnding: LineEnding.crlf,
        utf8Bom: Utf8Bom.present,
      ),
    );
    final first = File('${folder.path}/first.txt');
    dialogs.savePath = first.path;
    expect(await workspace.save(tab), isTrue);
    expect(await first.readAsBytes(), [
      0xef,
      0xbb,
      0xbf,
      0xc3,
      0xa9,
      0x0d,
      0x0a,
      0x78,
    ]);
    expect(tab.editor.isDirty, isFalse);
    expect(tab.editor.fileByteCount, await first.length());

    final second = File('${folder.path}/second.txt');
    dialogs.savePath = second.path;
    expect(await workspace.save(tab, saveAs: true), isTrue);
    expect(await second.readAsBytes(), await first.readAsBytes());
    expect(tab.editor.isDirty, isFalse);
    expect(tab.path, await second.resolveSymbolicLinks());
  });

  test(
    'metadata-only save changes disk format and becomes the reload baseline',
    () async {
      final file = File('${folder.path}/existing.txt');
      await file.writeAsBytes([0xef, 0xbb, 0xbf, 0x61, 0x0d, 0x0a]);
      await workspace.open(file.path);
      final tab = workspace.active!;
      expect(tab.editor.isDirty, isFalse);
      tab.editor.setMetadata(const TextDocumentMetadata());
      expect(await workspace.save(tab), isTrue);
      expect(await file.readAsBytes(), [0x61, 0x0a]);
      expect(tab.editor.isDirty, isFalse);
      tab.editor.setMetadata(
        const TextDocumentMetadata(utf8Bom: Utf8Bom.present),
      );
      expect(tab.editor.isDirty, isTrue);
      await workspace.revert(tab);
      expect(tab.editor.metadata, const TextDocumentMetadata());
      expect(tab.editor.isDirty, isFalse);
    },
  );

  test('changed format still honors the original conflict digest', () async {
    final file = File('${folder.path}/conflict.txt');
    await file.writeAsString('original');
    await workspace.open(file.path);
    final tab = workspace.active!;
    tab.editor.setMetadata(
      const TextDocumentMetadata(utf8Bom: Utf8Bom.present),
    );
    await file.writeAsString('external');
    expect(await workspace.save(tab), isFalse);
    expect(await file.readAsString(), 'external');
    expect(tab.editor.isDirty, isTrue);
  });

  test(
    'save cleanup is applied to the buffer and encoded using its chosen format',
    () async {
      workspace.saveOptions = const TextSaveOptions(
        trailingWhitespace: TrailingWhitespacePolicy.trim,
        finalNewline: FinalNewlinePolicy.ensure,
      );
      final tab = workspace.newDocument()!;
      tab.editor.text.text = 'a  \nb\t';
      tab.editor.setMetadata(
        const TextDocumentMetadata(lineEnding: LineEnding.crlf),
      );
      final file = File('${folder.path}/cleaned.txt');
      dialogs.savePath = file.path;
      expect(await workspace.save(tab), isTrue);
      expect(tab.editor.text.text, 'a\nb\n');
      expect(await file.readAsString(), 'a\r\nb\r\n');
      expect(tab.editor.isDirty, isFalse);
    },
  );
}
