import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:meta/meta.dart';

/// The isolate protocol version; [Hello] and [EngineReady] compare it so an
/// app and engine built apart fail loudly instead of silently desynchronizing
/// (03 D18).
///
/// v2 types [CatalogReplaced] as a list of [FleetEntry] values (v1 carried
/// an opaque record map) and adds the FL-02 import: [ImportSshConfig],
/// answered by [SshConfigImported].
const int kEngineProtocolVersion = 2;

/// Every message the UI isolate sends the engine (03 §10.1, D18). Plain data
/// only: no function-typed fields, no Futures, no `dartssh2` or `seance_core`
/// types, so values cross `SendPort`s untouched.
@immutable
sealed class EngineRequest {
  const EngineRequest();
}

/// The handshake: the first request the client sends after the engine's
/// command port arrives. The engine answers with [EngineReady], or
/// [RequestRejected] when [protocolVersion] is not [kEngineProtocolVersion].
/// Lifecycle plumbing, so it is not in the 03 §10.1 feature table.
final class Hello extends EngineRequest {
  const Hello({this.protocolVersion = kEngineProtocolVersion});

  final int protocolVersion;
}

/// Asks the engine isolate to stop. The engine closes its command port and
/// exits; the client observes the exit through the isolate's `onExit` signal.
/// Lifecycle plumbing beside [Hello], not a 03 §10.1 row.
final class Shutdown extends EngineRequest {
  const Shutdown();
}

/// Enroll this device into catalog sync (03 §10.1). Pull-only under D14: the
/// catalog applies pulled records and never seals dirty ones.
final class EnrollSync extends EngineRequest {
  const EnrollSync();
}

/// Runs one sync round (pull and, once D14's push policy allows, seal and
/// push local catalog records). Alert inbox fetches ride inside it (D42).
final class RunSyncRound extends EngineRequest {
  const RunSyncRound();
}

/// Imports the hosts of an OpenSSH client config as device-local fleet
/// entries (FL-02, 03 §4.2). The UI reads the file and sends its [text]:
/// which file to read, and whether the platform has one at all, stays the
/// UI's decision, and the engine opens no file for this request. The engine
/// parses [text] off the UI isolate (CN-19), replaces every entry an earlier
/// import produced, and answers [CatalogReplaced] with the whole fleet, then
/// [SshConfigImported].
///
/// Not a catalog write under D14: imported entries never become records and
/// are never pushed. Until the catalog library brings D13's device-local
/// store, they live in the engine's memory and are gone when it stops.
/// FL-02 has no 03 §10.1 row yet.
final class ImportSshConfig extends EngineRequest {
  const ImportSshConfig(this.text);

  /// The config file's text, decoded by the UI.
  final String text;
}

/// Confirms probed endpoints into the fleet (03 §5.1, §10.1).
final class ConfirmEndpoints extends EngineRequest {
  const ConfirmEndpoints(this.serverIds);

  final List<String> serverIds;
}

/// Sets which servers the monitor set samples continuously (03 §10.3).
final class SetMonitorSet extends EngineRequest {
  const SetMonitorSet(this.serverIds);

  final List<String> serverIds;
}

/// Opens the SSH link to one server (03 §10.1).
final class Connect extends EngineRequest {
  const Connect(this.serverId);

  final String serverId;
}

/// Tears the link down (03 §10.1).
final class Disconnect extends EngineRequest {
  const Disconnect(this.serverId);

  final String serverId;
}

/// Starts the server-side sampler tick for [serverId] (03 §10.1).
final class Subscribe extends EngineRequest {
  const Subscribe({
    required this.serverId,
    required this.collectors,
    required this.cadence,
  });

  final String serverId;

  /// The HWS/1 collector set (03 §6.4); the engine keeps the fast/slow
  /// sampler split these names imply.
  final Set<Collector> collectors;

  /// How often the server runs the tick.
  final Duration cadence;
}

/// Stops the tick the 03 §10.1 table abbreviates as `Unsubscribe`; the row's
/// own `Connect(serverId)`/`Disconnect(serverId)` naming is followed here.
final class Unsubscribe extends EngineRequest {
  const Unsubscribe(this.serverId);

  final String serverId;
}

/// Opens a server log stream; batches arrive as [LogBatch] (03 §10.1, §10.8).
final class OpenLogStream extends EngineRequest {
  const OpenLogStream(this.spec);

  final LogStreamSpec spec;
}

/// Closes an open [LogBatch] stream (03 §10.1).
final class CloseStream extends EngineRequest {
  const CloseStream(this.streamId);

  final String streamId;
}

/// Runs one read-only Docker Engine query (03 §10.1). Mutations go through
/// [PlanAction]/[RunAction] so every write is previewed and confirmed.
final class DockerQuery extends EngineRequest {
  const DockerQuery(this.serverId, this.query);

  final String serverId;
  final DockerQuerySpec query;
}

/// Previews an operation: the engine answers [ActionPlanned] and nothing runs
/// until [RunAction] carries the matching plan id (03 §8.5, §10.1).
final class PlanAction extends EngineRequest {
  const PlanAction(this.intent);

  final ActionIntent intent;
}

/// Runs the plan [planId] once its confirmation tier is satisfied
/// (03 §8.6, §10.1).
final class RunAction extends EngineRequest {
  const RunAction(this.planId, this.confirmation);

  final String planId;
  final ActionConfirmation confirmation;
}

/// Answers an outstanding [Prompt] event (03 §10.1).
final class AnswerPrompt extends EngineRequest {
  const AnswerPrompt(this.promptId, this.answer);

  final String promptId;
  final PromptAnswer answer;
}

/// Acknowledges or dismisses one alert (v1.x, 03 §10.1, D42).
final class HandleAlert extends EngineRequest {
  const HandleAlert(this.alertRef, this.action);

  final String alertRef;
  final AlertAction action;
}

/// Opens a container or host shell stream (v1, 03 §10.1); bytes arrive as
/// [TerminalBytes] until [TerminalClosed].
final class OpenTerminal extends EngineRequest {
  const OpenTerminal({required this.serverId, this.containerId, this.shell});

  final String serverId;

  /// Null means the host shell, not a container.
  final String? containerId;
  final String? shell;
}

/// Every message the engine sends the UI isolate (03 §10.1, D18). Same plain
/// -data rules as [EngineRequest].
@immutable
sealed class EngineEvent {
  const EngineEvent();
}

/// The engine's answer to [Hello]; carries the version it speaks so the
/// client can refuse a mismatched engine before any feature traffic.
final class EngineReady extends EngineEvent {
  const EngineReady(this.protocolVersion);

  final int protocolVersion;
}

/// The engine refused a request it does not serve (yet). The 03 §10.1 table
/// names no error row; this carries the rejected request's class name and a
/// human-readable reason so unimplemented rows surface during development
/// instead of going unanswered.
final class RequestRejected extends EngineEvent {
  const RequestRejected(this.requestName, this.reason);

  final String requestName;
  final String reason;
}

/// The fleet the engine knows changed (03 §10.1): [entries] is the whole
/// list in display order and replaces the previous one. Synced entries come
/// first (none until the catalog library lands, F3), then device-local
/// imports in file order. The catalog's own record types stay engine-side;
/// the UI only ever sees [FleetEntry] values.
final class CatalogReplaced extends EngineEvent {
  CatalogReplaced(Iterable<FleetEntry> entries)
    : entries = List.unmodifiable(entries);

  final List<FleetEntry> entries;
}

/// The answer to one [ImportSshConfig], sent after the [CatalogReplaced]
/// that carries the imported entries, so the fleet already shows them.
final class SshConfigImported extends EngineEvent {
  const SshConfigImported({
    required this.importedCount,
    required this.skippedCount,
  });

  /// Hosts the import added to the fleet; zero when the config names none.
  final int importedCount;

  /// Host blocks the import left out: a `Port` outside 1 to 65535, or an
  /// alias an earlier block already took. Wildcard-only blocks such as
  /// `Host *` are defaults rather than hosts and do not count.
  final int skippedCount;
}

/// The sync round's phase changed (03 §10.1).
final class SyncStatus extends EngineEvent {
  const SyncStatus(this.phase, {this.detail});

  final SyncPhase phase;
  final String? detail;
}

/// One endpoint's catalog record changed (03 §10.1).
final class EndpointChanged extends EngineEvent {
  const EndpointChanged(this.serverId);

  final String serverId;
}

/// The link to [serverId] moved phase (03 §10.1); [reason] carries the
/// engine's short diagnostic for `failed`/`blocked`-style transitions.
final class LinkState extends EngineEvent {
  const LinkState(this.serverId, this.phase, {this.reason});

  final String serverId;
  final LinkPhase phase;
  final String? reason;
}

/// One coalesced sampler tick (03 §10.1); [seq] is the HWS/1 tick number so
/// the UI can drop reordered batches.
final class Sample extends EngineEvent {
  const Sample({
    required this.serverId,
    required this.seq,
    required this.snapshot,
  });

  final String serverId;
  final int seq;

  /// The tick's metrics: [OverviewSnapshot] for fleet rows, `CoreSnapshot`
  /// for the focused server (03 §6.4).
  final OverviewSnapshot snapshot;
}

/// One batch of an [OpenLogStream] stream, capped by 03 §10.1's rate;
/// [dropped] counts lines the buffer discarded since the last batch.
final class LogBatch extends EngineEvent {
  const LogBatch({
    required this.streamId,
    required this.lines,
    this.dropped = 0,
  });

  final String streamId;
  final List<String> lines;
  final int dropped;
}

/// The answer to one [DockerQuery] (03 §10.1): the endpoint's decoded JSON
/// payload plus any parser warnings (03 §3.4's ParseResult convention).
final class DockerResult extends EngineEvent {
  const DockerResult({
    required this.serverId,
    required this.payload,
    this.warnings = const [],
  });

  final String serverId;
  final Map<String, Object?> payload;
  final List<String> warnings;
}

/// One Docker Engine `/events` record (03 §10.1); kept opaque until the
/// Docker events model lands in its milestone.
final class DockerEvent extends EngineEvent {
  const DockerEvent(this.serverId, this.payload);

  final String serverId;
  final Map<String, Object?> payload;
}

/// The plan [PlanAction] computed: what would run, in the user's words, and
/// which confirmation tier executes it (03 §8.5, §8.6).
final class ActionPlanned extends EngineEvent {
  const ActionPlanned(this.planId, this.preview);

  final String planId;
  final ActionPreview preview;
}

/// Progress on a running plan (03 §10.1).
final class ActionProgress extends EngineEvent {
  const ActionProgress({
    required this.planId,
    required this.stepIndex,
    required this.stepCount,
    this.message,
  });

  final String planId;
  final int stepIndex;
  final int stepCount;
  final String? message;
}

/// A plan finished, one way or another (03 §10.1).
final class ActionFinished extends EngineEvent {
  const ActionFinished({
    required this.planId,
    required this.outcome,
    this.error,
  });

  final String planId;
  final ActionOutcome outcome;
  final String? error;
}

/// The engine needs the user to decide something mid-operation: host-key
/// trust, keyboard-interactive answers, a credential, or an elevation
/// password (03 §10.1). [AnswerPrompt] carries the reply.
final class Prompt extends EngineEvent {
  const Prompt({
    required this.promptId,
    required this.serverId,
    required this.kind,
    required this.message,
    this.questions = const [],
  });

  final String promptId;
  final String serverId;
  final PromptKind kind;
  final String message;
  final List<String> questions;
}

/// Alerts fetched for one server inside a sync round (v1.x, 03 §10.1, D42).
final class AlertsArrived extends EngineEvent {
  const AlertsArrived(this.serverId, this.alerts);

  final String serverId;
  final List<AlertDescriptor> alerts;
}

/// One alert's lifecycle state changed (v1.x, 03 §10.1, D42).
final class AlertStatusChanged extends EngineEvent {
  const AlertStatusChanged(this.alertRef, this.status);

  final String alertRef;
  final AlertStatus status;
}

/// Output bytes from an [OpenTerminal] stream (v1, 03 §10.1).
final class TerminalBytes extends EngineEvent {
  const TerminalBytes(this.terminalId, this.bytes);

  final String terminalId;
  final Uint8List bytes;
}

/// The terminal stream ended (v1, 03 §10.1).
final class TerminalClosed extends EngineEvent {
  const TerminalClosed(this.terminalId, {this.reason});

  final String terminalId;
  final String? reason;
}

/// The port SSH uses when a config names none (RFC 4253, section 4.1).
const int kSshDefaultPort = 22;

/// Where a [FleetEntry] came from, which decides what may happen to it.
enum FleetEntryOrigin {
  /// A `serverConfig` record pulled from the shared Séance sync account
  /// (D13); read-only in the MVP (D14). None arrive until the catalog
  /// library lands (F3).
  synced,

  /// Imported on this device from an OpenSSH client config (FL-02, 03
  /// §4.2). Device-local and never pushed in the MVP; held in the engine's
  /// memory until the catalog library brings the device-local store.
  sshConfig,
}

/// One server as the fleet rail lists it (03 §10.1, §10.3): its identity
/// and endpoint, and nothing the rail does not need yet. The catalog's
/// full records stay engine-side; this is the plain data that crosses the
/// isolate boundary (D18).
@immutable
final class FleetEntry {
  const FleetEntry({
    required this.serverId,
    required this.label,
    required this.host,
    required this.port,
    required this.origin,
    this.user,
    this.group,
  });

  /// The id every per-server request carries: a synced record's bare
  /// UUID, or `ssh-config:<alias>` for an import. Import ids are
  /// device-local and never reach the sync server.
  final String serverId;

  /// The name the rail shows: the record's label or the config's alias.
  final String label;

  /// The host name or address SSH connects to.
  final String host;

  /// The SSH port, [kSshDefaultPort] unless the source names another.
  final int port;

  /// The login name; null leaves it to SSH, which uses the local account
  /// name when the config names no `User`.
  final String? user;

  /// The group the rail files the entry under, or null for none. An
  /// ssh_config has no groups, so imports always carry null.
  final String? group;

  final FleetEntryOrigin origin;

  // By value: every CatalogReplaced copies its entries across the isolate
  // boundary, so identity would make an unchanged entry look changed.
  @override
  bool operator ==(Object other) =>
      other is FleetEntry &&
      serverId == other.serverId &&
      label == other.label &&
      host == other.host &&
      port == other.port &&
      user == other.user &&
      group == other.group &&
      origin == other.origin;

  @override
  int get hashCode =>
      Object.hash(serverId, label, host, port, user, group, origin);
}

/// Which log source an [OpenLogStream] follows (03 §7.6).
enum LogStreamSource {
  /// `journalctl` over the unit or priority in [LogStreamSpec.target].
  journal,

  /// A file path in [LogStreamSpec.target].
  file,

  /// A container's logs; [LogStreamSpec.target] is the container id.
  docker,
}

/// What an [OpenLogStream] request follows (03 §10.1).
@immutable
final class LogStreamSpec {
  const LogStreamSpec({
    required this.serverId,
    required this.source,
    this.target,
    this.follow = true,
  });

  final String serverId;
  final LogStreamSource source;

  /// Unit name, file path, or container id, per [source].
  final String? target;

  /// `tail -f`-style streaming when true; a bounded read when false.
  final bool follow;
}

/// Which read-only endpoint a [DockerQuery] runs (03 §7.12 to §7.15).
enum DockerQueryKind {
  containers,
  images,
  networks,
  volumes,
  info,
  inspect,
  logs,
  stats,
  events,
}

/// One read-only Docker Engine query (03 §10.1).
@immutable
final class DockerQuerySpec {
  const DockerQuerySpec({
    required this.kind,
    this.targetId,
    this.parameters = const {},
  });

  final DockerQueryKind kind;

  /// Container/image/etc. id for `inspect`, `logs`, `stats`.
  final String? targetId;

  /// Endpoint arguments (filters, `all`, `since`); keys are the API's.
  final Map<String, String> parameters;
}

/// What the user wants done (03 §10.1 `intent`). The action vocabulary lands
/// with the actions milestone, so [action] is the intent's name until the
/// typed catalog of 03 §7 exists; [parameters] carries its arguments.
@immutable
final class ActionIntent {
  const ActionIntent({
    required this.serverId,
    required this.action,
    this.parameters = const {},
  });

  final String serverId;
  final String action;
  final Map<String, Object?> parameters;
}

/// How far 03 §8.6's tiers make the user go before a plan runs.
enum ConfirmationTier {
  /// No confirmation needed (read-only-shaped plans).
  none,

  /// A dialog acknowledgement.
  acknowledge,

  /// The user types the target's name (protected targets, 03 §8.6).
  typedPhrase,
}

/// The user's answer to [ActionPlanned]'s tier requirement (03 §8.6).
@immutable
final class ActionConfirmation {
  const ActionConfirmation({required this.tier, this.phrase});

  final ConfirmationTier tier;

  /// The typed target name when [tier] is [ConfirmationTier.typedPhrase].
  final String? phrase;
}

/// What [PlanAction] previews before anything runs (03 §8.5): human-readable
/// steps, warnings, and the tier [RunAction] must satisfy.
@immutable
final class ActionPreview {
  const ActionPreview({
    required this.title,
    this.steps = const [],
    this.warnings = const [],
    this.requiredTier = ConfirmationTier.acknowledge,
    this.protectedTarget = false,
  });

  final String title;
  final List<String> steps;
  final List<String> warnings;
  final ConfirmationTier requiredTier;
  final bool protectedTarget;
}

/// A running plan's end state (03 §10.1).
enum ActionOutcome { succeeded, failed, cancelled }

/// The 03 §10.1 prompt kinds, in the table's own order.
enum PromptKind { hostKey, keyboardInteractive, credential, elevation }

/// The answer to a [Prompt]; one variant per [PromptKind] (03 §10.1).
@immutable
sealed class PromptAnswer {
  const PromptAnswer();
}

/// The host-key decision for [PromptKind.hostKey].
final class PromptTrustAnswer extends PromptAnswer {
  const PromptTrustAnswer(this.accepted);

  /// Trust and record the presented key when true.
  final bool accepted;
}

/// One secret for [PromptKind.credential] and [PromptKind.elevation];
/// null dismisses the prompt without answering.
final class PromptSecretAnswer extends PromptAnswer {
  const PromptSecretAnswer(this.secret);

  final String? secret;
}

/// The ordered responses for [PromptKind.keyboardInteractive].
final class PromptResponsesAnswer extends PromptAnswer {
  const PromptResponsesAnswer(this.responses);

  final List<String> responses;
}

/// One alert as the UI shows it (v1.x, 03 §10.1, D42).
@immutable
final class AlertDescriptor {
  const AlertDescriptor({
    required this.ref,
    required this.title,
    this.severity = AlertSeverity.info,
    this.status = AlertStatus.open,
  });

  /// The alert's stable reference for [HandleAlert]/[AlertStatusChanged].
  final String ref;
  final String title;
  final AlertSeverity severity;
  final AlertStatus status;
}

/// 03 §7.19's alert severities.
enum AlertSeverity { info, warning, critical }

/// An alert's lifecycle (v1.x, D42).
enum AlertStatus { open, acknowledged, dismissed }

/// What [HandleAlert] does with an alert (v1.x, 03 §10.1).
enum AlertAction { acknowledge, dismiss }

/// The link lifecycle behind [LinkState] (03 §10.1, §5.9).
enum LinkPhase { disconnected, connecting, connected, failed }

/// The sync round's phase behind [SyncStatus] (03 §10.1).
enum SyncPhase { idle, running, succeeded, failed }
