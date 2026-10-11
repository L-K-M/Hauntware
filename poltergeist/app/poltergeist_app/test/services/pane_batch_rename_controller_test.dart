import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_batch_rename.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' show FakePaneChannel, FakePaneLanes;

const _home = '/home/tester';

RemoteFileEntry _file(String name, {String folder = _home}) => RemoteFileEntry(
  path: '$folder/$name',
  name: name,
  type: RemoteFileType.file,
  size: 1,
);

RemoteFileEntry _dir(String name, {String folder = _home}) => RemoteFileEntry(
  path: '$folder/$name',
  name: name,
  type: RemoteFileType.directory,
);

const _addX = AddTextRule(
  text: '-x',
  placement: BatchRenamePlacement.afterName,
);

void main() {
  late FakePaneLanes lanes;
  late FakePaneChannel channel;
  late PaneController pane;

  setUp(() {
    lanes = FakePaneLanes();
    channel = FakePaneChannel(_home);
    lanes.nextLocalChannel = channel;
    pane = PaneController(paneTabId: 'pane.left', lanes: lanes);
  });

  tearDown(() => pane.dispose());

  Future<void> open(List<RemoteFileEntry> listing) async {
    channel.listings[_home] = listing;
    await pane.openLocalHome();
    await pumpEventQueue();
  }

  int row(String name) {
    final index = pane.entries.indexWhere((entry) => entry.name == name);
    expect(index, isNonNegative, reason: '$name missing from listing');
    return index;
  }

  void select(List<String> names) {
    pane.setCursorIndex(row(names.first));
    for (final name in names.skip(1)) {
      pane.setCursorIndex(row(name), update: SelectionUpdate.toggle);
    }
  }

  group('availability', () {
    test('needs a listing and two selected rows', () async {
      expect(pane.batchRenameAvailability, BatchRenameAvailability.noListing);
      await open([_file('a.txt'), _file('b.txt')]);
      expect(pane.batchRenameAvailability, BatchRenameAvailability.needsTwo);
      select(['a.txt']);
      expect(pane.batchRenameAvailability, BatchRenameAvailability.needsTwo);
      select(['a.txt', 'b.txt']);
      expect(pane.batchRenameAvailability, BatchRenameAvailability.available);
    });

    test('refuses a row inside a selected folder', () async {
      channel.listings['$_home/docs'] = [_file('c.txt', folder: '$_home/docs')];
      await open([_dir('docs'), _file('a.txt')]);
      pane.expandAt(row('docs'));
      await pumpEventQueue();
      select(['docs', 'c.txt']);
      expect(pane.batchRenameAvailability, BatchRenameAvailability.nested);
      select(['a.txt', 'c.txt']);
      expect(pane.batchRenameAvailability, BatchRenameAvailability.available);
    });

    test('refuses a selection of only undecodable names', () async {
      await open([_file('a�'), _file('b�')]);
      select(['a�', 'b�']);
      expect(pane.batchRenameAvailability, BatchRenameAvailability.allFlagged);
    });

    test('inline rename and Rename Items exclude each other', () async {
      await open([_file('a.txt'), _file('b.txt')]);
      select(['a.txt', 'b.txt']);
      pane.startRename();
      expect(pane.inlineRenameActive, isTrue);
      expect(pane.batchRenameAvailability, BatchRenameAvailability.busy);
      expect(pane.startBatchRename(), isFalse);
      pane.cancelRename();

      expect(pane.startBatchRename(), isTrue);
      expect(pane.batchRenameAvailability, BatchRenameAvailability.busy);
      pane.startRename();
      expect(pane.inlineRenameActive, isFalse);
    });
  });

  group('session', () {
    test('freezes the selection in listing order with ordinals', () async {
      await open([_file('a.txt'), _file('b�'), _file('c.txt')]);
      select(['c.txt', 'a.txt', 'b�']);
      expect(pane.startBatchRename(), isTrue);
      final targets = pane.batchRename!.snapshot.targets;
      expect([for (final t in targets) t.name], ['a.txt', 'b�', 'c.txt']);
      expect([for (final t in targets) t.ordinal], [0, -1, 1]);
      expect(targets.every((t) => t.folder == _home), isTrue);
      expect(targets.first.parentPrefix, '$_home/');
      expect(pane.batchRename!.stage, BatchRenameStage.editing);
    });

    test('the preview re-plans when the folder re-lists', () async {
      await open([_file('a.txt'), _file('b.txt')]);
      select(['a.txt', 'b.txt']);
      pane.startBatchRename();
      final session = pane.batchRename!;
      var notified = 0;
      session.addListener(() => notified++);

      channel.listings[_home] = [_file('b.txt')];
      pane.refresh();
      await pumpEventQueue();

      expect(notified, greaterThan(0));
      final plan = planBatchRename(session.snapshot, _addX);
      expect(plan.rows.first.status, BatchRenameStatus.gone);
      expect(pane.batchRenameActive, isTrue);
    });

    test('a selected dotfile stays present when hidden files hide', () async {
      await open([_file('.a.txt'), _file('b.txt')]);
      pane.showHidden = true;
      select(['.a.txt', 'b.txt']);
      pane.startBatchRename();

      pane.showHidden = false;
      expect(pane.entries.map((e) => e.name), isNot(contains('.a.txt')));
      final plan = planBatchRename(pane.batchRename!.snapshot, _addX);
      expect(plan.rows.first.target.present, isTrue);
      expect(plan.rows.first.newName, '.a-x.txt');
      expect(plan.rows.first.status, BatchRenameStatus.rename);
    });
  });

  group('runBatchRename', () {
    test('renames, refreshes and selects every item at its new path', () async {
      await open([_file('a.txt'), _file('b.txt'), _file('c.txt')]);
      select(['a.txt', 'c.txt']);
      pane.startBatchRename();
      // What the folder holds once the renames land.
      channel.listings[_home] = [
        _file('a-x.txt'),
        _file('b.txt'),
        _file('c-x.txt'),
      ];

      expect(await pane.runBatchRename(_addX), isTrue);
      await pumpEventQueue();

      expect(channel.renameCalls, [
        ('$_home/a.txt', '$_home/a-x.txt'),
        ('$_home/c.txt', '$_home/c-x.txt'),
      ]);
      final session = pane.batchRename!;
      expect(session.stage, BatchRenameStage.finished);
      expect(session.stop, BatchRenameStop.completed);
      expect(session.renamedCount, 2);
      expect(
        [for (final entry in pane.selectedEntries) entry.name],
        ['a-x.txt', 'c-x.txt'],
      );
      expect(pane.entries[pane.cursorIndex!].name, 'a-x.txt');

      pane.closeBatchRename();
      expect(pane.batchRenameActive, isFalse);
      expect(session.stage, BatchRenameStage.ended);
    });

    test('selects renamed rows inside an open folder too', () async {
      const docs = '$_home/docs';
      channel.listings[docs] = [_file('c.txt', folder: docs)];
      await open([_dir('docs'), _file('a.txt')]);
      pane.expandAt(row('docs'));
      await pumpEventQueue();
      select(['a.txt', 'c.txt']);
      pane.startBatchRename();
      // Folders sort first and children sit under them: c.txt leads.
      expect(pane.batchRename!.snapshot.targets.first.folder, docs);
      channel.listings[_home] = [_dir('docs'), _file('a-x.txt')];
      channel.listings[docs] = [_file('c-x.txt', folder: docs)];

      await pane.runBatchRename(_addX);
      await pumpEventQueue();

      expect(channel.renameCalls, [
        ('$docs/c.txt', '$docs/c-x.txt'),
        ('$_home/a.txt', '$_home/a-x.txt'),
      ]);
      expect(
        [for (final entry in pane.selectedEntries) entry.path],
        ['$docs/c-x.txt', '$_home/a-x.txt'],
      );
    });

    test('re-plans first and sends nothing when the folder changed', () async {
      await open([_file('a.txt'), _file('b.txt')]);
      select(['a.txt', 'b.txt']);
      pane.startBatchRename();
      // Someone else created a-x.txt; the cache learns it on re-list.
      channel.listings[_home] = [
        _file('a.txt'),
        _file('b.txt'),
        _file('a-x.txt'),
      ];
      pane.refresh();
      await pumpEventQueue();

      expect(await pane.runBatchRename(_addX), isFalse);
      expect(channel.renameCalls, isEmpty);
      expect(pane.batchRename!.refusedChanged, isTrue);
      expect(pane.batchRename!.stage, BatchRenameStage.editing);
    });

    test('Stop lets the request in flight settle, then ends', () async {
      await open([_file('a.txt'), _file('b.txt')]);
      select(['a.txt', 'b.txt']);
      pane.startBatchRename();
      final held = Completer<void>();
      channel.heldRename = held;

      final running = pane.runBatchRename(_addX);
      await pumpEventQueue();
      expect(pane.batchRename!.stage, BatchRenameStage.running);
      expect(pane.batchRename!.currentRow, 0);
      pane.closeBatchRename(); // refused while running
      expect(pane.batchRenameActive, isTrue);

      pane.stopBatchRename();
      expect(pane.batchRename!.stopRequested, isTrue);
      held.complete();
      expect(await running, isTrue);

      final session = pane.batchRename!;
      expect(session.stop, BatchRenameStop.stopped);
      expect(channel.renameCalls, hasLength(1));
      expect(session.outcomes[0], isA<BatchRenameRenamed>());
      expect(session.outcomes[1], isNull);
    });

    test('a typed refusal is recorded and the rest still run', () async {
      await open([_file('a.txt'), _file('b.txt')]);
      select(['a.txt', 'b.txt']);
      pane.startBatchRename();
      channel.renameFailures['$_home/a.txt'] = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        message: 'denied',
      );
      await pane.runBatchRename(_addX);
      final session = pane.batchRename!;
      expect(session.stop, BatchRenameStop.completed);
      expect(session.outcomes[0], isA<BatchRenameFailed>());
      expect(session.outcomes[1], isA<BatchRenameRenamed>());
      expect(channel.renameCalls, hasLength(2));
    });
  });

  group('invalidation', () {
    test('leaving the folder while editing ends the session', () async {
      channel.listings['$_home/docs'] = const [];
      await open([_dir('docs'), _file('a.txt'), _file('b.txt')]);
      select(['a.txt', 'b.txt']);
      pane.startBatchRename();
      final session = pane.batchRename!;
      var ended = false;
      session.addListener(() {
        if (session.stage == BatchRenameStage.ended) ended = true;
      });

      pane.navigate('$_home/docs');
      expect(ended, isTrue);
      expect(pane.batchRenameActive, isFalse);
    });

    test('leaving the folder mid-run finishes as a pane change', () async {
      channel.listings['$_home/docs'] = const [];
      await open([_dir('docs'), _file('a.txt'), _file('b.txt')]);
      select(['a.txt', 'b.txt']);
      pane.startBatchRename();
      final held = Completer<void>();
      channel.heldRename = held;

      final running = pane.runBatchRename(_addX);
      await pumpEventQueue();
      pane.navigate('$_home/docs');
      expect(pane.batchRename!.stage, BatchRenameStage.running);
      held.complete();
      await running;
      await pumpEventQueue();

      final session = pane.batchRename!;
      expect(session.stage, BatchRenameStage.finished);
      expect(session.stop, BatchRenameStop.paneChanged);
      expect(channel.renameCalls, hasLength(1));
      expect(pane.location?.path, '$_home/docs');
      expect(pane.selectedEntries, isEmpty);
    });

    test('dispose ends the session in any stage', () async {
      await open([_file('a.txt'), _file('b.txt')]);
      select(['a.txt', 'b.txt']);
      pane.startBatchRename();
      final session = pane.batchRename!;
      final held = Completer<void>();
      channel.heldRename = held;
      final running = pane.runBatchRename(_addX);
      await pumpEventQueue();

      pane.dispose();
      expect(session.stage, BatchRenameStage.ended);
      held.complete();
      expect(await running, isTrue);
      expect(session.stage, BatchRenameStage.ended);
    });
  });
}
