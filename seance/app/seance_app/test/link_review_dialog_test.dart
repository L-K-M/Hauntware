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

void main() {
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

    testWidgets('discards the queue it drew, which follows arrivals', (
      tester,
    ) async {
      final review = _review(target: const SeanceLinkTarget(server: _web));
      await _show(tester, review);
      expect(find.text('Discard waiting links'), findsNothing);

      const arrived = SeanceLinkQueue(waitingLabels: ['db'], waitingCount: 1);
      (review as _FixedReview).queue.value = arrived;
      await tester.pumpAndSettle();
      expect(find.text('1 more link is waiting.'), findsOneWidget);
      expect(find.text('• db'), findsOneWidget);

      await tester.tap(find.text('Discard waiting links'));
      await tester.pumpAndSettle();
      expect(find.byType(SeanceLinkReviewDialog), findsNothing);
      expect(review.shown, same(arrived));
    });

    testWidgets('Connect and Cancel answer as labelled', (tester) async {
      final review = _review(target: const SeanceLinkTarget(server: _web));
      expect(
        await _show(tester, review, tap: 'Connect'),
        SeanceLinkDecision.connect,
      );
      expect(
        await _show(tester, review, tap: 'Cancel'),
        SeanceLinkDecision.cancel,
      );
    });

    testWidgets('lists waiting links and those it cannot open', (tester) async {
      await _show(
        tester,
        _review(
          target: const SeanceLinkTarget(server: _web),
          waitingLabels: ['db', null],
          waitingCount: 5,
          ignoredCount: 2,
        ),
      );

      expect(find.text('5 more links are waiting.'), findsOneWidget);
      expect(find.text('• db'), findsOneWidget);
      expect(find.text('• A link Séance cannot open'), findsOneWidget);
      expect(find.text('2 more links were ignored.'), findsOneWidget);
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

  group('SeanceAppLinkHandler', () {
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
      final handler = SeanceAppLinkHandler(state, GlobalKey());
      final intake = SeanceLinkIntake()..activate(handler);

      expect(state.configFor(_webId), isNotNull);
      expect(handler.servers, isEmpty);
      expect(
        resolveSeanceLink(
          const SeanceServerConnect(serverId: _webId),
          handler.servers,
        ).miss,
        SeanceLinkNoticeKind.unknownServer,
      );
      intake.deactivate(handler);
    });

    test('a folder opens a fresh tab, even beside an existing one', () async {
      state.servers = [_web];
      await state.newTab(_web);
      final handler = SeanceAppLinkHandler(state, GlobalKey());

      await handler.connect(const SeanceLinkTarget(server: _web, cwd: '/srv'));

      // The refused handshake ends the wait; there is no window to say so.
      expect(state.tabs, hasLength(2));
      expect(dialed, [_webId, _webId]);
    });

    test('without a folder the server row focus-or-connect runs', () async {
      state.servers = [_web];
      final handler = SeanceAppLinkHandler(state, GlobalKey());

      await handler.connect(const SeanceLinkTarget(server: _web));
      await handler.connect(const SeanceLinkTarget(server: _web));

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

SeanceLinkReview _review({
  required SeanceLinkTarget target,
  List<String?> waitingLabels = const [],
  int waitingCount = 0,
  int ignoredCount = 0,
}) => _FixedReview(
  target,
  SeanceLinkQueue(
    waitingLabels: waitingLabels,
    waitingCount: waitingCount,
    ignoredCount: ignoredCount,
  ),
);

final class _FixedReview implements SeanceLinkReview {
  _FixedReview(this.target, SeanceLinkQueue queue)
    : queue = ValueNotifier(queue);

  @override
  final SeanceLinkTarget target;

  @override
  final ValueNotifier<SeanceLinkQueue> queue;

  SeanceLinkQueue? shown;

  @override
  void markShown(SeanceLinkQueue shown) => this.shown = shown;
}

Future<SeanceLinkDecision?> _show(
  WidgetTester tester,
  SeanceLinkReview review, {
  String? tap,
}) async {
  SeanceLinkDecision? decision;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            decision = await showDialog<SeanceLinkDecision>(
              context: context,
              builder: (_) => SeanceLinkReviewDialog(review: review),
            );
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  if (tap != null) {
    await tester.tap(find.text(tap));
    await tester.pumpAndSettle();
  }
  return decision;
}
