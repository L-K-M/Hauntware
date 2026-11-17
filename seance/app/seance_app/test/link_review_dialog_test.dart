import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/link_intake.dart';
import 'package:seance_app/ui/link_review_dialog.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _webId = '123e4567-e89b-42d3-a456-426614174000';
const _dbId = '223e4567-e89b-42d3-a456-426614174000';

void main() {
  // The handler group's plain tests use the binding's messenger too.
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SeanceLinkReviewDialog', () {
    testWidgets('shows the saved server and the cleaned folder', (
      tester,
    ) async {
      await _show(
        tester,
        _review(
          target: const SeanceLinkTarget(
            server: _web,
            cwd: '/srv/\u202egpj.exe',
          ),
        ),
      );

      expect(find.text('Open a terminal from a link?'), findsOneWidget);
      expect(find.text('web'), findsOneWidget);
      expect(find.text('deploy@web.example:2222'), findsOneWidget);
      expect(find.text('/srv/gpj.exe'), findsOneWidget);
      expect(
        find.text('Hidden characters were removed from this folder name.'),
        findsOneWidget,
      );
      expect(
        find.text(
          'Links cannot run commands. Séance types the cd command at the '
          'prompt and does not press Enter.',
        ),
        findsOneWidget,
      );
      expect(find.text('Discard waiting links'), findsNothing);
    });

    testWidgets('without a folder says only that links run nothing', (
      tester,
    ) async {
      await _show(
        tester,
        _review(target: const SeanceLinkTarget(server: _web)),
      );

      expect(find.text('Starting folder'), findsNothing);
      expect(find.text('Links cannot run commands.'), findsOneWidget);
    });

    testWidgets('says how many times the link was opened', (tester) async {
      final review = _review(target: const SeanceLinkTarget(server: _web));
      await _show(tester, review);
      expect(find.textContaining('This link was opened'), findsNothing);

      for (final (count, text) in [
        (2, 'This link was opened twice.'),
        (3, 'This link was opened 3 times.'),
      ]) {
        review.fake.publish(
          LinkReviewSnapshot(
            current: SeanceLinkRequest(
              _webLink.request,
              activationCount: count,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(text), findsOneWidget);
      }
    });

    testWidgets('Connect and Cancel answer as labelled', (tester) async {
      final review = _review(target: const SeanceLinkTarget(server: _web));
      expect(
        await _show(tester, review, tap: 'Connect'),
        LinkReviewDecision.connect,
      );
      expect(review.fake.shown, same(review.fake.snapshot));
      expect(
        await _show(tester, review, tap: 'Cancel'),
        LinkReviewDecision.cancel,
      );
    });

    testWidgets('answers nothing until its buttons arm', (tester) async {
      final review = _review(target: const SeanceLinkTarget(server: _web));
      await _show(tester, review, settle: false);

      await tester.tap(find.text('Connect'));
      await tester.pump();
      expect(find.byType(SeanceLinkReviewDialog), findsOneWidget);

      await tester.pump(seanceLinkReviewArmDelay);
      await tester.tap(find.text('Connect'));
      await tester.pumpAndSettle();
      expect(find.byType(SeanceLinkReviewDialog), findsNothing);
    });

    testWidgets('the barrier and Escape do not answer it', (tester) async {
      final review = _review(target: const SeanceLinkTarget(server: _web));
      await _show(tester, review);

      await tester.tapAt(const Offset(4, 4));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(SeanceLinkReviewDialog), findsOneWidget);
    });

    testWidgets('closes unanswered when its link is cancelled', (tester) async {
      final review = _review(target: const SeanceLinkTarget(server: _web));
      final decision = _show(tester, review);
      await decision;
      expect(find.byType(SeanceLinkReviewDialog), findsOneWidget);

      review.fake.cancel();
      await tester.pumpAndSettle();
      expect(find.byType(SeanceLinkReviewDialog), findsNothing);
      expect(_lastDecision, LinkReviewDecision.cancel);
      expect(review.fake.shown, isNull);
    });

    testWidgets('discards the queue it drew, which follows arrivals', (
      tester,
    ) async {
      final review = _review(target: const SeanceLinkTarget(server: _web));
      await _show(tester, review);
      expect(find.text('Discard waiting links'), findsNothing);

      const arrived = LinkReviewSnapshot<SeanceLinkRequest>(
        current: _webLink,
        visibleWaiting: [_dbLink],
        remainingCount: 1,
      );
      review.fake.publish(arrived);
      await tester.pumpAndSettle();
      expect(find.text('1 more link is waiting.'), findsOneWidget);
      expect(find.text('• db'), findsOneWidget);

      await tester.tap(find.text('Discard waiting links'));
      await tester.pumpAndSettle();
      expect(find.byType(SeanceLinkReviewDialog), findsNothing);
      expect(_lastDecision, LinkReviewDecision.discardAllRemaining);
      expect(review.fake.shown, same(arrived));
    });

    testWidgets('lists every waiting link before it discards them', (
      tester,
    ) async {
      final review = _review(
        target: const SeanceLinkTarget(server: _web),
        visibleWaiting: [_dbLink, _unknownLink],
        overflow: [_dbLink, _webLink],
        ignoredCount: 2,
      );
      await _show(tester, review);

      expect(find.text('4 more links are waiting.'), findsOneWidget);
      expect(find.text('• db'), findsOneWidget);
      expect(find.text('• A link Séance cannot open'), findsOneWidget);
      expect(find.text('And 2 more links'), findsOneWidget);
      expect(find.text('2 more links were ignored.'), findsOneWidget);
      expect(_button('Discard waiting links').onPressed, isNull);

      await tester.tap(find.text('And 2 more links'));
      await tester.pumpAndSettle();
      expect(find.text('• db'), findsNWidgets(2));
      expect(_button('Discard waiting links').onPressed, isNotNull);

      // A link that arrives hidden needs the list opened again.
      review.fake.publish(
        LinkReviewSnapshot(
          current: _webLink,
          visibleWaiting: review.fake.snapshot.visibleWaiting,
          overflow: [...review.fake.snapshot.overflow, _dbLink],
          remainingCount: 5,
        ),
      );
      await tester.pumpAndSettle();
      expect(_button('Discard waiting links').onPressed, isNull);
    });
  });

  test('every notice names its problem', () {
    expect(
      {
        for (final kind in SeanceLinkNoticeKind.values)
          kind: seanceLinkNoticeMessage(SeanceLinkNotice(kind, count: 3)),
      },
      {
        SeanceLinkNoticeKind.notSeanceLink: 'This link is not a Séance link.',
        SeanceLinkNoticeKind.unacceptedParameters:
            'This link has parameters Séance does not accept.',
        SeanceLinkNoticeKind.invalidFolder:
            'The starting folder in this link is not valid.',
        SeanceLinkNoticeKind.unknownServer:
            'This link names a server Séance does not have.',
        SeanceLinkNoticeKind.ignoredLinks: '3 more links were ignored.',
        SeanceLinkNoticeKind.ambiguousServer:
            'Several saved servers match this link.',
      },
    );
  });

  group('SeanceAppLinkHost', () {
    late Directory directory;
    late AppServices services;
    late AppState state;
    late List<String> dialed;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('seance-link-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      dialed = [];
      // Every handshake is recorded, then refused, so nothing connects.
      state = AppState(
        services,
        openSshSession:
            (
              manager, {
              required config,
              required credentials,
              required engine,
              log,
            }) async {
              dialed.add(config.id);
              throw SshConnectException(
                'SSH error connecting',
                const SocketException('refused'),
                log!,
              );
            },
      );
    });

    tearDown(() async {
      state.dispose();
      await services.probe.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, null);
      FlutterSecureStorage.setMockInitialValues({});
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Deliberately ignored: the OS reaps system temp dirs.
      }
    });

    test('an open tab is not a saved server', () async {
      state.servers = [_web];
      await state.newTab(_web);
      state.servers = [];
      final host = SeanceAppLinkHost(state, GlobalKey());

      expect(state.configFor(_webId), isNotNull);
      expect(host.servers, isEmpty);
      expect(
        resolveSeanceLink(
          const SeanceServerConnect(serverId: _webId),
          host.servers,
        ).miss,
        SeanceLinkNoticeKind.unknownServer,
      );
    });

    test('a folder opens a fresh tab, even beside an existing one', () async {
      state.servers = [_web];
      await state.newTab(_web);
      final host = SeanceAppLinkHost(state, GlobalKey());

      await host.connect(const SeanceLinkTarget(server: _web, cwd: '/srv'));

      // The refused handshake ends the wait; there is no window to say so.
      expect(state.tabs, hasLength(2));
      expect(dialed, [_webId, _webId]);
    });

    test('without a folder the server row focus-or-connect runs', () async {
      state.servers = [_web];
      final host = SeanceAppLinkHost(state, GlobalKey());

      await host.connect(const SeanceLinkTarget(server: _web));
      await host.connect(const SeanceLinkTarget(server: _web));

      // The second focuses the first tab and redials it, since it failed.
      expect(state.tabs, hasLength(1));
      expect(dialed, [_webId, _webId]);
    });
  });
}

const _web = ServerConfig(
  id: _webId,
  label: 'web',
  host: 'web.example',
  port: 2222,
  username: 'deploy',
  createdAt: 1,
  updatedAt: 1,
);

const _db = ServerConfig(
  id: _dbId,
  label: 'db',
  host: 'db.example',
  port: 22,
  username: 'deploy',
  createdAt: 1,
  updatedAt: 1,
);

const _webLink = SeanceLinkRequest(SeanceServerConnect(serverId: _webId));
const _dbLink = SeanceLinkRequest(SeanceServerConnect(serverId: _dbId));
const _unknownLink = SeanceLinkRequest(
  SeanceServerConnect(serverId: '323e4567-e89b-42d3-a456-426614174000'),
);

SeanceLinkReview _review({
  required SeanceLinkTarget target,
  List<SeanceLinkRequest> visibleWaiting = const [],
  List<SeanceLinkRequest> overflow = const [],
  int ignoredCount = 0,
}) => SeanceLinkReview(
  target: target,
  link: _FakeLinkReview(
    LinkReviewSnapshot(
      current: _webLink,
      visibleWaiting: visibleWaiting,
      overflow: overflow,
      remainingCount: visibleWaiting.length + overflow.length,
      ignoredCount: ignoredCount,
    ),
  ),
  servers: const [_web, _db],
);

extension on SeanceLinkReview {
  _FakeLinkReview get fake => link as _FakeLinkReview;
}

final class _FakeLinkReview implements LinkReview<SeanceLinkRequest> {
  _FakeLinkReview(this._snapshot);

  final _snapshots =
      StreamController<LinkReviewSnapshot<SeanceLinkRequest>>.broadcast();
  final _cancellation = Completer<void>();
  LinkReviewSnapshot<SeanceLinkRequest> _snapshot;
  LinkReviewSnapshot<SeanceLinkRequest>? shown;

  @override
  LinkReviewSnapshot<SeanceLinkRequest> get snapshot => _snapshot;

  @override
  Stream<LinkReviewSnapshot<SeanceLinkRequest>> get snapshots =>
      _snapshots.stream;

  void publish(LinkReviewSnapshot<SeanceLinkRequest> snapshot) {
    _snapshot = snapshot;
    _snapshots.add(snapshot);
  }

  @override
  void markShown(LinkReviewSnapshot<SeanceLinkRequest> shown) =>
      this.shown = shown;

  @override
  bool get isCancelled => _cancellation.isCompleted;

  @override
  Future<void> get cancelled => _cancellation.future;

  void cancel() => _cancellation.complete();
}

LinkReviewDecision? _lastDecision;

TextButton _button(String label) =>
    find
            .ancestor(of: find.text(label), matching: find.byType(TextButton))
            .evaluate()
            .single
            .widget
        as TextButton;

/// Opens [review] the way the app does and, when [tap] names a button,
/// answers it; returns the decision, also kept in [_lastDecision].
Future<LinkReviewDecision?> _show(
  WidgetTester tester,
  SeanceLinkReview review, {
  String? tap,
  bool settle = true,
}) async {
  _lastDecision = null;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            _lastDecision = await showSeanceLinkReviewDialog(context, review);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  if (!settle) {
    await tester.pump();
    return null;
  }
  await tester.pumpAndSettle();
  await tester.pump(seanceLinkReviewArmDelay);
  if (tap != null) {
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
  }
  return _lastDecision;
}
