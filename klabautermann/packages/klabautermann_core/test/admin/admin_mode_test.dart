// Admin mode's state machine (03 §8.2, M4 plan M5) over a scripted sudo:
// detection from the probe's facts, the password prompt and its retries,
// rung 4 under `timestamp_timeout=0`, the refusals that need no prompt,
// every way admin mode ends, and that the password stays in the engine.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/links/prompt_broker.dart';
import 'package:seance_core/seance_core.dart' show RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';
const _password = 'correct-horse-staple';

/// A sudo 1.9 host whose prelude accepts [_password]; with [cachesNothing]
/// it validates but finds no record (`timestamp_timeout=0`), so only the
/// rung-4 `sudo -S` runs the command.
final class _SudoLink extends TestLinkBase {
  _SudoLink({this.cachesNothing = false});

  final bool cachesNothing;
  final commands = <String>[];

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    final line = utf8.decode(stdin ?? const []).split('\n').first;
    if (command.contains('sudo -n -- ') && !command.contains(' elevate ')) {
      return const RemoteCommandResult(exitCode: 0);
    }
    if (command.contains(' elevate ')) {
      if (line != _password) {
        return const RemoteCommandResult(
          exitCode: 125,
          stderr: 'Sorry, try again.\nsudo: 1 incorrect password attempt\n',
        );
      }
      return cachesNothing
          ? const RemoteCommandResult(
              exitCode: 1,
              stderr: 'sudo: a password is required\n',
            )
          : const RemoteCommandResult(exitCode: 0);
    }
    if (command.contains("sudo -S -p ''")) {
      return RemoteCommandResult(exitCode: line == _password ? 0 : 1);
    }
    throw StateError('unscripted command: $command');
  }
}

HostProfile _profile({
  String? sudo = 'Sudo version 1.9.16p2',
  bool sudoNopasswd = false,
  bool doas = false,
  bool doasNopasswd = false,
  int uid = 1000,
}) => HostProfile(
  uid: uid,
  user: 'deploy',
  sudoVersionLine: sudo,
  sudoNonInteractive: sudo == null ? null : sudoNopasswd,
  doasPresent: doas,
  doasNonInteractive: doas ? doasNopasswd : null,
  printfBuiltin: true,
);

final class _FakeTimer implements Timer {
  _FakeTimer(this.duration, this.callback);

  final Duration duration;
  final void Function() callback;
  var cancelled = false;

  void fire() => callback();

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled;

  @override
  int get tick => 0;
}

void main() {
  late List<EngineEvent> events;
  late PromptBroker prompts;
  late List<_FakeTimer> timers;
  late DateTime now;
  late _SudoLink link;

  AdminModeController controller({_SudoLink? over, bool withLink = true}) {
    link = over ?? _SudoLink();
    final admin = AdminModeController(
      linkFor: (_) => withLink ? link : null,
      endpointOf: (_) => (host: 'web-1', port: 22, user: 'deploy'),
      prompts: prompts,
      emit: events.add,
      now: () => now,
      startTimer: (duration, callback) {
        final timer = _FakeTimer(duration, callback);
        timers.add(timer);
        return timer;
      },
    );
    return admin;
  }

  setUp(() {
    events = [];
    timers = [];
    now = DateTime.utc(2026, 10, 18, 12);
    prompts = PromptBroker(
      emit: events.add,
      startTimer: (_, _) => _FakeTimer(Duration.zero, () {}),
    );
  });

  List<AdminModeState> states() => events.whereType<AdminModeState>().toList();

  /// Answers the newest open prompt with [secret], then lets the
  /// controller run.
  Future<void> answer(String? secret) async {
    final prompt = events.whereType<Prompt>().last;
    expect(prompt.request, isA<ElevationPromptRequest>());
    prompts.answer(prompt.promptId, PromptSecretAnswer(secret));
    await pumpEventQueue();
  }

  test('asks for the password, retries a wrong one, and turns on', () async {
    final admin = controller()..probed(_server, _profile());
    unawaited(admin.enable(_server));
    await pumpEventQueue();

    expect(
      (events.whereType<Prompt>().single.request as ElevationPromptRequest)
          .user,
      'deploy',
    );
    await answer('wrong-guess');
    final retry =
        events.whereType<Prompt>().last.request as ElevationPromptRequest;
    expect(retry.retry, isTrue);
    await answer(_password);

    expect(
      [for (final s in states()) s.phase],
      [
        AdminModePhase.detecting,
        AdminModePhase.awaitingPassword,
        AdminModePhase.validating,
        AdminModePhase.awaitingPassword,
        AdminModePhase.validating,
        AdminModePhase.on,
      ],
    );
    expect(states()[3].retry, isTrue);
    expect(states().last.expiresAt, now.add(kDefaultAdminExpiry));
    expect(admin.session(_server)?.password, _password);
  });

  test('takes rung 4 when the host caches nothing', () async {
    final admin = controller(over: _SudoLink(cachesNothing: true))
      ..probed(_server, _profile());
    unawaited(admin.enable(_server));
    await pumpEventQueue();
    await answer(_password);

    expect(states().last.phase, AdminModePhase.on);
    expect(link.commands, hasLength(2));
    expect(link.commands.last, contains("sudo -S -p ''"));
  });

  test('turns on without a prompt under a blanket NOPASSWD rule', () async {
    final admin = controller()..probed(_server, _profile(sudoNopasswd: true));
    await admin.enable(_server);

    expect(events.whereType<Prompt>(), isEmpty);
    expect(states().last.phase, AdminModePhase.on);
    expect(admin.session(_server)?.password, isNull);
  });

  test('doas with a password needs a terminal, and nothing is asked', () async {
    final admin = controller()
      ..probed(_server, _profile(sudo: null, doas: true));
    await admin.enable(_server);

    expect(events.whereType<Prompt>(), isEmpty);
    expect(states().last.phase, AdminModePhase.failed);
    expect(states().last.failure, AdminFailure.ttyRequired);
    expect(link.commands, isEmpty);
  });

  test('fails after three wrong passwords, or a cancelled prompt', () async {
    final admin = controller()..probed(_server, _profile());
    unawaited(admin.enable(_server));
    await pumpEventQueue();
    for (var i = 0; i < kAdminPasswordAttempts; i++) {
      await answer('wrong-$i');
    }
    expect(states().last.failure, AdminFailure.wrongPassword);
    expect(admin.session(_server), isNull);

    unawaited(admin.enable(_server));
    await pumpEventQueue();
    await answer(null);
    expect(states().last.failure, AdminFailure.cancelled);
  });

  test('without a link or a probe it fails at once', () async {
    final admin = controller(withLink: false)..probed(_server, _profile());
    await admin.enable(_server);
    expect(states().last.failure, AdminFailure.noLink);

    final unprobed = controller();
    await unprobed.enable('srv-2');
    expect(states().last.failure, AdminFailure.notProbed);
  });

  group('ends', () {
    late AdminModeController admin;

    setUp(() async {
      admin = controller()..probed(_server, _profile(sudoNopasswd: true));
      await admin.enable(_server);
      expect(admin.session(_server), isNotNull);
    });

    void expectEnded(AdminEnd end) {
      expect(states().last.phase, AdminModePhase.expired);
      expect(states().last.ended, end);
      expect(admin.session(_server), isNull);
      expect(timers.every((t) => t.cancelled || t == timers.last), isTrue);
    }

    test('after the expiry without elevated work, which touch resets', () {
      now = now.add(const Duration(minutes: 10));
      admin.touch(_server);
      expect(timers.first.cancelled, isTrue);
      expect(states().last.expiresAt, now.add(kDefaultAdminExpiry));

      timers.last.fire();
      expectEnded(AdminEnd.inactivity);
    });

    test('when the app goes to the background', () {
      admin.setActivity(AppActivity.foreground);
      expect(admin.session(_server), isNotNull);
      admin.setActivity(AppActivity.background);
      expectEnded(AdminEnd.background);
    });

    test('when the link drops', () {
      admin.linkLost(_server);
      expectEnded(AdminEnd.linkLost);
    });

    test('when the server leaves the fleet', () {
      admin.forget({_server});
      expectEnded(AdminEnd.serverRemoved);
    });

    test('when turned off, and a disabled prompt is withdrawn', () async {
      admin.disable(_server);
      expect(states().last.phase, AdminModePhase.off);

      final asking = controller()..probed('srv-2', _profile());
      unawaited(asking.enable('srv-2'));
      await pumpEventQueue();
      asking.disable('srv-2');
      await pumpEventQueue();
      expect(events.whereType<PromptWithdrawn>(), hasLength(1));
      expect(states().last.phase, AdminModePhase.off);
    });
  });

  test('the password reaches neither an event, argv nor a toString', () async {
    final admin = controller()..probed(_server, _profile());
    unawaited(admin.enable(_server));
    await pumpEventQueue();
    await answer(_password);

    expect(states().last.phase, AdminModePhase.on);
    for (final event in events) {
      expect('$event', isNot(contains(_password)));
      if (event is AdminModeState) {
        expect([
          event.serverId,
          '${event.expiresAt}',
          '${event.failure}',
        ], everyElement(isNot(contains(_password))));
      }
    }
    for (final command in link.commands) {
      expect(command, isNot(contains(_password)));
    }
    expect('${admin.session(_server)}', isNot(contains(_password)));
  });

  test('reads the probe\'s facts as the executor needs them', () {
    final probe = elevationProbeOf(_profile(uid: 0));
    expect(probe.isRoot, isTrue);
    expect(needsPassword(probe), isFalse);
    expect(needsPassword(elevationProbeOf(_profile())), isTrue);
    final rs = elevationProbeOf(_profile(sudo: 'sudo-rs 0.2.13-0ubuntu1'));
    expect(rs.sudoIsRs, isTrue);
    expect(
      elevationProbeOf(
        _profile(sudo: null, doas: true, doasNopasswd: true),
      ).doasNopasswd,
      isTrue,
    );
  });
}
