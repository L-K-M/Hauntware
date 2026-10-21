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
  group('SeanceLinkIntake', () {
    test('reviews a saved server by id and connects with its folder', () async {
      final handler = _Handler([_web, _db]);
      final intake = SeanceLinkIntake()..activate(handler);

      intake.add(_connect(_webId.toUpperCase(), cwd: '/srv/app'));
      await intake.idle;

      final review = handler.reviews.single;
      expect(review.target.server, same(_web));
      expect(review.target.cwd, '/srv/app');
      expect(handler.connects.single.server, same(_web));
      expect(handler.connects.single.cwd, '/srv/app');
      expect(handler.notices, isEmpty);
    });

    test('refuses an unknown id without a review or a connect', () async {
      final handler = _Handler([_db]);
      final intake = SeanceLinkIntake()..activate(handler);

      intake.add(_connect(_webId));
      await intake.idle;

      expect(handler.reviews, isEmpty);
      expect(handler.connects, isEmpty);
      expect(handler.noticeKinds, [SeanceLinkNoticeKind.unknownServer]);
    });

    test('takes the identity form only for a single saved match', () async {
      final twin = _server(_dbId, host: 'WEB.example', label: 'web twin');
      final cases = {
        <ServerConfig>[_db]: SeanceLinkNoticeKind.unknownServer,
        [_web, _db]: null,
        [_web, twin]: SeanceLinkNoticeKind.ambiguousServer,
      };
      for (final MapEntry(key: servers, value: miss) in cases.entries) {
        final handler = _Handler(servers);
        final intake = SeanceLinkIntake()..activate(handler);

        intake.add(
          Uri.parse(
            'seance://connect?host=web.EXAMPLE&port=22&username=deploy',
          ),
        );
        await intake.idle;

        if (miss == null) {
          expect(handler.reviews.single.target.server, same(_web));
          expect(handler.reviews.single.target.cwd, isNull);
          expect(handler.notices, isEmpty);
        } else {
          expect(handler.reviews, isEmpty);
          expect(handler.noticeKinds, [miss]);
        }
      }
    });

    test('names what is wrong with a link that does not parse', () async {
      final handler = _Handler([_web]);
      final intake = SeanceLinkIntake()..activate(handler);

      intake
        ..add(Uri.parse('poltergeist://browse?serverId=$_webId&path=/'))
        ..add(Uri.parse('seance://connect?serverId=$_webId&cmd=reboot'))
        ..add(Uri.parse('seance://connect?serverId=$_webId&cwd=/srv/../etc'))
        ..add(Uri.parse('seance://connect?host=web.example&username=deploy'))
        ..add(Uri.parse('klabautermann://server?serverId=$_webId'));
      await intake.idle;

      expect(handler.reviews, isEmpty);
      expect(handler.connects, isEmpty);
      expect(handler.noticeKinds, [
        SeanceLinkNoticeKind.notSeanceLink,
        SeanceLinkNoticeKind.unacceptedParameters,
        SeanceLinkNoticeKind.invalidFolder,
        SeanceLinkNoticeKind.unacceptedParameters,
        SeanceLinkNoticeKind.notSeanceLink,
      ]);
    });

    test('Cancel connects nothing', () async {
      final handler = _Handler([_web])
        ..decide = (_) => SeanceLinkDecision.cancel;
      final intake = SeanceLinkIntake()..activate(handler);

      intake.add(_connect(_webId, cwd: '/srv'));
      await intake.idle;

      expect(handler.reviews, hasLength(1));
      expect(handler.connects, isEmpty);
    });

    test('queues links until a handler binds', () async {
      final intake = SeanceLinkIntake();
      intake.add(_connect(_webId));
      await intake.idle;

      final handler = _Handler([_web]);
      intake.activate(handler);
      await intake.idle;

      expect(handler.connects.single.server, same(_web));
    });

    test('reviews one link at a time, in arrival order', () async {
      final handler = _Handler([_web, _db])..holdReviews = true;
      final intake = SeanceLinkIntake()..activate(handler);

      intake
        ..add(_connect(_webId))
        ..add(_connect(_dbId));
      await pumpEventQueue();
      expect(handler.reviews, hasLength(1));

      handler.answer(SeanceLinkDecision.connect);
      await pumpEventQueue();
      expect(handler.reviews, hasLength(2));
      expect(handler.reviews[1].target.server, same(_db));

      handler.answer(SeanceLinkDecision.connect);
      await intake.idle;
      expect(handler.connects.map((target) => target.server), [_web, _db]);
    });

    test('coalesces a link identical to one in hand or waiting', () async {
      final handler = _Handler([_web, _db])..holdReviews = true;
      final intake = SeanceLinkIntake()..activate(handler);

      intake.add(_connect(_webId, cwd: '/srv'));
      await pumpEventQueue();
      intake
        ..add(_connect(_webId, cwd: '/srv'))
        ..add(_connect(_dbId))
        ..add(_connect(_dbId))
        ..add(_connect(_webId, cwd: '/var'));

      handler.answer(SeanceLinkDecision.connect);
      await pumpEventQueue();
      final second = handler.reviews[1];
      expect(second.target.server, same(_db));
      expect(second.queue.value.waitingCount, 1);
      expect(second.queue.value.ignoredCount, 0);
      handler.answer(SeanceLinkDecision.connect);
      await pumpEventQueue();
      handler.answer(SeanceLinkDecision.connect);
      await intake.idle;

      expect(handler.connects.map((target) => target.cwd), [
        '/srv',
        null,
        '/var',
      ]);
    });

    test('drops links beyond the limit and says how many', () async {
      final handler = _Handler([_web])..holdReviews = true;
      final intake = SeanceLinkIntake()..activate(handler);

      intake.add(_connect(_webId));
      await pumpEventQueue();
      for (var i = 0; i < seanceLinkQueueLimit + 3; i++) {
        intake.add(_connect(_webId, cwd: '/srv/$i'));
      }

      // The open review follows the queue as links arrive.
      final first = handler.reviews.single.queue.value;
      expect(first.waitingCount, seanceLinkQueueLimit);
      expect(first.waitingLabels, ['web', 'web']);
      expect(first.ignoredCount, 3);

      handler.answer(SeanceLinkDecision.cancel);
      await pumpEventQueue();
      final second = handler.reviews[1].queue.value;
      expect(handler.reviews[1].target.cwd, '/srv/0');
      expect(second.waitingCount, seanceLinkQueueLimit - 1);
      // Reported once, by the review that showed it.
      expect(second.ignoredCount, 0);

      handler.answer(SeanceLinkDecision.discardWaiting);
      await intake.idle;
      expect(handler.reviews, hasLength(2));
      expect(handler.notices, isEmpty);
    });

    test('reports dropped links when no review is left to carry it', () async {
      final intake = SeanceLinkIntake();
      for (var i = 0; i < seanceLinkQueueLimit + 2; i++) {
        intake.add(Uri.parse('seance://connect?cmd=$i'));
      }
      final handler = _Handler([_web]);
      intake.activate(handler);
      await intake.idle;

      expect(handler.reviews, isEmpty);
      expect(handler.notices, hasLength(seanceLinkQueueLimit + 1));
      expect(handler.notices.last.kind, SeanceLinkNoticeKind.ignoredLinks);
      expect(handler.notices.last.count, 2);
    });

    test('Discard waiting links drops only the links it counted', () async {
      final handler = _Handler([_web, _db])..holdReviews = true;
      final intake = SeanceLinkIntake()..activate(handler);

      intake
        ..add(_connect(_webId))
        ..add(_connect(_dbId))
        ..add(Uri.parse('seance://connect?serverId=$_webId&cmd=x'));
      await pumpEventQueue();
      final first = handler.reviews.single;
      final shown = first.queue.value;
      expect(shown.waitingCount, 2);
      expect(shown.waitingLabels, ['db', null]);

      // Arrives after the review last drew, so it was never shown.
      intake.add(_connect(_webId, cwd: '/late'));
      expect(first.queue.value.waitingCount, 3);
      handler.answer(SeanceLinkDecision.discardWaiting, shown: shown);
      await pumpEventQueue();

      expect(handler.reviews, hasLength(2));
      expect(handler.reviews[1].target.cwd, '/late');
      handler.answer(SeanceLinkDecision.connect);
      await intake.idle;
      expect(handler.connects.single.cwd, '/late');
      expect(handler.notices, isEmpty);
    });

    test('keeps a link whose handler failed until the next link', () async {
      final errors = <Object>[];
      final handler = _Handler([_web, _db])..failReviews = 1;
      final intake = SeanceLinkIntake(onError: (error, _) => errors.add(error))
        ..activate(handler);

      intake.add(_connect(_webId));
      await intake.idle;
      expect(errors, hasLength(1));
      expect(handler.connects, isEmpty);

      intake.add(_connect(_dbId));
      await intake.idle;
      expect(handler.connects.map((target) => target.server), [_web, _db]);
    });

    test('stops at a deactivated handler and resumes at the next', () async {
      final first = _Handler([_web]);
      final intake = SeanceLinkIntake()
        ..activate(first)
        ..deactivate(first);

      intake.add(_connect(_webId));
      await intake.idle;
      expect(first.reviews, isEmpty);

      final second = _Handler([_web]);
      intake.activate(second);
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

final class _Handler implements SeanceLinkHandler {
  _Handler(this.servers);

  @override
  final List<ServerConfig> servers;

  final reviews = <SeanceLinkReview>[];
  final connects = <SeanceLinkTarget>[];
  final notices = <SeanceLinkNotice>[];
  SeanceLinkDecision Function(SeanceLinkReview review) decide = _connectAll;
  bool holdReviews = false;
  int failReviews = 0;
  Completer<SeanceLinkDecision>? _open;

  List<SeanceLinkNoticeKind> get noticeKinds => [
    for (final notice in notices) notice.kind,
  ];

  /// Answers the open review; a discard covers [shown], or what the
  /// review shows now.
  void answer(SeanceLinkDecision decision, {SeanceLinkQueue? shown}) {
    final open = _open!;
    _open = null;
    if (decision == SeanceLinkDecision.discardWaiting) {
      reviews.last.markShown(shown ?? reviews.last.queue.value);
    }
    open.complete(decision);
  }

  @override
  Future<SeanceLinkDecision> review(SeanceLinkReview review) {
    if (failReviews > 0) {
      failReviews--;
      throw StateError('no window');
    }
    reviews.add(review);
    if (!holdReviews) return Future.value(decide(review));
    return (_open = Completer<SeanceLinkDecision>()).future;
  }

  @override
  Future<void> connect(SeanceLinkTarget target) async => connects.add(target);

  @override
  Future<void> showNotice(SeanceLinkNotice notice) async => notices.add(notice);

  static SeanceLinkDecision _connectAll(SeanceLinkReview _) =>
      SeanceLinkDecision.connect;
}
