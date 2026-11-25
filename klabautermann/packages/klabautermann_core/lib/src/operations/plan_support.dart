// The helpers every operation planner builds its result with (03 §8.5):
// the attempt constructors, the facts of an elevated or login-user runner,
// the hash of a target's text, and a fresh random token. Written once here
// so the planner files cannot drift apart.
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' show sha256;

import '../engine/protocol.dart' show ActionRefusalReason;
import 'operation_plan.dart' show OperationPlan, PlanAttempt;
import 'plan_types.dart' show RunnerCredentials, RunnerFacts;

/// [plan] as a previewed plan, for a planner whose intent it can carry.
PlanAttempt planned(OperationPlan plan) =>
    (plan: plan, refusal: null, detail: null);

/// Why a planner cannot carry an intent: [reason], with the failed step's
/// [detail] where there is one.
PlanAttempt refused(ActionRefusalReason reason, {String? detail}) =>
    (plan: null, refusal: reason, detail: detail);

/// Who runs a host plan's steps: root under admin mode when [elevated],
/// otherwise the login account [user] names, with the credentials each
/// needs.
RunnerFacts runnerFacts({required bool elevated, String? user}) => RunnerFacts(
  identity: elevated ? 'root' : (user ?? 'login user'),
  credentials: elevated
      ? RunnerCredentials.adminPassword
      : RunnerCredentials.session,
);

/// The SHA-256 of [text]'s UTF-8 bytes, lowercase hex, as the edit
/// pipeline hashes what it read and writes.
String sha256OfText(String text) =>
    sha256.convert(utf8.encode(text)).toString();

/// A fresh 16-digit lowercase hex token from [random], for a plan id or a
/// temp path.
String randomHexToken(Random random) => [
  for (var i = 0; i < 8; i++)
    random.nextInt(256).toRadixString(16).padLeft(2, '0'),
].join();
