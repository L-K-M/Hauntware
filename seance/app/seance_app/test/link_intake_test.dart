import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/link_intake.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_core/seance_core.dart';

const _webId = '123e4567-e89b-42d3-a456-426614174000';
const _dbId = '223e4567-e89b-42d3-a456-426614174000';

void main() {
  // The queue's own rules (order, limit, coalescing, handoff, errors) are
  // seance_core's link_queue_test.dart. These cases are Séance's intake on
  // it: parsing, resolution, notices and the review's decisions.
  group('Séance link intake', () {
    test('reviews a saved server by id and connects with its folder', () async {
      final host = _Host([_web, _db]);
      final intake = _intake(host);

      intake.add(_connect(_webId.toUpperCase(), cwd: '/srv/app'));
      await intake.idle;

      final review = host.reviews.single;
      expect(review.target.server, same(_web));
      expect(review.target.cwd, '/srv/app');
      expect(host.connects.single.server, same(_web));
      expect(host.connects.single.cwd, '/srv/app');
      expect(host.notices, isEmpty);
    });

    test('refuses an unknown id without a review or a connect', () async {
      final host = _Host([_db]);
      final intake = _intake(host);

      intake.add(_connect(_webId));
      await intake.idle;

      expect(host.reviews, isEmpty);
      expect(host.connects, isEmpty);
      expect(host.noticeKinds, [SeanceLinkNoticeKind.unknownServer]);
    });

    test('takes the identity form only for a single saved match', () async {
      final twin = _server(_dbId, host: 'WEB.example', label: 'web twin');
      final cases = {
        <ServerConfig>[_db]: SeanceLinkNoticeKind.unknownServer,
        [_web, _db]: null,
        [_web, twin]: SeanceLinkNoticeKind.ambiguousServer,
      };
      for (final MapEntry(key: servers, value: miss) in cases.entries) {
        final host = _Host(servers);
        final intake = _intake(host);

        intake.add(
          Uri.parse(
            'seance://connect?host=web.EXAMPLE&port=22&username=deploy',
          ),
        );
        await intake.idle;

        if (miss == null) {
          expect(host.reviews.single.target.server, same(_web));
          expect(host.reviews.single.target.cwd, isNull);
          expect(host.notices, isEmpty);
        } else {
          expect(host.reviews, isEmpty);
          expect(host.noticeKinds, [miss]);
        }
      }
    });

    test('names what is wrong with a link that does not parse', () async {
      final host = _Host([_web]);
      final intake = _intake(host);

      intake
        ..add(Uri.parse('poltergeist://browse?serverId=$_webId&path=/'))
        ..add(Uri.parse('seance://connect?serverId=$_webId&cmd=reboot'))
        ..add(Uri.parse('seance://connect?serverId=$_webId&cwd=/srv/../etc'))
        ..add(Uri.parse('seance://connect?host=web.example&username=deploy'))
        ..add(Uri.parse('klabautermann://server?serverId=$_webId'));
      await intake.idle;

      expect(host.reviews, isEmpty);
      expect(host.connects, isEmpty);
      expect(host.noticeKinds, [
        SeanceLinkNoticeKind.notSeanceLink,
        SeanceLinkNoticeKind.unacceptedParameters,
        SeanceLinkNoticeKind.invalidFolder,
        SeanceLinkNoticeKind.unacceptedParameters,
        SeanceLinkNoticeKind.notSeanceLink,
      ]);
    });

    test('Cancel connects nothing and leaves the waiting links', () async {
      final host = _Host([_web, _db])..holdReviews = true;
      final intake = _intake(host);

      intake
        ..add(_connect(_webId, cwd: '/srv'))
        ..add(_connect(_dbId));
      await pumpEventQueue();
      host.answer(LinkReviewDecision.cancel);
      await pumpEventQueue();

      expect(host.reviews, hasLength(2));
      expect(host.reviews[1].target.server, same(_db));
      host.answer(LinkReviewDecision.connect);
      await intake.idle;
      expect(host.connects.single.server, same(_db));
    });

    test('queues links until a handler binds', () async {
      final intake = createSeanceLinkIntake();
      intake.add(_connect(_webId));
      await intake.idle;

      final host = _Host([_web]);
      intake.activate(SeanceLinkHandler(host));
      await intake.idle;

      expect(host.connects.single.server, same(_web));
    });

    test('reviews one link at a time, in arrival order', () async {
      final host = _Host([_web, _db])..holdReviews = true;
      final intake = _intake(host);

      intake
        ..add(_connect(_webId))
        ..add(_connect(_dbId));
      await pumpEventQueue();
      expect(host.reviews, hasLength(1));

      host.answer(LinkReviewDecision.connect);
      await pumpEventQueue();
      expect(host.reviews, hasLength(2));
      expect(host.reviews[1].target.server, same(_db));

      host.answer(LinkReviewDecision.connect);
      await intake.idle;
      expect(host.connects.map((target) => target.server), [_web, _db]);
    });

    test('coalesces a link identical to one in review or waiting', () async {
      final host = _Host([_web, _db])..holdReviews = true;
      final intake = _intake(host);

      intake.add(_connect(_webId, cwd: '/srv'));
      await pumpEventQueue();
      intake
        ..add(_connect(_webId, cwd: '/srv'))
        ..add(_connect(_dbId))
        ..add(_connect(_dbId))
        ..add(_connect(_webId, cwd: '/var'));
      expect(host.reviews.single.link.snapshot.remainingCount, 2);

      host.answer(LinkReviewDecision.connect);
      await pumpEventQueue();
      final second = host.reviews[1];
      expect(second.target.server, same(_db));
      expect(second.link.snapshot.remainingCount, 1);
      expect(second.link.snapshot.ignoredCount, 0);
      host.answer(LinkReviewDecision.connect);
      await pumpEventQueue();
      host.answer(LinkReviewDecision.connect);
      await intake.idle;

      expect(host.connects.map((target) => target.cwd), ['/srv', null, '/var']);
    });

    test('a repeat after the decision is a new link', () async {
      final host = _Host([_web])..holdConnects = true;
      final intake = _intake(host);

      intake.add(_connect(_webId, cwd: '/srv'));
      await pumpEventQueue();
      expect(host.connects, hasLength(1));
      intake.add(_connect(_webId, cwd: '/srv'));
      host.releaseConnect();
      await intake.idle;

      expect(host.reviews, hasLength(2));
      expect(host.connects, hasLength(2));
    });

    test('drops links beyond the limit and says how many', () async {
      final host = _Host([_web])..holdReviews = true;
      final intake = _intake(host);

      intake.add(_connect(_webId));
      await pumpEventQueue();
      for (var i = 0; i < linkQueueLimit + 3; i++) {
        intake.add(_connect(_webId, cwd: '/srv/$i'));
      }

      // The open review follows the queue as links arrive.
      final review = host.reviews.single;
      final first = review.link.snapshot;
      expect(first.remainingCount, linkQueueLimit);
      expect(
        [for (final link in first.visibleWaiting) review.labelOf(link)],
        ['web', 'web'],
      );
      expect(first.overflow, hasLength(linkQueueLimit - 2));
      expect(first.ignoredCount, 3);

      host.answer(LinkReviewDecision.cancel);
      await pumpEventQueue();
      final second = host.reviews[1].link.snapshot;
      expect(host.reviews[1].target.cwd, '/srv/0');
      expect(second.remainingCount, linkQueueLimit - 1);
      // Reported once, by the review that showed it.
      expect(second.ignoredCount, 0);

      host.answer(LinkReviewDecision.discardAllRemaining);
      await intake.idle;
      expect(host.reviews, hasLength(2));
      expect(host.notices, isEmpty);
    });

    test('drops after the review last drew reach the next one', () async {
      final host = _Host([_web])..holdReviews = true;
      final intake = _intake(host);

      intake.add(_connect(_webId));
      await pumpEventQueue();
      for (var i = 0; i < linkQueueLimit; i++) {
        intake.add(_connect(_webId, cwd: '/srv/$i'));
      }
      final drawn = host.reviews.single.link.snapshot;
      expect(drawn.ignoredCount, 0);
      intake
        ..add(_connect(_webId, cwd: '/srv/late-1'))
        ..add(_connect(_webId, cwd: '/srv/late-2'));
      expect(host.reviews.single.link.snapshot.ignoredCount, 2);

      // Decided before the dialog drew the drops.
      host.answer(LinkReviewDecision.cancel, shown: drawn);
      await pumpEventQueue();
      expect(host.reviews[1].link.snapshot.ignoredCount, 2);

      host.answer(LinkReviewDecision.discardAllRemaining);
      await intake.idle;
      expect(host.notices, isEmpty);
    });

    test('reports dropped links when no review is left to carry it', () async {
      final intake = createSeanceLinkIntake();
      for (var i = 0; i < linkQueueLimit + 2; i++) {
        intake.add(Uri.parse('seance://connect?cmd=$i'));
      }
      final host = _Host([_web]);
      intake.activate(SeanceLinkHandler(host));
      await intake.idle;

      expect(host.reviews, isEmpty);
      expect(host.notices, hasLength(linkQueueLimit + 1));
      expect(host.notices.last.kind, SeanceLinkNoticeKind.ignoredLinks);
      expect(host.notices.last.count, 2);
    });

    test('Discard drops the links it listed and keeps the rest', () async {
      final host = _Host([_web, _db])..holdReviews = true;
      final intake = _intake(host);

      intake
        ..add(_connect(_webId))
        ..add(_connect(_dbId))
        ..add(Uri.parse('seance://connect?serverId=$_webId&cmd=x'))
        ..add(_connect(_webId, cwd: '/listed'));
      await pumpEventQueue();
      final first = host.reviews.single;
      final shown = first.link.snapshot;
      // A link that does not parse is a notice, never a waiting review.
      expect(shown.remainingCount, 2);
      expect(
        [for (final link in shown.visibleWaiting) first.labelOf(link)],
        ['db', 'web'],
      );

      // Arrives after the review last drew, so it was never shown.
      intake.add(_connect(_webId, cwd: '/late'));
      expect(first.link.snapshot.remainingCount, 3);
      host.answer(LinkReviewDecision.discardAllRemaining, shown: shown);
      await pumpEventQueue();

      expect(host.noticeKinds, [SeanceLinkNoticeKind.unacceptedParameters]);
      expect(host.reviews, hasLength(2));
      expect(host.reviews[1].target.cwd, '/late');
      host.answer(LinkReviewDecision.connect);
      await intake.idle;
      expect(host.connects.single.cwd, '/late');
    });

    test('a review cancelled by deactivation returns to the queue', () async {
      final first = _Host([_web])..holdReviews = true;
      final intake = createSeanceLinkIntake();
      final firstHandler = SeanceLinkHandler(first);
      intake
        ..activate(firstHandler)
        ..add(_connect(_webId, cwd: '/srv'));
      await pumpEventQueue();
      final cancelled = first.reviews.single.link;

      intake.deactivate(firstHandler);
      await intake.idle;
      expect(cancelled.isCancelled, isTrue);
      expect(first.connects, isEmpty);

      final second = _Host([_web]);
      intake.activate(SeanceLinkHandler(second));
      await intake.idle;
      expect(second.reviews.single.target.cwd, '/srv');
      expect(second.connects.single.cwd, '/srv');
    });

    test('a server removed during the review is not opened', () async {
      final host = _Host([_web])..holdReviews = true;
      final intake = _intake(host);

      intake.add(_connect(_webId));
      await pumpEventQueue();
      host.servers.clear();
      host.answer(LinkReviewDecision.connect);
      await intake.idle;

      expect(host.connects, isEmpty);
      expect(host.noticeKinds, [SeanceLinkNoticeKind.unknownServer]);
    });

    test('keeps a link whose review failed until the next link', () async {
      final errors = <Object>[];
      final host = _Host([_web, _db])..failReviews = 1;
      final intake = createSeanceLinkIntake(
        onError: (error, _) => errors.add(error),
      )..activate(SeanceLinkHandler(host));

      intake.add(_connect(_webId));
      await intake.idle;
      expect(errors, hasLength(1));
      expect(host.connects, isEmpty);

      intake.add(_connect(_dbId));
      await intake.idle;
      expect(host.connects.map((target) => target.server), [_web, _db]);
    });

    test('stops at a deactivated handler and resumes at the next', () async {
      final first = _Host([_web]);
      final firstHandler = SeanceLinkHandler(first);
      final intake = createSeanceLinkIntake()
        ..activate(firstHandler)
        ..deactivate(firstHandler);

      intake.add(_connect(_webId));
      await intake.idle;
      expect(first.reviews, isEmpty);

      final second = _Host([_web]);
      intake.activate(SeanceLinkHandler(second));
      await intake.idle;
      expect(second.connects, hasLength(1));
    });
  });

  group('stageLinkFolder', () {
    late XtermTerminalEngine engine;
    late ValueNotifier<TerminalStatus?> status;
    late List<int> input;
    late StreamSubscription<List<int>> subscription;

    setUp(() {
      engine = XtermTerminalEngine();
      status = ValueNotifier(TerminalStatus.connecting);
      input = [];
      subscription = engine.userInput.listen(input.addAll);
    });

    tearDown(() async {
      await subscription.cancel();
      await engine.dispose();
      status.dispose();
    });

    Future<SeanceLinkFolderOutcome> stage(
      String folder, {
      Duration timeout = seanceLinkPromptTimeout,
    }) => stageLinkFolder(
      engine: engine,
      status: () => status.value,
      changes: status,
      folder: folder,
      timeout: timeout,
    );

    void prompt() => engine.feed(
      Uint8List.fromList(
        utf8.encode(
          '\x1b]1337;ShellIntegrationVersion=1;bash\x07'
          '\x1b]133;A\x07\x1b]133;B\x07',
        ),
      ),
    );

    test('stages exactly the cd at the first empty prompt', () async {
      const folder = "/srv/it's \$HOME; rm -rf ~";
      final outcome = stage(folder);
      await pumpEventQueue();
      prompt();
      await pumpEventQueue();
      // Not before the tab has connected.
      expect(input, isEmpty);

      status.value = TerminalStatus.connected;
      expect(await outcome, SeanceLinkFolderOutcome.staged);
      await pumpEventQueue();
      final staged = utf8.decode(input);
      expect(
        staged,
        buildChangeDirectoryCommand(folder, shell: RemoteShellKind.posix),
      );
      expect(staged, isNot(contains('\r')));
      expect(staged, isNot(contains('\n')));
    });

    test('ends at once when the tab fails or closes first', () async {
      for (final end in [TerminalStatus.error, null]) {
        status.value = TerminalStatus.connecting;
        final outcome = stage('/srv');
        await pumpEventQueue();
        status.value = end;
        expect(await outcome, SeanceLinkFolderOutcome.ended);
      }
      expect(input, isEmpty);
    });

    test('gives up without shell integration, typing nothing', () async {
      status.value = TerminalStatus.connected;
      final outcome = await stage(
        '/srv',
        timeout: const Duration(milliseconds: 20),
      );

      expect(outcome, SeanceLinkFolderOutcome.shellIntegrationRequired);
      expect(input, isEmpty);
    });

    test('gives up on a prompt that never comes back', () async {
      prompt();
      engine.feed(Uint8List.fromList(utf8.encode('\x1b]133;C\x07')));
      status.value = TerminalStatus.connected;
      final outcome = await stage(
        '/srv',
        timeout: const Duration(milliseconds: 20),
      );

      expect(outcome, SeanceLinkFolderOutcome.promptNotReady);
      expect(input, isEmpty);
    });

    test('leaves a prompt with input alone', () async {
      prompt();
      engine.sendCursorKey(TerminalCursorKey.arrowUp);
      await pumpEventQueue();
      input.clear();
      status.value = TerminalStatus.connected;

      expect(await stage('/srv'), SeanceLinkFolderOutcome.pendingInput);
      expect(input, isEmpty);
    });
  });
}

final _web = _server(_webId, host: 'web.example', label: 'web');
final _db = _server(_dbId, host: 'db.example', label: 'db');

ServerConfig _server(
  String id, {
  required String host,
  required String label,
}) => ServerConfig(
  id: id,
  label: label,
  host: host,
  port: 22,
  username: 'deploy',
  createdAt: 1,
  updatedAt: 1,
);

Uri _connect(String serverId, {String? cwd}) => Uri(
  scheme: 'seance',
  host: 'connect',
  queryParameters: {'serverId': serverId, 'cwd': ?cwd},
);

SeanceLinkIntake _intake(SeanceLinkHost host) =>
    createSeanceLinkIntake()..activate(SeanceLinkHandler(host));

final class _Host implements SeanceLinkHost {
  _Host(List<ServerConfig> servers) : servers = [...servers];

  @override
  final List<ServerConfig> servers;

  final reviews = <SeanceLinkReview>[];
  final connects = <SeanceLinkTarget>[];
  final notices = <SeanceLinkNotice>[];
  bool holdReviews = false;
  bool holdConnects = false;
  int failReviews = 0;
  Completer<LinkReviewDecision>? _open;
  final Completer<void> _connectGate = Completer<void>();

  List<SeanceLinkNoticeKind> get noticeKinds => [
    for (final notice in notices) notice.kind,
  ];

  /// Answers the open review on the snapshot the decision covered, which
  /// is what it shows now unless a test passes an older one.
  void answer(
    LinkReviewDecision decision, {
    LinkReviewSnapshot<SeanceConnectRequest>? shown,
  }) {
    final open = _open!;
    _open = null;
    final link = reviews.last.link;
    link.markShown(shown ?? link.snapshot);
    open.complete(decision);
  }

  void releaseConnect() => _connectGate.complete();

  @override
  Future<LinkReviewDecision> review(SeanceLinkReview review) {
    if (failReviews > 0) {
      failReviews--;
      throw StateError('no window');
    }
    reviews.add(review);
    if (!holdReviews) return Future.value(LinkReviewDecision.connect);
    final open = _open = Completer<LinkReviewDecision>();
    // As the dialog does: a cancelled review closes unanswered.
    unawaited(
      review.link.cancelled.then((_) {
        if (identical(_open, open)) {
          _open = null;
          open.complete(LinkReviewDecision.cancel);
        }
      }),
    );
    return open.future;
  }

  @override
  Future<void> connect(SeanceLinkTarget target) async {
    connects.add(target);
    if (holdConnects) await _connectGate.future;
  }

  @override
  Future<void> showNotice(SeanceLinkNotice notice) async => notices.add(notice);
}
