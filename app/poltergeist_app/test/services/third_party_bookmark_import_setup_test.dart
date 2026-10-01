import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/third_party_bookmark_import_setup.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_bookmark_store.dart';

void main() {
  test('keeps the caller bookmark store and picker', () async {
    final bookmarks = FakeBookmarkStore();
    final calls = <ThirdPartyBookmarkFormat>[];
    Future<List<ThirdPartyBookmarkImportFile>?> picker(
      ThirdPartyBookmarkFormat format,
    ) async {
      calls.add(format);
      return null;
    }

    final setup = buildThirdPartyBookmarkImportSetup(
      bookmarks: bookmarks,
      pickFiles: picker,
    );

    expect(setup.bookmarks, same(bookmarks));
    await setup.pickFiles(ThirdPartyBookmarkFormat.cyberduck);
    expect(calls, [ThirdPartyBookmarkFormat.cyberduck]);
  });

  test('production loader parses in a worker isolate', () async {
    final setup = buildThirdPartyBookmarkImportSetup(
      bookmarks: FakeBookmarkStore(),
    );

    final task = await setup.startPreview(
      format: ThirdPartyBookmarkFormat.cyberduck,
      files: [
        ThirdPartyBookmarkImportFile(
          'worker.duck',
          utf8.encode('''
<plist><dict><key>Protocol</key><string>sftp</string>
<key>Hostname</key><string>worker.example.com</string></dict></plist>
'''),
        ),
      ],
      existingBookmarks: const [],
    );
    final preview = await task.result;

    expect(preview.rows.single.host, 'worker.example.com');
  });

  test('production loader preserves typed parse failures', () async {
    final setup = buildThirdPartyBookmarkImportSetup(
      bookmarks: FakeBookmarkStore(),
    );

    await expectLater(
      () async {
        final task = await setup.startPreview(
          format: ThirdPartyBookmarkFormat.fileZilla,
          files: [
            ThirdPartyBookmarkImportFile(
              'broken.xml',
              utf8.encode('<FileZilla3>'),
            ),
          ],
          existingBookmarks: const [],
        );

        return task.result;
      }(),
      throwsA(
        isA<ThirdPartyBookmarkImportException>().having(
          (error) => error.failure,
          'failure',
          ThirdPartyBookmarkImportFailure.malformedSource,
        ),
      ),
    );
  });

  test('production preview can be cancelled', () async {
    final setup = buildThirdPartyBookmarkImportSetup(
      bookmarks: FakeBookmarkStore(),
    );
    final padding = ' '.padRight(thirdPartyBookmarkImportMaxFileBytes - 31);
    final task = await setup.startPreview(
      format: ThirdPartyBookmarkFormat.fileZilla,
      files: [
        ThirdPartyBookmarkImportFile(
          'large.xml',
          utf8.encode('<FileZilla3>$padding</FileZilla3>'),
        ),
      ],
      existingBookmarks: const [],
    );

    task.cancel();

    await expectLater(
      task.result,
      throwsA(isA<ThirdPartyBookmarkImportCancelledException>()),
    );
  });

  test('picker stream is copied into bounded input', () async {
    final files = await readThirdPartyBookmarkImportFiles([
      PlatformFile(
        name: 'site.duck',
        size: 3,
        readStream: Stream.value(const [1, 2, 3]),
      ),
    ]);

    expect(files.single.name, 'site.duck');
    expect(files.single.bytes, [1, 2, 3]);
  });

  test('picker metadata rejects oversized files before reading', () async {
    var listened = false;
    final stream = Stream<List<int>>.multi((controller) {
      listened = true;
      controller.add(Uint8List(1));
      controller.close();
    });

    await expectLater(
      readThirdPartyBookmarkImportFiles([
        PlatformFile(
          name: 'oversized.duck',
          size: thirdPartyBookmarkImportMaxFileBytes + 1,
          readStream: stream,
        ),
      ]),
      throwsA(
        isA<ThirdPartyBookmarkImportException>().having(
          (error) => error.failure,
          'failure',
          ThirdPartyBookmarkImportFailure.fileTooLarge,
        ),
      ),
    );
    expect(listened, isFalse);
  });

  test(
    'picker normalizes source names before oversized-file failures',
    () async {
      final rawName = ' unsafe\u0000${'x' * 600}.duck ';
      final normalizedName = ThirdPartyBookmarkImportFile.normalizeName(
        rawName,
      );

      await expectLater(
        readThirdPartyBookmarkImportFiles([
          PlatformFile(
            name: rawName,
            size: thirdPartyBookmarkImportMaxFileBytes + 1,
            readStream: const Stream.empty(),
          ),
        ]),
        throwsA(
          isA<ThirdPartyBookmarkImportException>()
              .having(
                (error) => error.failure,
                'failure',
                ThirdPartyBookmarkImportFailure.fileTooLarge,
              )
              .having(
                (error) => error.sourceName,
                'normalized source name',
                normalizedName,
              ),
        ),
      );
      expect(normalizedName.length, lessThan(rawName.trim().length));
      expect(normalizedName, contains('\uFFFD'));
      expect(normalizedName, isNot(contains('\u0000')));
    },
  );

  test('picker stream enforces the actual file limit', () async {
    final chunk = Uint8List(thirdPartyBookmarkImportMaxFileBytes);

    await expectLater(
      readThirdPartyBookmarkImportFiles([
        PlatformFile(
          name: 'underreported.duck',
          size: 1,
          readStream: Stream.fromIterable([
            chunk,
            const [0],
          ]),
        ),
      ]),
      throwsA(
        isA<ThirdPartyBookmarkImportException>().having(
          (error) => error.failure,
          'failure',
          ThirdPartyBookmarkImportFailure.fileTooLarge,
        ),
      ),
    );
  });

  test('picker streams enforce the actual aggregate limit', () async {
    final fullFile = Uint8List(thirdPartyBookmarkImportMaxFileBytes);
    final fullFileCount =
        thirdPartyBookmarkImportMaxTotalBytes ~/
        thirdPartyBookmarkImportMaxFileBytes;
    final crossingFileBytes =
        thirdPartyBookmarkImportMaxTotalBytes %
            thirdPartyBookmarkImportMaxFileBytes +
        1;
    var trailingFileRead = false;
    final trailingStream = Stream<List<int>>.multi((controller) {
      trailingFileRead = true;
      controller.add(const [0]);
      controller.close();
    });

    await expectLater(
      readThirdPartyBookmarkImportFiles([
        for (var index = 0; index < fullFileCount; index++)
          PlatformFile(
            name: 'underreported-$index.duck',
            size: 1,
            readStream: Stream.value(fullFile),
          ),
        PlatformFile(
          name: 'crosses-total.duck',
          size: 1,
          readStream: Stream.value(Uint8List(crossingFileBytes)),
        ),
        PlatformFile(
          name: 'must-not-read.duck',
          size: 1,
          readStream: trailingStream,
        ),
      ]),
      throwsA(
        isA<ThirdPartyBookmarkImportException>().having(
          (error) => error.failure,
          'failure',
          ThirdPartyBookmarkImportFailure.totalSizeExceeded,
        ),
      ),
    );
    expect(trailingFileRead, isFalse);
  });
}
