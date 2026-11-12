import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';

// The wrapper over planchette_core's text document: argument wiring
// (expected digest, digest injection, temporary observer), the loader
// failure classification, the symlink target resolver and the checkout
// byte-cap sink. The shared load/save mechanics (BOM, line endings,
// refusals, size limits) are tested in planchette_core's
// text_document_test.dart.
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
    expect((await loadBuiltInTextDocumentDetails(file)).text, 'one\ntwo\n');

    await saveBuiltInTextDocument(file, 'changed\n');

    expect(await file.readAsString(), 'changed\n');
    expect(await directory.list().length, 1);
  });

  test('refuses to overwrite an independently changed local copy', () async {
    final document = await loadBuiltInTextDocumentDetails(file);
    await file.writeAsString('external change\n');

    await expectLater(
      saveBuiltInTextDocument(
        file,
        'built-in change\n',
        expectedSha256: document.sha256,
      ),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'The file changed in another editor. Reopen it before '
              'saving to avoid losing those changes.',
        ),
      ),
    );
    // The external change survives untouched.
    expect(await file.readAsString(), 'external change\n');
  });

  test('refuses a file that changed while it was being opened', () async {
    var reads = 0;
    Future<String> tamperingSha256(File target) async {
      final digest = await streamedFileSha256(target);
      if (++reads == 1) {
        // Mutate between the pre-read and post-read digests — the
        // TOCTOU check must catch a file edited mid-open.
        await target.writeAsString('raced change\n');
      }
      return digest;
    }

    await expectLater(
      loadBuiltInTextDocumentDetails(file, sha256Of: tamperingSha256),
      throwsA(
        isA<BuiltInEditorException>().having(
          (error) => error.message,
          'message',
          'The file changed while it was being opened.',
        ),
      ),
    );
  });

  test('classifies loader failures for localized hosts', () {
    expect(
      classifyBuiltInTextDocumentFailure(
        const BuiltInEditorException('This file is not valid UTF-8 text.'),
      ),
      BuiltInTextDocumentFailure.invalidUtf8,
    );
    expect(
      classifyBuiltInTextDocumentFailure(
        const BuiltInEditorException(
          'This file appears to be binary, not editable text.',
        ),
      ),
      BuiltInTextDocumentFailure.binary,
    );
    expect(
      classifyBuiltInTextDocumentFailure(
        const BuiltInEditorException(
          'The file changed while it was being opened.',
        ),
      ),
      BuiltInTextDocumentFailure.changed,
    );
    expect(
      classifyBuiltInTextDocumentFailure(
        const BuiltInEditorException(
          'The file is missing or no longer a regular file.',
        ),
      ),
      BuiltInTextDocumentFailure.missing,
    );
    expect(
      classifyBuiltInTextDocumentFailure(
        const BuiltInEditorException('The file no longer exists.'),
      ),
      BuiltInTextDocumentFailure.missing,
    );
    expect(
      classifyBuiltInTextDocumentFailure(
        const BuiltInEditorException('Unrecognized failure.'),
      ),
      BuiltInTextDocumentFailure.other,
    );
  });

  test('a symlinked local target resolves at open and saves through the '
      'link, leaving it intact', () async {
    if (Platform.isWindows) return; // symlink creation needs privileges
    final real = File('${directory.path}/real.conf');
    await real.writeAsString('one\n');
    final link = Link('${directory.path}/alias.conf');
    await link.create(real.path);

    final resolved = await resolveBuiltInEditorTarget(File(link.path));
    expect(resolved.path, real.path);

    final document = await loadBuiltInTextDocumentDetails(resolved);
    await saveBuiltInTextDocument(
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

  test('the temp sibling is owner-only before the first write', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    // 0644 original: the only window the temp can sit at 0600 is between
    // step 1's chmod and step 4's mode restore (06 §2.1/§2.5).
    await Process.run('chmod', ['644', file.path]);
    File? temp;
    await saveBuiltInTextDocument(
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

  test('the byte-cap sink aborts a stream at the limit', () async {
    final sink = _RecordingSink();
    final capped = MaximumByteSink(sink, maximumBytes: 8);
    await expectLater(
      capped.addStream(
        Stream.fromIterable([
          [1, 2, 3],
          [4, 5, 6],
          [7, 8, 9, 10],
        ]),
      ),
      throwsA(
        isA<CheckoutLimitException>().having(
          (error) => error.toString(),
          'message',
          'The file is larger than the 8-byte editor limit.',
        ),
      ),
    );
    // The third chunk trips the cap before it lands.
    expect(sink.bytes, [1, 2, 3, 4, 5, 6]);
  });

  test('the byte-cap sink passes through under the limit', () async {
    final sink = _RecordingSink();
    final capped = MaximumByteSink(sink, maximumBytes: 8);
    await capped.addStream(
      Stream.fromIterable([
        [1, 2, 3],
        [4, 5],
      ]),
    );
    await capped.close();
    expect(sink.bytes, [1, 2, 3, 4, 5]);
    expect(sink.closed, isTrue);
  });
}

final class _RecordingSink implements StreamSink<List<int>> {
  final bytes = <int>[];
  var closed = false;

  @override
  void add(List<int> event) => bytes.addAll(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async => closed = true;

  @override
  Future<void> get done => Future.value();
}
