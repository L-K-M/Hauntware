import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

// Files over the background threshold (256 KiB) decode and encode in
// another isolate (P4). These pin that the results, the typed errors and
// the guarded checks are the same there as for small files, and that an
// injected digest which cannot cross isolates still works.

/// Comfortably over the threshold, well under the 4 MiB limit.
const _largeLength = 600 * 1024;

String _largeText(String lineEnding) {
  final line = 'final value = compute(alpha, beta); // straße$lineEnding';
  return line * (_largeLength ~/ line.length + 1);
}

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planchette-large-');
    directory = Directory(await directory.resolveSymbolicLinks());
    file = File('${directory.path}/large.txt');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('loads and saves a large CRLF file with its metadata', () async {
    final text = _largeText('\r\n');
    await file.writeAsBytes([0xef, 0xbb, 0xbf, ...utf8.encode(text)]);

    final document = await loadTextDocument(file);

    expect(document.text, text.replaceAll('\r\n', '\n'));
    expect(document.lineEnding, LineEnding.crlf);
    expect(document.hasUtf8Bom, isTrue);
    expect(document.encoding, TextEncoding.utf8);

    final digest = await saveTextDocument(
      file,
      '${document.text}tail\n',
      expectedSha256: document.sha256,
      hasUtf8Bom: true,
      lineEnding: LineEnding.crlf,
    );

    final bytes = await file.readAsBytes();
    expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
    expect(utf8.decode(bytes.skip(3).toList()), '${text}tail\r\n');
    expect(digest, await textDocumentSha256(file));
  });

  test('reports a large binary file with the usual message', () async {
    await file.writeAsString('${_largeText('\n')}\u0000');

    await expectLater(
      loadTextDocument(file),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'This file appears to be binary, not editable text.',
        ),
      ),
    );
  });

  test('keeps the encoding error type for a large invalid file', () async {
    await file.writeAsBytes([...utf8.encode(_largeText('\n')), 0xff]);

    await expectLater(
      loadTextDocument(file),
      throwsA(isA<UnsupportedTextEncodingException>()),
    );
  });

  test('refuses to save large text with a NUL, naming its offset', () async {
    await file.writeAsString('small\n');
    final document = await loadTextDocument(file);
    final text = _largeText('\n');

    await expectLater(
      saveTextDocument(file, '$text\u0000', expectedSha256: document.sha256),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          contains('NUL character at code unit ${text.length}'),
        ),
      ),
    );
    expect(await file.readAsString(), 'small\n');
  });

  test('a large file changed between the reads is refused', () async {
    await file.writeAsString(_largeText('\n'));
    // The closure holds a StreamController, which cannot be sent to another
    // isolate: the digest must stay on the caller's isolate.
    final events = StreamController<String>.broadcast();
    addTearDown(events.close);
    var reads = 0;
    Future<String> tamperingSha256(File target) async {
      events.add(target.path);
      final digest = await textDocumentSha256(target);
      if (++reads == 1) await target.writeAsString('raced change\n');
      return digest;
    }

    await expectLater(
      loadTextDocument(file, sha256Of: tamperingSha256),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'The file changed while it was being opened.',
        ),
      ),
    );
  });

  test('an injected digest that cannot cross isolates still loads', () async {
    final text = _largeText('\n');
    await file.writeAsString(text);
    final events = StreamController<String>.broadcast();
    addTearDown(events.close);
    Future<String> observedSha256(File target) {
      events.add(target.path);
      return textDocumentSha256(target);
    }

    final document = await loadTextDocument(file, sha256Of: observedSha256);

    expect(document.text, text);
  });
}
