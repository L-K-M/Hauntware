import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/document_windows.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/window_host.dart';

import 'document_workspace_test.dart'
    show FakeDialogs, MemoryDocuments, document, testPath;

/// A runner host that records what Dart asks of it and hands out view ids
/// the way the engines do: the main window is 0, extra windows count up.
final class FakeWindowHost implements WindowHost {
  bool available = true;
  int nextViewId = 1;
  Object? createError;
  Object? destroyError;
  Completer<void>? createGate;

  final calls = <String>[];
  final titles = <int, String>{};
  WindowHostListener? currentListener;
  final fullScreen = <int, bool>{};

  @override
  set listener(WindowHostListener? listener) => currentListener = listener;

  @override
  Future<bool> isAvailable() async => available;

  @override
  Future<int> create({String? title}) async {
    await createGate?.future;
    final error = createError;
    if (error != null) throw error;
    final viewId = nextViewId++;
    calls.add('create $viewId');
    if (title != null) titles[viewId] = title;
    return viewId;
  }

  @override
  Future<void> destroy(int viewId) async {
    final error = destroyError;
    if (error != null) throw error;
    calls.add('destroy $viewId');
  }

  @override
  Future<void> activate(int viewId) async => calls.add('activate $viewId');

  @override
  Future<void> hide(int viewId) async => calls.add('hide $viewId');

  @override
  Future<void> setTitle(int viewId, String title) async {
    titles[viewId] = title;
    calls.add('title $viewId');
  }

  @override
  Future<bool> isFullScreen(int viewId) async => fullScreen[viewId] ?? false;

  @override
  Future<void> setFullScreen(int viewId, {required bool fullScreen}) async {
    calls.add('fullScreen $viewId $fullScreen');
    this.fullScreen[viewId] = fullScreen;
  }

  List<String> openAnswer = const [];
  String? saveAnswer;

  @override
  Future<List<String>> pickOpenFiles(int viewId) async => openAnswer;

  @override
  Future<String?> pickSavePath(
    int viewId, {
    required String suggestedName,
    String? initialDirectory,
  }) async => saveAnswer;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeWindowHost host;
  late int quits;
  late List<Object> errors;
  late MemoryDocuments store;
  late Map<DocumentWindow, FakeDialogs> dialogs;
  late List<String> mainTitles;
  late DocumentWindows windows;

  DocumentWorkspace buildWorkspace(DocumentWindow window) {
    return DocumentWorkspace(
      store: store,
      dialogs: dialogs[window] = FakeDialogs(),
    );
  }

  DocumentWindows makeRegistry({Future<void> Function()? afterFrame}) =>
      DocumentWindows(
        host: host,
        workspaceFactory: buildWorkspace,
        quitApplication: () async => quits++,
        afterFrame: afterFrame ?? () async {},
        mainTitle: mainTitles.add,
        onError: (error, _) => errors.add(error),
      );

  setUp(() {
    host = FakeWindowHost();
    quits = 0;
    errors = [];
    store = MemoryDocuments();
    dialogs = {};
    mainTitles = [];
    windows = makeRegistry();
  });

  tearDown(() => windows.dispose());

  test('start records the main window, open and active', () async {
    await windows.start();

    expect(windows.windows, hasLength(1));
    final main = windows.windows.single;
    expect(main.isMain, isTrue);
    expect(main.viewId, mainWindowViewId);
    expect(main.isLaunchWindow, isTrue);
    expect(windows.activeWindow, same(main));
    expect(windows.canOpenWindows, isTrue);
    expect(host.currentListener, same(windows));
  });

  test('a runner without the host keeps the app at one window', () async {
    host.available = false;
    await windows.start();

    await windows.openWindow();

    expect(windows.canOpenWindows, isFalse);
    expect(windows.windows, hasLength(1));
    expect(host.calls, isEmpty);
  });

  test('New Window opens an extra window, which becomes active', () async {
    await windows.start();
    var notified = 0;
    windows.addListener(() => notified++);

    await windows.openWindow();

    expect(host.calls, contains('create 1'));
    expect(windows.windows, hasLength(2));
    final extra = windows.windows.last;
    expect(extra.kind, DocumentWindowKind.extra);
    expect(extra.viewId, 1);
    expect(extra.isLaunchWindow, isFalse);
    expect(windows.activeWindow, same(extra));
    expect(extra.isActive, isTrue);
    expect(windows.windows.first.isActive, isFalse);
    expect(notified, greaterThan(0));
  });

  test('a window the runner could not create is reported, not added', () async {
    await windows.start();
    host.createError = const WindowHostException('no');

    await windows.openWindow();

    expect(windows.windows, hasLength(1));
    expect(errors, [isA<WindowHostException>()]);
    expect(
      windows.activeWindow!.workspace.error,
      contains('Could not open a window'),
    );
  });

  test('closing an extra window destroys it once its frame has gone and '
      'activates the one worked in before', () async {
    final frame = Completer<void>();
    windows.dispose();
    windows = makeRegistry(afterFrame: () => frame.future);
    await windows.start();
    await windows.openWindow();
    final extra = windows.windows.last;

    final closing = windows.closeWindow(extra);
    await pumpEventQueue();

    // Out of the list at once, so the root drops its subtree this frame;
    // the view goes only after that frame.
    expect(windows.windows, hasLength(1));
    expect(host.calls, isNot(contains('destroy 1')));

    frame.complete();
    await closing;

    expect(host.calls, containsAllInOrder(['destroy 1', 'activate 0']));
    expect(windows.activeWindow!.isMain, isTrue);
    expect(quits, 0);
  });

  test('closing the last open window quits instead', () async {
    await windows.start();

    await windows.closeWindow(windows.windows.single);

    expect(quits, 1);
    expect(windows.windows, hasLength(1));
    expect(host.calls, isEmpty);
  });

  test('the close button on the main window hides it while another window '
      'is open, and leaves the quit to the caller otherwise', () async {
    await windows.start();
    expect(await windows.closeMainWindowInstead(), isFalse);
    expect(host.calls, isEmpty);

    await windows.openWindow();
    expect(await windows.closeMainWindowInstead(), isTrue);

    expect(host.calls, containsAllInOrder(['hide 0', 'activate 1']));
    expect(windows.windowForView(mainWindowViewId), isNull);
    expect(windows.windows.single.viewId, 1);
    expect(quits, 0);
  });

  test("the main window's close button decides after a close already under "
      'way, so the last window leaves the quit to the caller', () async {
    final frame = Completer<void>();
    final registry = makeRegistry(afterFrame: () => frame.future);
    windows.dispose();
    windows = registry;
    await registry.start();
    await registry.openWindow();

    final closingExtra = registry.closeWindow(registry.windows.last);
    final closedInstead = registry.closeMainWindowInstead();
    frame.complete();
    await closingExtra;

    // By its turn the main window is the only one open: the caller's
    // quit path takes it, and the registry does not quit a second time.
    expect(await closedInstead, isFalse);
    expect(quits, 0);
    expect(registry.windows.single.isMain, isTrue);
  });

  test('a close interrupted by disposal leaves the runner alone', () async {
    final frame = Completer<void>();
    final registry = makeRegistry(afterFrame: () => frame.future);
    await registry.start();
    await registry.openWindow();
    host.calls.clear();

    final closing = registry.closeWindow(registry.windows.last);
    await pumpEventQueue();
    registry.dispose();
    frame.complete();
    await closing;

    expect(host.calls, isEmpty);
  });

  test('New Window shows a hidden main window again, fresh, before asking '
      'the runner for another', () async {
    await windows.start();
    final launched = windows.windows.single;
    launched.workspace.newDocument();
    await windows.openWindow();
    await windows.closeWindow(launched);
    host.calls.clear();

    await windows.openWindow();

    expect(host.calls, ['activate 0']);
    final main = windows.windowForView(mainWindowViewId)!;
    expect(main, isNot(same(launched)));
    expect(main.serial, isNot(launched.serial));
    expect(main.isLaunchWindow, isFalse);
    // A fresh workspace: the documents the closed window held are gone.
    expect(main.workspace, isNot(same(launched.workspace)));
    expect(main.workspace.documents, isEmpty);
    expect(windows.activeWindow, same(main));
    // Opening order: the extra window came first this time.
    expect(windows.windows.map((window) => window.viewId), [1, 0]);
  });

  test('opens are serialized, so two quick New Windows cannot both reuse '
      'the hidden main window', () async {
    await windows.start();
    await windows.openWindow();
    await windows.closeWindow(windows.windowForView(mainWindowViewId)!);
    host.calls.clear();

    await Future.wait([windows.openWindow(), windows.openWindow()]);

    expect(host.calls, containsAllInOrder(['activate 0', 'create 2']));
    expect(windows.windows, hasLength(3));
  });

  test(
    'a view created across a quit is destroyed before it can open',
    () async {
      await windows.start();
      host.createGate = Completer<void>();
      final opening = windows.openWindow();
      await pumpEventQueue();

      // A quit that completes while the runner is still creating the view.
      final quit = windows.confirmAllClose();
      host.createGate!.complete();
      await opening;
      expect(await quit, isTrue);

      expect(windows.windows, hasLength(1));
      // The review activated the window it asked; the late view was made
      // and then destroyed before it could open.
      expect(host.calls, ['activate 0', 'create 1', 'destroy 1']);
    },
  );

  test(
    "the runner's reports move the active window and close windows",
    () async {
      await windows.start();
      await windows.openWindow();
      final main = windows.windowForView(mainWindowViewId)!;

      windows.onWindowActivated(mainWindowViewId);
      expect(windows.activeWindow, same(main));

      // Unknown and stale view ids are explicit no-ops.
      windows.onWindowActivated(42);
      expect(windows.activeWindow, same(main));
      windows.onWindowCloseRequested(42);
      await pumpEventQueue();
      expect(windows.windows, hasLength(2));

      windows.onWindowCloseRequested(1);
      await pumpEventQueue();
      expect(host.calls, contains('destroy 1'));
      expect(windows.windows, [main]);
    },
  );

  test('a declined close keeps the window and its documents', () async {
    await windows.start();
    await windows.openWindow();
    final extra = windows.windows.last;
    extra.workspace.newDocument()!.editor.text.text = 'unsaved';
    // The fake's empty queue answers Cancel.
    await windows.closeWindow(extra);

    expect(windows.windows, hasLength(2));
    expect(host.calls, isNot(contains('destroy 1')));
    expect(extra.workspace.documents, hasLength(1));
    expect(quits, 0);
  });

  test('quit reviews every window, and a later cancel closes none', () async {
    await windows.start();
    await windows.openWindow();
    final main = windows.windows.first;
    final extra = windows.windows.last;
    extra.workspace.newDocument()!.editor.text.text = 'unsaved';
    dialogs[extra]!.choices.add(CloseChoice.cancel);
    host.calls.clear();

    expect(await windows.confirmAllClose(), isFalse);

    // Both stay open and neither is left locked out of its own close;
    // the review raised each window while it asked it.
    expect(windows.windows, hasLength(2));
    expect(main.workspace.interactionLocked, isFalse);
    expect(extra.workspace.interactionLocked, isFalse);
    expect(host.calls, ['activate 0', 'activate 1']);
    expect(quits, 0);
  });

  test('a granted quit locks the windows until teardown; a failed one '
      'unlocks them and says why', () async {
    await windows.start();
    await windows.openWindow();
    final extra = windows.windows.last;

    expect(await windows.confirmAllClose(), isTrue);
    expect(extra.workspace.interactionLocked, isTrue);

    windows.quitFailed(StateError('destroy failed'));
    expect(extra.workspace.interactionLocked, isFalse);
    expect(extra.workspace.error, contains('Could not close Planchette'));

    // After the failure the app can still quit.
    expect(await windows.confirmAllClose(), isTrue);
  });

  test('a failed native destroy restores the window unlocked', () async {
    await windows.start();
    await windows.openWindow();
    final extra = windows.windows.last;
    host.destroyError = StateError('gone wrong');

    await windows.closeWindow(extra);
    await pumpEventQueue();

    expect(windows.windows, contains(extra));
    expect(extra.workspace.interactionLocked, isFalse);
    expect(extra.workspace.error, contains('Could not close the window'));
    expect(errors, isNotEmpty);
    expect(windows.activeWindow, same(extra));

    // The close stays retryable.
    host.destroyError = null;
    await windows.closeWindow(extra);
    await pumpEventQueue();
    expect(windows.windows, isNot(contains(extra)));
    expect(host.calls, contains('destroy 1'));
  });

  test('window titles follow their workspace; the main one goes to '
      'window_manager', () async {
    await windows.start();
    await windows.openWindow();
    final extra = windows.windows.last;

    extra.workspace.newDocument();

    expect(host.titles[1], contains('— Planchette'));
    // The main window's title went to its own setter, never the host.
    expect(mainTitles, isNotEmpty);
    expect(host.titles.containsKey(mainWindowViewId), isFalse);
  });

  test('a file open lands in the active window', () async {
    await windows.start();
    store.files[testPath('one.txt')] = document('one.txt', 'one');
    await windows.openWindow();

    await windows.openDocument(testPath('one.txt'));

    final extra = windows.windows.last;
    expect(extra.workspace.documents, hasLength(1));
    expect(extra.workspace.active!.path, testPath('one.txt'));
    expect(windows.windows.first.workspace.documents, isEmpty);
    expect(host.calls, contains('activate 1'));
  });

  test('a file already open in another window focuses that window', () async {
    await windows.start();
    store.files[testPath('one.txt')] = document('one.txt', 'one');
    await windows.openDocument(testPath('one.txt'));
    final main = windows.windows.single;
    await windows.openWindow();
    host.calls.clear();
    final flashes = main.workspace.active!.flashRequest;

    await windows.openDocument(testPath('one.txt'));

    // Nothing new opened; the owner's window came forward and its tab
    // flashed for the user who asked for the file again.
    expect(windows.windows.last.workspace.documents, isEmpty);
    expect(main.workspace.active!.flashRequest, flashes + 1);
    expect(host.calls, ['activate 0']);
  });

  test('Save As in one window cannot target a file open in another', () async {
    await windows.start();
    store.files[testPath('taken.txt')] = document('taken.txt', 'taken');
    await windows.openDocument(testPath('taken.txt'));
    await windows.openWindow();
    final extra = windows.windows.last;
    final draft = extra.workspace.newDocument()!;
    draft.editor.text.text = 'draft';
    dialogs[extra]!.savePath = testPath('taken.txt');

    expect(await extra.workspace.save(draft, saveAs: true), isFalse);
    expect(extra.workspace.error, contains('another window'));
    expect(store.writes, isEmpty);
  });

  test('a file open that arrives during a quit review waits it out', () async {
    await windows.start();
    final main = windows.windows.single;
    main.workspace.newDocument()!.editor.text.text = 'unsaved';
    store.files[testPath('one.txt')] = document('one.txt', 'one');
    dialogs[main]!.choiceGate = Completer<CloseChoice>();

    final quit = windows.confirmAllClose();
    await pumpEventQueue();
    final open = windows.openDocument(testPath('one.txt'));
    await pumpEventQueue();
    // The review still asks: the file has not snuck in behind it.
    expect(main.workspace.documents, hasLength(1));

    dialogs[main]!.choiceGate!.complete(CloseChoice.cancel);
    expect(await quit, isFalse);
    await open;
    expect(main.workspace.documents, hasLength(2));
  });

  testWidgets('the app-wide keys answer for the active window', (tester) async {
    // Built inside the test's zone so its futures run there.
    windows.dispose();
    windows = makeRegistry();
    await windows.start();
    await windows.openWindow();
    final main = windows.windowForView(mainWindowViewId)!;
    final extra = windows.windows.last;
    Widget navigator(DocumentWindow window) => SizedBox(
      width: 100,
      height: 100,
      child: ScaffoldMessenger(
        key: window.scaffoldMessengerKey,
        child: Navigator(
          key: window.navigatorKey,
          onGenerateRoute: (_) =>
              MaterialPageRoute<void>(builder: (_) => const SizedBox()),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(home: Row(children: [navigator(main), navigator(extra)])),
    );

    expect(
      windows.navigatorKey.currentState,
      same(extra.navigatorKey.currentState),
    );
    expect(
      windows.scaffoldMessengerKey.currentState,
      same(extra.scaffoldMessengerKey.currentState),
    );

    windows.onWindowActivated(mainWindowViewId);

    expect(
      windows.navigatorKey.currentState,
      same(main.navigatorKey.currentState),
    );
    expect(windows.navigatorKey.currentContext, isNotNull);
  });
}
