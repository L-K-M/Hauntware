import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_batch_rename.dart';
import 'package:poltergeist_app/services/pane_rename.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_pane_channel.dart';

const _folder = '/srv';

/// A selected item in [_folder] (or [folder]), numbered in list order.
BatchRenameTarget _target(
  String name, {
  int ordinal = 0,
  bool isDirectory = false,
  bool present = true,
  String folder = _folder,
}) => BatchRenameTarget(
  path: '$folder/$name',
  name: name,
  folder: folder,
  parentPrefix: '$folder/',
  isDirectory: isDirectory,
  ordinal: ordinal,
  present: present,
);

/// Targets numbered 0, 1, 2… in the given order.
List<BatchRenameTarget> _targets(List<String> names) => [
  for (var i = 0; i < names.length; i++) _target(names[i], ordinal: i),
];

BatchRenameSnapshot _snapshot(
  List<BatchRenameTarget> targets, {
  List<String> others = const [],
  Map<String, List<String>> otherFolders = const {},
  bool remote = true,
  TargetPlatform platform = TargetPlatform.linux,
}) {
  final entries = <String, List<BatchRenameFolderEntry>>{};
  void add(String folder, String name) => entries
      .putIfAbsent(folder, () => [])
      .add((path: '$folder/$name', name: name));
  for (final target in targets) {
    if (target.present) add(target.folder, target.name);
  }
  for (final name in others) {
    add(_folder, name);
  }
  for (final MapEntry(key: folder, value: names) in otherFolders.entries) {
    for (final name in names) {
      add(folder, name);
    }
  }
  return BatchRenameSnapshot(
    targets: targets,
    folderEntries: entries,
    remote: remote,
    platform: platform,
  );
}

String _apply(
  BatchRenameRule rule,
  String name, {
  bool isDirectory = false,
  int number = 0,
  int numberWidth = 1,
}) => applyBatchRenameRule(
  rule,
  name,
  isDirectory: isDirectory,
  number: number,
  numberWidth: numberWidth,
).name;

List<String> _newNames(BatchRenamePlan plan) => [
  for (final row in plan.rows) row.newName,
];

List<BatchRenameStatus> _statuses(BatchRenamePlan plan) => [
  for (final row in plan.rows) row.status,
];

void main() {
  group('splitRenameExtension', () {
    test('splits at the last dot, never a leading one or a folder', () {
      expect(splitRenameExtension('archive.tar.gz', isDirectory: false), (
        stem: 'archive.tar',
        extension: '.gz',
      ));
      expect(splitRenameExtension('.bashrc', isDirectory: false), (
        stem: '.bashrc',
        extension: '',
      ));
      expect(splitRenameExtension('name.', isDirectory: false), (
        stem: 'name',
        extension: '.',
      ));
      expect(splitRenameExtension('README', isDirectory: false), (
        stem: 'README',
        extension: '',
      ));
      expect(splitRenameExtension('v1.2', isDirectory: true), (
        stem: 'v1.2',
        extension: '',
      ));
    });

    test('agrees with Keep Both numbering', () {
      for (final (name, isDirectory) in [
        ('report.pdf', false),
        ('archive.tar.gz', false),
        ('.bashrc', false),
        ('name.', false),
        ('v1.2', true),
        ('README', false),
      ]) {
        final (:stem, :extension) = splitRenameExtension(
          name,
          isDirectory: isDirectory,
        );
        expect(
          numberedConflictName(name, 2, isDirectory: isDirectory),
          '$stem (2)$extension',
          reason: name,
        );
      }
    });
  });

  group('Replace Text', () {
    test('replaces every match in the stem by default', () {
      const rule = ReplaceTextRule(find: 'IMG_', replacement: 'Trip ');
      expect(_apply(rule, 'IMG_0001.JPG'), 'Trip 0001.JPG');
      expect(_apply(rule, 'IMG_IMG_.png'), 'Trip Trip .png');
    });

    test('leaves the extension alone unless asked', () {
      const stemOnly = ReplaceTextRule(find: 'jpeg', replacement: 'jpg');
      expect(_apply(stemOnly, 'photo.jpeg'), 'photo.jpeg');
      const whole = ReplaceTextRule(
        find: 'jpeg',
        replacement: 'jpg',
        includeExtension: true,
      );
      expect(_apply(whole, 'photo.jpeg'), 'photo.jpg');
      // A folder has no extension to protect.
      const dot = ReplaceTextRule(find: '.', replacement: '-');
      expect(_apply(dot, 'v1.2', isDirectory: true), 'v1-2');
    });

    test('matches case unless Match case is off', () {
      const sensitive = ReplaceTextRule(find: 'img', replacement: 'pic');
      expect(_apply(sensitive, 'IMG_1.png'), 'IMG_1.png');
      const insensitive = ReplaceTextRule(
        find: 'img',
        replacement: 'pic',
        matchCase: false,
      );
      expect(_apply(insensitive, 'IMG_1.png'), 'pic_1.png');
      expect(_apply(insensitive, 'Img-2.png'), 'pic-2.png');
      const accent = ReplaceTextRule(
        find: 'é',
        replacement: 'e',
        matchCase: false,
      );
      expect(_apply(accent, 'CAFÉ menu.txt'), 'CAFe menu.txt');
    });

    test('find and replacement are literal', () {
      const rule = ReplaceTextRule(find: 'a.c', replacement: r'$1');
      expect(_apply(rule, 'a.c.txt', isDirectory: true), r'$1.txt');
      expect(_apply(rule, 'abc.txt'), 'abc.txt');
    });

    test('an empty find changes nothing', () {
      const rule = ReplaceTextRule(find: '', replacement: 'x');
      expect(_apply(rule, 'report.txt'), 'report.txt');
    });

    test('reports a stem replaced away', () {
      const rule = ReplaceTextRule(find: 'report', replacement: '');
      final result = applyBatchRenameRule(
        rule,
        'report.txt',
        isDirectory: false,
      );
      expect(result.name, '.txt');
      expect(result.stemEmptied, isTrue);
    });
  });

  group('Add Text', () {
    test('after the name goes before the extension', () {
      const rule = AddTextRule(
        text: ' (old)',
        placement: BatchRenamePlacement.afterName,
      );
      expect(_apply(rule, 'notes.txt'), 'notes (old).txt');
      expect(_apply(rule, 'src.bak', isDirectory: true), 'src.bak (old)');
      expect(_apply(rule, '.bashrc'), '.bashrc (old)');
      expect(
        _apply(
          const AddTextRule(
            text: '_v2',
            placement: BatchRenamePlacement.afterName,
          ),
          'archive.tar.gz',
        ),
        'archive.tar_v2.gz',
      );
    });

    test('before the name prefixes it; empty text changes nothing', () {
      const rule = AddTextRule(
        text: '2026-',
        placement: BatchRenamePlacement.beforeName,
      );
      expect(_apply(rule, 'a.pdf'), '2026-a.pdf');
      const empty = AddTextRule(
        text: '',
        placement: BatchRenamePlacement.beforeName,
      );
      expect(_apply(empty, 'a.pdf'), 'a.pdf');
    });
  });

  group('Format', () {
    test('numbers in list order with the name, keeping extensions', () {
      final plan = planBatchRename(
        _snapshot([
          _target('b.pdf', ordinal: 0),
          _target('a.jpg', ordinal: 1),
          _target('Docs', ordinal: 2, isDirectory: true),
        ]),
        const FormatRule(
          name: 'Scan',
          placement: BatchRenamePlacement.afterName,
          startAt: 1,
        ),
      );
      expect(_newNames(plan), ['Scan 1.pdf', 'Scan 2.jpg', 'Scan 3']);
    });

    test('an empty name keeps each stem', () {
      final plan = planBatchRename(
        _snapshot(_targets(['b.pdf', 'a.jpg'])),
        const FormatRule(
          name: '',
          placement: BatchRenamePlacement.afterName,
          startAt: 1,
        ),
      );
      expect(_newNames(plan), ['b 1.pdf', 'a 2.jpg']);
    });

    test('before the name pads to the widest number', () {
      final names = [for (var i = 0; i < 12; i++) 'x$i.mp3'];
      final plan = planBatchRename(
        _snapshot(_targets(names)),
        const FormatRule(
          name: 'Track',
          placement: BatchRenamePlacement.beforeName,
          startAt: 1,
        ),
      );
      expect(plan.rows.first.newName, '01 Track.mp3');
      expect(plan.rows.last.newName, '12 Track.mp3');
    });

    test('width covers the first and the last number', () {
      expect(batchRenameNumberWidth(startAt: 8, count: 5), 2);
      expect(batchRenameNumberWidth(startAt: 98, count: 4), 3);
      expect(batchRenameNumberWidth(startAt: 0, count: 10), 1);
      expect(batchRenameNumberWidth(startAt: 5, count: 0), 1);
    });

    test('left-out items get no number and keep the sequence', () {
      final plan = planBatchRename(
        _snapshot([
          _target('a.txt', ordinal: 0),
          _target('bad�.txt', ordinal: -1),
          _target('c.txt', ordinal: 1),
        ]),
        const FormatRule(
          name: 'File',
          placement: BatchRenamePlacement.afterName,
          startAt: 1,
        ),
      );
      expect(_statuses(plan), [
        BatchRenameStatus.rename,
        BatchRenameStatus.leftOut,
        BatchRenameStatus.rename,
      ]);
      expect(_newNames(plan), ['File 1.txt', 'bad�.txt', 'File 2.txt']);
      expect(plan.leftOutCount, 1);
      expect(plan.runnable, isTrue);
    });

    test('one sequence runs across folders', () {
      final plan = planBatchRename(
        _snapshot([
          _target('a.txt', ordinal: 0),
          _target('b.txt', ordinal: 1, folder: '/srv/sub'),
        ]),
        const FormatRule(
          name: 'Doc',
          placement: BatchRenamePlacement.afterName,
          startAt: 1,
        ),
      );
      expect(_newNames(plan), ['Doc 1.txt', 'Doc 2.txt']);
      expect(plan.rows.last.newPath, '/srv/sub/Doc 2.txt');
    });

    test('numbers stay with their item when another goes missing', () {
      final plan = planBatchRename(
        _snapshot([
          _target('a.txt', ordinal: 0, present: false),
          _target('b.txt', ordinal: 1),
        ]),
        const FormatRule(
          name: 'N',
          placement: BatchRenamePlacement.afterName,
          startAt: 1,
        ),
      );
      expect(_newNames(plan), ['N 1.txt', 'N 2.txt']);
      expect(plan.rows.first.status, BatchRenameStatus.gone);
    });
  });

  group('planBatchRename checks', () {
    const addX = AddTextRule(
      text: '-x',
      placement: BatchRenamePlacement.afterName,
    );

    test('unchanged names are neither sent nor blocking', () {
      final plan = planBatchRename(
        _snapshot(_targets(['a.txt', 'b.txt'])),
        const ReplaceTextRule(find: 'a', replacement: 'z'),
      );
      expect(_statuses(plan), [
        BatchRenameStatus.rename,
        BatchRenameStatus.unchanged,
      ]);
      expect(plan.renameCount, 1);
      expect(plan.unchangedCount, 1);
      expect(plan.steps, [0]);
    });

    test('nothing to rename is not runnable', () {
      final plan = planBatchRename(
        _snapshot(_targets(['a.txt', 'b.txt'])),
        const ReplaceTextRule(find: 'q', replacement: 'z'),
      );
      expect(plan.runnable, isFalse);
      expect(plan.blockedCount, 0);
    });

    test('invalid names block, by pane rules', () {
      final separator = planBatchRename(
        _snapshot(_targets(['a.txt'])),
        const AddTextRule(
          text: '/x',
          placement: BatchRenamePlacement.afterName,
        ),
      );
      expect(separator.rows.single.status, BatchRenameStatus.invalidName);
      expect(separator.rows.single.nameError, RenameNameError.separator);

      const colon = AddTextRule(
        text: ':',
        placement: BatchRenamePlacement.afterName,
      );
      final remote = planBatchRename(_snapshot(_targets(['a.txt'])), colon);
      expect(remote.rows.single.status, BatchRenameStatus.rename);
      final windows = planBatchRename(
        _snapshot(
          _targets(['a.txt']),
          remote: false,
          platform: TargetPlatform.windows,
        ),
        colon,
      );
      expect(windows.rows.single.status, BatchRenameStatus.invalidName);
      expect(windows.rows.single.nameError, RenameNameError.invalid);
    });

    test('dot names and a typed U+FFFD are invalid', () {
      for (final find in ['a', 'b']) {
        final plan = planBatchRename(
          _snapshot([_target(find, isDirectory: true)]),
          ReplaceTextRule(find: find, replacement: find == 'a' ? '.' : '..'),
        );
        expect(plan.rows.single.status, BatchRenameStatus.invalidName);
        expect(plan.rows.single.nameError, RenameNameError.invalid);
      }
      final replacement = planBatchRename(
        _snapshot(_targets(['a.txt'])),
        const ReplaceTextRule(find: 'a', replacement: '�'),
      );
      expect(replacement.rows.single.status, BatchRenameStatus.invalidName);
    });

    test('an emptied stem is an empty name', () {
      final plan = planBatchRename(
        _snapshot(_targets(['report.txt'])),
        const ReplaceTextRule(find: 'report', replacement: ''),
      );
      expect(plan.rows.single.status, BatchRenameStatus.invalidName);
      expect(plan.rows.single.nameError, RenameNameError.empty);
    });

    test('a name that would become hidden blocks', () {
      final plan = planBatchRename(
        _snapshot(_targets(['env', '.profile'])),
        const AddTextRule(
          text: '.',
          placement: BatchRenamePlacement.beforeName,
        ),
      );
      expect(_statuses(plan), [
        BatchRenameStatus.becomesHidden,
        BatchRenameStatus.rename,
      ]);
      expect(plan.runnable, isFalse);
    });

    test('a gone item blocks', () {
      final plan = planBatchRename(
        _snapshot([_target('a.txt', present: false), _target('b.txt')]),
        addX,
      );
      expect(plan.rows.first.status, BatchRenameStatus.gone);
      expect(plan.runnable, isFalse);
      expect(plan.firstBlockedRow, 0);
    });

    test('duplicates in one folder block every member', () {
      // ab -> b and ba -> b.
      final plan = planBatchRename(
        _snapshot(_targets(['ab.txt', 'ba.txt', 'c.txt'])),
        const ReplaceTextRule(find: 'a', replacement: ''),
      );
      expect(_newNames(plan), ['b.txt', 'b.txt', 'c.txt']);
      expect(_statuses(plan), [
        BatchRenameStatus.duplicate,
        BatchRenameStatus.duplicate,
        BatchRenameStatus.unchanged,
      ]);
      expect(plan.blockedCount, 2);
      expect(plan.runnable, isFalse);
    });

    test('case-only and normalization-only duplicates count', () {
      final caseOnly = planBatchRename(
        _snapshot(_targets(['photo.JPG', 'photo.jpg'])),
        const ReplaceTextRule(find: 'photo', replacement: 'pic'),
      );
      expect(_newNames(caseOnly), ['pic.JPG', 'pic.jpg']);
      expect(_statuses(caseOnly), [
        BatchRenameStatus.duplicate,
        BatchRenameStatus.duplicate,
      ]);

      const nfd = 'cafe\u0301';
      const nfc = 'caf\u00e9';
      final normalized = planBatchRename(
        _snapshot(_targets(['${nfd}Q.txt', 'Q$nfc.txt'])),
        const ReplaceTextRule(find: 'Q', replacement: ''),
      );
      expect(_newNames(normalized), ['$nfd.txt', '$nfc.txt']);
      expect(_statuses(normalized), [
        BatchRenameStatus.duplicate,
        BatchRenameStatus.duplicate,
      ]);
    });

    test('the same new name in two folders is fine', () {
      final plan = planBatchRename(
        _snapshot([
          _target('a.txt', ordinal: 0),
          _target('a.txt', ordinal: 1, folder: '/srv/sub'),
        ]),
        addX,
      );
      expect(plan.runnable, isTrue);
    });

    test('a name that stays blocks, hidden or selected', () {
      final hidden = planBatchRename(
        _snapshot(_targets(['draft.txt']), others: ['Notes.txt', '.n.txt']),
        const ReplaceTextRule(find: 'draft', replacement: 'notes'),
      );
      expect(hidden.rows.single.status, BatchRenameStatus.exists);
      expect(hidden.rows.single.conflictName, 'Notes.txt');

      // b.txt is selected but unchanged, so its name stays taken.
      final unchanged = planBatchRename(
        _snapshot(_targets(['a.txt', 'b.txt'])),
        const ReplaceTextRule(find: 'a', replacement: 'b'),
      );
      expect(unchanged.rows.first.status, BatchRenameStatus.exists);
      expect(unchanged.rows.first.conflictName, 'b.txt');

      // A left-out name stays too.
      final leftOut = planBatchRename(
        _snapshot([_target('bad�', ordinal: -1), _target('a', ordinal: 0)]),
        const ReplaceTextRule(find: 'a', replacement: 'bad�'),
      );
      expect(leftOut.rows.last.status, BatchRenameStatus.invalidName);
    });

    test('a case-only change to its own name is allowed', () {
      final plan = planBatchRename(
        _snapshot(_targets(['readme.md'])),
        const ReplaceTextRule(find: 'readme', replacement: 'README'),
      );
      expect(plan.rows.single.status, BatchRenameStatus.rename);
    });

    test('a case-sensitive twin still blocks', () {
      final plan = planBatchRename(
        _snapshot(_targets(['a.txt']), others: ['A.txt']),
        const ReplaceTextRule(find: 'a', replacement: 'A'),
      );
      expect(plan.rows.single.status, BatchRenameStatus.exists);
      expect(plan.rows.single.conflictName, 'A.txt');
    });

    test('a chain renames in dependency order', () {
      final plan = planBatchRename(
        _snapshot(_targets(['File 1.txt', 'File 2.txt', 'File 3.txt'])),
        const FormatRule(
          name: 'File',
          placement: BatchRenamePlacement.afterName,
          startAt: 2,
        ),
      );
      expect(plan.runnable, isTrue);
      expect(_newNames(plan), ['File 2.txt', 'File 3.txt', 'File 4.txt']);
      expect(plan.rows[0].dependsOn, 1);
      expect(plan.rows[1].dependsOn, 2);
      expect(plan.rows[2].dependsOn, isNull);
      expect(plan.steps, [2, 1, 0]);
    });

    test('swaps and rotations are refused', () {
      final swap = planBatchRename(
        _snapshot(_targets(['x 2.txt', 'x 1.txt'])),
        const FormatRule(
          name: 'x',
          placement: BatchRenamePlacement.afterName,
          startAt: 1,
        ),
      );
      expect(_statuses(swap), [
        BatchRenameStatus.cycle,
        BatchRenameStatus.cycle,
      ]);
      expect(swap.steps, isEmpty);

      final rotation = planBatchRename(
        _snapshot(_targets(['n 3', 'n 1', 'n 2'])),
        const FormatRule(
          name: 'n',
          placement: BatchRenamePlacement.afterName,
          startAt: 1,
        ),
      );
      expect(
        rotation.rows.map((row) => row.status),
        everyElement(BatchRenameStatus.cycle),
      );
    });

    test('the plan does not depend on folder map order', () {
      final targets = _targets(['a.txt', 'b.txt', 'c.txt']);
      final forward = BatchRenameSnapshot(
        targets: targets,
        folderEntries: {
          _folder: [
            for (final target in targets)
              (path: target.path, name: target.name),
            (path: '$_folder/z.txt', name: 'z.txt'),
          ],
          '/other': [(path: '/other/q', name: 'q')],
        },
        remote: true,
        platform: TargetPlatform.linux,
      );
      final backward = BatchRenameSnapshot(
        targets: targets,
        folderEntries: {
          '/other': [(path: '/other/q', name: 'q')],
          _folder: [
            (path: '$_folder/z.txt', name: 'z.txt'),
            for (final target in targets.reversed)
              (path: target.path, name: target.name),
          ],
        },
        remote: true,
        platform: TargetPlatform.linux,
      );
      const rule = FormatRule(
        name: 'z',
        placement: BatchRenamePlacement.afterName,
        startAt: 1,
      );
      final a = planBatchRename(forward, rule);
      final b = planBatchRename(backward, rule);
      expect(_statuses(a), _statuses(b));
      expect(_newNames(a), _newNames(b));
      expect(a.steps, b.steps);
    });
  });

  group('executeBatchRename', () {
    late FakePaneChannel channel;

    setUp(() => channel = FakePaneChannel(_folder));

    BatchRenamePlan chainPlan() => planBatchRename(
      _snapshot(_targets(['File 1.txt', 'File 2.txt', 'File 3.txt'])),
      const FormatRule(
        name: 'File',
        placement: BatchRenamePlacement.afterName,
        startAt: 2,
      ),
    );

    Future<(BatchRenameStop, Map<int, BatchRenameOutcome>)> run(
      BatchRenamePlan plan, {
      BatchRenameStop? Function()? checkpoint,
    }) async {
      final outcomes = <int, BatchRenameOutcome>{};
      final stop = await executeBatchRename(
        channel,
        plan,
        checkpoint: checkpoint ?? () => null,
        onStart: (_) {},
        onOutcome: (row, outcome) => outcomes[row] = outcome,
      );
      return (stop, outcomes);
    }

    test('sends renames in step order and only rename rows', () async {
      final plan = planBatchRename(
        _snapshot([
          ..._targets(['File 1.txt', 'File 2.txt', 'File 3.txt']),
          _target('bad\uFFFD.md', ordinal: -1),
        ]),
        const FormatRule(
          name: 'File',
          placement: BatchRenamePlacement.afterName,
          startAt: 2,
        ),
      );
      final (stop, outcomes) = await run(plan);
      expect(stop, BatchRenameStop.completed);
      expect(channel.renameCalls, [
        ('/srv/File 3.txt', '/srv/File 4.txt'),
        ('/srv/File 2.txt', '/srv/File 3.txt'),
        ('/srv/File 1.txt', '/srv/File 2.txt'),
      ]);
      expect(outcomes.values, everyElement(isA<BatchRenameRenamed>()));
    });

    test('a refusal continues and skips the rows that depend on it', () async {
      channel.renameFailures['/srv/File 3.txt'] = const RemoteFileException(
        kind: RemoteFileErrorKind.conflict,
        operation: 'rename',
        message: 'exists',
      );
      final (stop, outcomes) = await run(chainPlan());
      expect(stop, BatchRenameStop.completed);
      expect(channel.renameCalls, [('/srv/File 3.txt', '/srv/File 4.txt')]);
      expect(outcomes[2], isA<BatchRenameFailed>());
      expect(outcomes[1], isA<BatchRenameSkippedBlocked>());
      expect((outcomes[1]! as BatchRenameSkippedBlocked).blocker, 2);
      expect(outcomes[0], isA<BatchRenameSkippedBlocked>());
    });

    test('independent rows go on after a refusal', () async {
      final plan = planBatchRename(
        _snapshot(_targets(['a.txt', 'b.txt', 'c.txt'])),
        const AddTextRule(
          text: '-x',
          placement: BatchRenamePlacement.afterName,
        ),
      );
      channel.renameFailures['/srv/b.txt'] = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'rename',
        message: 'denied',
      );
      final (stop, outcomes) = await run(plan);
      expect(stop, BatchRenameStop.completed);
      expect(channel.renameCalls, hasLength(3));
      expect(outcomes[0], isA<BatchRenameRenamed>());
      expect(outcomes[1], isA<BatchRenameFailed>());
      expect(outcomes[2], isA<BatchRenameRenamed>());
    });

    test('a lost connection stops with the outcome unknown', () async {
      final plan = planBatchRename(
        _snapshot(_targets(['a.txt', 'b.txt'])),
        const AddTextRule(
          text: '-x',
          placement: BatchRenamePlacement.afterName,
        ),
      );
      channel.renameFailures['/srv/a.txt'] = const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'rename',
        message: 'timed out',
      );
      final (stop, outcomes) = await run(plan);
      expect(stop, BatchRenameStop.connectionLost);
      expect(channel.renameCalls, hasLength(1));
      expect(outcomes[0], isA<BatchRenameUnknown>());
      expect(outcomes.containsKey(1), isFalse);
    });

    test('an unexpected error stops as a fault and is reported', () async {
      final plan = planBatchRename(
        _snapshot(_targets(['a.txt', 'b.txt'])),
        const AddTextRule(
          text: '-x',
          placement: BatchRenamePlacement.afterName,
        ),
      );
      channel.renameFailure = StateError('boom');
      final faults = <Object>[];
      final outcomes = <int, BatchRenameOutcome>{};
      final stop = await executeBatchRename(
        channel,
        plan,
        checkpoint: () => null,
        onStart: (_) {},
        onOutcome: (row, outcome) => outcomes[row] = outcome,
        onFault: (error, _) => faults.add(error),
      );
      expect(stop, BatchRenameStop.fault);
      expect(faults.single, isA<StateError>());
      expect(outcomes[0], isA<BatchRenameUnknown>());
      expect(channel.renameCalls, hasLength(1));
    });

    test('a stop during a call lets it settle, then sends nothing', () async {
      final plan = planBatchRename(
        _snapshot(_targets(['a.txt', 'b.txt'])),
        const AddTextRule(
          text: '-x',
          placement: BatchRenamePlacement.afterName,
        ),
      );
      final held = Completer<void>();
      channel.heldRename = held;
      var stopRequested = false;
      final outcomes = <int, BatchRenameOutcome>{};
      final running = executeBatchRename(
        channel,
        plan,
        checkpoint: () => stopRequested ? BatchRenameStop.stopped : null,
        onStart: (_) {},
        onOutcome: (row, outcome) => outcomes[row] = outcome,
      );
      await pumpEventQueue();
      stopRequested = true;
      held.complete();
      expect(await running, BatchRenameStop.stopped);
      expect(channel.renameCalls, hasLength(1));
      expect(outcomes[0], isA<BatchRenameRenamed>());
      expect(outcomes.containsKey(1), isFalse);
    });

    test('a pane change at a checkpoint ends the run', () async {
      final (stop, outcomes) = await run(
        chainPlan(),
        checkpoint: () => BatchRenameStop.paneChanged,
      );
      expect(stop, BatchRenameStop.paneChanged);
      expect(channel.renameCalls, isEmpty);
      expect(outcomes, isEmpty);
    });
  });
}
