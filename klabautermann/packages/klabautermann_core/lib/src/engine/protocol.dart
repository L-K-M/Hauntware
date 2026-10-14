import 'dart:typed_data';

// Only plain-data host types cross (D52): none here holds a function, as
// `Collector` (its argument validators) and `ServerZone` (`offsetAt`) do.
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        CpuPercentages,
        CronSnapshot,
        DiskRate,
        FsSnapshot,
        HostProfile,
        LoadAvg,
        NetRate,
        SystemdUnit,
        TimersSnapshot,
        UnitsSnapshot;
import 'package:meta/meta.dart';

/// The isolate protocol version; [Hello] and [EngineReady] compare it so an
/// app and engine built apart fail loudly instead of silently desynchronizing
/// (03 D18).
///
/// v2 types [CatalogReplaced] as a list of [FleetEntry] values (v1 carried
/// an opaque record map) and adds the FL-02 import: [ImportSshConfig],
/// answered by [SshConfigImported].
///
/// The import store (03 §4.10) added [EngineReady.importStoreIssue] and
/// [SshConfigImported.saved] within v2, without a bump: the app and the
/// engine compile against these classes in one build, so neither side can
/// lack a required field and the check has nothing more to catch. 03 §10.1
/// lists both fields.
///
/// v3 carries links (03 §10.1, D46): [LinkState] holds a sealed
/// [LinkStatus] whose variants type their own reasons, [Prompt] holds a
/// sealed [PromptRequest] instead of engine text, [PromptWithdrawn]
/// retracts a prompt, [SetAppActivity] reports the app's activity,
/// [Reachability] reports probe results, and [FleetEntry] gains the
/// nullable `jumpRoute`, `authKind`, `searchText` and `locatorConflict`.
///
/// Sampling joined v3 without a bump, as the import store's fields joined
/// v2, before any v3 build shipped: [Subscribe] and [Unsubscribe] name one
/// surface's subscription and its [SampleStream]s (D45),
/// [SetCadenceProfile] picks the cadence column, [Sample] carries an
/// engine-owned `seq` (D44) and a sealed [SampleResult] of derived values
/// (D43), and [SamplingState], [Gap] and [HostProfileChanged] join.
const int kEngineProtocolVersion = 3;

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
/// import produced, saves the new set to `ssh_config_imports.json` (D13's
/// device-local store, 03 §4.10), and answers [CatalogReplaced] with the
/// whole fleet, then [SshConfigImported].
///
/// Not a catalog write under D14: imported entries never become records and
/// are never pushed; the store is a device-local file only.
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

/// Tells the engine whether the user can see the app (03 §10.1). One
/// request covers every subscription, link and probe at once, so a change
/// never resends them (D45); 03 §6.4 pauses everything while the app is in
/// the background, and D34 adds the phones' link grace period.
final class SetAppActivity extends EngineRequest {
  const SetAppActivity(this.activity);

  final AppActivity activity;
}

/// One surface's interest in [serverId]'s readings (03 §10.1, §6.4, D45).
/// Each surface that shows the server (a fleet row, the overview, a
/// visible panel) holds its own [subscriptionId]. The engine samples the
/// union of the streams the server's subscriptions name, so closing one
/// surface never stops another's. Sending the same ids again replaces
/// that subscription's [streams]; an empty set drops it. Cadence is not a
/// field: [SetCadenceProfile] and [SetAppActivity] hold for every
/// subscription at once.
final class Subscribe extends EngineRequest {
  const Subscribe({
    required this.serverId,
    required this.subscriptionId,
    required this.streams,
  });

  final String serverId;

  /// The surface's own id, unique among the server's subscriptions.
  final String subscriptionId;

  /// What the surface shows. Pass an unmodifiable set.
  final Set<SampleStream> streams;
}

/// Drops the subscription [Subscribe] made with the same ids (03 §10.1).
/// The engine stops a stream once no subscription for the server names it.
final class Unsubscribe extends EngineRequest {
  const Unsubscribe({required this.serverId, required this.subscriptionId});

  final String serverId;
  final String subscriptionId;
}

/// Picks the 03 §6.4 cadence column for every subscription at once (D45),
/// such as the phones' column or the cellular saver.
final class SetCadenceProfile extends EngineRequest {
  const SetCadenceProfile(this.profile);

  final CadenceProfile profile;
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
/// client can refuse a mismatched engine before any feature traffic. The
/// engine follows it at once with a [CatalogReplaced] holding the fleet it
/// started with: the imports an earlier run saved.
final class EngineReady extends EngineEvent {
  const EngineReady(this.protocolVersion, {this.importStoreIssue});

  final int protocolVersion;

  /// What was wrong with `ssh_config_imports.json` when the engine loaded
  /// it at start, or null when it was fine or absent. Told once, here, so
  /// the app can report it with its other startup problems.
  final ImportStoreIssue? importStoreIssue;
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
    required this.saved,
  });

  /// Hosts the import added to the fleet; zero when the config names none.
  final int importedCount;

  /// Hosts the import left out: a `Port` the importer refuses (one ssh
  /// rejects, or a service name other than `ssh`, `http` or `https`), or an
  /// alias an earlier block already took. Wildcard-only blocks such as
  /// `Host *` are defaults rather than hosts and do not count.
  final int skippedCount;

  /// Whether `ssh_config_imports.json` now holds this import. False when
  /// the write failed or this run leaves the file as it is
  /// ([ImportStoreIssueKind.leftAsIs], [ImportStoreIssueKind.newerVersion]):
  /// the fleet shows the import until the engine stops, and the next start
  /// loads whatever the file held before.
  final bool saved;
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

/// The link to [serverId] changed (03 §10.1, D46). The app keeps the last
/// [status] per server and ignores one for a server its fleet does not
/// list.
final class LinkState extends EngineEvent {
  const LinkState(this.serverId, this.status);

  final String serverId;
  final LinkStatus status;
}

/// The last reachability probe of [serverId] (FL-04, 03 §5.12). A probe
/// is a TCP connect to the SSH port, not a link: [LinkState] says whether
/// the engine is connected.
final class Reachability extends EngineEvent {
  const Reachability(this.serverId, this.status);

  final String serverId;
  final ReachabilityStatus status;
}

/// One reading of one subscribed [stream] of [serverId] (03 §10.1, §6.4).
final class Sample extends EngineEvent {
  const Sample({
    required this.serverId,
    required this.stream,
    required this.seq,
    required this.at,
    required this.result,
  });

  final String serverId;
  final SampleStream stream;

  /// The engine's counter for [serverId] (D44): it rises with every
  /// sample of the server, whatever its stream, for the engine's
  /// lifetime, across sampler restarts and reconnects. The app drops a
  /// sample whose seq is not above the last one it kept for the server.
  /// The HWS/1 request number stays inside the engine.
  final int seq;

  /// When the engine took the reading, by its own clock (this device's)
  /// in UTC; freshness and charts use it, since a host's clock may be off.
  final DateTime at;

  /// The reading with its rates and percentages already derived (D43):
  /// the variant for [stream], or [CollectorUnavailable].
  final SampleResult result;
}

/// What sampling [serverId] is doing since [since] (03 §9.5 item 4). The
/// engine sends it whenever [phase] changes; rows and cards word their
/// freshness from it and from the last [Sample.at].
final class SamplingState extends EngineEvent {
  const SamplingState({
    required this.serverId,
    required this.phase,
    required this.since,
  });

  final String serverId;
  final SamplingPhase phase;

  /// When [phase] began, by the engine's clock in UTC.
  final DateTime since;
}

/// [serverId]'s [streams] have no readings from [from] to [until], for
/// [cause] (03 §9.5 item 5, §6.2). The engine sends it when readings
/// resume, so both ends are known; a gap still open shows in
/// [SamplingState]. Charts draw it as a labelled band and never
/// interpolate across it.
final class Gap extends EngineEvent {
  const Gap({
    required this.serverId,
    required this.streams,
    required this.from,
    required this.until,
    required this.cause,
  });

  final String serverId;

  /// The streams without readings. Pass an unmodifiable set.
  final Set<SampleStream> streams;

  /// The last reading before the gap, or when sampling stopped, and when
  /// readings resumed; both by the engine's clock in UTC.
  final DateTime from, until;

  final GapCause cause;
}

/// What the capability probe found on [serverId] (03 §6.1). The engine
/// sends it when it first knows the server's profile in a run, and again
/// whenever a later probe finds a different one. The probe is not a
/// [SampleStream]: the engine runs it itself after connecting.
final class HostProfileChanged extends EngineEvent {
  const HostProfileChanged(this.serverId, this.profile);

  final String serverId;

  /// The probe's findings; what it could not tell stays null.
  final HostProfile profile;
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

/// The engine needs the user to decide something: trust a host key,
/// answer keyboard-interactive questions, give a password, or give the
/// sudo password for admin mode (03 §10.1). [AnswerPrompt] with
/// [promptId] answers it, and [PromptWithdrawn] retracts it. The engine
/// sends no text of its own: the app words [request] from its fields
/// through its ARB catalog (D35), and the only text is what the server
/// sent.
final class Prompt extends EngineEvent {
  const Prompt({
    required this.promptId,
    required this.serverId,
    required this.host,
    required this.port,
    required this.request,
  });

  final String promptId;

  /// The fleet server whose link or operation asks.
  final String serverId;

  /// The machine that asks: [serverId]'s own endpoint, or one of its jump
  /// hosts while the engine connects through it.
  final String host;
  final int port;

  final PromptRequest request;
}

/// The engine stopped waiting on [promptId] (03 §10.1): the app closes the
/// prompt, and a later [AnswerPrompt] for it has nothing to answer.
final class PromptWithdrawn extends EngineEvent {
  const PromptWithdrawn(this.promptId, this.reason);

  final String promptId;
  final PromptWithdrawnReason reason;
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
  /// §4.2). Device-local and never pushed in the MVP; the engine keeps the
  /// set in `ssh_config_imports.json` (03 §4.10).
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
    this.jumpRoute,
    this.authKind,
    this.searchText,
    this.locatorConflict,
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

  /// The jump hosts the engine connects through, first hop first, each as
  /// its source names it (an ssh_config alias, or `[user@]host[:port]`);
  /// null for a direct connection. Pass an unmodifiable list.
  final List<String>? jumpRoute;

  /// How the engine signs in to the server, or null when the source does
  /// not say.
  final FleetAuthKind? authKind;

  /// The lowercase text the rail's filter matches, built by the engine
  /// with `seance_protocol`'s `serverSearchHaystack`, which the app may not
  /// import (03 §3.2); null when the engine built none.
  final String? searchText;

  /// The server ids of the other entries that share this entry's host-key
  /// pin locator (`host:port`) behind a different jump route, whose pins
  /// would collide (03 §4.6); null when none do. Pass an unmodifiable list.
  final List<String>? locatorConflict;

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
      origin == other.origin &&
      _sameItems(jumpRoute, other.jumpRoute) &&
      authKind == other.authKind &&
      searchText == other.searchText &&
      _sameItems(locatorConflict, other.locatorConflict);

  @override
  int get hashCode => Object.hash(
    serverId,
    label,
    host,
    port,
    user,
    group,
    origin,
    jumpRoute == null ? null : Object.hashAll(jumpRoute!),
    authKind,
    searchText,
    locatorConflict == null ? null : Object.hashAll(locatorConflict!),
  );
}

/// How the engine signs in to a [FleetEntry]'s server (03 §4.5).
enum FleetAuthKind {
  /// An ssh-agent signs; the device stores nothing.
  agent,

  /// A private key file on this device, read by its path (an ssh_config
  /// `IdentityFile`).
  identityFile,

  /// A private key held in the vault.
  storedKey,

  /// A password, from the vault or asked for.
  password,
}

/// Whether two optional lists hold equal items in the same order.
bool _sameItems(List<Object?>? a, List<Object?>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;

  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// What went wrong with `ssh_config_imports.json` when the engine started
/// (03 §4.10). In every case the engine started without imports.
enum ImportStoreIssueKind {
  /// The file was not an import store this build can read. It was renamed
  /// to [ImportStoreIssue.preservedAs], byte for byte, and the next import
  /// saves a new file.
  recovered,

  /// The file could not be read, or it was damaged and could not be
  /// renamed aside. It is left as it is, and imports are not saved while
  /// this engine runs, so nothing replaces bytes nobody has kept.
  leftAsIs,

  /// A newer build wrote the file. It is left as it is, and imports are not
  /// saved while this engine runs, so the newer build finds its own file.
  newerVersion,
}

/// The problem the engine met loading `ssh_config_imports.json`, carried by
/// [EngineReady]. Plain data: the underlying error crosses as text.
@immutable
final class ImportStoreIssue {
  const ImportStoreIssue(this.kind, {this.preservedAs, this.detail});

  final ImportStoreIssueKind kind;

  /// The damaged file's new path; set for [ImportStoreIssueKind.recovered]
  /// only.
  final String? preservedAs;

  /// The failure behind [kind], for diagnostics only.
  final String? detail;
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

/// What a [Prompt] asks; one variant per [PromptKind].
@immutable
sealed class PromptRequest {
  const PromptRequest();

  PromptKind get kind;
}

/// Trust a host key the pin store has never seen (03 §4.6). A key that
/// differs from the pinned one does not prompt: it blocks the link with
/// [LinkBlockedReason.hostKeyChanged].
final class HostKeyPromptRequest extends PromptRequest {
  const HostKeyPromptRequest({
    required this.keyType,
    required this.fingerprintSha256,
  });

  /// The key algorithm, such as `ssh-ed25519`.
  final String keyType;

  /// The fingerprint in OpenSSH's `SHA256:` form.
  final String fingerprintSha256;

  @override
  PromptKind get kind => PromptKind.hostKey;
}

/// The server's keyboard-interactive challenge (RFC 4256), shown as the
/// server sent it. It carries no echo flags (`seance_core`'s
/// `KeyboardInteractiveChallenge` has none), so a surface masks every
/// answer. [PromptResponsesAnswer] answers [questions] in order.
final class KeyboardInteractivePromptRequest extends PromptRequest {
  const KeyboardInteractivePromptRequest({
    this.name = '',
    this.instruction = '',
    this.questions = const [],
  });

  final String name;
  final String instruction;
  final List<String> questions;

  @override
  PromptKind get kind => PromptKind.keyboardInteractive;
}

/// The login password for [user] (03 §4.5).
final class CredentialPromptRequest extends PromptRequest {
  const CredentialPromptRequest({required this.user, this.retry = false});

  final String user;

  /// Whether the server refused the previous answer to this question.
  final bool retry;

  @override
  PromptKind get kind => PromptKind.credential;
}

/// The sudo password of [user] for admin mode (03 §8.2, D41).
final class ElevationPromptRequest extends PromptRequest {
  const ElevationPromptRequest({required this.user, this.retry = false});

  final String user;

  /// Whether sudo refused the previous answer.
  final bool retry;

  @override
  PromptKind get kind => PromptKind.elevation;
}

/// Why the engine withdrew a [Prompt].
enum PromptWithdrawnReason {
  /// Nobody answered before the prompt's deadline.
  expired,

  /// What asked ended first: the connect attempt or operation stopped.
  attemptEnded,
}

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

/// Whether the user can see the app, as [SetAppActivity] reports it.
enum AppActivity {
  /// The user can see the app.
  foreground,

  /// The user cannot see the app, such as a phone app sent to the
  /// background.
  background,
}

/// A link's state behind [LinkState] (D46): the eight states of
/// `seance_core`'s `SshLinkState`, mirrored so that no `seance_core` type
/// crosses the boundary (03 §3.2), plus the engine's own [LinkBlocked].
/// Every reason is an enum the app words through its ARB catalog (D35).
/// Compares by value, because a status that crosses the boundary may
/// arrive as a copy.
@immutable
sealed class LinkStatus {
  const LinkStatus();

  /// The values that tell two statuses of one variant apart.
  List<Object?> get _values => const [];

  @override
  bool operator ==(Object other) =>
      other is LinkStatus &&
      other.runtimeType == runtimeType &&
      _sameItems(other._values, _values);

  @override
  int get hashCode => Object.hash(runtimeType, Object.hashAll(_values));
}

/// No attempt has started. The app reads a server it has no status for as
/// idle.
final class LinkIdle extends LinkStatus {
  const LinkIdle();
}

/// Reaching the server, possibly through its jump hosts.
final class LinkConnecting extends LinkStatus {
  const LinkConnecting();
}

/// The transport is up; user authentication runs.
final class LinkAuthenticating extends LinkStatus {
  const LinkAuthenticating();
}

/// Authenticated and working. A learned session limit is [LinkDegraded];
/// what the host can do arrives with the sampling protocol, not here.
final class LinkReady extends LinkStatus {
  const LinkReady();
}

/// Working, but the server showed a limit below the engine's budget.
final class LinkDegraded extends LinkStatus {
  const LinkDegraded(this.reason);

  final LinkDegradedReason reason;

  @override
  List<Object?> get _values => [reason];
}

/// Waiting until [until] before the engine dials again (CN-05).
final class LinkBackoff extends LinkStatus {
  const LinkBackoff(this.until);

  final DateTime until;

  @override
  List<Object?> get _values => [until];
}

/// Waiting on the [Prompt] [promptId], which asks for [kind]; the prompt
/// itself arrives as its own event.
final class LinkNeedsUser extends LinkStatus {
  const LinkNeedsUser({required this.promptId, required this.kind});

  final String promptId;
  final PromptKind kind;

  @override
  List<Object?> get _values => [promptId, kind];
}

/// The engine does not dial until the user decides something outside the
/// connect flow (D46); no prompt can answer it.
final class LinkBlocked extends LinkStatus {
  const LinkBlocked(this.reason);

  final LinkBlockedReason reason;

  @override
  List<Object?> get _values => [reason];
}

/// The link ended. [reason] says how; [failure] says what the engine found
/// behind it, or null when nothing failed or the engine could not tell.
final class LinkClosed extends LinkStatus {
  const LinkClosed(this.reason, {this.failure});

  final LinkClosedReason reason;
  final LinkFailureKind? failure;

  @override
  List<Object?> get _values => [reason, failure];
}

/// Why a link is [LinkDegraded] (`seance_core`'s `SshLinkDegradedReason`).
enum LinkDegradedReason {
  /// The server refused a session channel below the budget, so the link
  /// queues at the learned limit (03 §5.2's low-session mode).
  sessionLimitLearned,
}

/// Why a link is [LinkBlocked].
enum LinkBlockedReason {
  /// The server's endpoint no longer matches the one confirmed on this
  /// device (D16, 03 §4.7).
  endpointChanged,

  /// The server presented a host key other than the pinned one (03 §4.6).
  hostKeyChanged,
}

/// How a link ended (`seance_core`'s `SshLinkClosedReason`).
enum LinkClosedReason {
  /// The engine closed the link on purpose, for example on [Disconnect].
  closedByOwner,

  /// The transport ended underneath the link.
  linkLost,

  /// The transport reported an error before it ended.
  transportError,

  /// A keepalive ping went unanswered past its deadline (CN-06).
  pingTimeout,

  /// Connecting or authenticating never produced a transport.
  connectFailed,
}

/// What the engine found behind a [LinkClosed]. The first five are the
/// connect failures protocol version 3 classifies (03 §10.1); the last
/// three are 03 §5.3's client limitations.
enum LinkFailureKind {
  /// The connection was refused, or the host had no route or no address.
  unreachable,

  /// Connecting or the handshake ran past its deadline.
  timedOut,

  /// The server refused every credential offered.
  authenticationRejected,

  /// No credential could be offered: no agent answered, or a key file
  /// could not be read.
  credentialUnavailable,

  /// The user, or the background rule, declined a first-seen host key.
  hostKeyDeclined,

  /// The server requires an algorithm the client does not support yet
  /// (CN-23).
  unsupportedAlgorithm,

  /// The server offers only algorithms the suite refuses as insecure
  /// (D23).
  insecureAlgorithmsOnly,

  /// The key exchange did not finish before the server gave up (03 §5.3:
  /// finite-field Diffie-Hellman on Android).
  keyExchangeTimedOut,
}

/// A reachability probe's answer behind [Reachability] (`seance_core`'s
/// `ProbeStatus`).
enum ReachabilityStatus {
  /// The host accepted a TCP connection on its SSH port.
  online,

  /// The connection was refused, or the host had no route or no address.
  offline,

  /// The probe could not tell, for example after a timeout; not
  /// [offline], since a host behind a firewall or a jump host may be up.
  unknown,
}

/// The sync round's phase behind [SyncStatus] (03 §10.1).
enum SyncPhase { idle, running, succeeded, failed }

/// What a [Subscribe] names and each [Sample] carries: the 03 §6.4
/// collectors as surfaces see them. [units] and [failedUnits] both come
/// from the host's `units` collector: [failedUnits] is the health card's
/// list every 60 s, apart from the Services panel's full list every 15 s,
/// so the engine tells the two surfaces apart by stream (D45). The probe
/// is not a stream (see [HostProfileChanged]).
enum SampleStream {
  /// Fleet-row metrics: CPU, memory, load and network ([OverviewResult]).
  overview,

  /// The focused server's metrics: the overview's plus per-core CPU,
  /// disks, pressure and uptime ([CoreResult]).
  core,

  /// Mount usage and inodes ([FsResult]).
  fs,

  /// OS, kernel and host name, read once per session ([IdentityResult]).
  identity,

  /// The process list ([ProcsResult]).
  procs,

  /// Every systemd unit, for the Services panel ([UnitsResult]).
  units,

  /// The failed systemd units, for the health card ([FailedUnitsResult]).
  failedUnits,

  /// systemd timers ([TimersResult]).
  timers,

  /// Cron jobs ([CronResult]).
  cron,
}

/// The 03 §6.4 cadence columns [SetCadenceProfile] picks among.
enum CadenceProfile {
  /// The Desktop column; the engine starts with it.
  desktop,

  /// The Phone column.
  phone,

  /// The Cellular saver column.
  cellularSaver,
}

/// What sampling a server is doing, behind [SamplingState].
enum SamplingPhase {
  /// No subscription names the server, so nothing runs (03 §9.5's "not
  /// watched on this device").
  notWatched,

  /// Subscribed, but the server's link is not ready; [LinkState] says why.
  waitingForLink,

  /// The samplers run the subscribed streams.
  sampling,

  /// Paused while the app is in the background ([SetAppActivity]); the
  /// subscriptions stay and resume on return.
  pausedInBackground,
}

/// Why a [Gap] has no readings; 03 §9.5 labels the band from it.
enum GapCause {
  /// The app was in the background ("in background").
  background,

  /// The server's link was down ("disconnected").
  disconnected,

  /// Sampling ran but a reading was lost: a request missed its deadline,
  /// a framing error lost its reply, or the sampler restarted (03 §6.2).
  readingLost,
}

/// Why a [CollectorUnavailable] has no value: the HWS/1 section statuses
/// other than `ok` (03 §6.2).
enum CollectorUnavailableReason {
  /// A tool the collector needs is absent on the host.
  missing,

  /// The host refused the collector, such as with a permission error.
  denied,

  /// The `timeout` guard stopped the collector.
  timeout,

  /// The collector failed otherwise.
  error,
}

/// The reading behind a [Sample]: one variant per [SampleStream], or
/// [CollectorUnavailable]. Rates arrive as rates (D43), so the app keeps
/// no previous reading to compute them from.
@immutable
sealed class SampleResult {
  const SampleResult();
}

/// The stream's collector produced no value this time (03 §6.2). The app
/// words [reason] through its catalog (D35); [detail] is the collector's
/// error output as the host sent it, control characters stripped, or null
/// when there was none.
final class CollectorUnavailable extends SampleResult {
  const CollectorUnavailable(this.reason, {this.detail});

  final CollectorUnavailableReason reason;
  final String? detail;
}

/// A fleet row's reading ([SampleStream.overview], FL-07).
final class OverviewResult extends SampleResult {
  OverviewResult({
    this.cpu,
    this.memory,
    this.load,
    this.loadPerCore,
    Map<String, NetRate>? network,
  }) : network = _unmodifiable(network);

  /// CPU occupancy since the previous reading; null without one to compare
  /// with (the first reading, or after a reboot or a counter reset).
  final CpuPercentages? cpu;

  final MemoryUsage? memory;

  /// The load averages as the host reports them.
  final LoadAvg? load;

  /// The one-minute load divided by the number of CPUs (7.1's load with
  /// core context); null while the engine does not know that number.
  final double? loadPerCore;

  /// Byte rates per interface since the previous reading; null without
  /// one, and empty only when the host reported no interface, so unknown
  /// never sums to zero (03 §1.2 principle 6).
  final Map<String, NetRate>? network;
}

/// The focused server's reading ([SampleStream.core], OV-01): the
/// overview's values plus per-core CPU, disk rates, pressure and uptime.
final class CoreResult extends SampleResult {
  CoreResult({
    this.cpu,
    Map<String, CpuPercentages>? perCpu,
    this.memory,
    this.load,
    this.loadPerCore,
    Map<String, NetRate>? network,
    Map<String, DiskRate>? disks,
    this.cpuPressure,
    this.ioPressure,
    this.memoryPressure,
    this.uptime,
    this.bootedAt,
  }) : perCpu = _unmodifiable(perCpu),
       network = _unmodifiable(network),
       disks = _unmodifiable(disks);

  /// As [OverviewResult.cpu].
  final CpuPercentages? cpu;

  /// Occupancy per core (`cpu0`, `cpu1` and so on) since the previous
  /// reading; null without one, as [OverviewResult.network].
  final Map<String, CpuPercentages>? perCpu;

  final MemoryUsage? memory;
  final LoadAvg? load;

  /// As [OverviewResult.loadPerCore].
  final double? loadPerCore;

  /// As [OverviewResult.network].
  final Map<String, NetRate>? network;

  /// Byte rates per block device since the previous reading; null without
  /// one, as [OverviewResult.network].
  final Map<String, DiskRate>? disks;

  /// Pressure stall information; null where the kernel has none, which is
  /// normal (7.1).
  final StallShares? cpuPressure, ioPressure, memoryPressure;

  /// How long the host has been up.
  final Duration? uptime;

  /// When the host booted (`btime`), in UTC.
  final DateTime? bootedAt;
}

/// Memory as MEM-01's breakdown shows it, in bytes, which the engine
/// derives from `/proc/meminfo` with `MemAvailable` semantics (7.1). What
/// the host did not report stays null.
@immutable
final class MemoryUsage {
  const MemoryUsage({
    this.totalBytes,
    this.usedBytes,
    this.availableBytes,
    this.buffersBytes,
    this.cachedBytes,
    this.sharedBytes,
    this.swapTotalBytes,
    this.swapUsedBytes,
    this.zfsArcCountedAsUsed,
  });

  final int? totalBytes, usedBytes, availableBytes;
  final int? buffersBytes, cachedBytes, sharedBytes;
  final int? swapTotalBytes, swapUsedBytes;

  /// Whether `/proc/spl/kstat/zfs/arcstats` exists: the ZFS ARC is then
  /// part of [usedBytes], and MEM-01's bar says "ZFS ARC counted as used"
  /// (7.1). Null while the engine does not know.
  final bool? zfsArcCountedAsUsed;
}

/// One `/proc/pressure` file as 7.1 shows it: the shares of time some or
/// all tasks stalled. The kernel's cumulative stall counter (`total`)
/// stays in the engine (D43). A line the file lacks stays null.
@immutable
final class StallShares {
  const StallShares({this.some, this.full});

  final StallAverages? some, full;
}

/// Stall shares in percent over the last 10, 60 and 300 seconds.
@immutable
final class StallAverages {
  const StallAverages(this.avg10, this.avg60, this.avg300);

  final double avg10, avg60, avg300;
}

Map<String, V>? _unmodifiable<V>(Map<String, V>? map) =>
    map == null ? null : Map.unmodifiable(map);

/// Mount usage and inodes ([SampleStream.fs], 7.3).
final class FsResult extends SampleResult {
  const FsResult(this.fs);

  final FsSnapshot fs;
}

/// SYS-01's identity ([SampleStream.identity]); virtualization comes with
/// [HostProfileChanged]. The engine resolves each value from hostnamectl,
/// then os-release and `uname`, so the host's JSON never crosses (03
/// §6.5); what the host did not report stays null.
final class IdentityResult extends SampleResult {
  const IdentityResult({
    this.hostname,
    this.osPrettyName,
    this.kernelName,
    this.kernelRelease,
    this.arch,
  });

  /// The static host name, which only hostnamectl reports.
  final String? hostname;

  final String? osPrettyName, kernelName, kernelRelease, arch;
}

/// The process list ([SampleStream.procs], 7.2).
final class ProcsResult extends SampleResult {
  ProcsResult(List<ProcessRow> processes)
    : processes = List.unmodifiable(processes);

  final List<ProcessRow> processes;
}

/// One process as [ProcsResult] lists it (PRC-01).
@immutable
final class ProcessRow {
  const ProcessRow({
    required this.pid,
    this.parentPid,
    this.name,
    this.state,
    this.userName,
    this.uid,
    this.threads,
    this.residentBytes,
    this.cpuPercent,
    this.startTicks,
    this.arguments,
  });

  final int pid;
  final int? parentPid;

  /// The kernel's name for it (`comm`), as the host sent it.
  final String? name;

  /// The state letter of `/proc/<pid>/stat`, such as `R` or `S`.
  final String? state;

  final String? userName;
  final int? uid;
  final int? threads;
  final int? residentBytes;

  /// Its share of one CPU since the previous reading, in percent: above
  /// 100 when it runs on several CPUs, and null on its first reading.
  final double? cpuPercent;

  /// When it started, in clock ticks after boot (field 22 of
  /// `/proc/<pid>/stat`): with [pid], what PRC-02's PID-reuse guard
  /// compares before signalling it.
  final int? startTicks;

  /// The command line, one item per argument; null when it could not be
  /// read (7.2's "command line unavailable"). Pass an unmodifiable list.
  final List<String>? arguments;
}

/// Every systemd unit and the failed ones ([SampleStream.units], 7.5).
final class UnitsResult extends SampleResult {
  const UnitsResult(this.units);

  final UnitsSnapshot units;
}

/// The failed systemd units ([SampleStream.failedUnits], OV-02).
final class FailedUnitsResult extends SampleResult {
  FailedUnitsResult(List<SystemdUnit> failed)
    : failed = List.unmodifiable(failed);

  final List<SystemdUnit> failed;
}

/// systemd timers ([SampleStream.timers], 7.7).
final class TimersResult extends SampleResult {
  const TimersResult(this.timers);

  final TimersSnapshot timers;
}

/// Cron jobs ([SampleStream.cron], 7.7).
final class CronResult extends SampleResult {
  const CronResult(this.cron);

  final CronSnapshot cron;
}
