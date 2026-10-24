// Actions through a fixture engine (M4 E28, E29): plan an intent, run
// the plan with the confirmation its tier asks for, and read how it
// ended, as the app's action preview does.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

import 'fixture.dart';

/// Covers a plan's reads and a run's steps over the link, a systemctl
/// job or a Docker request included.
const actionWait = Duration(seconds: 60);

/// Covers sudo's delay after each wrong password (pam_faildelay) and the
/// validation runs that follow.
const _adminWait = Duration(seconds: 60);

/// Turns management on for [servers], so their plans may run; every other
/// server stays observe-only (SAF-01). The host syslog line (SAF-13) is
/// off unless [hostAuditLine], so a plan holds only its action's steps.
void manage(
  FixtureEngine engine,
  Iterable<String> servers, {
  bool hostAuditLine = false,
}) => engine.send(
  SetSafetyPolicy(
    SafetyPolicy(
      servers: {
        for (final server in servers)
          server: ServerSafety(management: true, hostAuditLine: hostAuditLine),
      },
    ),
  ),
);

/// Plans [intent] and returns the engine's answer: an [ActionPlanned] or
/// an [ActionRefused].
Future<EngineEvent> planAnswer(
  FixtureEngine engine,
  ActionIntent intent,
) async {
  engine.send(PlanAction(intent));
  return engine.until<EngineEvent>(
    (e) => e is ActionPlanned || (e is ActionRefused && e.intent != null),
    actionWait,
  );
}

/// Plans [intent]; a refusal fails the test.
Future<ActionPlanned> plan(FixtureEngine engine, ActionIntent intent) async {
  final answer = await planAnswer(engine, intent);
  if (answer case ActionRefused(:final reason)) fail('refused: $reason');
  return answer as ActionPlanned;
}

/// The confirmation [preview]'s tier asks for, the target's name typed
/// where it must be.
ActionConfirmation confirmationFor(ActionPreview preview) => ActionConfirmation(
  tier: preview.requiredTier,
  phrase: preview.requiredTier == ConfirmationTier.typedPhrase
      ? preview.targetName
      : null,
);

/// Runs [planned] with [confirmation], by default the one its tier asks
/// for, and returns how it finished or why it was refused.
Future<EngineEvent> run(
  FixtureEngine engine,
  ActionPlanned planned, {
  ActionConfirmation? confirmation,
}) {
  engine.send(
    RunAction(planned.planId, confirmation ?? confirmationFor(planned.preview)),
  );
  return engine.until<EngineEvent>(
    (e) => switch (e) {
      ActionFinished(:final planId) ||
      ActionRefused(:final planId?) => planId == planned.planId,
      _ => false,
    },
    actionWait,
  );
}

/// Plans [intent] and runs it with the confirmation its tier asks for,
/// expecting it to succeed; returns how it finished.
Future<ActionFinished> planAndRun(
  FixtureEngine engine,
  ActionIntent intent,
) async {
  final finished = await run(engine, await plan(engine, intent));
  expectSucceeded(finished);
  return finished as ActionFinished;
}

/// Expects [event] to be a plan that succeeded.
void expectSucceeded(EngineEvent event) {
  expect(
    event,
    isA<ActionFinished>().having(
      (f) => (f.outcome, f.failure, f.exitCode, f.httpStatus),
      'outcome',
      (ActionOutcome.succeeded, null, null, null),
    ),
  );
}

/// Turns admin mode on for [serverId], answering each elevation prompt
/// with the next of [answers], and returns the state it settles in with
/// the prompts it asked.
Future<(AdminModeState, List<ElevationPromptRequest>)> turnOnAdmin(
  FixtureEngine engine,
  String serverId,
  List<String> answers,
) async {
  final asked = <ElevationPromptRequest>[];
  engine.send(SetAdminMode(serverId, enabled: true));
  while (true) {
    final event = await engine.until<EngineEvent>(
      (e) => switch (e) {
        Prompt(serverId: final s, request: ElevationPromptRequest()) =>
          s == serverId,
        AdminModeState(serverId: final s, :final phase) =>
          s == serverId &&
              (phase == AdminModePhase.on || phase == AdminModePhase.failed),
        _ => false,
      },
      _adminWait,
    );
    switch (event) {
      case Prompt(:final promptId, request: final ElevationPromptRequest r):
        asked.add(r);
        expect(
          asked.length,
          lessThanOrEqualTo(answers.length),
          reason: 'asked more often than expected',
        );
        engine.send(
          AnswerPrompt(promptId, PromptSecretAnswer(answers[asked.length - 1])),
        );
      case final AdminModeState state:
        return (state, asked);
      default:
        // The test above accepts nothing else.
        break;
    }
  }
}

/// [serverId]'s host profile: the latest one the engine sent, or the
/// next.
Future<HostProfile> hostProfile(FixtureEngine engine, String serverId) async {
  final latest = engine.seen
      .whereType<HostProfileChanged>()
      .where((e) => e.serverId == serverId)
      .lastOrNull;
  if (latest != null) return latest.profile;
  final changed = await engine.until<HostProfileChanged>(
    (e) => e.serverId == serverId,
  );
  return changed.profile;
}
