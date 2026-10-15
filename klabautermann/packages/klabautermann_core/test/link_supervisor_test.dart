import 'dart:async';
import 'dart:math';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/links/link_connector.dart';
import 'package:klabautermann_core/src/links/link_supervisor.dart';
import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        ServerConfig,
        SshLink,
        SshLinkClosed,
        SshLinkClosedReason,
        SshLinkDegraded,
        SshLinkDegradedReason,
        SshLinkReady,
        SshLinkSeen,
        SshLinkState;
import 'package:test/test.dart';

/// A clock whose timers fire only when the test lets time pass.
final class _Clock {
  DateTime now = DateTime.utc(2026, 10, 15, 12);
  final List<_Timer> _timers = [];

  Timer start(Duration duration, void Function() callback) {
    final timer = _Timer(now.add(duration), callback);
    _timers.add(timer);
    return timer;
  }

  /// Lets [duration] pass, firing due timers in order.
  Future<void> elapse(Duration duration) async {
    final end = now.add(duration);
    while (true) {
      await pumpEventQueue();
      _timers.removeWhere((t) => !t.isActive);
      final due = _timers.where((t) => !t.due.isAfter(end)).toList()
        ..sort((a, b) => a.due.compareTo(b.due));
      if (due.isEmpty) break;
      now = due.first.due;
      due.first.fire();
    }
    now = end;
    await pumpEventQueue();
  }
}

final class _Timer implements Timer {
  _Timer(this.due, this._callback);

  final DateTime due;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

final class _FixedRandom implements Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => throw UnimplementedError();

  @override
  int nextInt(int max) => throw UnimplementedError();
}

final class _Link implements SshLink {
  final _changes = StreamController<SshLinkState>.broadcast();
  @override
  SshLinkState state = const SshLinkReady(SshLinkSeen());
  int closes = 0;

  @override
  Stream<SshLinkState> get states => Stream.multi((controller) {
    controller.add(state);
    final subscription = _changes.stream.listen(controller.add);
    controller.onCancel = subscription.cancel;
  });

  void become(SshLinkState next) => _changes.add(state = next);

  @override
  Future<void> close() async => closes++;

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

/// One dial the supervisor asked for; the test settles it.
final class _Call {
  _Call(this.serverId, this.purpose, this.onPhase, this.abandoned) {
    unawaited(abandoned!.then((_) => wasAbandoned = true));
  }

  final String serverId;
  final ConnectPurpose purpose;
  final void Function(LinkStatus phase)? onPhase;
  final Future<void>? abandoned;
  final _result = Completer<LinkConnectResult>();
  bool wasAbandoned = false;

  void fail(LinkFailureKind? failure) => _result.complete(
    LinkConnectFailed(Exception('failed'), failure: failure),
  );

  _Link succeed({bool keyboardInteractive = false}) {
    final link = _Link();
    _result.complete(
      LinkConnected(link, keyboardInteractive: keyboardInteractive),
    );
    return link;
  }
}

ServerConfig _config(String id) => ServerConfig(
  id: id,
  label: id,
  host: '192.0.2.10',
  port: 22,
  username: 'me',
  authMethod: AuthMethod.agent,
  createdAt: 0,
  updatedAt: 0,
);

const _interactive = ConnectPurpose.interactive;
const _background = ConnectPurpose.background;
const _ownerClosed = LinkClosed(LinkClosedReason.closedByOwner);

LinkClosed _failed(LinkFailureKind? failure) =>
    LinkClosed(LinkClosedReason.connectFailed, failure: failure);

void main() {
  late _Clock clock;
  late List<EngineEvent> events;
  late List<_Call> calls;
  late LinkSupervisor supervisor;

  LinkSupervisor make({
    BackgroundLinkPolicy policy = BackgroundLinkPolicy.keepOpen,
    double random = 0,
  }) => LinkSupervisor(
    connect: (config, {required purpose, onPhase, abandoned}) {
      final call = _Call(config.id, purpose, onPhase, abandoned);
      calls.add(call);
      return call._result.future;
    },
    configFor: (id) => id.startsWith('s') ? _config(id) : null,
    emit: events.add,
    policy: policy,
    startTimer: clock.start,
    now: () => clock.now,
    random: _FixedRandom(random),
  );

  setUp(() {
    clock = _Clock();
    events = [];
    calls = [];
    supervisor = make();
  });

  List<LinkStatus> statuses([String serverId = 's1']) => [
    for (final event in events.whereType<LinkState>())
      if (event.serverId == serverId) event.status,
  ];

  /// Connects s1 interactively and settles the dial with a link.
  Future<_Link> linked({bool keyboardInteractive = false}) async {
    supervisor.connect('s1', purpose: _interactive);
    final link = calls.last.succeed(keyboardInteractive: keyboardInteractive);
    await clock.elapse(Duration.zero);
    return link;
  }

  test('an unknown server is refused', () {
    expect(supervisor.connect('unknown', purpose: _interactive), isFalse);
    expect(calls, isEmpty);
    expect(events, isEmpty);
  });

  test('holds one link per server and passes its states on', () async {
    final link = await linked();
    supervisor.connect('s1', purpose: _interactive);
    supervisor.connect('s1', purpose: _background);
    link.become(
      const SshLinkDegraded(SshLinkDegradedReason.sessionLimitLearned),
    );
    await clock.elapse(Duration.zero);

    expect(calls, hasLength(1));
    expect(supervisor.link('s1'), same(link));
    expect(statuses(), [
      const LinkConnecting(),
      const LinkReady(),
      const LinkDegraded(LinkDegradedReason.sessionLimitLearned),
    ]);
  });

  test('at most four dials run at once, unattended ones after their jitter '
      'and the user\'s ahead of them', () async {
    supervisor = make(random: 0.5);
    for (final id in ['s1', 's2', 's3', 's4', 's5']) {
      supervisor.connect(id, purpose: _background);
    }
    supervisor.connect('s6', purpose: _interactive);

    await clock.elapse(const Duration(milliseconds: 499));
    expect(calls, isEmpty);
    await clock.elapse(const Duration(milliseconds: 1));
    expect(calls.map((c) => c.serverId), ['s1', 's2', 's3', 's4']);

    calls.first.fail(LinkFailureKind.unreachable);
    await clock.elapse(Duration.zero);
    expect(calls.map((c) => c.serverId).skip(4), ['s6']);
    expect(calls.last.purpose, _interactive);
    expect(statuses('s5'), [const LinkConnecting()]);
  });

  test('backs off from 1 s, doubling, and redials unattended; a link '
      'resets the count, and losing it backs off too', () async {
    supervisor.connect('s1', purpose: _interactive);
    calls.last.fail(LinkFailureKind.unreachable);
    await clock.elapse(Duration.zero);
    final firstUntil = clock.now.add(const Duration(seconds: 1));

    await clock.elapse(const Duration(seconds: 1));
    expect(calls.last.purpose, _background);
    calls.last.fail(LinkFailureKind.timedOut);
    await clock.elapse(Duration.zero);
    final secondUntil = clock.now.add(const Duration(seconds: 2));

    await clock.elapse(const Duration(milliseconds: 1999));
    expect(calls, hasLength(2));
    await clock.elapse(const Duration(milliseconds: 1));
    final link = calls.last.succeed();
    await clock.elapse(Duration.zero);
    link.become(const SshLinkClosed(SshLinkClosedReason.pingTimeout));
    await clock.elapse(Duration.zero);

    expect(statuses(), [
      const LinkConnecting(),
      _failed(LinkFailureKind.unreachable),
      LinkBackoff(firstUntil),
      const LinkConnecting(),
      _failed(LinkFailureKind.timedOut),
      LinkBackoff(secondUntil),
      const LinkConnecting(),
      const LinkReady(),
      const LinkClosed(LinkClosedReason.pingTimeout),
      LinkBackoff(clock.now.add(const Duration(seconds: 1))),
    ]);
  });

  for (final failure in <LinkFailureKind?>[
    null,
    LinkFailureKind.authenticationRejected,
    LinkFailureKind.credentialUnavailable,
    LinkFailureKind.hostKeyDeclined,
    LinkFailureKind.unsupportedAlgorithm,
    LinkFailureKind.keyExchangeTimedOut,
  ]) {
    test('${failure?.name ?? 'an unclassified failure'} waits for an '
        'interactive request', () async {
      supervisor.connect('s1', purpose: _background);
      await clock.elapse(Duration.zero);
      calls.last.fail(failure);
      await clock.elapse(const Duration(minutes: 5));
      supervisor.connect('s1', purpose: _background);

      expect(calls, hasLength(1));
      expect(statuses().last, _failed(failure));

      supervisor.connect('s1', purpose: _interactive);
      expect(calls.last.purpose, _interactive);
      expect(calls, hasLength(2));
    });
  }

  test('a changed host key blocks the server', () async {
    supervisor.connect('s1', purpose: _interactive);
    calls.last._result.complete(
      LinkConnectBlocked(LinkBlockedReason.hostKeyChanged, Exception('key')),
    );
    await clock.elapse(const Duration(minutes: 5));
    supervisor.connect('s1', purpose: _interactive);
    supervisor.disconnect('s1');

    expect(calls, hasLength(1));
    expect(
      statuses().last,
      const LinkBlocked(LinkBlockedReason.hostKeyChanged),
    );
  });

  group('the attempt deadline', () {
    test('gives up a stalled attempt as timed out; the redial waits for the '
        'stalled dial, whose late link is closed', () async {
      supervisor.connect('s1', purpose: _interactive);
      final stalled = calls.single;

      await clock.elapse(kConnectAttemptDeadline);
      expect(stalled.wasAbandoned, isTrue);
      expect(statuses().skip(1), [
        _failed(LinkFailureKind.timedOut),
        LinkBackoff(clock.now.add(const Duration(seconds: 1))),
      ]);

      await clock.elapse(const Duration(seconds: 10));
      expect(calls, hasLength(1));

      final late = stalled.succeed();
      await clock.elapse(Duration.zero);
      expect(late.closes, 1);
      expect(calls, hasLength(2));
      expect(supervisor.link('s1'), isNull);
    });

    test('leaves out the time a prompt waits on the user', () async {
      supervisor.connect('s1', purpose: _interactive);
      final call = calls.single;
      const asking = LinkNeedsUser(promptId: 'p1', kind: PromptKind.hostKey);

      await clock.elapse(const Duration(seconds: 30));
      call.onPhase!(asking);
      await clock.elapse(const Duration(minutes: 2));
      call.onPhase!(const LinkAuthenticating());
      await clock.elapse(const Duration(seconds: 59));
      expect(call.wasAbandoned, isFalse);
      await clock.elapse(const Duration(seconds: 1));

      expect(call.wasAbandoned, isTrue);
      expect(statuses().take(4), [
        const LinkConnecting(),
        asking,
        const LinkAuthenticating(),
        _failed(LinkFailureKind.timedOut),
      ]);
    });
  });

  group('disconnect', () {
    test('gives up the attempt and closes the link it brings late, '
        'reporting nothing more for it', () async {
      supervisor.connect('s1', purpose: _interactive);
      final call = calls.single;
      supervisor.disconnect('s1');
      call.onPhase!(const LinkAuthenticating());
      final late = call.succeed();
      await clock.elapse(Duration.zero);

      expect(call.wasAbandoned, isTrue);
      expect(late.closes, 1);
      expect(statuses(), [const LinkConnecting(), _ownerClosed]);
    });

    test('closes a ready link, which is not redialed', () async {
      final link = await linked();
      supervisor.disconnect('s1');
      link.become(const SshLinkClosed(SshLinkClosedReason.closedByOwner));
      await clock.elapse(const Duration(minutes: 1));

      expect(link.closes, 1);
      expect(calls, hasLength(1));
      expect(statuses().last, _ownerClosed);
    });

    test('ends a backoff', () async {
      supervisor.connect('s1', purpose: _interactive);
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      supervisor.disconnect('s1');
      await clock.elapse(const Duration(minutes: 1));

      expect(calls, hasLength(1));
      expect(statuses().last, _ownerClosed);
    });
  });

  group('a user\'s request while an unattended dial runs', () {
    Future<void> askDuringDial() async {
      supervisor.connect('s1', purpose: _background);
      await clock.elapse(Duration.zero);
      supervisor.connect('s1', purpose: _interactive);
    }

    test('takes over when that dial needs the user', () async {
      await askDuringDial();
      calls.single.fail(LinkFailureKind.hostKeyDeclined);
      await clock.elapse(Duration.zero);

      expect(calls.map((c) => c.purpose), [_background, _interactive]);
    });

    test('does not take over a failure no prompt resolves', () async {
      await askDuringDial();
      calls.single.fail(LinkFailureKind.unsupportedAlgorithm);
      await clock.elapse(Duration.zero);

      expect(calls, hasLength(1));
      expect(statuses().last, _failed(LinkFailureKind.unsupportedAlgorithm));
    });

    test('ends when that dial is given up', () async {
      await askDuringDial();
      await clock.elapse(kConnectAttemptDeadline);
      calls.first.fail(LinkFailureKind.unreachable);
      await clock.elapse(const Duration(seconds: 1));
      calls.last.fail(LinkFailureKind.authenticationRejected);
      await clock.elapse(Duration.zero);

      expect(calls.map((c) => c.purpose), [_background, _background]);
    });
  });

  group('a keyboard-interactive server is never dialed unattended', () {
    test('after a disconnect, a lost link or a failed connect', () async {
      await linked(keyboardInteractive: true);
      supervisor.disconnect('s1');
      supervisor.connect('s1', purpose: _background);
      expect(calls, hasLength(1));

      final link = await linked(keyboardInteractive: true);
      link.become(const SshLinkClosed(SshLinkClosedReason.linkLost));
      await clock.elapse(const Duration(minutes: 5));
      supervisor.connect('s1', purpose: _background);
      expect(calls, hasLength(2));
      expect(statuses().last, const LinkClosed(LinkClosedReason.linkLost));

      supervisor.connect('s1', purpose: _interactive);
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(const Duration(minutes: 5));
      expect(calls, hasLength(3));
      expect(statuses().last, _failed(LinkFailureKind.unreachable));
    });

    test('after the background grace period', () async {
      supervisor = make(policy: BackgroundLinkPolicy.closeAfterGrace);
      await linked(keyboardInteractive: true);
      supervisor.setActivity(AppActivity.background);
      await clock.elapse(kBackgroundGracePeriod);
      supervisor.setActivity(AppActivity.foreground);
      await clock.elapse(const Duration(minutes: 5));

      expect(calls, hasLength(1));
      expect(statuses().last, _ownerClosed);
      supervisor.connect('s1', purpose: _interactive);
      expect(calls, hasLength(2));
    });

    test('once a connect asked its questions, even if it failed', () async {
      supervisor.connect('s1', purpose: _interactive);
      calls.last.onPhase!(
        const LinkNeedsUser(
          promptId: 'p1',
          kind: PromptKind.keyboardInteractive,
        ),
      );
      calls.last.onPhase!(const LinkAuthenticating());
      calls.last.fail(LinkFailureKind.timedOut);
      await clock.elapse(const Duration(minutes: 5));

      expect(calls, hasLength(1));
    });
  });

  group('in the background', () {
    test('no attempt starts, and a desktop keeps its links', () async {
      final link = await linked();
      supervisor.setActivity(AppActivity.background);
      supervisor.connect('s2', purpose: _background);
      await clock.elapse(const Duration(minutes: 5));

      expect(calls, hasLength(1));
      expect(link.closes, 0);
      expect(statuses('s2'), [const LinkConnecting()]);

      supervisor.setActivity(AppActivity.foreground);
      await clock.elapse(Duration.zero);
      expect(calls.map((c) => c.serverId), ['s1', 's2']);
    });

    test(
      'a phone closes its links after 30 s and redials them on return',
      () async {
        supervisor = make(policy: BackgroundLinkPolicy.closeAfterGrace);
        final link = await linked();

        supervisor.setActivity(AppActivity.background);
        await clock.elapse(const Duration(seconds: 10));
        supervisor.setActivity(AppActivity.foreground);
        supervisor.setActivity(AppActivity.background);
        await clock.elapse(const Duration(seconds: 29));
        expect(link.closes, 0);
        await clock.elapse(const Duration(seconds: 1));
        expect(link.closes, 1);
        expect(statuses().last, _ownerClosed);

        supervisor.setActivity(AppActivity.foreground);
        await clock.elapse(Duration.zero);
        expect(calls.map((c) => c.purpose), [_interactive, _background]);
      },
    );
  });
}
