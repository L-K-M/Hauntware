import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/app_settings.dart';
import 'package:planchette_app/services/document_windows.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/save_siblings.dart';
import 'package:planchette_app/services/session_journal.dart';
import 'package:planchette_app/services/session_state.dart';
import 'package:planchette_editor/planchette_editor.dart';

import 'document_windows_test.dart' show FakeWindowHost;
import 'document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments, document, testPath;
import 'memory_settings.dart';

const _short = Duration(milliseconds: 20);

Future<void> _settle() => Future<void>.delayed(_short * 3);

/// Polls [condition] until it holds: an atomic replace syncs to disk, which
/// takes as long as the file system wants.
Future<void> _until(Future<bool> Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await condition()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out');
    await Future<void>.delayed(_short);
  }
}

final class _Siblings implements SaveSiblings {
  final found = <String, List<SaveSibling>>{};

  @override
  Future<List<SaveSibling>> find(String documentPath) async =>
      found[documentPath] ?? const [];

  @override
  Future<void> delete(String documentPath, SaveSibling sibling) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory temp;
  late MemoryDocuments store;
  late FakeDialogs dialogs;
  final workspaces = <DocumentWorkspace>[];

  DocumentWorkspace newWorkspace({SaveSiblings? siblings}) {
    final workspace = DocumentWorkspace(
      store: store,
      dialogs: dialogs,
      saveSiblings: siblings,
    );
    workspaces.add(workspace);
    return workspace;
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('planchette-journal-');
    store = MemoryDocuments();
    dialogs = FakeDialogs();
  });

  tearDown(() async {
    for (final workspace in workspaces) {
      workspace.dispose();
    }
    workspaces.clear();
    await temp.delete(recursive: true);
  });

  group('session state', () {
    test('round-trips through JSON', () {
      final window = SessionWindow(
        tabs: [
          SessionTab(
            path: testPath('a.txt'),
            text: 'edited',
            baselineSha256: 'abc',
            metadata: const TextDocumentMetadata(
              lineEnding: LineEnding.crlf,
              utf8Bom: Utf8Bom.present,
            ),
            line: 3,
            column: 4,
          ),
          const SessionTab(untitledName: 'Untitled 2', text: 'draft'),
        ],
        active: 1,
      );
      final read = SessionWindow.fromJson(
        jsonDecode(jsonEncode(window.toJson())),
      )!;
      expect(read.active, 1);
      expect(read.tabs, hasLength(2));
      final file = read.tabs.first;
      expect(file.path, testPath('a.txt'));
      expect(file.text, 'edited');
      expect(file.baselineSha256, 'abc');
      expect(file.metadata.lineEnding, LineEnding.crlf);
      expect(file.metadata.utf8Bom, Utf8Bom.present);
      expect((file.line, file.column), (3, 4));
      expect(read.tabs.last.untitledName, 'Untitled 2');
      expect(read.tabs.last.text, 'draft');
    });

    test('skips entries it cannot use and refuses other versions', () {
      final read = SessionWindow.fromJson({
        'version': SessionWindow.version,
        'tabs': [
          {'path': testPath('a.txt'), 'untitledName': 'both'},
          {'text': 'neither'},
          'not a tab',
          {'untitledName': 'Untitled', 'text': 'kept', 'line': -2},
        ],
        'active': 7,
      })!;
      expect(read.tabs.single.untitledName, 'Untitled');
      expect(read.tabs.single.line, 1);
      expect(read.active, isNull);
      expect(SessionWindow.fromJson({'version': 99, 'tabs': []}), isNull);
      expect(SessionWindow.fromJson('garbage'), isNull);
    });

    test('the active tab survives a skipped tab before it', () {
      final read = SessionWindow.fromJson({
        'version': SessionWindow.version,
        'tabs': [
          'not a tab',
          {'untitledName': 'A', 'text': 'a'},
          {'untitledName': 'B', 'text': 'b'},
        ],
        'active': 2,
      })!;
      expect(read.tabs[read.active!].untitledName, 'B');
    });
  });

  group('workspace snapshot and restore', () {
    test('keeps unsaved text only, and skips an untouched page', () async {
      final workspace = newWorkspace();
      workspace.newDocument();
      store.files[testPath('clean.txt')] = document('clean.txt', 'disk');
      store.files[testPath('dirty.txt')] = document('dirty.txt', 'disk');
      await workspace.open(testPath('clean.txt'));
      await workspace.open(testPath('dirty.txt'));
      workspace.active!.editor.text.text = 'edited';
      final draft = workspace.newDocument()!;
      draft.editor.text.text = 'draft';

      final snapshot = workspace.sessionSnapshot();
      expect(snapshot.tabs, hasLength(3));
      final [clean, dirty, untitled] = snapshot.tabs;
      expect(clean.path, testPath('clean.txt'));
      expect(clean.text, isNull);
      expect(dirty.text, 'edited');
      expect(dirty.baselineSha256, 'baseline');
      expect(untitled.untitledName, draft.untitledName);
      expect(untitled.text, 'draft');
      expect(snapshot.active, 2);
    });

    test('restores files, unsaved edits and untitled buffers', () async {
      store.files[testPath('clean.txt')] = document('clean.txt', 'disk');
      store.files[testPath('dirty.txt')] = document('dirty.txt', 'disk');
      final workspace = newWorkspace();
      await workspace.restoreSession(
        SessionWindow(
          tabs: [
            SessionTab(path: testPath('clean.txt'), line: 1, column: 3),
            SessionTab(
              path: testPath('dirty.txt'),
              text: 'edited',
              baselineSha256: 'baseline',
            ),
            const SessionTab(untitledName: 'Untitled', text: 'draft'),
          ],
          active: 1,
        ),
      );

      final [clean, dirty, untitled] = workspace.documents;
      expect(clean.editor.isDirty, isFalse);
      expect(clean.editor.text.text, 'disk');
      expect(dirty.editor.text.text, 'edited');
      expect(dirty.editor.isDirty, isTrue);
      expect(untitled.path, isNull);
      expect(untitled.editor.text.text, 'draft');
      expect(workspace.active, same(dirty));
      expect(workspace.error, isNull);
      // Nothing was written: a restored edit waits for its own save.
      expect(store.writes, isEmpty);
    });

    test(
      'says when a file changed on disk since its edits were kept',
      () async {
        store.files[testPath('a.txt')] = document(
          'a.txt',
          'new',
          digest: 'new',
        );
        final workspace = newWorkspace();
        await workspace.restoreSession(
          SessionWindow(
            tabs: [
              SessionTab(
                path: testPath('a.txt'),
                text: 'mine',
                baselineSha256: 'old',
              ),
            ],
          ),
        );
        expect(workspace.documents.single.editor.text.text, 'mine');
        expect(workspace.error, contains('a.txt changed on disk'));
      },
    );

    test('a missing file gives its text to an untitled tab and offers the '
        'copies an interrupted save left beside it', () async {
      final siblings = _Siblings()
        ..found[testPath('gone.txt')] = [
          (
            path: testPath('gone.txt.planchette-x.backup'),
            stamp: (modified: DateTime.utc(2026), size: 4),
          ),
        ];
      final workspace = newWorkspace(siblings: siblings);
      await workspace.restoreSession(
        SessionWindow(
          tabs: [
            SessionTab(
              path: testPath('gone.txt'),
              text: 'lost?',
              baselineSha256: 'baseline',
            ),
            SessionTab(path: testPath('clean-gone.txt')),
          ],
        ),
      );
      await _settle();

      final tab = workspace.documents.single;
      expect(tab.path, isNull);
      expect(tab.name, 'gone.txt');
      expect(tab.editor.text.text, 'lost?');
      expect(workspace.error, contains('gone.txt could not be reopened'));
      expect(workspace.error, contains('clean-gone.txt could not be'));
      expect(dialogs.siblingsAsked.single.$1, 'gone.txt');
    });

    test('an untitled buffer is kept once it has text', () async {
      final workspace = newWorkspace();
      final draft = workspace.newDocument()!;
      expect(workspace.sessionSnapshot().tabs, isEmpty);
      draft.editor.text.text = 'x';
      expect(workspace.sessionSnapshot().tabs.single.text, 'x');
    });
  });

  group('quitting', () {
    test(
      'keeps unsaved documents without asking when the journal has them',
      () async {
        final workspace = newWorkspace();
        final tab = workspace.newDocument()!;
        tab.editor.text.text = 'unsaved';
        var kept = 0;
        workspace.keepUnsavedOnQuit = () async {
          kept++;
          return true;
        };
        expect(await workspace.confirmQuit(), isTrue);
        expect(kept, 1);
        expect(dialogs.asked, isEmpty);
        expect(workspace.documents.single.editor.text.text, 'unsaved');
      },
    );

    test('asks when the journal could not be written', () async {
      final workspace = newWorkspace();
      workspace.newDocument()!.editor.text.text = 'unsaved';
      workspace.keepUnsavedOnQuit = () async => false;
      expect(await workspace.confirmQuit(), isFalse);
      expect(dialogs.asked, hasLength(1));
    });

    test('closing one window still asks', () async {
      final workspace = newWorkspace();
      workspace.newDocument()!.editor.text.text = 'unsaved';
      var kept = 0;
      workspace.keepUnsavedOnQuit = () async {
        kept++;
        return true;
      };
      expect(await workspace.confirmQuit(scope: QuitScope.window), isFalse);
      expect(kept, 0);
      expect(dialogs.asked, hasLength(1));
    });
  });

  group('journal store', () {
    test('writes owner-only files in an owner-only folder', () async {
      final journal = SessionJournalStore(
        Directory(paths.join(temp.path, 'session')),
      );
      expect(await journal.acquire(), isTrue);
      addTearDown(journal.release);
      await journal.write(
        'a1b2c3d4e5f60718',
        const SessionWindow(
          tabs: [SessionTab(untitledName: 'U', text: 't')],
        ),
      );
      final kept = await journal.readAll();
      expect(kept.single.id, 'a1b2c3d4e5f60718');
      expect(kept.single.window.tabs.single.text, 't');
      if (!Platform.isWindows) {
        final folder = journal.directory.statSync().mode & 0x1ff;
        final file =
            File(
              paths.join(
                journal.directory.path,
                'window-a1b2c3d4e5f60718.json',
              ),
            ).statSync().mode &
            0x1ff;
        expect(folder.toRadixString(8), '700');
        expect(file.toRadixString(8), '600');
      }
      await journal.delete('a1b2c3d4e5f60718');
      expect(await journal.readAll(), isEmpty);
    });

    test('ignores files it did not write and unreadable ones', () async {
      final journal = SessionJournalStore(temp);
      File(paths.join(temp.path, 'notes.json')).writeAsStringSync('{}');
      File(
        paths.join(temp.path, 'window-0000000000000000.json'),
      ).writeAsStringSync('{');
      expect(await journal.readAll(), isEmpty);
      await journal.clear();
      // Only the journal's own names go.
      expect(File(paths.join(temp.path, 'notes.json')).existsSync(), isTrue);
    });

    test('a journal another process holds is not taken over', () async {
      final lock = File(paths.join(temp.path, '.lock'))..createSync();
      // Python's lockf takes the same POSIX record lock Dart's does.
      final holder = await Process.start('python3', [
        '-c',
        'import fcntl,sys;f=open(sys.argv[1],"a");'
            'fcntl.lockf(f,fcntl.LOCK_EX);print("held",flush=True);'
            'sys.stdin.read()',
        lock.path,
      ]);
      addTearDown(holder.kill);
      await holder.stdout
          .transform(utf8.decoder)
          .firstWhere((line) => line.contains('held'));
      expect(await SessionJournalStore(temp).acquire(), isFalse);
      await holder.stdin.close();
      await holder.exitCode;
      final store = SessionJournalStore(temp);
      expect(await store.acquire(), isTrue);
      store.release();
    }, skip: Platform.isWindows ? 'POSIX record locks only' : false);

    test('a disposed journal lets the journal go', () async {
      final journal = SessionJournal(
        store: SessionJournalStore(temp),
        settings: testSettings(),
      );
      await journal.open();
      journal.dispose();
      // Another process can take the lock only once this one closed it.
      final probe = await Process.run('python3', [
        '-c',
        'import fcntl,sys;f=open(sys.argv[1],"a");'
            'fcntl.lockf(f,fcntl.LOCK_EX|fcntl.LOCK_NB);print("taken")',
        paths.join(temp.path, '.lock'),
      ]);
      expect(probe.stdout, contains('taken'), reason: '${probe.stderr}');
    }, skip: Platform.isWindows ? 'POSIX record locks only' : false);
  });

  group('workspace journal', () {
    late SessionJournalStore journalStore;
    setUp(() async {
      journalStore = SessionJournalStore(temp);
      await journalStore.acquire();
      addTearDown(journalStore.release);
    });

    Future<SessionWindow?> onDisk(String id) async {
      for (final kept in await journalStore.readAll()) {
        if (kept.id == id) return kept.window;
      }
      return null;
    }

    test('writes typing after a pause and closes at once', () async {
      final workspace = newWorkspace();
      final journal = WorkspaceJournal(
        workspace: workspace,
        store: journalStore,
        id: '1111111111111111',
        delay: _short,
      )..start();
      addTearDown(journal.stop);
      final tab = workspace.newDocument()!;
      Future<String?> keptText() async =>
          (await onDisk('1111111111111111'))?.tabs.singleOrNull?.text;
      tab.editor.text.text = 'a';
      await _until(() async => await keptText() == 'a');

      tab.editor.text.text = 'ab';
      await _until(() async => await keptText() == 'ab');

      // Don't Save: the discarded text leaves the disk with the tab.
      dialogs.choices.add(CloseChoice.discard);
      expect(await workspace.closeTab(tab), isTrue);
      await _until(
        () async => (await onDisk('1111111111111111'))?.tabs.isEmpty ?? false,
      );
    });

    test('a save drops the kept text', () async {
      store.files[testPath('a.txt')] = document('a.txt', 'disk');
      final workspace = newWorkspace();
      final journal = WorkspaceJournal(
        workspace: workspace,
        store: journalStore,
        id: '2222222222222222',
        delay: _short,
      )..start();
      addTearDown(journal.stop);
      await workspace.open(testPath('a.txt'));
      workspace.active!.editor.text.text = 'edited';
      expect(await journal.flush(), isTrue);
      expect((await onDisk('2222222222222222'))!.tabs.single.text, 'edited');

      expect(await workspace.save(workspace.active!), isTrue);
      await _until(
        () async =>
            (await onDisk('2222222222222222'))?.tabs.single.text == null,
      );
      final kept = (await onDisk('2222222222222222'))!.tabs.single;
      expect(kept.path, testPath('a.txt'));
    });

    test('a failed write makes the quit ask', () async {
      final blocked = File(paths.join(temp.path, 'blocked'))
        ..writeAsStringSync('not a folder');
      final workspace = newWorkspace();
      final errors = <Object>[];
      final journal = WorkspaceJournal(
        workspace: workspace,
        store: SessionJournalStore(Directory(blocked.path)),
        id: '3333333333333333',
        delay: _short,
        onError: errors.add,
      )..start();
      addTearDown(journal.stop);
      workspace.newDocument()!.editor.text.text = 'unsaved';
      expect(await workspace.confirmQuit(), isFalse);
      expect(dialogs.asked, hasLength(1));
      expect(errors, hasLength(1));
    });
  });

  group('session journal', () {
    late SettingsController settings;
    setUp(() async {
      settings = testSettings();
    });

    SessionJournal makeJournal() {
      final journal = SessionJournal(
        store: SessionJournalStore(temp),
        settings: settings,
        delay: _short,
      );
      addTearDown(journal.dispose);
      return journal;
    }

    Future<void> keep(String id, SessionWindow window) =>
        SessionJournalStore(temp).write(id, window);

    test('turning hot exit off deletes what was kept', () async {
      await keep(
        '4444444444444444',
        const SessionWindow(
          tabs: [SessionTab(untitledName: 'U', text: 't')],
        ),
      );
      await settings.update(
        settings.value.copyWith(unsavedOnQuit: UnsavedOnQuit.ask),
      );
      final journal = makeJournal();
      expect(await journal.open(), isEmpty);
      expect(journal.isEnabled, isFalse);
      expect(await SessionJournalStore(temp).readAll(), isEmpty);
    });

    test('the setting starts and stops the journal while running', () async {
      final journal = makeJournal();
      expect(await journal.open(), isEmpty);
      final workspace = newWorkspace();
      journal.attach(workspace);
      workspace.newDocument()!.editor.text.text = 'kept';
      await journal.flushAll();
      expect(await SessionJournalStore(temp).readAll(), hasLength(1));

      await settings.update(
        settings.value.copyWith(unsavedOnQuit: UnsavedOnQuit.ask),
      );
      await _until(
        () async => (await SessionJournalStore(temp).readAll()).isEmpty,
      );
      expect(workspace.keepUnsavedOnQuit, isNull);

      await settings.update(
        settings.value.copyWith(unsavedOnQuit: UnsavedOnQuit.keep),
      );
      expect(workspace.keepUnsavedOnQuit, isNotNull);
      await _until(
        () async => (await SessionJournalStore(temp).readAll()).length == 1,
      );
    });

    test(
      'restores every window, keeps them, and forgets a closed one',
      () async {
        await keep(
          '5555555555555555',
          const SessionWindow(
            tabs: [SessionTab(untitledName: 'First', text: 'one')],
          ),
        );
        // The second window was kept later.
        await Future<void>.delayed(const Duration(milliseconds: 10));
        await keep(
          '6666666666666666',
          const SessionWindow(
            tabs: [SessionTab(untitledName: 'Second', text: 'two')],
          ),
        );
        await keep('7777777777777777', const SessionWindow());

        final host = FakeWindowHost();
        final windows = DocumentWindows(
          host: host,
          workspaceFactory: (_) =>
              DocumentWorkspace(store: store, dialogs: dialogs),
          quitApplication: () async {},
          afterFrame: () async {},
          mainTitle: (_) {},
          onError: (_, _) {},
        );
        addTearDown(windows.dispose);
        await windows.start();

        final journal = makeJournal();
        final kept = await journal.open();
        expect(kept, hasLength(3));
        await journal.restoreInto(windows, kept);

        expect(windows.windows, hasLength(2));
        final [main, extra] = windows.windows;
        expect(main.workspace.documents.single.editor.text.text, 'one');
        expect(extra.workspace.documents.single.editor.text.text, 'two');
        final ids = {
          for (final window in await SessionJournalStore(temp).readAll())
            window.id,
        };
        // The empty window's file went; the others continue in place.
        expect(ids, {'5555555555555555', '6666666666666666'});

        // Closing the extra window asks about its document, then forgets it.
        dialogs.choices.add(CloseChoice.discard);
        await extra.close();
        expect(dialogs.asked, ['Second']);
        await _until(
          () async =>
              (await SessionJournalStore(temp).readAll()).single.id ==
              '5555555555555555',
        );
      },
    );

    test('a frozen journal keeps the files through the teardown', () async {
      final journal = makeJournal();
      await journal.open();
      final workspace = newWorkspace();
      journal.attach(workspace);
      workspace.newDocument()!.editor.text.text = 'kept';
      expect(await workspace.confirmQuit(), isTrue);
      journal.freeze();
      await journal.detach(workspace);
      final kept = await SessionJournalStore(temp).readAll();
      expect(kept.single.window.tabs.single.text, 'kept');

      // A failed quit resumes journaling.
      journal.thaw();
      expect(workspace.keepUnsavedOnQuit, isNotNull);
      await journal.flushAll();
    });

    test('restores into the one workspace a phone has', () async {
      await keep(
        '8888888888888888',
        const SessionWindow(
          tabs: [SessionTab(untitledName: 'A', text: 'a')],
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await keep(
        '9999999999999999',
        const SessionWindow(
          tabs: [SessionTab(untitledName: 'B', text: 'b')],
        ),
      );
      final journal = makeJournal();
      final workspace = newWorkspace();
      await journal.restoreWorkspace(workspace, await journal.open());
      expect(
        [for (final tab in workspace.documents) tab.editor.text.text],
        ['a', 'b'],
      );
      final kept = await SessionJournalStore(temp).readAll();
      expect(kept.single.id, '8888888888888888');
      expect(kept.single.window.tabs, hasLength(2));
    });

    test('a write queued before a window closes cannot bring its file '
        'back', () async {
      await keep(
        'aaaaaaaaaaaaaaaa',
        const SessionWindow(
          tabs: [SessionTab(untitledName: 'A', text: 'a')],
        ),
      );
      final journal = makeJournal();
      final workspace = newWorkspace();
      await journal.restoreWorkspace(workspace, await journal.open());
      workspace.documents.single.editor.text.text = 'changed';
      final pending = journal.flushAll();
      await journal.detach(workspace);
      await pending;
      await _settle();
      expect(await SessionJournalStore(temp).readAll(), isEmpty);
    });
  });

  test('the setting round-trips and defaults to keeping', () {
    expect(const AppSettings().unsavedOnQuit, UnsavedOnQuit.keep);
    expect(const AppSettings().toJson(), isNot(contains('unsavedOnQuit')));
    const ask = AppSettings(unsavedOnQuit: UnsavedOnQuit.ask);
    expect(AppSettings.fromJson(ask.toJson()), ask);
    expect(
      AppSettings.fromJson({'unsavedOnQuit': 'bogus'}).unsavedOnQuit,
      UnsavedOnQuit.keep,
    );
  });
}
