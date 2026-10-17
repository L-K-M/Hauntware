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
      final due = _timers.where((t) => !t.due.isAfter(end));
      if (due.isEmpty) break;
      // The earliest, first started among equals, as real timers fire:
      // List.sort is not guaranteed to be stable.
      final next = due.reduce((a, b) => b.due.isBefore(a.due) ? b : a);
      now = next.due;
      next.fire();
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
  _Call(
    this.serverId,
    this.purpose,
    this.changedKey,
    this.onPhase,
    this.onDialing,
    this.abandoned,
  ) {
    unawaited(abandoned!.then((_) => wasAbandoned = true));
  }

  final String serverId;
  final ConnectPurpose purpose;
  final ChangedHostKey changedKey;
  final void Function(LinkStatus phase)? onPhase;
  final void Function()? onDialing;
  final Future<void>? abandoned;
  final _result = Completer<LinkConnectResult>();
  bool wasAbandoned = false;

  void block(LinkBlockedReason reason) =>
      _result.complete(LinkConnectBlocked(reason, Exception('blocked')));

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
  final gone = <String>{};

  LinkSupervisor make({
    BackgroundLinkPolicy policy = BackgroundLinkPolicy.keepOpen,
    double random = 0,
  }) => LinkSupervisor(
    connect:
        (
          config, {
          required purpose,
          required changedKey,
          onPhase,
          onDialing,
          abandoned,
        }) {
          final call = _Call(
            config.id,
            purpose,
            changedKey,
            onPhase,
            onDialing,
            abandoned,
          );
          calls.add(call);
          return call._result.future;
        },
    configFor: (id) =>
        id.startsWith('s') && !gone.contains(id) ? _config(id) : null,
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
    gone.clear();
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

  test('the test clock fires timers due at once in start order', () async {
    // The dial order tests rely on this, as with real timers. More than
    // the 33 timers List.sort happens to keep in order today.
    final fired = <int>[];
    for (var i = 0; i < 40; i++) {
      clock.start(const Duration(seconds: 1), () => fired.add(i));
    }

    await clock.elapse(const Duration(seconds: 1));
    expect(fired, [for (var i = 0; i < 40; i++) i]);
  });

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

  test('the user\'s request moves a queued unattended attempt ahead, and '
      'one in its slot dials at once', () async {
    supervisor = make(random: 0.5);
    for (final id in ['s1', 's2', 's3', 's4', 's5', 's6']) {
      supervisor.connect(id, purpose: _background);
    }
    supervisor.connect('s1', purpose: _interactive);
    supervisor.connect('s6', purpose: _interactive);
    await clock.elapse(Duration.zero);
    expect(calls.map((c) => (c.serverId, c.purpose)), [('s1', _interactive)]);

    calls.single.fail(LinkFailureKind.unreachable);
    await clock.elapse(Duration.zero);
    expect((calls.last.serverId, calls.last.purpose), ('s6', _interactive));
  });

  test('a server that leaves the fleet before its dial is closed, and its '
      'slot goes to the next attempt', () async {
    supervisor = make(random: 0.5);
    for (final id in ['s1', 's2', 's3', 's4', 's5']) {
      supervisor.connect(id, purpose: _background);
    }
    gone.add('s1');
    await clock.elapse(kConnectJitter);

    expect(calls.map((c) => c.serverId), ['s2', 's3', 's4', 's5']);
    expect(statuses(), [const LinkConnecting(), _ownerClosed]);
  });

  test('a given-up dial keeps its slot until it returns once it is on its '
      'way to the network', () async {
    for (final id in ['s1', 's2', 's3', 's4', 's5', 's6']) {
      supervisor.connect(id, purpose: _interactive);
    }
    calls[0].onDialing!();
    supervisor.disconnect('s1');
    supervisor.disconnect('s2');
    await clock.elapse(Duration.zero);
    expect(calls.map((c) => c.serverId).skip(4), ['s5']);

    calls[0].fail(LinkFailureKind.unreachable);
    await clock.elapse(Duration.zero);
    expect(calls.map((c) => c.serverId).skip(4), ['s5', 's6']);
  });

  test('backs off from 1 s, doubling, and redials unattended; a link '
      'resets the count, and losing it backs off too', () async {
    supervisor.connect('s1', purpose: _interactive);
    calls.last.fail(LinkFailureKind.unreachable);
    await clock.elapse(Duration.zero);
    final firstUntil = clock.now.add(const Duration(seconds: 1));
    // An unattended request does not cut the backoff short.
    supervisor.connect('s1', purpose: _background);
    await clock.elapse(const Duration(milliseconds: 999));
    expect(calls, hasLength(1));

    await clock.elapse(const Duration(milliseconds: 1));
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
    LinkFailureKind.keyPassphraseRequired,
    LinkFailureKind.keyFileHiddenBySandbox,
    LinkFailureKind.hostKeyDeclined,
    LinkFailureKind.unsupportedAlgorithm,
    LinkFailureKind.insecureAlgorithmsOnly,
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

  group('a changed host key (D61)', () {
    const blocked = LinkBlocked(LinkBlockedReason.hostKeyChanged);

    setUp(() async {
      supervisor.connect('s1', purpose: _interactive);
      expect(calls.single.changedKey, ChangedHostKey.block);
      calls.single.block(LinkBlockedReason.hostKeyChanged);
      await clock.elapse(const Duration(minutes: 5));
    });

    test('blocks the server: nothing unattended dials', () async {
      supervisor.connect('s1', purpose: _background);
      supervisor.setActivity(AppActivity.background);
      supervisor.setActivity(AppActivity.foreground);
      await clock.elapse(const Duration(minutes: 5));

      expect(calls, hasLength(1));
      expect(statuses().last, blocked);
    });

    test('the user\'s next connect reviews the key, and trusting it '
        'connects', () async {
      supervisor.connect('s1', purpose: _interactive);
      expect(calls, hasLength(2));
      expect(
        (calls.last.purpose, calls.last.changedKey),
        (_interactive, ChangedHostKey.review),
      );
      expect(statuses().last, const LinkConnecting());

      calls.last.succeed();
      await clock.elapse(Duration.zero);
      expect(statuses().last, const LinkReady());

      // The block is gone: the link is held like any other.
      supervisor.connect('s1', purpose: _interactive);
      expect(calls, hasLength(2));
    });

    test('a declined review blocks again, and only the next user connect '
        'reviews again', () async {
      supervisor.connect('s1', purpose: _interactive);
      calls.last.block(LinkBlockedReason.hostKeyChanged);
      await clock.elapse(Duration.zero);
      expect(statuses().last, blocked);

      supervisor.connect('s1', purpose: _background);
      expect(calls, hasLength(2));
      supervisor.connect('s1', purpose: _interactive);
      expect(calls, hasLength(3));
      expect(calls.last.changedKey, ChangedHostKey.review);
    });

    test('a review given up undecided keeps the block', () async {
      supervisor.connect('s1', purpose: _interactive);
      final review = calls.last;
      supervisor.disconnect('s1');
      await clock.elapse(Duration.zero);

      expect(review.wasAbandoned, isTrue);
      expect(statuses().last, blocked);
      supervisor.connect('s1', purpose: _background);
      expect(calls, hasLength(2));
    });

    test('a review given up after trusting the key leaves no block', () async {
      supervisor.connect('s1', purpose: _interactive);
      final review = calls.last..onPhase!(const LinkAuthenticating());
      supervisor.disconnect('s1');
      await clock.elapse(Duration.zero);

      expect(statuses().last, const LinkClosed(LinkClosedReason.closedByOwner));
      // The given-up dial returns before the next one starts.
      review.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      supervisor.connect('s1', purpose: _background);
      await clock.elapse(const Duration(seconds: 5));
      expect(calls, hasLength(3));
      expect(
        (calls.last.purpose, calls.last.changedKey),
        (_background, ChangedHostKey.block),
      );
    });

    test('a review that fails otherwise follows the usual rules', () async {
      supervisor.connect('s1', purpose: _interactive);
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      expect(statuses().last, isA<LinkBackoff>());

      // The redial is unattended, so the still-changed key blocks it.
      await clock.elapse(const Duration(seconds: 1));
      expect(
        (calls.last.purpose, calls.last.changedKey),
        (_background, ChangedHostKey.block),
      );
    });
  });

  test('a changed endpoint stays blocked on the user\'s connect', () async {
    supervisor.connect('s1', purpose: _interactive);
    calls.single.block(LinkBlockedReason.endpointChanged);
    await clock.elapse(Duration.zero);
    supervisor.connect('s1', purpose: _interactive);

    expect(calls, hasLength(1));
    expect(
      statuses().last,
      const LinkBlocked(LinkBlockedReason.endpointChanged),
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

    test('frees the slot of an attempt not on the network yet', () async {
      for (final id in ['s1', 's2', 's3', 's4', 's5']) {
        supervisor.connect(id, purpose: _interactive);
      }
      await clock.elapse(kConnectAttemptDeadline);

      expect(calls.map((c) => c.serverId).skip(4), ['s5']);
    });

    test('also gives up an attempt waiting for the stalled dial', () async {
      supervisor.connect('s1', purpose: _interactive);
      await clock.elapse(kConnectAttemptDeadline);
      supervisor.connect('s1', purpose: _interactive);
      await clock.elapse(kConnectAttemptDeadline);

      expect(calls, hasLength(1));
      expect(statuses().skip(3), [
        const LinkConnecting(),
        _failed(LinkFailureKind.timedOut),
        LinkBackoff(clock.now.add(const Duration(seconds: 2))),
      ]);
    });

    test('leaves out a slot wait after the stalled dial returns', () async {
      supervisor.connect('s1', purpose: _interactive);
      await clock.elapse(kConnectAttemptDeadline);
      supervisor.connect('s1', purpose: _interactive);
      await clock.elapse(const Duration(seconds: 10));
      for (final id in ['s2', 's3', 's4', 's5']) {
        supervisor.connect(id, purpose: _interactive);
      }
      calls.first.fail(LinkFailureKind.unreachable);
      await clock.elapse(const Duration(seconds: 55));

      expect(statuses().skip(3), [const LinkConnecting()]);
    });

    test('runs on through a phase without a prompt', () async {
      supervisor.connect('s1', purpose: _interactive);
      await clock.elapse(const Duration(seconds: 30));
      calls.single.onPhase!(const LinkAuthenticating());
      await clock.elapse(const Duration(seconds: 30));

      expect(calls.single.wasAbandoned, isTrue);
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

  group('forget, for a server that left the fleet', () {
    test('closes its link and reports nothing', () async {
      final link = await linked();
      gone.add('s1');
      supervisor.forget(['s1']);
      link.become(const SshLinkClosed(SshLinkClosedReason.closedByOwner));
      await clock.elapse(const Duration(minutes: 5));

      expect(link.closes, 1);
      expect(supervisor.link('s1'), isNull);
      expect(calls, hasLength(1));
      expect(statuses(), [const LinkConnecting(), const LinkReady()]);
    });

    test('gives up its attempt and backoff, and closes a link the attempt '
        'brings late', () async {
      supervisor.connect('s1', purpose: _interactive);
      final call = calls.single;
      supervisor.connect('s2', purpose: _interactive);
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      gone.addAll(['s1', 's2']);
      supervisor.forget(['s1', 's2']);
      final late = call.succeed();
      await clock.elapse(const Duration(minutes: 5));

      expect(call.wasAbandoned, isTrue);
      expect(late.closes, 1);
      expect(calls, hasLength(2), reason: 's2 is not redialed');
      expect(statuses(), [const LinkConnecting()]);
      expect(statuses('s2'), [
        const LinkConnecting(),
        _failed(LinkFailureKind.unreachable),
        isA<LinkBackoff>(),
      ]);
    });

    test('keeps nothing it learned, so a server that comes back starts '
        'over', () async {
      supervisor.connect('s1', purpose: _interactive);
      calls.last._result.complete(
        LinkConnectBlocked(LinkBlockedReason.hostKeyChanged, Exception('key')),
      );
      await clock.elapse(Duration.zero);
      supervisor.forget(['s1']);
      supervisor.connect('s1', purpose: _interactive);
      expect(calls, hasLength(2), reason: 'no longer blocked');

      calls.last.succeed(keyboardInteractive: true);
      await clock.elapse(Duration.zero);
      supervisor.forget(['s1']);
      supervisor.connect('s1', purpose: _background);
      await clock.elapse(kConnectJitter);
      expect(calls, hasLength(3), reason: 'dialed unattended again');

      // Two failures in, a server that comes back backs off from 1 s.
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(const Duration(seconds: 1));
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      supervisor.forget(['s1']);
      events.clear();
      supervisor.connect('s1', purpose: _interactive);
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);

      expect(statuses(), [
        const LinkConnecting(),
        _failed(LinkFailureKind.unreachable),
        LinkBackoff(clock.now.add(const Duration(seconds: 1))),
      ]);
    });

    test('a dial on its way to the network still holds the server\'s next '
        'attempt until it returns', () async {
      supervisor.connect('s1', purpose: _interactive);
      final first = calls.single..onDialing!();
      supervisor.forget(['s1']);
      supervisor.connect('s1', purpose: _interactive);
      await clock.elapse(Duration.zero);
      expect(calls, hasLength(1));

      final late = first.succeed();
      await clock.elapse(Duration.zero);
      expect(late.closes, 1);
      expect(calls, hasLength(2));
      // Forgetting reported nothing, so the comeback reports connecting.
      expect(statuses(), [const LinkConnecting(), const LinkConnecting()]);
    });

    test('a dial on its way keeps nothing learned either: the server that '
        'comes back before it returns starts over', () async {
      supervisor.connect('s1', purpose: _interactive);
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      supervisor.connect('s1', purpose: _interactive);
      // One failure in, and asked keyboard-interactive questions.
      final pending = calls.last
        ..onPhase!(
          const LinkNeedsUser(
            promptId: 'p1',
            kind: PromptKind.keyboardInteractive,
          ),
        );
      supervisor
        ..forget(['s1'])
        ..connect('s1', purpose: _background);
      pending.fail(null);
      await clock.elapse(Duration.zero);
      expect(calls, hasLength(3), reason: 'dialed unattended again');
      expect(calls.last.purpose, _background);

      events.clear();
      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      expect(statuses(), [
        _failed(LinkFailureKind.unreachable),
        LinkBackoff(clock.now.add(const Duration(seconds: 1))),
      ]);
    });

    test('a server that comes back waits for a slot without a deadline once '
        'its old dial returns', () async {
      // Dials waiting on the user hold their slots with no deadline.
      void ask(_Call call) => call.onPhase!(
        LinkNeedsUser(promptId: call.serverId, kind: PromptKind.hostKey),
      );
      for (final id in ['s1', 's2', 's3', 's4']) {
        supervisor.connect(id, purpose: _interactive);
      }
      final old = calls.first..onDialing!();
      calls.skip(1).forEach(ask);
      supervisor
        ..forget(['s1'])
        ..connect('s9', purpose: _interactive)
        // Queued behind s9, with a deadline while the old dial runs.
        ..connect('s1', purpose: _interactive);
      await clock.elapse(const Duration(seconds: 10));
      old.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      expect(calls.map((c) => c.serverId).skip(4), ['s9']);
      ask(calls.last);

      await clock.elapse(kConnectAttemptDeadline);
      expect(statuses(), [const LinkConnecting(), const LinkConnecting()]);

      calls.last.fail(LinkFailureKind.unreachable);
      await clock.elapse(Duration.zero);
      expect(calls.map((c) => c.serverId).skip(5), ['s1']);
    });

    test('several go together: a slot one frees does not dial another\'s '
        'queued attempt', () async {
      final servers = [
        for (var i = 1; i <= kMaxConnectsInFlight + 1; i++) 's$i',
      ];
      for (final serverId in servers) {
        supervisor.connect(serverId, purpose: _interactive);
      }
      expect(calls, hasLength(kMaxConnectsInFlight));
      final queued = servers.last;
      gone.addAll(['s1', queued]);
      supervisor.forget(['s1', queued]);
      await clock.elapse(const Duration(minutes: 5));

      expect(calls, hasLength(kMaxConnectsInFlight));
      expect(statuses(queued), [const LinkConnecting()]);
    });

    test('a server it does not hold is ignored', () {
      supervisor.forget(['s1']);
      expect(events, isEmpty);
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

    // No prompt asks for a passphrase until K45b, so the user's attempt
    // would fail the same way.
    test('does not take over a key that needs a passphrase, and nothing '
        'redials it', () async {
      await askDuringDial();
      calls.single.fail(LinkFailureKind.keyPassphraseRequired);
      await clock.elapse(const Duration(minutes: 5));
      supervisor.connect('s1', purpose: _background);
      await clock.elapse(const Duration(minutes: 5));

      expect(calls, hasLength(1));
      expect(statuses().last, _failed(LinkFailureKind.keyPassphraseRequired));
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
      await clock.elapse(kConnectJitter);
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

    test('an attempt in its slot does not dial either', () async {
      supervisor = make(random: 0.5);
      supervisor.connect('s1', purpose: _background);
      supervisor.connect('s2', purpose: _background);
      supervisor.setActivity(AppActivity.background);
      supervisor.connect('s2', purpose: _interactive);
      await clock.elapse(const Duration(minutes: 5));
      expect(calls, isEmpty);

      supervisor.setActivity(AppActivity.foreground);
      await clock.elapse(const Duration(seconds: 1));
      expect(calls.map((c) => (c.serverId, c.purpose)), [
        ('s2', _interactive),
        ('s1', _background),
      ]);
    });

    test(
      'a phone closes its links after 30 s and redials them on return',
      () async {
        supervisor = make(policy: BackgroundLinkPolicy.closeAfterGrace);
        final link = await linked();
        supervisor.connect('s2', purpose: _interactive);
        calls.last.succeed();

        supervisor.setActivity(AppActivity.background);
        await clock.elapse(const Duration(seconds: 10));
        supervisor.setActivity(AppActivity.foreground);
        supervisor.setActivity(AppActivity.background);
        await clock.elapse(const Duration(seconds: 29));
        expect(link.closes, 0);
        await clock.elapse(const Duration(seconds: 1));
        expect(link.closes, 1);
        expect(statuses().last, _ownerClosed);
        // One disconnected meanwhile stays closed.
        supervisor.disconnect('s2');

        supervisor.setActivity(AppActivity.foreground);
        await clock.elapse(Duration.zero);
        expect(calls.map((c) => (c.serverId, c.purpose)), [
          ('s1', _interactive),
          ('s2', _interactive),
          ('s1', _background),
        ]);
      },
    );
  });

  group('a dead-peer hint (K22)', () {
    const pingTimeout = LinkClosed(LinkClosedReason.pingTimeout);

    test('closes a link that stays silent for the grace, which then backs '
        'off and redials as after a lost link', () async {
      final link = await linked();
      supervisor.deadPeerHint('s1', link);
      // A second hint while the first runs keeps its deadline.
      await clock.elapse(const Duration(seconds: 10));
      supervisor.deadPeerHint('s1', link);

      await clock.elapse(
        kDeadPeerGrace - const Duration(seconds: 10, milliseconds: 1),
      );
      expect(link.closes, 0);
      await clock.elapse(const Duration(milliseconds: 1));
      expect(link.closes, 1);
      expect(supervisor.link('s1'), isNull);
      expect(statuses().skip(2), [
        pingTimeout,
        LinkBackoff(clock.now.add(const Duration(seconds: 1))),
      ]);

      await clock.elapse(const Duration(seconds: 1));
      expect(calls.map((c) => (c.serverId, c.purpose)), [
        ('s1', _interactive),
        ('s1', _background),
      ]);
    });

    test('cleared in time keeps the link, and a hint about another link '
        'changes nothing', () async {
      final link = await linked();
      supervisor.deadPeerHint('s1', link);
      await clock.elapse(const Duration(seconds: 19));
      supervisor.clearDeadPeerHint('s1', link);
      supervisor.deadPeerHint('s1', _Link());
      supervisor.deadPeerHint('s2', link);

      await clock.elapse(const Duration(minutes: 1));
      expect(link.closes, 0);
      expect(statuses(), [const LinkConnecting(), const LinkReady()]);
    });

    test('ends with a link lost underneath, so the redialed link\'s hint '
        'runs a grace of its own', () async {
      final lost = await linked();
      supervisor.deadPeerHint('s1', lost);
      lost.become(const SshLinkClosed(SshLinkClosedReason.linkLost));
      await clock.elapse(Duration.zero);
      await clock.elapse(const Duration(seconds: 1));
      final redial = calls.last.succeed();
      await clock.elapse(Duration.zero);

      supervisor.deadPeerHint('s1', redial);
      await clock.elapse(kDeadPeerGrace);
      expect(redial.closes, 1);
      expect(statuses().where((s) => s == pingTimeout), hasLength(1));
    });

    test('ends with a link its owner closes, so the next link\'s hint runs '
        'a grace of its own', () async {
      final first = await linked();
      supervisor.deadPeerHint('s1', first);
      await clock.elapse(const Duration(seconds: 10));
      supervisor.disconnect('s1');
      expect(statuses().last, _ownerClosed);

      final next = await linked();
      supervisor.deadPeerHint('s1', next);
      await clock.elapse(kDeadPeerGrace);
      expect(next.closes, 1);
      expect(statuses().where((s) => s == pingTimeout), hasLength(1));
    });
  });
}
