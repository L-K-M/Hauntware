@TestOn('vm')
library;

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
}
