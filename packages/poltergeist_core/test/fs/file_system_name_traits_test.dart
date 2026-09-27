import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:test/test.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

final class _ProbeFileSystem implements RemoteFileSystem {
  _ProbeFileSystem({
    required this.caseSensitivity,
    required this.normalizationSensitivity,
  });

  final FileSystemNameSensitivity caseSensitivity;
  final FileSystemNameSensitivity normalizationSensitivity;
  final Map<String, RemoteFileEntry> _entries = {};

  int uploadCalls = 0;
  int deleteCalls = 0;
  String? uploadedPath;
  Object? deleteError;
  Object? postCommitUploadError;

  String _key(String path) {
    var key = path;
    if (normalizationSensitivity == FileSystemNameSensitivity.insensitive) {
      key = unorm.nfc(key);
    }
    if (caseSensitivity == FileSystemNameSensitivity.insensitive) {
      key = key.toLowerCase();
    }
    return key;
  }

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    uploadCalls++;
    uploadedPath = path;
    await content.drain<void>();

    final entry = RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: 0,
    );
    _entries[_key(path)] = entry;
    final error = postCommitUploadError;
    if (error != null) throw error;
    return entry;
  }

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    final entry = _entries[_key(path)];
    if (entry != null) return entry;

    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'stat',
      path: path,
      message: 'not found',
    );
  }

  @override
  Future<void> delete(RemoteFileEntry entry) async {
    deleteCalls++;
    final error = deleteError;
    if (error != null) throw error;
    _entries.remove(_key(entry.path));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  group('probeFileSystemNameTraits', () {
    for (final expected in <FileSystemNameTraits>[
      const FileSystemNameTraits(
        caseSensitivity: FileSystemNameSensitivity.sensitive,
        normalizationSensitivity: FileSystemNameSensitivity.sensitive,
      ),
      const FileSystemNameTraits(
        caseSensitivity: FileSystemNameSensitivity.insensitive,
        normalizationSensitivity: FileSystemNameSensitivity.sensitive,
      ),
      const FileSystemNameTraits(
        caseSensitivity: FileSystemNameSensitivity.sensitive,
        normalizationSensitivity: FileSystemNameSensitivity.insensitive,
      ),
      const FileSystemNameTraits(
        caseSensitivity: FileSystemNameSensitivity.insensitive,
        normalizationSensitivity: FileSystemNameSensitivity.insensitive,
      ),
    ]) {
      test('detects ${expected.caseSensitivity.name} case and '
          '${expected.normalizationSensitivity.name} normalization', () async {
        final fileSystem = _ProbeFileSystem(
          caseSensitivity: expected.caseSensitivity,
          normalizationSensitivity: expected.normalizationSensitivity,
        );

        final actual = await probeFileSystemNameTraits(
          fileSystem,
          '/root',
          probeSuffix: 'fixed',
        );

        expect(actual.caseSensitivity, expected.caseSensitivity);
        expect(
          actual.normalizationSensitivity,
          expected.normalizationSensitivity,
        );
        expect(fileSystem.uploadCalls, 1);
        expect(fileSystem.deleteCalls, 1);
        expect(fileSystem._entries, isEmpty);
      });
    }

    test('uses the destination filesystem path join', () async {
      final fileSystem = _ProbeFileSystem(
        caseSensitivity: FileSystemNameSensitivity.sensitive,
        normalizationSensitivity: FileSystemNameSensitivity.sensitive,
      );

      await probeFileSystemNameTraits(
        fileSystem,
        r'C:\root',
        probeSuffix: 'fixed',
        joinPath: (root, name) => '$root\\$name',
      );

      expect(
        fileSystem.uploadedPath,
        'C:\\root\\.poltergeist-nameprobe-fixed-e\u0301',
      );
    });

    test('surfaces cleanup failure instead of hiding probe debris', () async {
      final fileSystem = _ProbeFileSystem(
        caseSensitivity: FileSystemNameSensitivity.sensitive,
        normalizationSensitivity: FileSystemNameSensitivity.sensitive,
      )..deleteError = StateError('cleanup failed');

      await expectLater(
        probeFileSystemNameTraits(fileSystem, '/root', probeSuffix: 'fixed'),
        throwsA(isA<FileSystemNameProbeCleanupException>()),
      );

      expect(fileSystem._entries, isNotEmpty);
    });

    test('surfaces an ambiguous post-commit upload failure', () async {
      final fileSystem = _ProbeFileSystem(
        caseSensitivity: FileSystemNameSensitivity.sensitive,
        normalizationSensitivity: FileSystemNameSensitivity.sensitive,
      )..postCommitUploadError = StateError('response failed');

      await expectLater(
        probeFileSystemNameTraits(fileSystem, '/root', probeSuffix: 'fixed'),
        throwsA(isA<FileSystemNameProbeCleanupException>()),
      );

      expect(fileSystem.deleteCalls, 0);
      expect(fileSystem._entries, isNotEmpty);
    });
  });

  group('destinationNameKey', () {
    const decomposed = 'A\u030A.TXT';

    test('represents all case and normalization combinations', () {
      expect(
        destinationNameKey(decomposed, DestinationNameComparison.exact),
        decomposed,
      );
      expect(
        destinationNameKey(
          decomposed,
          DestinationNameComparison.caseInsensitive,
        ),
        'a\u030A.txt',
      );
      expect(
        destinationNameKey(decomposed, DestinationNameComparison.normalized),
        '\u00C5.TXT',
      );
      expect(
        destinationNameKey(
          decomposed,
          DestinationNameComparison.normalizedCaseInsensitive,
        ),
        '\u00E5.txt',
      );
    });

    test('maps traits onto the matching comparison', () {
      expect(
        destinationNameComparisonFor(
          const FileSystemNameTraits(
            caseSensitivity: FileSystemNameSensitivity.insensitive,
            normalizationSensitivity: FileSystemNameSensitivity.sensitive,
          ),
        ),
        DestinationNameComparison.caseInsensitive,
      );
      expect(
        destinationNameComparisonFor(
          const FileSystemNameTraits(
            caseSensitivity: FileSystemNameSensitivity.sensitive,
            normalizationSensitivity: FileSystemNameSensitivity.insensitive,
          ),
        ),
        DestinationNameComparison.normalized,
      );
    });
  });
}
