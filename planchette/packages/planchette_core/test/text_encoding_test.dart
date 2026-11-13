import 'dart:io';
import 'dart:typed_data';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

// A9: UTF-16 is detected by its byte order mark and saved back the same
// way; Latin-1 and Windows-1252 open only when the user names them, and
// saving refuses a character the encoding cannot hold.
void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    final created = await Directory.systemTemp.createTemp('planchette-enc-');
    directory = Directory(await created.resolveSymbolicLinks());
    file = File('${directory.path}/document.txt');
  });

  tearDown(() => directory.delete(recursive: true));

  Future<void> saveBack(TextDocument document, {String? text}) async {
    await saveTextDocument(
      file,
      text ?? document.text,
      expectedSha256: document.sha256,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      encoding: document.encoding,
    );
  }

  Matcher failsWith(String message, {bool reopenable = false}) => throwsA(
    allOf(
      reopenable
          ? isA<UnsupportedTextEncodingException>()
          : isA<TextDocumentException>(),
      isA<TextDocumentException>().having((e) => e.message, 'message', message),
    ),
  );

  // 'é', an astral emoji (a surrogate pair), CRLF breaks and a second
  // U+FEFF that is content, not a mark.
  const fixture = 'café \u{1F600}\r\n\u{FEFF}line two\r\n';

  Uint8List utf16(String text, Endian endian, {bool bom = true}) {
    final units = [if (bom) 0xFEFF, ...text.codeUnits];
    final data = ByteData(units.length * 2);
    for (var i = 0; i < units.length; i++) {
      data.setUint16(i * 2, units[i], endian);
    }
    return data.buffer.asUint8List();
  }

  group('UTF-16 by byte order mark', () {
    for (final (encoding, endian) in [
      (TextEncoding.utf16le, Endian.little),
      (TextEncoding.utf16be, Endian.big),
    ]) {
      test('${encoding.label} round-trips byte for byte', () async {
        final bytes = utf16(fixture, endian);
        await file.writeAsBytes(bytes);

        final document = await loadTextDocument(file);

        expect(document.encoding, encoding);
        expect(document.hasUtf8Bom, isFalse);
        expect(document.lineEnding, LineEnding.crlf);
        expect(document.text, 'café \u{1F600}\n\u{FEFF}line two\n');
        expect(document.metadata.encodingLabel, encoding.label);

        await saveBack(document);
        expect(await file.readAsBytes(), bytes);
      });
    }

    test('edits save in the document encoding with its mark', () async {
      await file.writeAsBytes(utf16('a\n', Endian.big));
      final document = await loadTextDocument(file);

      await saveBack(document, text: 'a\n€\n');

      expect(await file.readAsBytes(), utf16('a\n€\n', Endian.big));
    });

    test('an odd byte count is rejected precisely', () async {
      await file.writeAsBytes([...utf16('ab', Endian.little), 0x63]);

      await expectLater(
        loadTextDocument(file),
        failsWith(
          'This file starts with a UTF-16 LE byte order mark but is not '
          'valid UTF-16: it has an odd number of bytes, so its last '
          'character is incomplete.',
          reopenable: true,
        ),
      );
    });

    test('an unpaired surrogate is rejected with its offset', () async {
      // BOM, 'a', then a trail surrogate with no lead at byte 4.
      await file.writeAsBytes([0xfe, 0xff, 0x00, 0x61, 0xdc, 0x00]);

      await expectLater(
        loadTextDocument(file),
        failsWith(
          'This file starts with a UTF-16 BE byte order mark but is not '
          'valid UTF-16: the unpaired surrogate 0xDC00 at byte 4 is not '
          'part of a character.',
          reopenable: true,
        ),
      );
    });

    test('a lead surrogate at the end is rejected', () async {
      await file.writeAsBytes([0xff, 0xfe, 0x3d, 0xd8]);

      await expectLater(
        loadTextDocument(file),
        failsWith(
          'This file starts with a UTF-16 LE byte order mark but is not '
          'valid UTF-16: the unpaired surrogate 0xD83D at byte 2 is not '
          'part of a character.',
          reopenable: true,
        ),
      );
    });

    test('a UTF-32 mark is named rather than read as UTF-16', () async {
      await file.writeAsBytes([0xff, 0xfe, 0x00, 0x00, 0x61, 0, 0, 0]);

      await expectLater(
        loadTextDocument(file),
        failsWith(
          'This file starts with a UTF-32 byte order mark. UTF-32 text is '
          'not supported.',
          reopenable: true,
        ),
      );
    });

    test('an unmarked file is never guessed to be UTF-16', () async {
      await file.writeAsBytes(utf16('ab', Endian.little, bom: false));

      // 'a', NUL, 'b', NUL: valid UTF-8 holding NULs, so binary.
      await expectLater(
        loadTextDocument(file),
        failsWith('This file appears to be binary, not editable text.'),
      );
      await expectLater(
        loadTextDocument(file, encoding: TextEncoding.utf16le),
        failsWith(
          'This file does not start with a UTF-16 LE byte order mark. Only '
          'marked UTF-16 files can be opened as UTF-16.',
          reopenable: true,
        ),
      );
    });

    test('the size limit counts encoded bytes', () async {
      // Six characters are 14 bytes with the mark: over a 12-byte limit.
      await file.writeAsBytes(utf16('abcdef', Endian.little));
      await expectLater(
        loadTextDocument(file, maximumBytes: 12),
        failsWith('The built-in editor supports text files up to 0 MB.'),
      );
      expect(
        textDocumentByteCount(
          'ab\ncd',
          const TextDocumentMetadata(
            lineEnding: LineEnding.crlf,
            encoding: TextEncoding.utf16be,
          ),
        ),
        2 + 2 * 'ab\r\ncd'.length,
      );

      await file.writeAsBytes(utf16('a', Endian.little));
      final document = await loadTextDocument(file);
      await expectLater(
        saveTextDocument(
          file,
          'abcdef',
          expectedSha256: document.sha256,
          encoding: TextEncoding.utf16le,
          maximumBytes: 12,
        ),
        failsWith('The edited file exceeds the 0 MB built-in editor limit.'),
      );
    });

    test('an unpaired surrogate in the buffer blocks a UTF-16 save', () async {
      await file.writeAsBytes(utf16('a', Endian.little));
      final document = await loadTextDocument(file);

      await expectLater(
        saveBack(document, text: 'a\nb\uD800'),
        failsWith(
          'The character U+D800 at line 2, column 2 cannot be saved in '
          'UTF-16 LE. Remove or replace it, or choose an encoding that '
          'can represent it.',
        ),
      );
      expect(await file.readAsBytes(), utf16('a', Endian.little));
    });
  });

  group('text that is not UTF-8', () {
    // 'café' in Latin-1: the é is the single byte 0xE9.
    final latin1Bytes = [0x63, 0x61, 0x66, 0xe9, 0x0a];

    test('is refused by default with the first bad byte', () async {
      await file.writeAsBytes(latin1Bytes);

      await expectLater(
        loadTextDocument(file),
        failsWith(
          'This file is not valid UTF-8 text: the byte 0xE9 at offset 3 '
          'does not begin a valid UTF-8 sequence.',
          reopenable: true,
        ),
      );
    });

    test('names the offset after a UTF-8 mark', () async {
      await file.writeAsBytes([0xef, 0xbb, 0xbf, 0x61, 0xc3, 0x28]);

      await expectLater(
        loadTextDocument(file),
        failsWith(
          'This file is not valid UTF-8 text: the byte 0xC3 at offset 4 '
          'does not begin a valid UTF-8 sequence.',
          reopenable: true,
        ),
      );
    });

    test('reopens as Latin-1 only when asked, and round-trips', () async {
      // Every byte value except NUL, which loading treats as binary.
      final bytes = [for (var b = 1; b < 256; b++) b];
      await file.writeAsBytes(bytes);

      final document = await loadTextDocument(
        file,
        encoding: TextEncoding.latin1,
        normalization: TextNormalization.preserve,
      );

      expect(document.encoding, TextEncoding.latin1);
      expect(document.text, String.fromCharCodes(bytes));
      expect(document.metadata.encodingLabel, 'Latin-1');
      await saveTextDocument(
        file,
        document.text,
        expectedSha256: document.sha256,
        encoding: document.encoding,
        normalization: TextNormalization.preserve,
      );
      expect(await file.readAsBytes(), bytes);
    });

    test('reopens as Windows-1252 and maps its extra characters', () async {
      // 0x80 is the euro sign and 0x93/0x94 are curly quotes in 1252.
      final bytes = [0x80, 0x20, 0x93, 0x61, 0x94, 0x0a, 0xe9, 0x0a];
      await file.writeAsBytes(bytes);

      final document = await loadTextDocument(
        file,
        encoding: TextEncoding.windows1252,
      );

      expect(document.text, '€ “a”\né\n');
      expect(document.metadata.encodingLabel, 'Windows-1252');
      await saveBack(document);
      expect(await file.readAsBytes(), bytes);
    });

    test('Windows-1252 rejects a byte it does not define', () async {
      await file.writeAsBytes([0x61, 0x81]);

      await expectLater(
        loadTextDocument(file, encoding: TextEncoding.windows1252),
        failsWith(
          'This file is not valid Windows-1252 text: the byte 0x81 at '
          'offset 1 has no character in Windows-1252.',
          reopenable: true,
        ),
      );
    });

    test('a character the encoding lacks blocks the save', () async {
      await file.writeAsBytes(latin1Bytes);
      final document = await loadTextDocument(
        file,
        encoding: TextEncoding.latin1,
      );

      await expectLater(
        saveBack(document, text: 'café\nprice: 5€\n'),
        failsWith(
          'The character "€" (U+20AC) at line 2, column 9 cannot be '
          'saved in Latin-1. Remove or replace it, or choose an encoding '
          'that can represent it.',
        ),
      );
      await expectLater(
        saveBack(document, text: '\u{1F600}'),
        failsWith(
          'The character "\u{1F600}" (U+1F600) at line 1, column 1 cannot '
          'be saved in Latin-1. Remove or replace it, or choose an '
          'encoding that can represent it.',
        ),
      );
      // Nothing was replaced or written.
      expect(await file.readAsBytes(), latin1Bytes);
    });

    test('Latin-1 byte count is one byte per character', () {
      expect(
        textDocumentByteCount(
          'café\n',
          const TextDocumentMetadata(encoding: TextEncoding.latin1),
        ),
        5,
      );
    });
  });

  group('UTF-8', () {
    test('a byte order mark is kept on save when it was there', () async {
      final bytes = [
        0xef,
        0xbb,
        0xbf,
        ...'café\n'.runes.expand((rune) => rune < 0x80 ? [rune] : [0xc3, 0xa9]),
      ];
      await file.writeAsBytes(bytes);
      final document = await loadTextDocument(file);

      expect(document.encoding, TextEncoding.utf8);
      expect(document.hasUtf8Bom, isTrue);
      expect(document.metadata.encodingLabel, 'UTF-8 BOM');
      await saveBack(document);
      expect(await file.readAsBytes(), bytes);
    });

    test('a file without a mark is plain UTF-8', () async {
      await file.writeAsString('a\n');
      final document = await loadTextDocument(file);
      expect(document.encoding, TextEncoding.utf8);
      expect(document.metadata.encodingLabel, 'UTF-8');
    });
  });
}
