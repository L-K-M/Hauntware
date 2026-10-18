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
        JobEntry,
        LoadAvg,
        NetRate,
        ProcsSelection,
        SystemdUnit,
        TimersSnapshot,
        UnitsSnapshot;
// A masked process argument (03 §8.9): its display and toString carry the
// mask, so the app shows a secret only through the reveal action.
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show MaskedValue;
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
///
/// Log streams joined v3 the same way: [OpenLogStream] names its stream
/// and reads a [LogStreamSpec] (a sealed [LogSource] with its filters, a
/// window, follow and a resume cursor), [LogBatch] carries sealed
/// [LogRecord]s the engine resolved, and [LogStreamState] joins.
///
/// [ProcsResult] then gained the host's process count and how it chose
/// its rows, and [ProcessRow] lost the thread count the host no longer
/// sends (03 D48), within v3 the same way.
///
/// [CronResult] then gained the jobs rows with next runs in the server's
/// zone and that zone's basis (03 §7.7, D58), within v3 the same way.
///
/// [ProcessRow.arguments] then became masked values (03 §8.9), and
/// [HostProfileChanged] gained `cachedAt` for a profile the device cache
/// kept (D59), within v3 the same way.
///
/// [ProcessRow] then gained `startedAt`, its start by the engine's clock
/// (03 §7.2), within v3 the same way.
///
/// [LogStreamRunning] then gained [LogContinuity], whether a follow that
/// ran again may lack records (03 §7.6), within v3 the same way.
///
/// [LinkFailureKind] then gained `keyPassphraseRequired` and
/// `keyFileHiddenBySandbox` (03 §10.1), within v3 the same way.
///
/// [RefreshSubscription] then joined, reading a subscription's streams at
/// once for the phones' pull to refresh (PLT-02), within v3 the same way.
///
/// [KeyboardInteractivePromptRequest] then gained `user`, the account it
/// signs in as, [PromptCancelAnswer] joined to decline its questions, and
/// [LinkFailureKind] gained `keyboardInteractiveCancelled` for the attempt
/// a cancel ends (03 §10.1), within v3 the same way.
///
/// [HostKeyPromptRequest] then gained `pinnedFingerprintSha256` and
/// `pinnedKeyType` for the re-pin review of a changed key, and
/// [ConnectRejected] joined to say why a [Connect] to a fleet server
/// cannot start (03 §4.6, §10.1, D61), within v3 the same way.
///
/// Pull-only sync then joined v3 the same way (03 §4.3, D63): [EnrollSync]
/// carries the account to sign in to, [SyncStatus] reports each sync
/// operation with a typed [SyncFailure], [EngineReady] gains the enrolled
/// account and what was wrong with the sync state files, and the engine
/// asks the app for the OS keystore with [KeystoreRequest], which
/// [AnswerKeystore] answers.
///
/// Endpoint confirmation then joined v3 the same way (03 §4.7, K41):
/// [FleetEntry] gains `endpoint`, whether a synced server's endpoint is
/// confirmed on this device, [ConfirmEndpoints] confirms them,
/// [EndpointChanged] reports a confirmed one a sync changed, and
/// [ConnectRejectedReason] gains `endpointNotConfirmed`.
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

/// Signs this device in to the user's Séance sync account (03 §4.3 step
/// 1, §10.1): the shared enrollment (prelogin, KDF-downgrade refusal,
/// login, a full pull and the passphrase trial), the vault re-key through
/// its journal, then the pulled records applied. Pull-only under D14: the
/// catalog applies pulled records and never seals dirty ones. Answered by
/// [SyncStatus] events for [SyncOperation.enroll], and the fleet in a
/// [CatalogReplaced] when it succeeds.
///
/// The fields hold the user's secrets for the length of the request; the
/// engine keeps neither, and only the derived token and vault key reach
/// the keystore (03 §4.5).
final class EnrollSync extends EngineRequest {
  const EnrollSync({
    required this.baseUrl,
    required this.username,
    required this.password,
    required this.encryptionPassphrase,
  });

  /// The sync server's address, as Séance's account settings show it.
  final String baseUrl;
  final String username;

  /// The account password, which derives the login verifier.
  final String password;

  /// The encryption passphrase, which derives the key every record of the
  /// account is sealed with; often the same as [password].
  final String encryptionPassphrase;
}

/// Runs one sync round on the enrolled account: a pull, applied under
/// D14's push policy, which seals and pushes nothing in the MVP. Answered
/// by [SyncStatus] events for [SyncOperation.round], and the fleet in a
/// [CatalogReplaced] when it succeeds. Alert inbox fetches ride inside it
/// (v1.x, D42).
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

/// Confirms the endpoints of the synced servers [serverIds] on this
/// device as they stand (03 §4.3 step 3, §4.7, SAF-09): their host, port,
/// user and jump route, and those of each jump host on a route that has
/// none confirmed yet (D64). Only a confirmed synced server is dialed.
/// An id that is no synced server is skipped; imports count as confirmed
/// on the device that imported them. Device-local: the pins never sync
/// (03 §4.9). Answered by [CatalogReplaced] with the new
/// [FleetEntry.endpoint] values, after a [RequestRejected] when a pin
/// could not be saved.
final class ConfirmEndpoints extends EngineRequest {
  const ConfirmEndpoints(this.serverIds);

  final List<String> serverIds;
}

/// Sets FL-21's monitor set (03 §4.3 step 4, §6.4): the servers whose
/// `overview` the engine samples while the app is in the foreground,
/// whether or not a view shows them, over links it dials unattended, so
/// nothing prompts. It replaces the last set. Only a fleet server that
/// `monitorEligibilityOf` allows joins; others are skipped and named in a
/// [RequestRejected], and a set of more than `kMonitorSetLimit` (10)
/// servers is rejected whole, leaving the last one. A server that leaves the fleet
/// or stops being eligible leaves the set. No other event answers it.
/// Device-local: the app keeps the set in `settings.json` (03 §4.9).
final class SetMonitorSet extends EngineRequest {
  const SetMonitorSet(this.serverIds);

  final List<String> serverIds;
}

/// Opens the SSH link to one server (03 §10.1). The app sends it when the
/// user opens the server, so the connect may prompt; to a server blocked
/// by [LinkBlockedReason.hostKeyChanged] it reviews the changed key
/// (D61). A fleet server the engine cannot dial gets [ConnectRejected].
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
/// subscription at once. A stream the profile reads on demand (see
/// [CadenceProfile.cellularSaver]) is read once per [Subscribe] that
/// names it, a repeat included, so a surface refreshes it by resending.
/// While the server is [SamplingPhase.waitingForLink] or
/// [SamplingPhase.pausedInBackground], that reading waits until the link
/// is ready and the app is in the foreground, and resends in the meantime
/// add no further reading.
final class Subscribe extends EngineRequest {
  const Subscribe({
    required this.serverId,
    required this.subscriptionId,
    required this.streams,
  });

  final String serverId;

  /// The surface's own id, unique among the server's subscriptions. The
  /// engine's monitor set holds one of its own (`engine:monitorSet`),
  /// which the app never uses.
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

/// Reads the streams of the subscription [Subscribe] made with the same
/// ids at once rather than at their next 03 §6.4 tick, as a pull to
/// refresh asks (PLT-02). While the server samples, each stream is read
/// once more as soon as its sampler is free, a busy, restarting or
/// probing sampler holding the reading rather than losing it, and a
/// stream that rides on another's collector (`overview` on `core`,
/// `failedUnits` on `units`) is read through that collector. `identity`,
/// otherwise read once per link, is read again too. While the server is
/// [SamplingPhase.waitingForLink] or [SamplingPhase.pausedInBackground],
/// nothing is read now, and sampling resumes with every stream the
/// subscription names. No event answers it but the readings, and a
/// subscription the engine does not hold changes nothing.
final class RefreshSubscription extends EngineRequest {
  const RefreshSubscription({
    required this.serverId,
    required this.subscriptionId,
  });

  final String serverId;
  final String subscriptionId;
}

/// Picks the 03 §6.4 cadence column for every subscription at once (D45),
/// such as the phones' column or the cellular saver.
final class SetCadenceProfile extends EngineRequest {
  const SetCadenceProfile(this.profile);

  final CadenceProfile profile;
}

/// Opens a log stream on [spec]'s server (03 §10.1, §7.6): its records
/// arrive as [LogBatch]es and its progress as [LogStreamState]s, all
/// under [streamId], until it ends or [CloseStream] closes it. The engine
/// answers an open it accepts with a [LogStreamState] before it handles
/// the next request, so the app can give a [RequestRejected] to the
/// oldest open with no answer yet.
final class OpenLogStream extends EngineRequest {
  const OpenLogStream({required this.streamId, required this.spec});

  /// The app's own id for the stream, which it picks so it can close the
  /// stream before the engine has answered. Unlike a [Subscribe] id, it
  /// is never reused for the engine's lifetime (a counter will do):
  /// stream events carry no generation, so a closed stream's last batch
  /// or end can arrive after the next open, and an open the engine
  /// rejects outright gets a [RequestRejected], which names no stream.
  /// The engine rejects an open whose id an earlier open used.
  final String streamId;

  final LogStreamSpec spec;
}

/// Closes the stream [OpenLogStream] opened as [streamId] (03 §10.1). The
/// engine stops the read, and its last event for the stream is a
/// [LogStreamState] with [LogStreamEndReason.closed]; batches it sent
/// before it handled this request arrive ahead of that. Closing a stream
/// that is not open, because it ended or never opened, does nothing.
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

/// Answers the [KeystoreRequest] with [requestId] (03 §10.1, D62, D63).
/// The engine takes it ahead of the requests queued before it, since the
/// sync operation that asked waits on it.
final class AnswerKeystore extends EngineRequest {
  const AnswerKeystore(this.requestId, this.result);

  final int requestId;
  final KeystoreResult result;
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
  const EngineReady(
    this.protocolVersion, {
    this.importStoreIssue,
    this.syncAccount,
    this.syncStoreIssues = const [],
  });

  final int protocolVersion;

  /// What was wrong with `ssh_config_imports.json` when the engine loaded
  /// it at start, or null when it was fine or absent. Told once, here, so
  /// the app can report it with its other startup problems.
  final ImportStoreIssue? importStoreIssue;

  /// The sync account this device is enrolled in, or null when it is not
  /// (03 §4.3). Later changes arrive in [SyncStatus.account].
  final SyncAccountInfo? syncAccount;

  /// What was wrong with each sync state file the engine opened at start
  /// (03 §4.10, D62), told once like [importStoreIssue].
  final List<SyncStoreIssue> syncStoreIssues;
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

  /// Hosts the import left out because the engine cannot dial them as ssh
  /// would (03 §10.1): a route through a `ProxyCommand`; a `Match` or
  /// `Include` that could set a value the engine cannot know, or a
  /// second pass over the config (`CanonicalizeHostname`, or a `Match
  /// final` or `Include` while a value is still unset); a `HostName`
  /// token other than `%h` or `%%`, or an `IdentityFile` holding a `%`
  /// token or `${VAR}`; a `ProxyJump` the engine cannot follow as ssh
  /// would; a line ssh rejects, such as a `Port` the import refuses (one
  /// ssh rejects, or a service name other than `ssh`, `http` or `https`);
  /// or a jump hop left out for any of these. Wildcard-only blocks such
  /// as `Host *` name no host and do not count.
  final int skippedCount;

  /// Whether `ssh_config_imports.json` now holds this import. False when
  /// the write failed or this run leaves the file as it is
  /// ([ImportStoreIssueKind.leftAsIs], [ImportStoreIssueKind.newerVersion]):
  /// the fleet shows the import until the engine stops, and the next start
  /// loads whatever the file held before.
  final bool saved;
}

/// A sync operation started or ended (03 §10.1). Operations run one at a
/// time in request order, each reported [SyncPhase.running] and then
/// [SyncPhase.succeeded] or [SyncPhase.failed].
final class SyncStatus extends EngineEvent {
  const SyncStatus(
    this.phase, {
    required this.operation,
    this.account,
    this.failure,
    this.passphraseUnverified = false,
    this.detail,
  });

  final SyncPhase phase;
  final SyncOperation operation;

  /// The enrolled account as the operation leaves it, or null when this
  /// device is not enrolled.
  final SyncAccountInfo? account;

  /// Why the operation failed; set with [SyncPhase.failed] only.
  final SyncFailure? failure;

  /// Whether no pulled record has proved the encryption passphrase yet
  /// (the push hold of 03 §4.5): the passphrase may be wrong, or the
  /// account holds nothing to check it against.
  final bool passphraseUnverified;

  /// The failure behind [failure], for diagnostics only.
  final String? detail;
}

/// A sync changed the endpoint of the synced server [serverId], which was
/// confirmed on this device (03 §4.7, SYN-08): its host, port or user,
/// its jump route, or a jump host's endpoint. The engine closed its link,
/// dials it no more and purged its cached profile; the [CatalogReplaced]
/// that follows lists it with [EndpointConfirmation.changed] until the
/// user confirms it again.
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

/// A [Connect] to the fleet server [serverId] could not start, because the
/// engine has no config to dial it with (03 §10.1, D61) or its endpoint
/// is not confirmed on this device (03 §4.7). Nothing about
/// the server's link changes; a later [CatalogReplaced] may give it one.
/// A [Connect] for an id outside the fleet still gets [RequestRejected].
final class ConnectRejected extends EngineEvent {
  const ConnectRejected(this.serverId, this.reason);

  final String serverId;
  final ConnectRejectedReason reason;
}

/// Why the engine has no config for a fleet server.
enum ConnectRejectedReason {
  /// No login name is known for the server or a jump host on its route:
  /// the import names no `User`, and neither `USER` nor `USERNAME` is
  /// set in the engine's environment.
  noLoginName,

  /// The import store is of an older schema (1 or 2), which kept each
  /// host's address only (`ImportedHostDetail.addressOnly`), so how the
  /// server signs in and which jump hosts it needs are unknown until the
  /// next import.
  addressOnlyImport,

  /// A synced server whose endpoint is not confirmed on this device, or
  /// changed since it was ([FleetEntry.endpoint], 03 §4.7, SAF-09).
  /// [ConfirmEndpoints] lets the engine dial it.
  endpointNotConfirmed,
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
  }) : assert(
         // Comparisons rather than a switch: the assert of a const
         // constructor takes only constant expressions.
         result is CollectorUnavailable ||
             (stream == SampleStream.overview && result is OverviewResult) ||
             (stream == SampleStream.core && result is CoreResult) ||
             (stream == SampleStream.fs && result is FsResult) ||
             (stream == SampleStream.identity && result is IdentityResult) ||
             (stream == SampleStream.procs && result is ProcsResult) ||
             (stream == SampleStream.units && result is UnitsResult) ||
             (stream == SampleStream.failedUnits &&
                 result is FailedUnitsResult) ||
             (stream == SampleStream.timers && result is TimersResult) ||
             (stream == SampleStream.cron && result is CronResult),
         'result must be the variant for stream, or CollectorUnavailable',
       );

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
/// resume, so both ends are known. While a gap is open, a background or
/// disconnected one shows in [SamplingState]; a [GapCause.readingLost]
/// one shows only as an ageing [Sample.at], since the phase stays
/// [SamplingPhase.sampling]. Charts draw it as a labelled band and never
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

  /// The streams' last reading before the gap and the reading that
  /// resumed them, which follows this event; both by the engine's clock
  /// in UTC. A stream without an earlier reading has no gap.
  final DateTime from, until;

  final GapCause cause;
}

/// What the capability probe found on [serverId] (03 §6.1). The engine
/// sends it when it first knows the server's profile in a run, and again
/// whenever a later probe finds a different one, compared without the
/// fields every probe or session changes: the clock (`epochSeconds`,
/// `zoneOffset`) and the session (`sshConnection`, `sessionParentPid`,
/// `sessionParentComm`), which may therefore be older than the last
/// probe. The probe is not a [SampleStream]: the engine runs it itself
/// after connecting.
///
/// A profile the device cache kept from an earlier run (D59) comes first,
/// with [cachedAt], when a [Connect] or [Subscribe] first names the
/// server and no probe has answered in this run; the run's first probe
/// answer follows it, changed or not.
final class HostProfileChanged extends EngineEvent {
  const HostProfileChanged(this.serverId, this.profile, {this.cachedAt});

  final String serverId;

  /// The probe's findings; what it could not tell stays null. A cached
  /// profile carries no clock or session fields.
  final HostProfile profile;

  /// When the probe behind a cached [profile] answered, by the engine's
  /// clock in UTC; null when a probe in this run found it.
  final DateTime? cachedAt;
}

/// The next records of the [OpenLogStream] stream [streamId], in the
/// stream's order ([LogStreamSpec]). The engine sends at most 20 batches
/// a second per stream (03 §10.1), so a busy follow arrives in batches
/// rather than record by record.
final class LogBatch extends EngineEvent {
  LogBatch({
    required this.streamId,
    required Iterable<LogRecord> records,
    this.dropped = 0,
  }) : records = List.unmodifiable(records),
       assert(dropped >= 0, 'dropped counts records');

  final String streamId;

  /// The records, of the variants the stream's [LogSource] names.
  final List<LogRecord> records;

  /// How many records the engine discarded since the stream's previous
  /// batch, before [records]; the view shows them as one "dropped N
  /// lines" entry (LOG-02, 03 §10.8).
  final int dropped;
}

/// What the [OpenLogStream] stream [streamId] is doing, for LOG-02's
/// connection chip (03 §10.1). The engine sends it as it accepts the open,
/// before the next request, and whenever [status] changes; a
/// [LogStreamEnded] status is the stream's last event.
final class LogStreamState extends EngineEvent {
  const LogStreamState(this.streamId, this.status);

  final String streamId;
  final LogStreamStatus status;
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

/// The engine asks the app for the OS keystore (03 §4.5, §10.1, D62): the
/// keystore plugin answers only the app's root isolate, so the app runs
/// [operation] and answers [AnswerKeystore] with [requestId]. A sync
/// operation waits for the answer.
final class KeystoreRequest extends EngineEvent {
  const KeystoreRequest(this.requestId, this.operation);

  /// Unique for the engine's lifetime.
  final int requestId;
  final KeystoreOperation operation;
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
    this.endpoint,
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

  /// The login name the source names; null when it names none, and the
  /// engine then signs in as the local account (`USER` or `USERNAME`).
  final String? user;

  /// The group the rail files the entry under, or null for none. An
  /// ssh_config has no groups, so imports always carry null.
  final String? group;

  final FleetEntryOrigin origin;

  /// The jump hosts the engine connects through, first hop first, each as
  /// its source names it (an ssh_config alias, or `[user@]host[:port]`);
  /// null for a direct connection, and for an import whose route is
  /// unknown: one from an older import store (03 §4.10), which the engine
  /// marks by sending no [authKind]. Pass an unmodifiable list.
  final List<String>? jumpRoute;

  /// How the engine signs in to the server, or null when the source does
  /// not say.
  final FleetAuthKind? authKind;

  /// The lowercase text the rail's filter matches, built by the engine
  /// with `seance_protocol`'s `serverSearchHaystack`, which the app may not
  /// import (03 §3.2); null when the engine built none.
  final String? searchText;

  /// The server ids of the other entries that pin a host key at one of
  /// this entry's pin locators (`host:port`: the server's or a jump hop's)
  /// behind a different jump route, whose pins would collide (03 §4.6);
  /// null when none do, and for an import whose route is unknown (see
  /// [jumpRoute]). Pass an unmodifiable list.
  final List<String>? locatorConflict;

  /// Whether this device confirmed a synced server's endpoint (03 §4.7);
  /// null for an import, which counts as confirmed on the device that
  /// imported it.
  final EndpointConfirmation? endpoint;

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
      _sameItems(locatorConflict, other.locatorConflict) &&
      endpoint == other.endpoint;

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
    endpoint,
  );
}

/// Where a synced server's endpoint stands on this device (03 §4.7,
/// SAF-09). Only a [confirmed] one is dialed.
enum EndpointConfirmation {
  /// Its host, port, user and jump route match what this device
  /// confirmed, and so does each jump host's.
  confirmed,

  /// Never confirmed on this device.
  unconfirmed,

  /// Confirmed once, but a sync has changed it or a jump host on its
  /// route since: it waits to be confirmed again.
  changed,
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

/// What an [OpenLogStream] reads, on which server, and how much (03 §7.6,
/// §10.1).
///
/// A window ([follow] false) reads the newest [window] records, older than
/// [afterCursor] when it is set, and ends. They arrive newest first, so
/// the last one's cursor reads on to older records (LOG-01's "load
/// older"; SVC-04's unit logs are one window). A follow delivers up to
/// [window] earlier records oldest first, then each new record as the
/// host writes it, until [CloseStream]. With [afterCursor] it resumes
/// after a record the app already holds instead (LOG-02): it delivers
/// every record after that one, so a reconnect leaves no gap, and
/// [window] does not apply.
@immutable
final class LogStreamSpec {
  LogStreamSpec({
    required this.serverId,
    required this.source,
    required this.window,
    required this.follow,
    this.afterCursor,
  }) : assert(window >= 0, 'window counts records'),
       assert(
         afterCursor == null || source is! FileLogSource,
         'a file tail has no cursor',
       ),
       assert(
         !follow || source is! JournalLogSource || source.until == null,
         'a follow reads up to the present',
       );

  final String serverId;
  final LogSource source;

  /// How many records: a window's size (LOG-01's pages hold 500, SVC-04's
  /// unit logs 50), or how many earlier records a follow without
  /// [afterCursor] delivers before the new ones.
  final int window;

  /// Whether the stream follows new records instead of ending after its
  /// window.
  final bool follow;

  /// A [JournalRecord.cursor] the read continues after, in the stream's
  /// order: a window reads older records, a follow the ones written after
  /// it. File tails and `dmesg` have no cursor. Null starts at the newest
  /// record. journalctl refuses `--since` together with a cursor, so with
  /// one the engine applies [JournalLogSource.since] itself: a window ends
  /// with [LogStreamEndReason.oldestReached] at the first record older
  /// than it, and a follow skips such records, as it does without one.
  final String? afterCursor;
}

/// Where an [OpenLogStream] reads (03 §7.6). Container logs (CTX-01) are
/// not a source yet: they come from the Docker Engine API with M3.
@immutable
sealed class LogSource {
  const LogSource();
}

/// The systemd journal through `journalctl -o json`, read as
/// [JournalRecord]s, with LOG-01's filters; SVC-04's unit logs filter by
/// [unit]. A null filter matches every record. There is no text filter:
/// LOG-05 searches the records the view holds, and `journalctl -g`
/// arrives with LOG-06 (v1).
final class JournalLogSource extends LogSource {
  const JournalLogSource({
    this.unit,
    this.identifier,
    this.priority,
    this.currentBootOnly = false,
    this.since,
    this.until,
  });

  /// A systemd unit name (`-u`).
  final String? unit;

  /// A syslog identifier (`-t`).
  final String? identifier;

  /// The least urgent priority shown (`-p`): records at it or more urgent.
  final LogPriority? priority;

  /// Only the current boot's records (`-b`); past boots arrive with
  /// LOG-09's boot picker (v1).
  final bool currentBootOnly;

  /// The time range (`--since`, `--until`). A follow takes no [until],
  /// since it reads up to the present.
  final DateTime? since, until;
}

/// The kernel's messages for the current boot (LOG-03): `journalctl -k`,
/// read as [JournalRecord]s, with `dmesg --json --decode` only as a
/// fallback, read as [KernelRecord]s. Past boots arrive with LOG-09 (v1).
final class KernelLogSource extends LogSource {
  const KernelLogSource();
}

/// One file's lines as [FileRecord]s (LOG-22): `tail -n` for a window,
/// and `tail -F`, which follows the file by name across rotation, for a
/// follow. No archives.
final class FileLogSource extends LogSource {
  const FileLogSource(this.path);

  /// The absolute path, typed or picked from the common paths; the engine
  /// validates it (03 §8.8) before it quotes it into the command.
  final String path;
}

/// A syslog severity as journald and the kernel record it, most urgent
/// first, so a value's [Enum.index] is its number (0 to 7, RFC 5424).
enum LogPriority {
  emergency,
  alert,
  critical,
  error,
  warning,
  notice,
  info,
  debug,
}

/// One record of a [LogBatch]; the stream's [LogSource] decides the
/// variant. Each is plain data the engine resolved from what the host sent
/// (D52, 03 §6.5), so the app parses nothing.
@immutable
sealed class LogRecord {
  const LogRecord();
}

/// One journal entry from `journalctl -o json` (LOG-01 to LOG-03, SVC-04).
/// The engine reads its columns once; a value the host sent that does not
/// fit its column, such as a time beyond [DateTime]'s range or a priority
/// outside 0 to 7, is null, as a missing one is.
final class JournalRecord extends LogRecord {
  const JournalRecord({
    this.cursor,
    this.at,
    this.priority,
    this.unit,
    this.identifier,
    this.pid,
    this.message,
    this.fields = const {},
  });

  /// `__CURSOR`, which [LogStreamSpec.afterCursor] continues after.
  final String? cursor;

  /// `__REALTIME_TIMESTAMP`: when journald received the entry, by the
  /// host's clock.
  final DateTime? at;

  /// `PRIORITY`.
  final LogPriority? priority;

  /// `_SYSTEMD_UNIT`, or `_SYSTEMD_USER_UNIT` or `UNIT` without one.
  final String? unit;

  /// `SYSLOG_IDENTIFIER`.
  final String? identifier;

  /// `_PID`, when it is a positive number.
  final int? pid;

  /// `MESSAGE`; null when the entry has none or journalctl sent it as
  /// null, which `-o json` does for a field over 4,096 bytes unless it
  /// runs with `--all`.
  final String? message;

  /// Every field as `klabautermann_host`'s journal parser decoded it, the
  /// ones above included, for the row's expandable fields (03 §10.8); null
  /// where journalctl sent null. Pass an unmodifiable map.
  final Map<String, String?> fields;
}

/// One kernel ring-buffer record from `dmesg --json --decode`, LOG-03's
/// fallback.
final class KernelRecord extends LogRecord {
  const KernelRecord({required this.message, this.sinceBoot, this.priority});

  /// `msg`.
  final String message;

  /// `time`: how long after boot the kernel logged it.
  final Duration? sinceBoot;

  /// The level that `pri` names; null when dmesg sent no level name.
  final LogPriority? priority;
}

/// One line of a tailed file (LOG-22), without its line break.
final class FileRecord extends LogRecord {
  const FileRecord(this.text);

  final String text;
}

/// A log stream's state behind [LogStreamState]. Compares by value, as
/// [LinkStatus] does, because a status that crosses the boundary may
/// arrive as a copy.
@immutable
sealed class LogStreamStatus {
  const LogStreamStatus();

  /// The values that tell two statuses of one variant apart.
  List<Object?> get _values => const [];

  @override
  bool operator ==(Object other) =>
      other is LogStreamStatus &&
      other.runtimeType == runtimeType &&
      _sameItems(other._values, _values);

  @override
  int get hashCode => Object.hash(runtimeType, Object.hashAll(_values));
}

/// The read waits for [reason] to clear, then runs on its own: a window
/// starts, and a follow starts or resumes after its last record.
final class LogStreamWaiting extends LogStreamStatus {
  const LogStreamWaiting(this.reason);

  final LogStreamWaitReason reason;

  @override
  List<Object?> get _values => [reason];
}

/// The read runs on the host: a window until it ends, a follow live.
/// [reader] says which of its source's readers serves it, so the view can
/// name where a kernel log came from (LOG-03), and [continuity] whether a
/// follow that waited may lack records written meanwhile (LOG-02).
final class LogStreamRunning extends LogStreamStatus {
  const LogStreamRunning({
    this.reader = LogReader.primary,
    this.continuity = LogContinuity.complete,
  });

  final LogReader reader;
  final LogContinuity continuity;

  @override
  List<Object?> get _values => [reader, continuity];
}

/// Whether a running stream holds every record since it opened (03 §7.6).
enum LogContinuity {
  /// Every record arrived or was counted in a [LogBatch.dropped]: a
  /// window, a follow on its first run, or one that resumed after its
  /// newest journal cursor.
  complete,

  /// A follow without a cursor to resume after, such as a file's `tail
  /// -F`, started again after it waited and delivers only new records:
  /// records written while it waited may be missing, uncounted.
  gap,
}

/// Which reader a [LogStreamRunning] stream reads with (03 §7.6).
enum LogReader {
  /// The source's own: `journalctl` for the journal and the kernel log,
  /// `tail` for a file.
  primary,

  /// The kernel log's fallback, `dmesg --json --decode`, read as
  /// [KernelRecord]s when `journalctl -k -b` gives no kernel record.
  fallback,
}

/// The stream ended for [reason], and nothing more arrives for it.
/// [detail] is the host's error output when the host ended it, control
/// characters stripped, or null.
final class LogStreamEnded extends LogStreamStatus {
  const LogStreamEnded(this.reason, {this.detail});

  final LogStreamEndReason reason;
  final String? detail;

  @override
  List<Object?> get _values => [reason, detail];
}

/// What a [LogStreamWaiting] stream waits for.
enum LogStreamWaitReason {
  /// The server's link; [LinkState] says why it is not ready.
  link,

  /// A free session channel: reads of its kind already hold their share
  /// of the budget (03 §5.2), or the server allows fewer sessions than
  /// the budget ([LinkDegraded]).
  channel,

  /// The app's return to the foreground ([SetAppActivity]): 03 §6.4
  /// pauses everything while it is in the background.
  background,
}

/// Why a [LogStreamEnded] stream ended.
enum LogStreamEndReason {
  /// A window delivered [LogStreamSpec.window] records, or fewer when the
  /// engine's output cap for the read stopped it first. Older records may
  /// remain; a journal window after the last record's cursor reads on.
  windowFilled,

  /// A window reached the oldest record its source holds within its
  /// filters: nothing older remains.
  oldestReached,

  /// [CloseStream] closed it.
  closed,

  /// The engine refused the spec without running anything, such as a
  /// unit name or path its validation rejects (03 §8.8).
  invalid,

  /// The tool or file the source reads is absent on the host.
  missing,

  /// The host refused the read, such as a file only `adm` or root may
  /// read; admin mode (03 §8.2), which reads such files, arrives with M4.
  denied,

  /// The read failed otherwise.
  failed,
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

/// Trust a host key the pin store has never seen, or re-pin a changed one
/// (03 §4.6). A key that differs from the pinned one blocks the link with
/// [LinkBlockedReason.hostKeyChanged]; only the user's next [Connect] to
/// the blocked server asks about it, with the pinned key in
/// [pinnedFingerprintSha256] and [pinnedKeyType] (D61). Trusting it
/// replaces the pin. An unattended connect never asks.
final class HostKeyPromptRequest extends PromptRequest {
  const HostKeyPromptRequest({
    required this.keyType,
    required this.fingerprintSha256,
    this.pinnedFingerprintSha256,
    this.pinnedKeyType,
  });

  /// The presented key's algorithm, such as `ssh-ed25519`.
  final String keyType;

  /// The presented key's fingerprint in OpenSSH's `SHA256:` form.
  final String fingerprintSha256;

  /// The pinned key's fingerprint in the same form when the presented key
  /// differs from it, or null for a first-seen key.
  final String? pinnedFingerprintSha256;

  /// The pinned key's algorithm beside [pinnedFingerprintSha256]; it can
  /// differ from [keyType] when the server changed key algorithm.
  final String? pinnedKeyType;

  @override
  PromptKind get kind => PromptKind.hostKey;
}

/// The server's keyboard-interactive challenge (RFC 4256), shown as the
/// server sent it. It carries no echo flags (`seance_core`'s
/// `KeyboardInteractiveChallenge` has none), so a surface masks every
/// answer. [PromptResponsesAnswer] answers [questions] in order, and
/// [PromptCancelAnswer] declines them.
final class KeyboardInteractivePromptRequest extends PromptRequest {
  const KeyboardInteractivePromptRequest({
    this.user,
    this.name = '',
    this.instruction = '',
    this.questions = const [],
  });

  /// The account the engine signs in as on the asking machine; null
  /// where it does not say.
  final String? user;

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

/// The user declined [PromptKind.keyboardInteractive]'s questions. The
/// engine sends the server no responses, so the attempt fails with
/// [LinkFailureKind.keyboardInteractiveCancelled] at once rather than
/// when the prompt expires. Only that kind takes it: a host key is
/// declined with `PromptTrustAnswer(false)`, a password prompt dismissed
/// with `PromptSecretAnswer(null)`.
final class PromptCancelAnswer extends PromptAnswer {
  const PromptCancelAnswer();
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

  /// A keepalive ping went unanswered past its deadline, or the samplers
  /// stayed silent after one missed a deadline (CN-06, 03 §6.4).
  pingTimeout,

  /// Connecting or authenticating never produced a transport.
  connectFailed,
}

/// What the engine found behind a [LinkClosed]. The first eight are the
/// connect failures protocol version 3 classifies (03 §10.1); the last
/// three are 03 §5.3's client limitations.
enum LinkFailureKind {
  /// The connection was refused, or the host had no route or no address.
  unreachable,

  /// Connecting or the handshake ran past its deadline.
  timedOut,

  /// The server refused every credential offered.
  authenticationRejected,

  /// No credential could be offered: the ssh-agent holds no keys, a key
  /// file could not be read or holds no key the client can use, or a
  /// stored secret is not on this device.
  credentialUnavailable,

  /// The private key is encrypted and the engine has no passphrase that
  /// opens it: none was given, or the one given was wrong. Nothing reached
  /// the server. No prompt asks for one yet, so only an agent holding the
  /// key gets past it.
  keyPassphraseRequired,

  /// Inside the Flatpak sandbox, a key file could not be found: the
  /// sandbox shows only the paths its manifest grants, so a key outside
  /// them reads as missing whether or not it exists (03 §4.5).
  keyFileHiddenBySandbox,

  /// The user, or the background rule, declined a first-seen host key.
  hostKeyDeclined,

  /// The user cancelled keyboard-interactive questions the server or one
  /// of its jump hosts asked ([PromptCancelAnswer]).
  keyboardInteractiveCancelled,

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

/// The request a [SyncStatus] answers.
enum SyncOperation {
  /// [EnrollSync].
  enroll,

  /// [RunSyncRound].
  round,
}

/// Why a sync operation failed (03 §4.3, §4.5).
enum SyncFailure {
  /// This process does not hold the support directory alone (03 §4.10,
  /// D63): the instance lock could not be taken, so the engine signs in
  /// and syncs nothing.
  directoryShared,

  /// `settings.json` gave no device id this session, so no record could
  /// carry this install's authorship.
  noDeviceId,

  /// A round was asked for, but this device is not enrolled.
  notEnrolled,

  /// The device is enrolled in another account; signing out comes later.
  otherAccount,

  /// The server address, account name, password or passphrase is not
  /// one the engine can send (`validateSyncEnrollment`).
  invalidRequest,

  /// The server offered weaker key derivation than the suite accepts, so
  /// no key was derived (03 §4.5).
  kdfDowngrade,

  /// The server refused the account name and password.
  credentialsRejected,

  /// The server refused the stored session: the account was deleted or
  /// signed out elsewhere.
  sessionRejected,

  /// The server could not be reached or did not answer in time.
  unreachable,

  /// The server answered with an error of its own.
  serverError,

  /// The OS keystore could not store or hand over the session token or
  /// the vault key.
  keystoreUnavailable,

  /// A sync state file is left as it is this session, so the operation's
  /// state could not be saved.
  storeUnavailable,

  /// Anything else; [SyncStatus.detail] says what.
  other,
}

/// The enrolled sync account as the app shows it: never a secret.
@immutable
final class SyncAccountInfo {
  const SyncAccountInfo({required this.baseUrl, required this.username});

  final String baseUrl;
  final String username;

  @override
  bool operator ==(Object other) =>
      other is SyncAccountInfo &&
      baseUrl == other.baseUrl &&
      username == other.username;

  @override
  int get hashCode => Object.hash(baseUrl, username);
}

/// What went wrong with a sync state file when the engine opened it (03
/// §4.10, D62).
enum SyncStoreIssueKind {
  /// It was damaged and renamed to [SyncStoreIssue.preservedAs]; the store
  /// started empty.
  recovered,

  /// It could not be read, or was damaged and could not be renamed. It is
  /// left as it is and nothing is saved to it this session.
  leftAsIs,

  /// A newer build wrote it. It is left as it is and nothing is saved to
  /// it this session.
  newerVersion,
}

/// One sync state file's problem at start, carried by [EngineReady].
@immutable
final class SyncStoreIssue {
  const SyncStoreIssue(
    this.fileName,
    this.kind, {
    this.preservedAs,
    this.detail,
  });

  /// The file's name in the support directory, such as
  /// `sync_enrollment.json`.
  final String fileName;
  final SyncStoreIssueKind kind;

  /// The damaged file's new path; set for [SyncStoreIssueKind.recovered]
  /// only.
  final String? preservedAs;

  /// The failure behind [kind], for diagnostics only.
  final String? detail;
}

/// One OS-keystore call a [KeystoreRequest] carries: the engine's
/// `SyncKeystore` port, which the app forwards to `ghost_keystore`'s
/// `MasterKeyManager` under Klabautermann's entry names (03 §4.5, D62).
@immutable
sealed class KeystoreOperation {
  const KeystoreOperation();
}

/// Store [value] under the API-key [name]; answered [KeystoreDone].
final class KeystorePutApiKey extends KeystoreOperation {
  const KeystorePutApiKey(this.name, this.value);

  final String name;
  final String value;
}

/// Read the API-key [name]; answered [KeystoreApiKey].
final class KeystoreGetApiKey extends KeystoreOperation {
  const KeystoreGetApiKey(this.name);

  final String name;
}

/// Forget the API-key [name]; answered [KeystoreDone].
final class KeystoreDeleteApiKey extends KeystoreOperation {
  const KeystoreDeleteApiKey(this.name);

  final String name;
}

/// Read the vault master key without minting one; answered
/// [KeystoreMasterKey].
final class KeystoreReadMasterKey extends KeystoreOperation {
  const KeystoreReadMasterKey();
}

/// Replace the vault master key with [key]; answered [KeystoreDone].
final class KeystoreWriteMasterKey extends KeystoreOperation {
  const KeystoreWriteMasterKey(this.key);

  final Uint8List key;
}

/// The app's answer to a [KeystoreOperation].
@immutable
sealed class KeystoreResult {
  const KeystoreResult();
}

/// A write or delete finished.
final class KeystoreDone extends KeystoreResult {
  const KeystoreDone();
}

/// An API key's value, or null when there is none or the keystore cannot
/// answer.
final class KeystoreApiKey extends KeystoreResult {
  const KeystoreApiKey(this.value);

  final String? value;
}

/// The vault master key, or null when there is none or the keystore cannot
/// answer.
final class KeystoreMasterKey extends KeystoreResult {
  const KeystoreMasterKey(this.key);

  final Uint8List? key;
}

/// The keystore refused the operation; [detail] says why, for diagnostics.
final class KeystoreRefused extends KeystoreResult {
  const KeystoreRefused(this.detail);

  final String detail;
}

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

  /// The Cellular saver column, which reads `timers` and `cron` on
  /// demand: once per [Subscribe] that names them, as soon as the link is
  /// ready and the app is in the foreground (see [Subscribe]).
  cellularSaver,
}

/// What sampling a server is doing, behind [SamplingState].
enum SamplingPhase {
  /// No subscription names the server, so nothing runs, such as for a
  /// monitored server whose surfaces are all hidden. This is not 03
  /// §9.5's "not watched on this device": the app words that from the
  /// monitor set it owns (FL-21, [SetMonitorSet]).
  unsubscribed,

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
/// error output as the host sent it, control characters stripped and
/// at most its last 4,096 characters kept, or null when there was none.
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
    Map<MetricField, MetricWithheldReason> withheld = const {},
  }) : network = _unmodifiable(network),
       withheld = Map.unmodifiable(withheld);

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

  /// The values the engine left null for a reason the app words (D50):
  /// each field of this result whose `/proc` file shows a container
  /// host's figures, whether or not this reading carried it. Empty
  /// outside containers and while the probe cannot tell whether the
  /// server is one.
  final Map<MetricField, MetricWithheldReason> withheld;
}

/// The focused server's reading ([SampleStream.core], OV-01): the
/// overview's values plus per-core busy shares, disk rates, pressure and
/// uptime.
final class CoreResult extends SampleResult {
  CoreResult({
    this.cpu,
    Map<String, double>? perCpu,
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
    Map<MetricField, MetricWithheldReason> withheld = const {},
  }) : perCpu = _unmodifiable(perCpu),
       network = _unmodifiable(network),
       disks = _unmodifiable(disks),
       withheld = Map.unmodifiable(withheld);

  /// As [OverviewResult.cpu].
  final CpuPercentages? cpu;

  /// Busy percent per core (`cpu0`, `cpu1` and so on) since the previous
  /// reading, as CPU-02 shows it; null without one, as
  /// [OverviewResult.network]. The host sends each core's busy and idle
  /// jiffies only, without the per-field breakdown of [cpu] (D48).
  final Map<String, double>? perCpu;

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

  /// As [OverviewResult.withheld].
  final Map<MetricField, MetricWithheldReason> withheld;
}

/// A value of [OverviewResult] or [CoreResult] that
/// [OverviewResult.withheld] or [CoreResult.withheld] can name, after
/// the `/proc` file it comes from (D50).
enum MetricField {
  /// `cpu`, from `/proc/stat`.
  cpu,

  /// [CoreResult.perCpu], from `/proc/stat`.
  perCpu,

  /// `memory`, from `/proc/meminfo`.
  memory,

  /// `load`, from `/proc/loadavg`.
  load,

  /// `loadPerCore`, from `/proc/loadavg` and the CPU count of
  /// `/proc/stat`.
  loadPerCore,

  /// [CoreResult.disks], from `/proc/diskstats`.
  disks,

  /// [CoreResult.cpuPressure], from `/proc/pressure/cpu`.
  cpuPressure,

  /// [CoreResult.ioPressure], from `/proc/pressure/io`.
  ioPressure,

  /// [CoreResult.memoryPressure], from `/proc/pressure/memory`.
  memoryPressure,

  /// [CoreResult.uptime], from `/proc/uptime`.
  uptime,

  /// [CoreResult.bootedAt], from the `btime` line of `/proc/stat`.
  bootedAt,
}

/// Why the engine left a [MetricField] null (D50).
enum MetricWithheldReason {
  /// Inside a container, the field's `/proc` file shows the container
  /// host's figures, not this system's (SYS-04): no lxcfs mount serves
  /// the container's own there, or lxcfs passes the host's through.
  containerHostFigures,
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

  /// Whether the ZFS ARC is part of [usedBytes], and MEM-01's bar says
  /// "ZFS ARC counted as used" (7.1): true where
  /// `/proc/spl/kstat/zfs/arcstats` exists and the `meminfo` shown is the
  /// kernel's own, outside a container or without an lxcfs mount (D48).
  /// Null while the engine does not know.
  final bool? zfsArcCountedAsUsed;
}

/// One `/proc/pressure` file as 7.1 shows it: the shares of time some or
/// all tasks stalled. The host leaves out the kernel's cumulative stall
/// counter (`total`, D48). A line the file lacks stays null.
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
  ProcsResult(List<ProcessRow> processes, {this.totalProcesses, this.selection})
    : processes = List.unmodifiable(processes);

  final List<ProcessRow> processes;

  /// How many processes the host counted; above 500 it sends only some of
  /// them (D48), so PRC-01 says "showing N of M". Null when the host did
  /// not report it.
  ///
  /// [processes] can hold more: with [ProcsSelection.all], a `ps` fallback
  /// adds the processes it lists that the count missed, such as `ps`
  /// itself and those started after the count. The host left processes
  /// out when [selection] is not [ProcsSelection.all] or this count
  /// exceeds the rows, never merely because the two differ.
  final int? totalProcesses;

  /// How the host chose [processes] (D48); null when it did not report it.
  final ProcsSelection? selection;
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
    this.residentBytes,
    this.cpuPercent,
    this.startTicks,
    this.startedAt,
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
  final int? residentBytes;

  /// Its share of one CPU since the previous reading, in percent: above
  /// 100 when it runs on several CPUs, and null on its first reading.
  final double? cpuPercent;

  /// When it started, in clock ticks after boot (field 22 of
  /// `/proc/<pid>/stat`): with [pid], what PRC-02's PID-reuse guard
  /// compares before signalling it.
  final int? startTicks;

  /// When it started by the engine's clock, UTC: the reading's time less
  /// the host's uptime, plus [startTicks] at 100 a second, the USER_HZ the
  /// CPU shares assume too (7.2). Null without either, before the probe
  /// reports its lxcfs mounts, and where lxcfs serves a container's own
  /// age as `/proc/uptime`, since start ticks count from the kernel's
  /// boot (D50).
  final DateTime? startedAt;

  /// The command line, one item per argument (per whitespace token on a
  /// host where only `ps` lists it, 7.2), each masked by 03 §8.9's rules;
  /// null when it could not be read (7.2's "command line unavailable").
  /// Pass an unmodifiable list.
  final List<MaskedValue>? arguments;
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

/// Cron jobs ([SampleStream.cron], 7.7): the parsed table, and its jobs
/// rows with next runs the engine evaluated at the sample's time in the
/// server's zone (D58), since the zone rules stay in the engine (D52).
final class CronResult extends SampleResult {
  CronResult(
    this.cron, {
    List<JobEntry> jobs = const [],
    this.zoneName,
    this.zoneFallback,
  }) : jobs = List.unmodifiable(jobs),
       assert(
         zoneName == null || zoneFallback == null,
         'zoneName and zoneFallback are mutually exclusive '
         '(both null means the server zone is unknown)',
       );

  final CronSnapshot cron;

  /// The cron lines, then the `cron.<period>` scripts, as jobs rows with
  /// their next runs (7.7); the timers' rows come from [TimersResult].
  final List<JobEntry> jobs;

  /// The IANA zone whose rules the server-zone runs follow; null when
  /// they follow the probe's fixed offset or no server zone is known.
  final String? zoneName;

  /// Why the server-zone runs follow the probe's fixed offset; null when
  /// they follow [zoneName]'s rules or no server zone is known, in which
  /// case those rows give `JobRunsUnknown.serverZoneUnknown`.
  final CronZoneFallback? zoneFallback;
}

/// Why [CronResult]'s server-zone runs follow the probe's fixed offset
/// instead of a zone's rules, so no DST change after now shows in them
/// (7.7, D58).
enum CronZoneFallback {
  /// The probe found no IANA zone name.
  noZoneName,

  /// The client's zone database has no zone of that name.
  unknownZone,

  /// The database's offset for the zone at the probe's clock reading
  /// differs from the offset the server reported: the name is stale or
  /// the two zone databases disagree.
  offsetMismatch,
}
