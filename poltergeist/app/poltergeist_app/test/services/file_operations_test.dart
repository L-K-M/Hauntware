// P4-21 (decision Q5): the app-internal file clipboard and the Undo
// model of its file operations, over the scripted queue seam and a fake
// host channel.
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_ui/ghost_ui.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/file_clipboard.dart';
import 'package:poltergeist_app/services/file_operations.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';

const _local = LocalFsLocation();
const _srv = ServerFsLocation('srv');
const _other = ServerFsLocation('other');

class _FakeChannel implements FileHostChannel {
  _FakeChannel([Set<String>? names]) : names = names ?? {};

  Set<String> names;
  Object? listError;
  final renames = <(String, String)>[];
  final failRenames = <String, Object>{};

  @override
  Future<Set<String>> listNames(String folder) async {
    final error = listError;
    if (error != null) throw error;
    return names;
  }

  @override
  Future<void> rename(String from, String to) async {
    final error = failRenames[from];
    if (error != null) throw error;
    renames.add((from, to));
  }
}

class _Harness {
  _Harness() {
    operations = FileOperations(
      history: history,
      clipboard: clipboard,
      delegate: () => queueBound ? PaneDropDelegate(queue: queue) : null,
      hostChannel: (host) => channels[host],
      confirmCopyUndo: (host, paths) async {
        confirmCalls.add((host, paths));
        return confirmAnswer;
      },
      hostLabel: (host) => host is ServerFsLocation ? host.serverId : 'device',
      notify: notices.add,
      strings: () => l10n,
    );
  }

  final l10n = lookupAppLocalizations(const Locale('en'));
  final history = GhostUndoHistory();
  final clipboard = FileClipboard();
  final queue = FakeAppTransferQueue();
  final channels = <FsLocation, _FakeChannel>{};
  final confirmCalls = <(FsLocation, List<String>)>[];
  final notices = <String>[];
  bool confirmAnswer = true;
  bool queueBound = true;
  late final FileOperations operations;

  /// Settles [task] as [state] with [items] and tells the listeners.
  void settle(
    TransferTask task, {
    List<TransferItem> items = const [],
    TransferTaskState state = TransferTaskState.completed,
  }) {
    task.items.addAll(items);
    task.state = state;
    queue.emit(TransferQueueTaskEvent(task.id, state));
  }

  /// Completes the next task Undo enqueues, once it has.
  Future<void> completeNextTask(int before) async {
    for (var i = 0; i < 20 && queue.tasks.length <= before; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final task = queue.tasks.last;
    settle(
      task,
      items: [
        for (final root in task.rootPaths)
          item(root, '${task.destinationDir}/x'),
      ],
    );
  }
}

TransferItem item(
  String source,
  String destination, {
  TransferItemState state = TransferItemState.completed,
  ItemDisposition? disposition,
  bool directory = false,
}) =>
    TransferItem(
        id: source,
        sourcePath: source,
        isDirectory: directory,
        destinationPath: destination,
      )
      ..state = state
      ..disposition = disposition;

Future<void> expectDeclined(Future<void> step, String message) async {
  await expectLater(
    step,
    throwsA(
      isA<GhostUndoDeclined>().having((e) => e.message, 'message', message),
    ),
  );
}

void main() {
  group('FileClipboard', () {
    test('put replaces the content and notifies; empty puts are ignored', () {
      final clipboard = FileClipboard();
      var notified = 0;
      clipboard.addListener(() => notified++);

      clipboard.put(
        source: _local,
        rootPaths: const [],
        mode: FileClipboardMode.copy,
      );
      expect(clipboard.content, isNull);
      expect(notified, 0);

      clipboard.put(
        source: _srv,
        rootPaths: ['/a', '/b'],
        mode: FileClipboardMode.cut,
      );
      expect(clipboard.content!.rootPaths, ['/a', '/b']);
      expect(clipboard.content!.mode, FileClipboardMode.cut);
      expect(notified, 1);

      clipboard.clear();
      clipboard.clear();
      expect(clipboard.content, isNull);
      expect(notified, 2);
    });

    test('isCut dims cut roots on their own host only', () {
      final clipboard = FileClipboard()
        ..put(source: _srv, rootPaths: ['/a'], mode: FileClipboardMode.cut);
      expect(clipboard.isCut(_srv, '/a'), isTrue);
      expect(clipboard.isCut(_srv, '/a/inner'), isFalse);
      expect(clipboard.isCut(_other, '/a'), isFalse);
      expect(clipboard.isCut(_local, '/a'), isFalse);

      clipboard.put(
        source: _srv,
        rootPaths: ['/a'],
        mode: FileClipboardMode.copy,
      );
      expect(clipboard.isCut(_srv, '/a'), isFalse);
    });
  });

  group('filePasteKind', () {
    FileClipboardContent content(FsLocation source, FileClipboardMode mode) =>
        FileClipboardContent(
          source: source,
          rootPaths: const ['/d/a', '/d/folder'],
          mode: mode,
        );

    test('copy is a queue copy anywhere the containment rules allow', () {
      final copy = content(_local, FileClipboardMode.copy);
      expect(
        filePasteKind(copy, destination: _srv, destinationDir: '/x'),
        FilePasteKind.copy,
      );
      // Beside the originals: a copy may land in its own folder.
      expect(
        filePasteKind(copy, destination: _local, destinationDir: '/d'),
        FilePasteKind.copy,
      );
      // Never into a copied folder or below it.
      expect(
        filePasteKind(copy, destination: _local, destinationDir: '/d/folder'),
        isNull,
      );
      expect(
        filePasteKind(
          copy,
          destination: _local,
          destinationDir: '/d/folder/sub',
        ),
        isNull,
      );
    });

    test('cut renames on one server and moves everywhere else', () {
      expect(
        filePasteKind(
          content(_srv, FileClipboardMode.cut),
          destination: _srv,
          destinationDir: '/x',
        ),
        FilePasteKind.rename,
      );
      expect(
        filePasteKind(
          content(_srv, FileClipboardMode.cut),
          destination: _other,
          destinationDir: '/x',
        ),
        FilePasteKind.move,
      );
      expect(
        filePasteKind(
          content(_local, FileClipboardMode.cut),
          destination: _local,
          destinationDir: '/x',
        ),
        FilePasteKind.move,
      );
      expect(
        filePasteKind(
          content(_srv, FileClipboardMode.cut),
          destination: _local,
          destinationDir: '/x',
        ),
        FilePasteKind.move,
      );
      // A cut item back into its own folder is nothing to do.
      expect(
        filePasteKind(
          content(_srv, FileClipboardMode.cut),
          destination: _srv,
          destinationDir: '/d',
        ),
        isNull,
      );
    });
  });

  group('copy and its Undo', () {
    late _Harness h;
    setUp(() {
      h = _Harness();
      h.channels[_srv] = _FakeChannel({'old.txt', 'merged'});
      h.clipboard.put(
        source: _local,
        rootPaths: ['/home/a.txt', '/home/merged', '/home/old.txt'],
        mode: FileClipboardMode.copy,
      );
    });

    test(
      'Paste queues a copy; the clipboard stays for another paste',
      () async {
        final result = await h.operations.paste(
          destination: _srv,
          destinationDir: '/www',
        );

        expect(result.outcome, FilePasteOutcome.queued);
        final spec = h.queue.enqueuedSpecs.single;
        expect(spec.operation, TransferOperation.copy);
        expect(spec.source, _local);
        expect(spec.destination, _srv);
        expect(spec.destinationDir, '/www');
        expect(spec.rootPaths, [
          '/home/a.txt',
          '/home/merged',
          '/home/old.txt',
        ]);
        expect(h.clipboard.content, isNotNull);
        expect(h.history.undoName, 'Copy');
      },
    );

    test('Undo waits for the copy to finish', () async {
      await h.operations.paste(destination: _srv, destinationDir: '/www');

      await expectDeclined(h.history.undo(), h.l10n.fileUndoWaitForTransfer);
      // Declined, so the same Undo works once the copy is done.
      expect(h.history.undoName, 'Copy');
      expect(h.confirmCalls, isEmpty);
    });

    test('Undo deletes only what the copy created, after confirming', () async {
      await h.operations.paste(destination: _srv, destinationDir: '/www');
      final copy = h.queue.tasks.single;
      h.settle(
        copy,
        items: [
          item('/home/a.txt', '/www/a.txt'),
          // Merged into a folder that was already there: kept.
          item('/home/merged', '/www/merged', directory: true),
          // Replaced an existing file: kept.
          item('/home/old.txt', '/www/old.txt'),
          // A child item is not a root of its own.
          item('/home/merged/c', '/www/merged/c'),
        ],
      );

      final undo = h.history.undo();
      await h.completeNextTask(1);
      await undo;

      expect(h.confirmCalls.single.$1, _srv);
      expect(h.confirmCalls.single.$2, ['/www/a.txt']);
      final delete = h.queue.enqueuedDeletes.single;
      expect(delete.source, _srv);
      expect(delete.rootPaths, ['/www/a.txt']);
      expect(delete.confirmed, isTrue);
      expect(h.queue.prepareDeleteCalls.single.preferTrash, isTrue);
      expect(h.history.redoName, 'Copy');
    });

    test('a keep-both copy counts as created', () async {
      await h.operations.paste(destination: _srv, destinationDir: '/www');
      h.settle(
        h.queue.tasks.single,
        items: [item('/home/old.txt', '/www/old (2).txt')],
      );

      final undo = h.history.undo();
      await h.completeNextTask(1);
      await undo;

      expect(h.queue.enqueuedDeletes.single.rootPaths, ['/www/old (2).txt']);
    });

    test('declining the confirmation keeps the copies and the entry', () async {
      h.confirmAnswer = false;
      await h.operations.paste(destination: _srv, destinationDir: '/www');
      h.settle(
        h.queue.tasks.single,
        items: [item('/home/a.txt', '/www/a.txt')],
      );

      await expectDeclined(h.history.undo(), h.l10n.fileUndoCopyKept);
      expect(h.queue.enqueuedDeletes, isEmpty);
      expect(h.history.undoName, 'Copy');
    });

    test('an unreadable destination makes Undo refuse to guess', () async {
      h.channels[_srv]!.listError = StateError('offline');
      await h.operations.paste(destination: _srv, destinationDir: '/www');
      h.settle(
        h.queue.tasks.single,
        items: [item('/home/a.txt', '/www/a.txt')],
      );

      await expectDeclined(h.history.undo(), h.l10n.fileUndoUnknownOrigin);
      expect(h.confirmCalls, isEmpty);
      expect(h.queue.enqueuedDeletes, isEmpty);
    });

    test('nothing created leaves nothing to undo', () async {
      await h.operations.paste(destination: _srv, destinationDir: '/www');
      h.settle(
        h.queue.tasks.single,
        items: [
          item('/home/a.txt', '/www/a.txt', state: TransferItemState.skipped),
        ],
      );

      await expectDeclined(h.history.undo(), h.l10n.fileUndoNothing);
    });

    test('a failed delete fails the Undo', () async {
      await h.operations.paste(destination: _srv, destinationDir: '/www');
      h.settle(
        h.queue.tasks.single,
        items: [item('/home/a.txt', '/www/a.txt')],
      );

      final undo = h.history.undo();
      for (var i = 0; i < 20 && h.queue.tasks.length < 2; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final delete = h.queue.tasks.last..error = 'permission denied';
      h.settle(delete, state: TransferTaskState.failed);

      await expectLater(
        undo,
        throwsA(
          isA<FileOperationFailed>().having(
            (e) => e.message,
            'message',
            'permission denied',
          ),
        ),
      );
    });

    test('Redo copies again', () async {
      await h.operations.paste(destination: _srv, destinationDir: '/www');
      h.settle(
        h.queue.tasks.single,
        items: [item('/home/a.txt', '/www/a.txt')],
      );
      final undo = h.history.undo();
      await h.completeNextTask(1);
      await undo;

      await h.history.redo();

      expect(h.queue.enqueuedSpecs, hasLength(2));
      expect(h.queue.enqueuedSpecs.last.operation, TransferOperation.copy);
      expect(h.history.undoName, 'Copy');
    });
  });

  group('cut', () {
    late _Harness h;
    setUp(() => h = _Harness());

    test('on one server renames each item into the folder', () async {
      final channel = h.channels[_srv] = _FakeChannel();
      h.clipboard.put(
        source: _srv,
        rootPaths: ['/a/one', '/a/two'],
        mode: FileClipboardMode.cut,
      );

      final result = await h.operations.paste(
        destination: _srv,
        destinationDir: '/b',
      );

      expect(result.outcome, FilePasteOutcome.renamed);
      expect(channel.renames, [('/a/one', '/b/one'), ('/a/two', '/b/two')]);
      expect(h.queue.enqueuedSpecs, isEmpty);
      expect(h.clipboard.content, isNull);
      expect(h.history.undoName, 'Move');

      await h.history.undo();
      expect(channel.renames.skip(2), [
        ('/b/two', '/a/two'),
        ('/b/one', '/a/one'),
      ]);

      await h.history.redo();
      expect(channel.renames.skip(4), [
        ('/a/one', '/b/one'),
        ('/a/two', '/b/two'),
      ]);
    });

    test('a failed rename is reported and left out of Undo', () async {
      final channel = h.channels[_srv] = _FakeChannel()
        ..failRenames['/a/two'] = const RemoteFileException(
          kind: RemoteFileErrorKind.conflict,
          operation: 'rename',
          message: 'exists',
        );
      h.clipboard.put(
        source: _srv,
        rootPaths: ['/a/one', '/a/two'],
        mode: FileClipboardMode.cut,
      );

      final result = await h.operations.paste(
        destination: _srv,
        destinationDir: '/b',
      );

      expect(result.outcome, FilePasteOutcome.partial);
      expect(result.failures.single.path, '/a/two');
      await h.history.undo();
      expect(channel.renames.last, ('/b/one', '/a/one'));
      expect(channel.renames, hasLength(2));
    });

    test('Undo of a rename needs a live tab on the host', () async {
      h.channels[_srv] = _FakeChannel();
      h.clipboard.put(
        source: _srv,
        rootPaths: ['/a/one'],
        mode: FileClipboardMode.cut,
      );
      await h.operations.paste(destination: _srv, destinationDir: '/b');
      h.channels.remove(_srv);

      await expectDeclined(h.history.undo(), h.l10n.fileUndoNeedsTab('srv'));
    });

    test('across hosts is a queue move, undone by moving back', () async {
      h.channels[_local] = _FakeChannel({'existing'});
      h.clipboard.put(
        source: _srv,
        rootPaths: ['/a/one', '/c/two', '/a/existing'],
        mode: FileClipboardMode.cut,
      );

      final result = await h.operations.paste(
        destination: _local,
        destinationDir: '/home',
      );

      expect(result.outcome, FilePasteOutcome.queued);
      expect(h.queue.enqueuedSpecs.single.operation, TransferOperation.move);
      expect(h.clipboard.content, isNull);
      expect(h.history.undoName, 'Move');

      h.settle(
        h.queue.tasks.single,
        items: [
          item('/a/one', '/home/one'),
          item('/c/two', '/home/two'),
          // Merged into a folder that existed: never moved back.
          item('/a/existing', '/home/existing', directory: true),
        ],
      );
      final undo = h.history.undo();
      for (var i = 0; i < 20 && h.queue.tasks.length < 3; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      final back = h.queue.enqueuedSpecs.skip(1).toList();
      expect([for (final spec in back) spec.destinationDir], ['/a', '/c']);
      expect(
        [for (final spec in back) spec.rootPaths],
        [
          ['/home/one'],
          ['/home/two'],
        ],
      );
      for (final spec in back) {
        expect(spec.operation, TransferOperation.move);
        expect(spec.source, _local);
        expect(spec.destination, _srv);
      }
      for (final task in h.queue.tasks.skip(1)) {
        h.settle(
          task,
          items: [
            for (final root in task.rootPaths)
              item(root, '${task.destinationDir}/${root.split('/').last}'),
          ],
        );
      }
      await undo;
      expect(h.notices, isEmpty);
    });

    group('a root Keep Both renamed', () {
      /// Cuts /a/notes from the server into /home on this device, where
      /// Keep Both lands it as "notes 2", and undoes the move with the
      /// move back landing at [backAt].
      Future<void> moveAndUndo({String backAt = '/a/notes 2'}) async {
        h.channels[_local] = _FakeChannel({'notes'});
        h.clipboard.put(
          source: _srv,
          rootPaths: ['/a/notes'],
          mode: FileClipboardMode.cut,
        );
        await h.operations.paste(destination: _local, destinationDir: '/home');
        h.settle(
          h.queue.tasks.single,
          items: [item('/a/notes', '/home/notes 2')],
        );

        final undo = h.history.undo();
        for (var i = 0; i < 20 && h.queue.tasks.length < 2; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          h.queue.tasks,
          hasLength(2),
          reason: 'undo never enqueued the move back',
        );
        final back = h.queue.tasks.last;
        expect(back.rootPaths, ['/home/notes 2']);
        h.settle(back, items: [item('/home/notes 2', backAt)]);
        await undo;
      }

      test('gets its own name back when the name is free', () async {
        final channel = h.channels[_srv] = _FakeChannel();

        await moveAndUndo();

        expect(channel.renames, [('/a/notes 2', '/a/notes')]);
        expect(h.notices, isEmpty);
      });

      test('keeps its name, and says so, when the name is taken', () async {
        h.channels[_srv] = _FakeChannel()
          ..failRenames['/a/notes 2'] = const RemoteFileException(
            kind: RemoteFileErrorKind.conflict,
            operation: 'rename',
            message: 'exists',
          );

        await moveAndUndo();

        expect(h.notices, [
          h.l10n.fileUndoNameKept('notes 2', h.l10n.fileUndoNameTaken('notes')),
        ]);
        // The move itself was undone.
        expect(h.history.redoName, 'Move');
      });

      test('keeps its name, and says so, without a tab on the host', () async {
        await moveAndUndo();

        expect(h.notices, [
          h.l10n.fileUndoNameKept('notes 2', h.l10n.fileUndoNameNoTab('srv')),
        ]);
      });

      test(
        'a move back that clashed again is renamed from where it landed',
        () async {
          final channel = h.channels[_srv] = _FakeChannel();

          await moveAndUndo(backAt: '/a/notes 3');

          expect(channel.renames, [('/a/notes 3', '/a/notes')]);
        },
      );

      test('several kept names share one notice', () async {
        h.channels[_local] = _FakeChannel({'notes', 'todo'});
        h.clipboard.put(
          source: _srv,
          rootPaths: ['/a/notes', '/a/todo'],
          mode: FileClipboardMode.cut,
        );
        await h.operations.paste(destination: _local, destinationDir: '/home');
        h.settle(
          h.queue.tasks.single,
          items: [
            item('/a/notes', '/home/notes 2'),
            item('/a/todo', '/home/todo 2'),
          ],
        );

        final undo = h.history.undo();
        for (var i = 0; i < 20 && h.queue.tasks.length < 2; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(
          h.queue.tasks,
          hasLength(2),
          reason: 'undo never enqueued the move back',
        );
        h.settle(
          h.queue.tasks.last,
          items: [
            item('/home/notes 2', '/a/notes 2'),
            item('/home/todo 2', '/a/todo 2'),
          ],
        );
        await undo;

        final noTab = h.l10n.fileUndoNameNoTab('srv');
        expect(h.notices, [
          '${h.l10n.fileUndoNameKept('notes 2', noTab)}\n'
              '${h.l10n.fileUndoNameKept('todo 2', noTab)}',
        ]);
      });
    });

    test(
      'on this device is a queue move too (the queue renames there)',
      () async {
        h.channels[_local] = _FakeChannel();
        h.clipboard.put(
          source: _local,
          rootPaths: ['/a/one'],
          mode: FileClipboardMode.cut,
        );

        await h.operations.paste(destination: _local, destinationDir: '/b');

        final spec = h.queue.enqueuedSpecs.single;
        expect(spec.operation, TransferOperation.move);
        expect(spec.source, _local);
        expect(spec.destination, _local);
      },
    );
  });

  test(
    'Paste with an empty clipboard or a refused folder does nothing',
    () async {
      final h = _Harness();
      expect(
        (await h.operations.paste(
          destination: _local,
          destinationDir: '/x',
        )).outcome,
        FilePasteOutcome.unavailable,
      );
      h.clipboard.put(
        source: _local,
        rootPaths: ['/x/f'],
        mode: FileClipboardMode.copy,
      );
      expect(
        (await h.operations.paste(
          destination: _local,
          destinationDir: '/x/f',
        )).outcome,
        FilePasteOutcome.refused,
      );
      h.queueBound = false;
      expect(
        (await h.operations.paste(
          destination: _srv,
          destinationDir: '/y',
        )).outcome,
        FilePasteOutcome.unavailable,
      );
      expect(h.queue.enqueuedSpecs, isEmpty);
      expect(h.history.undoName, isNull);
    },
  );

  group('inline rename', () {
    test('Undo renames back on the same host', () async {
      final h = _Harness();
      final channel = h.channels[_srv] = _FakeChannel();
      h.operations.recordRename(_srv, '/a/old', '/a/new');
      expect(h.history.undoName, 'Rename');

      await h.history.undo();
      expect(channel.renames.single, ('/a/new', '/a/old'));
      await h.history.redo();
      expect(channel.renames.last, ('/a/old', '/a/new'));
    });
  });

  group('Rename Items', () {
    test('Undo renames every item back, last first; Redo replays', () async {
      final h = _Harness();
      final channel = h.channels[_srv] = _FakeChannel();
      // A chain, in the order the run sent it: f 2 made room for f 1.
      h.operations.recordBatchRename(_srv, [
        (from: '/a/f 2', to: '/a/f 3'),
        (from: '/a/f 1', to: '/a/f 2'),
      ]);
      expect(h.history.undoName, 'Rename Items');

      await h.history.undo();
      expect(channel.renames, [('/a/f 2', '/a/f 1'), ('/a/f 3', '/a/f 2')]);

      channel.renames.clear();
      await h.history.redo();
      expect(channel.renames, [('/a/f 2', '/a/f 3'), ('/a/f 1', '/a/f 2')]);
    });

    test('Undo needs a live tab on the host', () async {
      final h = _Harness();
      h.operations.recordBatchRename(_srv, [(from: '/a/x', to: '/a/y')]);

      await expectDeclined(h.history.undo(), 'Open a tab on srv to undo this.');
      expect(h.history.undoName, 'Rename Items');
    });
  });

  group('Move to Trash', () {
    late _Harness h;
    late _FakeChannel channel;
    setUp(() {
      h = _Harness();
      channel = h.channels[_local] = _FakeChannel();
    });

    Future<TransferTask> trash(List<String> roots) => h.queue.enqueueDelete(
      DeleteRequest(
        source: _local,
        rootPaths: roots,
        disposition: DeleteDisposition.trash,
      ),
    );

    test('Undo puts the items back where the trash says it put them', () async {
      final task = await trash(['/home/a', '/home/b']);
      h.operations.recordTrash(task);
      expect(h.history.undoName, 'Move to Trash');

      await expectDeclined(h.history.undo(), h.l10n.fileUndoWaitForTransfer);

      h.settle(
        task,
        items: [
          item(
            '/home/a',
            '/Users/me/.Trash/a',
            disposition: ItemDisposition.osTrash,
          ),
          item(
            '/home/b',
            '/Users/me/.Trash/b 2',
            disposition: ItemDisposition.osTrash,
          ),
        ],
      );
      await h.history.undo();

      expect(channel.renames, [
        ('/Users/me/.Trash/a', '/home/a'),
        ('/Users/me/.Trash/b 2', '/home/b'),
      ]);

      // Redo trashes them again.
      await h.history.redo();
      final again = h.queue.enqueuedDeletes.last;
      expect(again.rootPaths, ['/home/a', '/home/b']);
      expect(again.disposition, DeleteDisposition.trash);
    });

    test('a trash without Put Back locations says so', () async {
      final task = await trash(['/home/a']);
      h.operations.recordTrash(task);
      h.settle(
        task,
        items: [
          item('/home/a', '/home/a', disposition: ItemDisposition.osTrash),
        ],
      );

      await expectDeclined(h.history.undo(), h.l10n.fileUndoPutBackUnavailable);
      expect(channel.renames, isEmpty);
    });

    test(
      'items without a location are reported after the rest come back',
      () async {
        final task = await trash(['/home/a', '/home/b']);
        h.operations.recordTrash(task);
        h.settle(
          task,
          items: [
            item('/home/a', '/T/a', disposition: ItemDisposition.osTrash),
            item('/home/b', '/home/b', disposition: ItemDisposition.osTrash),
          ],
        );

        await expectLater(
          h.history.undo(),
          throwsA(
            isA<FileOperationFailed>().having(
              (e) => e.message,
              'message',
              h.l10n.fileUndoPutBackPartial(1),
            ),
          ),
        );
        expect(channel.renames, [('/T/a', '/home/a')]);
      },
    );
  });

  group('irreversible deletes', () {
    test('block Undo by name until another change is recorded', () async {
      final h = _Harness();
      h.operations.recordRename(_srv, '/a', '/b');
      h.operations.recordIrreversibleDelete();

      expect(h.operations.blockedUndoName, 'Delete');
      await expectDeclined(h.history.undo(), h.l10n.fileUndoIrreversibleDelete);
      // Never stepped past: the rename beneath stays put.
      expect(h.history.undoName, 'Delete');

      h.operations.recordRename(_srv, '/b', '/c');
      expect(h.operations.blockedUndoName, isNull);
      expect(h.history.undoName, 'Rename');
    });
  });
}
