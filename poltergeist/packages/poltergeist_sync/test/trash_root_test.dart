@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';
import 'package:test/test.dart';

void main() {
  test('an unmarked run-like directory is never adopted', () async {
    final scratch = await Directory.systemTemp.createTemp(
      'poltergeist-trash-root-',
    );
    addTearDown(() async {
      if (await scratch.exists()) await scratch.delete(recursive: true);
    });
    final style = Platform.isWindows
        ? SyncTrashPathStyle.windows
        : SyncTrashPathStyle.posix;
    final context = syncTrashPathContext(style);
    final root = Directory(context.join(scratch.path, 'unmarked'))
      ..createSync();
    final runId =
        '${syncRunDevicePrefix('other-device')}-'
        '00000000-0000-4000-8000-000000000000';
    final run = Directory(context.join(root.path, runId))..createSync();
    final precious = File(context.join(run.path, 'precious.txt'))
      ..writeAsStringSync('keep');

    await expectLater(
      resolveSyncTrashRoot(
        LocalFileSystem(),
        root.path,
        pathStyle: style,
        access: SyncTrashRootAccess.createOrClaim,
      ),
      throwsA(
        isA<RemoteFileException>().having(
          (error) => error.kind,
          'kind',
          RemoteFileErrorKind.conflict,
        ),
      ),
    );

    expect(precious.readAsStringSync(), 'keep');
    expect(
      Directory(context.join(root.path, syncTrashRootMarkerName)).existsSync(),
      isFalse,
    );
  });

  group('a staged marker from another claim', () {
    late Directory root;

    setUp(() async {
      final scratch = await Directory.systemTemp.createTemp(
        'poltergeist-trash-root-',
      );
      addTearDown(() async {
        if (await scratch.exists()) await scratch.delete(recursive: true);
      });
      root = Directory(_context.join(scratch.path, 'trash'))..createSync();
    });

    Future<SyncTrashRootIdentity> claim([RemoteFileSystem? fileSystem]) =>
        resolveSyncTrashRoot(
          fileSystem ?? LocalFileSystem(),
          root.path,
          pathStyle: _style,
          access: SyncTrashRootAccess.createOrClaim,
        );

    Directory stage(String? identity, {String suffix = ''}) {
      final candidate = Directory(
        _context.join(
          root.path,
          '$syncTrashRootMarkerName.init-${suffix.isEmpty ? 'a' * 32 : suffix}',
        ),
      )..createSync();
      if (identity != null) {
        File(
          _context.join(candidate.path, 'identity'),
        ).writeAsStringSync(identity);
      }
      return candidate;
    }

    test('still being written, it is waited out, not refused', () async {
      final first = _StalledClaimFs();
      final firstClaim = claim(first);
      await first.staged.future;

      // The root holds only the first claim's candidate, with no identity.
      final second = await claim();
      first.release.complete();

      expect((await firstClaim).rootId, second.rootId);
      expect(root.listSync().map((entry) => _context.basename(entry.path)), [
        syncTrashRootMarkerName,
      ]);
    });

    test('left unfinished by a claim that stopped, it is adopted', () async {
      for (final identity in [null, '', 'poltergeist-sync-trash-v1:0123']) {
        final candidate = stage(identity);

        await expectLater(claim(), completes, reason: '$identity');

        Directory(
          _context.join(root.path, syncTrashRootMarkerName),
        ).deleteSync(recursive: true);
        candidate.deleteSync(recursive: true);
      }
    });

    test('holding anything but a marker, it still fails closed', () async {
      stage('poltergeist-sync-trash-v1:not-hex');

      await expectLater(claim(), throwsA(_conflict));
      expect(
        Directory(
          _context.join(root.path, syncTrashRootMarkerName),
        ).existsSync(),
        isFalse,
      );
    });

    test('named unlike a claim would name it, it fails closed', () async {
      for (final suffix in ['tmp', 'A' * 32, '${'a' * 32}0']) {
        final candidate = stage(null, suffix: suffix);

        await expectLater(claim(), throwsA(_conflict), reason: suffix);

        candidate.deleteSync(recursive: true);
      }
    });
  });
}

final _conflict = isA<RemoteFileException>().having(
  (error) => error.kind,
  'kind',
  RemoteFileErrorKind.conflict,
);

final _style = Platform.isWindows
    ? SyncTrashPathStyle.windows
    : SyncTrashPathStyle.posix;
final _context = syncTrashPathContext(_style);

/// Holds the first marker claim after it stages its candidate directory
/// and before it writes the identity, so a second claim lists the root
/// while the first is mid-write.
final class _StalledClaimFs extends LocalFileSystem {
  final staged = Completer<void>();
  final release = Completer<void>();

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
    if (_context.basename(path) == 'identity' && !staged.isCompleted) {
      staged.complete();
      await release.future;
    }
    return super.upload(
      path,
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    );
  }
}
