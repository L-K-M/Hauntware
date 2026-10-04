import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'pane_controller_test.dart' as controller_test;

/// 02 §2.5: folders expand in place — a folder row opens its listing
/// indented below it, and actions never act twice on a row a selected
/// folder already carries.
RemoteFileEntry _file(String parent, String name) => RemoteFileEntry(
  path: '$parent/$name',
  name: name,
  type: RemoteFileType.file,
);

RemoteFileEntry _dir(String parent, String name) => RemoteFileEntry(
  path: '$parent/$name',
  name: name,
  type: RemoteFileType.directory,
);

const _home = '/home/tester';

void main() {
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  late controller_test.FakePaneLanes lanes;
  late controller_test.FakePaneChannel channel;
  late PaneController controller;

  /// ~/.cache (gh, codex-runtimes/{a,b}), ~/.docker, ~/notes.txt, and a
  /// symlink — the shape of the owner's screenshots.
  Future<void> openTree() async {
    lanes = controller_test.FakePaneLanes();
    channel = controller_test.FakePaneChannel(_home);
    channel.listings[_home] = [
      _dir(_home, '.cache'),
      _dir(_home, '.docker'),
      _file(_home, 'notes.txt'),
      RemoteFileEntry(
        path: '$_home/link',
        name: 'link',
        type: RemoteFileType.symbolicLink,
      ),
    ];
    channel.listings['$_home/.cache'] = [
      _dir('$_home/.cache', 'gh'),
      _dir('$_home/.cache', 'codex-runtimes'),
      _file('$_home/.cache', '.hidden-state'),
    ];
    channel.listings['$_home/.cache/codex-runtimes'] = [
      _file('$_home/.cache/codex-runtimes', 'a'),
      _file('$_home/.cache/codex-runtimes', 'b'),
    ];
    channel.listings['$_home/.docker'] = [_file('$_home/.docker', 'config')];
    lanes.nextLocalChannel = channel;
    controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    addTearDown(controller.dispose);
    await controller.openLocalHome();
    await settle();
    // Binding resets the lens; the screenshots show dotfiles.
    controller.showHidden = true;
  }

  List<String> rows() => [
    for (var i = 0; i < controller.entries.length; i++)
      '${'  ' * controller.rowDepth(i)}${controller.entries[i].name}',
  ];

  int rowOf(String name) =>
      controller.entries.indexWhere((entry) => entry.name == name);

  Future<void> expand(String name) async {
    expect(controller.expandAt(rowOf(name)), isTrue, reason: name);
    await settle();
  }

  List<String> selectedNames() => [
    for (final entry in controller.selectedEntries) entry.name,
  ];

  List<String> rootNames() => [
    for (final entry in controller.selectedRoots) entry.name,
  ];

  test('a folder opens in place, its rows indented under it', () async {
    await openTree();
    expect(controller.disclosureAt(rowOf('.cache')), PaneDisclosure.collapsed);
    expect(controller.disclosureAt(rowOf('notes.txt')), PaneDisclosure.none);
    // A link is not a directory from listing metadata (02 §2.3).
    expect(controller.disclosureAt(rowOf('link')), PaneDisclosure.none);

    channel.holdNext = Completer<void>();
    final hold = channel.holdNext!;
    expect(controller.expandAt(rowOf('.cache')), isTrue);
    expect(controller.disclosureAt(rowOf('.cache')), PaneDisclosure.loading);
    hold.complete();
    await settle();

    expect(controller.disclosureAt(rowOf('.cache')), PaneDisclosure.expanded);
    expect(rows(), [
      '.cache',
      '  codex-runtimes',
      '  gh',
      '  .hidden-state',
      '.docker',
      'link',
      'notes.txt',
    ]);
    expect(controller.location!.path, _home, reason: 'no navigation');

    await expand('codex-runtimes');
    expect(rows(), [
      '.cache',
      '  codex-runtimes',
      '    a',
      '    b',
      '  gh',
      '  .hidden-state',
      '.docker',
      'link',
      'notes.txt',
    ]);
  });

  test('closing a folder closes the folders inside it', () async {
    await openTree();
    await expand('.cache');
    await expand('codex-runtimes');
    expect(controller.collapseAt(rowOf('.cache')), isTrue);
    expect(rows(), ['.cache', '.docker', 'link', 'notes.txt']);

    // Reopened, the inner folder starts closed again.
    await expand('.cache');
    expect(
      controller.disclosureAt(rowOf('codex-runtimes')),
      PaneDisclosure.collapsed,
    );
  });

  test('selected rows inside a closing folder fold into it', () async {
    await openTree();
    await expand('.cache');
    controller.setCursorIndex(rowOf('.docker'));
    controller.setCursorIndex(rowOf('gh'), update: SelectionUpdate.toggle);
    expect(selectedNames(), ['gh', '.docker']);

    controller.collapseAt(rowOf('.cache'));
    expect(selectedNames(), ['.cache', '.docker']);
    expect(controller.entries[controller.cursorIndex!].name, '.cache');
    expect(controller.canUndoSelection, isTrue);
  });

  test('a folder closing over nothing selected leaves the selection', () async {
    await openTree();
    await expand('.cache');
    controller.setCursorIndex(rowOf('notes.txt'));
    controller.collapseAt(rowOf('.cache'));
    expect(selectedNames(), ['notes.txt']);
    expect(controller.entries[controller.cursorIndex!].name, 'notes.txt');
  });

  group('selectedRoots', () {
    test('drops a row whose folder is selected too', () async {
      // Screenshot 2: .docker, .cache and .cache/codex-runtimes selected.
      await openTree();
      await expand('.cache');
      controller.setCursorIndex(rowOf('.cache'));
      controller.setCursorIndex(
        rowOf('.docker'),
        update: SelectionUpdate.toggle,
      );
      controller.setCursorIndex(
        rowOf('codex-runtimes'),
        update: SelectionUpdate.toggle,
      );
      expect(selectedNames(), ['.cache', 'codex-runtimes', '.docker']);
      expect(rootNames(), ['.cache', '.docker']);
    });

    test('keeps a row whose folder is not selected', () async {
      // Screenshot 3: .docker and .cache/codex-runtimes, .cache not.
      await openTree();
      await expand('.cache');
      controller.setCursorIndex(rowOf('.docker'));
      controller.setCursorIndex(
        rowOf('codex-runtimes'),
        update: SelectionUpdate.toggle,
      );
      expect(rootNames(), ['codex-runtimes', '.docker']);
    });

    test('drops rows at any depth under a selected folder', () async {
      await openTree();
      await expand('.cache');
      await expand('codex-runtimes');
      controller.setCursorIndex(rowOf('.cache'));
      controller.setCursorIndex(rowOf('b'), update: SelectionUpdate.toggle);
      controller.setCursorIndex(rowOf('gh'), update: SelectionUpdate.toggle);
      expect(rootNames(), ['.cache']);
    });

    test('a range across depths selects the rows between', () async {
      await openTree();
      await expand('.cache');
      controller.setCursorIndex(rowOf('gh'));
      controller.setCursorIndex(
        rowOf('.docker'),
        update: SelectionUpdate.range,
      );
      expect(selectedNames(), ['gh', '.hidden-state', '.docker']);
      expect(rootNames(), ['gh', '.hidden-state', '.docker']);
    });
  });

  group('keyboard', () {
    test('→ opens a folder, then steps into it', () async {
      await openTree();
      controller.setCursorIndex(rowOf('.cache'));
      expect(controller.expandCursor(), isTrue);
      await settle();
      expect(controller.disclosureAt(rowOf('.cache')), PaneDisclosure.expanded);
      expect(controller.entries[controller.cursorIndex!].name, '.cache');

      expect(controller.expandCursor(), isTrue);
      expect(
        controller.entries[controller.cursorIndex!].name,
        'codex-runtimes',
      );
    });

    test('→ on a file does nothing', () async {
      await openTree();
      controller.setCursorIndex(rowOf('notes.txt'));
      expect(controller.expandCursor(), isFalse);
    });

    test('← steps out to the folder, then closes it', () async {
      await openTree();
      await expand('.cache');
      controller.setCursorIndex(rowOf('gh'));
      expect(controller.collapseCursor(), isTrue);
      expect(controller.entries[controller.cursorIndex!].name, '.cache');
      expect(controller.collapseCursor(), isTrue);
      expect(rows(), ['.cache', '.docker', 'link', 'notes.txt']);
      expect(controller.collapseCursor(), isFalse);
    });
  });

  group('lenses', () {
    test('hidden files inside follow the pane', () async {
      await openTree();
      await expand('.cache');
      expect(rowOf('.hidden-state'), isNonNegative);
      controller.showHidden = false;
      // .cache itself is hidden now, and its rows with it.
      expect(rows(), ['link', 'notes.txt']);
      controller.showHidden = true;
      expect(rowOf('.hidden-state'), isNonNegative, reason: 'still open');
    });

    test('the filter applies inside open folders', () async {
      await openTree();
      await expand('.cache');
      controller.setFilterQuery('c');
      expect(rows(), ['.cache', '  codex-runtimes', '.docker']);
    });

    test('sorting applies inside open folders', () async {
      await openTree();
      await expand('.cache');
      controller.setSort(FileSortKey.name, FileSortDirection.descending);
      expect(rows(), [
        '.docker',
        '.cache',
        '  gh',
        '  codex-runtimes',
        '  .hidden-state',
        'notes.txt',
        'link',
      ]);
    });
  });

  group('freshness', () {
    test('a refresh re-lists open folders', () async {
      await openTree();
      await expand('.cache');
      channel.listings['$_home/.cache'] = [_dir('$_home/.cache', 'gh')];
      controller.refresh();
      await settle();
      await settle();
      expect(rows(), ['.cache', '  gh', '.docker', 'link', 'notes.txt']);
    });

    test('a refresh closes an open folder that is gone', () async {
      await openTree();
      await expand('.cache');
      channel.listings[_home] = [_dir(_home, '.docker')];
      controller.refresh();
      await settle();
      await settle();
      expect(rows(), ['.docker']);
      channel.listings[_home] = [_dir(_home, '.docker'), _dir(_home, '.cache')];
      controller.refresh();
      await settle();
      expect(
        controller.disclosureAt(rowOf('.cache')),
        PaneDisclosure.collapsed,
      );
    });

    test('navigating elsewhere closes everything', () async {
      await openTree();
      await expand('.cache');
      controller.navigate('$_home/.docker');
      await settle();
      controller.navigate(_home);
      await settle();
      expect(rows(), ['.cache', '.docker', 'link', 'notes.txt']);
    });

    test('an Esc-cancelled navigation keeps the open folders', () async {
      await openTree();
      await expand('.cache');
      channel.holdNext = Completer<void>();
      controller.navigate('$_home/.docker');
      controller.cancelNavigation();
      expect(rows(), [
        '.cache',
        '  codex-runtimes',
        '  gh',
        '  .hidden-state',
        '.docker',
        'link',
        'notes.txt',
      ]);
      channel.holdNext!.complete();
      await settle();
      // The cancelled navigation's late answer is dropped.
      expect(controller.location!.path, _home);
      expect(controller.disclosureAt(rowOf('.cache')), PaneDisclosure.expanded);
    });

    test('a listing that answers after its folder closed is dropped', () async {
      await openTree();
      channel.holdNext = Completer<void>();
      final hold = channel.holdNext!;
      controller.expandAt(rowOf('.cache'));
      controller.collapseAt(rowOf('.cache'));
      hold.complete();
      await settle();
      expect(rows(), ['.cache', '.docker', 'link', 'notes.txt']);
    });

    test('a row renamed inside an open folder stays selected', () async {
      await openTree();
      await expand('.cache');
      controller.setCursorIndex(rowOf('gh'));
      controller.startRename();
      channel.listings['$_home/.cache'] = [
        _dir('$_home/.cache', 'codex-runtimes'),
        _dir('$_home/.cache', 'github'),
        _file('$_home/.cache', '.hidden-state'),
      ];
      await controller.submitRename('github');
      await settle();
      await settle();
      expect(controller.entries[controller.cursorIndex!].name, 'github');
      expect(controller.rowDepth(controller.cursorIndex!), 1);
      expect(selectedNames(), ['github']);
    });

    test(
      'a failed re-list folds the rows picked inside into the folder',
      () async {
        await openTree();
        await expand('.cache');
        controller.setCursorIndex(rowOf('.docker'));
        controller.setCursorIndex(rowOf('gh'), update: SelectionUpdate.toggle);
        channel.listingFailures['$_home/.cache'] = const RemoteFileException(
          kind: RemoteFileErrorKind.permissionDenied,
          operation: 'list',
          path: '$_home/.cache',
          message: 'Permission denied',
        );
        controller.refresh();
        await settle();
        await settle();
        expect(rows(), ['.cache', '.docker', 'link', 'notes.txt']);
        expect(selectedNames(), ['.cache', '.docker']);
        expect(controller.entries[controller.cursorIndex!].name, '.cache');
        // A refresh's re-list closes quietly: no notice.
        expect(controller.notice, isNull);
      },
    );

    test('a folder that cannot be listed closes with a notice', () async {
      await openTree();
      channel.listingFailures['$_home/.cache'] = const RemoteFileException(
        kind: RemoteFileErrorKind.permissionDenied,
        operation: 'list',
        path: '$_home/.cache',
        message: 'Permission denied',
      );
      await expand('.cache');
      expect(
        controller.disclosureAt(rowOf('.cache')),
        PaneDisclosure.collapsed,
      );
      expect(controller.notice, PaneNotice.expandFailed);
      expect(controller.expansionFailure?.name, '.cache');
    });
  });
}
