import 'dart:io';

import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'poltergeist-editor-test-',
    );
    // The safety layer refuses to walk pre-existing symlinked ancestors
    // (macOS temp dirs begin at one) — resolve once here like callers do.
    directory = Directory(await directory.resolveSymbolicLinks());
    file = File('${directory.path}/config.txt');
    await file.writeAsString('one\ntwo\n');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test('loads UTF-8 and atomically saves edited text', () async {
    expect(await _loadText(file), 'one\ntwo\n');

    await _save(file, 'changed\n');

    expect(await file.readAsString(), 'changed\n');
    expect(await directory.list().length, 1);
  });

  test('preserves a UTF-8 BOM and CRLF line endings byte-for-byte', () async {
    await file.writeAsBytes([0xef, 0xbb, 0xbf, ...'one\r\ntwo\r\n'.codeUnits]);
    final document = await loadTextDocument(file);

    // The in-memory invariant: LF, no BOM (06 §2.1).
    expect(document.text, 'one\ntwo\n');
    expect(document.hasUtf8Bom, isTrue);
    expect(document.lineEnding, LineEnding.crlf);

    await _save(
      file,
      '${document.text}three\n',
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), [
      0xef,
      0xbb,
      0xbf,
      ...'one\r\ntwo\r\nthree\r\n'.codeUnits,
    ]);
  });

  test('a second leading BOM is content and survives the round trip', () async {
    // Utf8Decoder drops a BOM at the start of whatever it is handed, so
    // stripping one BOM and decoding the rest would also swallow the
    // U+FEFF right behind it (ported from Séance's fix).
    const bom = [0xef, 0xbb, 0xbf];
    await file.writeAsBytes([...bom, ...bom, ...bom, ...'a\n'.codeUnits]);
    final document = await loadTextDocument(file);

    expect(document.hasUtf8Bom, isTrue);
    expect(document.text, '﻿﻿a\n');

    await _save(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), [
      ...bom,
      ...bom,
      ...bom,
      ...'a\n'.codeUnits,
    ]);
  });

  test('a BOM-less LF file round-trips byte-for-byte', () async {
    await file.writeAsBytes('one\ntwo\n'.codeUnits);
    final document = await loadTextDocument(file);

    expect(document.text, 'one\ntwo\n');
    expect(document.hasUtf8Bom, isFalse);
    expect(document.lineEnding, LineEnding.lf);

    await _save(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), 'one\ntwo\n'.codeUnits);
  });

  test('mixed line endings normalize on first save by majority vote', () async {
    // 2 CRLF vs 1 lone LF — the vote is crlf, and the lone LF folds into
    // the family on save (06 §2.1's pinned normalization).
    await file.writeAsBytes('a\r\nb\nc\r\n'.codeUnits);
    final document = await loadTextDocument(file);

    expect(document.text, 'a\nb\nc\n');
    expect(document.lineEnding, LineEnding.crlf);

    await _save(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), 'a\r\nb\r\nc\r\n'.codeUnits);
  });

  test('a lone-CR file votes LF and normalizes to LF on save', () async {
    // A lone \r never votes: a CR-only file saves back all-LF (06 §2.1).
    await file.writeAsBytes('a\rb\rc'.codeUnits);
    final document = await loadTextDocument(file);

    expect(document.text, 'a\nb\nc');
    expect(document.lineEnding, LineEnding.lf);

    await _save(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), 'a\nb\nc'.codeUnits);
  });

  test('a single-line file never grows CRLF', () async {
    await file.writeAsString('single line, no breaks');
    final document = await loadTextDocument(file);

    expect(document.lineEnding, LineEnding.lf);

    await _save(
      file,
      document.text,
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    expect(await file.readAsBytes(), 'single line, no breaks'.codeUnits);
  });

  test('refuses to overwrite an independently changed local copy', () async {
    final document = await loadTextDocument(file);
    await file.writeAsString('external change\n');

    await expectLater(
      _save(file, 'built-in change\n', expectedSha256: document.sha256),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'The local copy changed in another editor. Reopen it before '
              'saving to avoid losing those changes.',
        ),
      ),
    );
    // The external change survives untouched.
    expect(await file.readAsString(), 'external change\n');
  });

  test('rejects malformed, binary, and oversized content', () async {
    await file.writeAsBytes([0xff]);
    await expectLater(
      _loadText(file),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'This file is not valid UTF-8 text.',
        ),
      ),
    );

    await file.writeAsBytes([0, 1, 2]);
    await expectLater(
      _loadText(file),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'This file appears to be binary, not editable text.',
        ),
      ),
    );

    await file.writeAsBytes([1, 2, 3]);
    await expectLater(
      _loadText(file, maximumBytes: 2),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'The built-in editor supports text files up to 0 MB.',
        ),
      ),
    );
  });

  test('refuses a file that changed while it was being opened', () async {
    var reads = 0;
    Future<String> tamperingSha256(File target) async {
      final digest = await textDocumentSha256(target);
      if (++reads == 1) {
        // Mutate between the pre-read and post-read digests — the
        // TOCTOU check must catch a file edited mid-open.
        await target.writeAsString('raced change\n');
      }
      return digest;
    }

    await expectLater(
      loadTextDocument(file, sha256Of: tamperingSha256),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'The local copy changed while it was being opened.',
        ),
      ),
    );
  });

  test('error messages surface bare — no Exception prefix', () async {
    await file.writeAsBytes([0xff]);
    try {
      await _loadText(file);
      fail('expected the load to refuse');
    } on TextDocumentException catch (error) {
      // §2.4's toast contract: error.toString() IS the message.
      expect(error.toString(), 'This file is not valid UTF-8 text.');
    }
  });

  test('the save refuses when the target vanished mid-save', () async {
    final document = await loadTextDocument(file);
    await file.delete();
    await expectLater(
      _save(file, 'edit\n', expectedSha256: document.sha256),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'The local copy is missing or no longer a regular file.',
        ),
      ),
    );
  });

  test('a symlinked local target resolves at open and saves through the '
      'link, leaving it intact', () async {
    if (Platform.isWindows) return; // symlink creation needs privileges
    final real = File('${directory.path}/real.conf');
    await real.writeAsString('one\n');
    final link = Link('${directory.path}/alias.conf');
    await link.create(real.path);

    final resolved = await resolveTextDocumentTarget(
      File(link.path),
      symlinkPolicy: SymlinkPolicy.resolveOnce,
    );
    expect(resolved.path, real.path);

    final document = await loadTextDocument(resolved);
    await _save(
      resolved,
      'edited\n',
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );

    // The link still points at the real file — never replaced by a
    // regular file (06 §2.1 step 2).
    expect(
      await FileSystemEntity.type(link.path, followLinks: false),
      FileSystemEntityType.link,
    );
    expect(await real.readAsString(), 'edited\n');
  });

  test('the save refuses when the target became a symlink', () async {
    if (Platform.isWindows) return;
    final document = await loadTextDocument(file);
    // Swap the target for a symlink after load — the save must refuse
    // rather than replace the link with a regular file.
    await file.delete();
    await Link(file.path).create('${directory.path}/elsewhere.conf');

    await expectLater(
      _save(file, 'edit\n', expectedSha256: document.sha256),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'The local copy is a symbolic link, not a regular file.',
        ),
      ),
    );
    expect(
      await FileSystemEntity.type(file.path, followLinks: false),
      FileSystemEntityType.link,
    );
  });

  test('the temp sibling is owner-only before the first write', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    // 0644 original: the only window the temp can sit at 0600 is between
    // step 1's chmod and step 4's mode restore (06 §2.1/§2.5).
    await Process.run('chmod', ['644', file.path]);
    File? temp;
    await _save(
      file,
      'edit\n',
      observeTemporary: (temporary) async {
        temp = temporary;
        final stat = await temporary.stat();
        expect(stat.mode & 0x1ff, 0x180); // 0600
      },
    );
    expect(temp, isNotNull);
    expect(await temp!.exists(), isFalse);
    // Step 4 restored the ORIGINAL mode — a 644 original saves back 644.
    final saved = await file.stat();
    expect(saved.mode & 0x1ff, 0x1a4);
  });

  test('a 0600 checkout stays 0600 after a save', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    await Process.run('chmod', ['600', file.path]);
    final document = await loadTextDocument(file);
    await _save(
      file,
      'edit\n',
      hasUtf8Bom: document.hasUtf8Bom,
      lineEnding: document.lineEnding,
      expectedSha256: document.sha256,
    );
    final saved = await file.stat();
    expect(saved.mode & 0x1ff, 0x180);
  });

  test('the encoded output is size-checked too', () async {
    await expectLater(
      _save(file, 'x' * (textDocumentMaximumBytes + 1)),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          'The edited file exceeds the 4 MB built-in editor limit.',
        ),
      ),
    );
  });

  test('an unwritable folder fails the save with an actionable error', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    // Root bypasses directory mode bits; the precondition cannot hold there.
    final uid = await Process.run('id', ['-u']);
    if (uid.stdout.toString().trim() == '0') return;
    final originalMode = (await directory.stat()).mode & 0x1ff;
    final restrict = await Process.run('chmod', ['555', directory.path]);
    if (restrict.exitCode != 0) {
      fail('chmod 555 failed: ${restrict.stderr}');
    }
    addTearDown(() async {
      await Process.run('chmod', [
        originalMode.toRadixString(8),
        directory.path,
      ]);
    });

    await expectLater(
      _save(file, 'edit\n'),
      throwsA(
        isA<TextDocumentException>().having(
          (error) => error.message,
          'message',
          startsWith(
            'A temporary file could not be created beside the document.',
          ),
        ),
      ),
    );
    // The guarded path refuses before renaming: the original stays intact.
    expect(await file.readAsString(), 'one\ntwo\n');
    expect(await directory.list().length, 1);
  });
}

Future<String> _loadText(
  File file, {
  int maximumBytes = textDocumentMaximumBytes,
}) async => (await loadTextDocument(file, maximumBytes: maximumBytes)).text;

Future<String> _save(
  File file,
  String text, {
  String? expectedSha256,
  bool hasUtf8Bom = false,
  LineEnding lineEnding = LineEnding.lf,
  Future<void> Function(File)? observeTemporary,
}) async => saveTextDocument(
  file,
  text,
  expectedSha256: expectedSha256 ?? await textDocumentSha256(file),
  hasUtf8Bom: hasUtf8Bom,
  lineEnding: lineEnding,
  observeTemporary: observeTemporary,
);
