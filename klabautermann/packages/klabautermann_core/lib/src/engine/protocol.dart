import 'dart:typed_data';

// Only plain-data host types cross (D52): none here holds a function, as
// `Collector` (its argument validators) and `ServerZone` (`offsetAt`) do.
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        AnacronJob,
        BackupEntry,
        CpuPercentages,
        CronSnapshot,
        DiskRate,
        FootprintRow,
        FsSnapshot,
        HostProfile,
        JobEntry,
        JournalBoot,
        JournalBootEntry,
        KillSignal,
        LoadAvg,
        LogFileEntry,
        LoggedCronRun,
        NetRate,
        OpDirectoryKind,
        OpDirectoryListing,
        ProcsSelection,
        SystemdUnit,
        SystemctlVerb,
        ThresholdRule,
        TimerLastRun,
        TimersSnapshot,
        UnitResources,
        UnitSocket,
        UnitsSnapshot,
        EngineMode,
        EngineRuntime;
// A masked process argument (03 §8.9): its display and toString carry the
// mask, so the app shows a secret only through the reveal action. The
// Docker models are plain data too: no field holds a function, and the
// engine masks the ones that could hold a secret before they cross.
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show
        ApiVersion,
        ComposeGrouping,
        ContainerHostConfig,
        ContainerMount,
        ContainerNetworkSettings,
        ContainerSummary,
        DockerServerVersion,
        EngineInfo,
        EnvVar,
        ExternalManager,
        HealthStatus,
        ImageSummary,
        MaskedValue,
        SystemDf;
import 'package:meta/meta.dart';
// DangerLinter's findings are plain data: a severity and three values.
import 'package:seance_core/seance_core.dart' show DangerFinding;

import '../docker/docker_ladder.dart'
    show
        DockerNoRouteReason,
        DockerRank,
        DockerRootEquivalence,
        DockerRouteLabel,
        dockerSocketPathProblem;
import '../operations/plan_types.dart';

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
///
/// Docker reads then joined v3 the same way (03 §5.8, §5.9, §10.1):
/// [DockerQuery] gained a `queryId` and reads a sealed [DockerQuerySpec]
/// instead of an endpoint kind and API arguments, [DockerResult] echoes
/// the id and carries a sealed [DockerPayload] of typed, masked values
/// instead of decoded JSON, and [DockerEndpointState] reports the route,
/// the runtime as the Docker API names it and the negotiated version.
///
/// Docker watches then joined v3 the same way (03 §7.12 DKE-02, CST-01):
/// [DockerWatch] and [DockerUnwatch] name the lists a view shows and the
/// containers it wants stats for, and [DockerListChanged] carries each
/// list as a typed [DockerPayload] in place of the opaque `DockerEvent`
/// record, which is gone.
///
/// Container logs then joined v3 the same way (03 §7.12 CTX-01):
/// [ContainerLogSource] reads one container's logs over its server's
/// Docker endpoint as [ContainerRecord]s through the same
/// [OpenLogStream], [LogBatch] and [LogStreamState], and
/// [LogStreamEndReason] gained `logDriverUnreadable`, whose detail names
/// the driver.
///
/// Stack sources then joined v3 the same way (03 §7.16 STK-01, STK-04,
/// STK-05): [DockerStacksPayload] gained each project's [StackVerdict]
/// and the [DockerComposeCli] found, and [DockerStackFileQuery] reads a
/// verified stack's file, answered by [DockerStackFilePayload] or
/// [DockerStackFileFailed].
///
/// Operation plans then joined v3 the same way (03 §8.5, §10.1, M4 E09):
/// [ActionIntent] became sealed, one variant per MVP action, [ActionPreview]
/// carries the plan's typed steps, host writes, runner and risk facts
/// instead of display strings, and [ActionRefused] answers a [PlanAction]
/// or [RunAction] the engine will not carry out. Admin mode and the safety
/// policy joined next (03 §8.2, M4 E11): [SetSafetyPolicy], [SetAdminMode]
/// and [AdminModeState].
///
/// Low-session mode then set [DockerEndpointState.lowSession] (03 §5.2,
/// M9), which goes out again when a link learns a session limit; no
/// message changed shape.
///
/// CN-09's endpoint choice then joined v3 the same way (D54):
/// [SetDockerEndpoint] carries a sealed [DockerEndpointChoice] the app
/// keeps per server on the device, [DockerEndpointState] gained the
/// choice it resolved with, [DockerEndpointFailure] gained
/// `invalidChoice`, and [DockerComposeQuery], answered by
/// [DockerComposePayload], reads the compose CLIs for the Access tab
/// without a stacks watch.
/// Disk use then joined v3 the same way (03 §7.1 OV-05): a
/// [DockerSystemDfQuery] reads `/system/df` on demand, answered by a
/// [DockerSystemDfPayload] of per-type totals.
///
/// The vault then joined v3 the same way (03 §4.5, SYN-02, FL-03):
/// [SetSyncSecrets] carries the device's "sync passwords" switch,
/// [CredentialPromptRequest] gained `canSave` and [PromptSecretAnswer]
/// `save`, which keeps a login password in the vault.
///
/// Container shells then joined v3 the same way (03 §7.13 CTX-07):
/// [OpenTerminal], [TerminalInput], [TerminalResize], [TerminalEndInput]
/// and [CloseTerminal] run one, answered by [TerminalOpened],
/// [TerminalBytes] and [TerminalClosed]. One-off commands joined next
/// (CTX-08): [ContainerExec] is planned as an action, and
/// [ActionFinished] gained the [ExecOutput] it captured.
///
/// Synced settings then joined v3 the same way (03 §4.8, M5 plan M04):
/// [ServerPrefsChanged] carries a server's pulled `pref` record as
/// [ServerPrefs], and [SyncStatus] gained [SyncStatus.prefixBudget].
///
/// The v1 log sources then joined v3 the same way (03 §7.6, LOG-06 to
/// LOG-10): [JournalLogSource] gained `grep` and `boot`,
/// [KernelLogSource] `boot`, [FileLogSource] `compressed`, and
/// [LogStreamEndReason] `searchUnsupported`; [HostQuery], answered by
/// [HostResult], lists `/var/log` and the journal's boots; and
/// [RedactLines], answered by [RedactedLines], redacts an export.
///
/// The v1 unit rows then joined v3 the same way (03 §7.5, SVC-05 to
/// SVC-10): [UnitAction] and [StartTimer] gained a [UnitScope], and
/// [UnitQuery], answered by [UnitQueryResult], reads a unit's file, its
/// resources or the sockets. [SampleStream] gained `userUnits` and
/// `userTimers`, the login user's own manager's units and timers, which
/// cross as [UnitsResult] and [TimersResult].
///
/// Job history then joined v3 the same way (03 §7.7, JOB-04, JOB-05):
/// [JobHistoryQuery], answered by [JobHistoryResult], reads anacron's
/// jobs and stamps, a timer's last run, or the runs cron logged.
///
/// The edit pipeline then joined v3 the same way (03 §8.5, SAF-12):
/// [ReadEditable], answered by [EditRead], reads an [EditTarget] for the
/// editor; the [EditFile] intent plans its write; [RevalidationFailure]
/// gained `contentChanged` for a target changed under the write.
///
/// The footprint then joined v3 the same way (03 §8.11, SAF-14):
/// [FootprintQuery], answered by [FootprintState], which the engine also
/// sends unasked; the [KeepLastBackups] and [RemoveBackups] intents plan
/// backup removal.
///
/// Running a cron line now then joined v3 the same way (03 §7.7,
/// JOB-19): [RunCronJob] is planned as a host action, and reports its
/// output as [ContainerExec] does.
///
/// Stack files and folders then joined v3 the same way (03 §7.16 STK-07
/// to STK-09): a [StackFileTarget] edits a verified stack's file through
/// the same pipeline, [DockerStackProfilesQuery] lists the profiles its
/// files name, and [DockerStackScanQuery] finds compose files in the
/// folders the user chose.
///
/// Catalog writes then joined v3 the same way (03 §4.4, M5 plan M05):
/// [ReadServerDraft], [SaveServer], [DeleteServer], [SetServerPrefs],
/// [PutRule] and [RemoveRule], answered by [ServerDraftRead],
/// [CatalogWritten] and [CatalogWriteRefused].
const int kEngineProtocolVersion = 3;

/// The most container shells one server holds open at once [E]: each on a
/// relay holds a session channel (03 §5.2).
const int kTerminalsPerServerMax = 4;

/// The largest terminal [OpenTerminal] and [TerminalResize] take, in
/// either dimension.
const int kTerminalDimensionMax = 1000;

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
/// its journal, then the pulled records applied. Since v1 (D14's end, M5
/// plan M05) the catalog seals local edits; enrollment itself pushes
/// nothing. Answered by
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

/// Runs one sync round on the enrolled account: a pull, applied, then a
/// push of every record this device sealed since, in batches the server
/// allows (03 §4.4; pull-only until v1, D14). Answered
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

/// Reads one unit's details, or the sockets, on [serverId] (03 §7.5,
/// SVC-07, SVC-08, SVC-10), answered by one [UnitQueryResult] with
/// [requestId]. Each reads as the login user, never through sudo.
final class UnitQuery extends EngineRequest {
  const UnitQuery({
    required this.serverId,
    required this.requestId,
    required this.query,
  });

  final String serverId;
  final String requestId;
  final UnitQuerySpec query;
}

/// What a [UnitQuery] reads.
@immutable
sealed class UnitQuerySpec {
  const UnitQuerySpec({this.scope = UnitScope.system});

  final UnitScope scope;
}

/// [unit]'s file and drop-ins (`systemctl cat`, SVC-07), answered by
/// [UnitFilePayload].
final class UnitFileQuery extends UnitQuerySpec {
  const UnitFileQuery(this.unit, {super.scope});

  final String unit;
}

/// [unit]'s resources (`systemctl show`, SVC-08), answered by
/// [UnitResourcesPayload].
final class UnitResourcesQuery extends UnitQuerySpec {
  const UnitResourcesQuery(this.unit, {super.scope});

  final String unit;
}

/// The manager's sockets (`systemctl list-sockets`, SVC-10), answered by
/// [UnitSocketsPayload].
final class SocketsQuery extends UnitQuerySpec {
  const SocketsQuery({super.scope});
}

/// Reads one piece of [serverId]'s job history (03 §7.7, JOB-04, JOB-05),
/// answered by one [JobHistoryResult] with [requestId]. Each reads as the
/// login user, or through admin mode when it is on, which the journal of
/// cron's runs may need.
final class JobHistoryQuery extends EngineRequest {
  const JobHistoryQuery({
    required this.serverId,
    required this.requestId,
    required this.query,
  });

  final String serverId;
  final String requestId;
  final JobHistorySpec query;
}

/// What a [JobHistoryQuery] reads.
@immutable
sealed class JobHistorySpec {
  const JobHistorySpec();
}

/// `/etc/anacrontab` with each job's stamp (JOB-04), answered by
/// [AnacronPayload].
final class AnacronQuery extends JobHistorySpec {
  const AnacronQuery();
}

/// [timer]'s last trigger and how [service]'s run ended (JOB-05),
/// answered by [TimerLastRunPayload].
final class TimerLastRunQuery extends JobHistorySpec {
  const TimerLastRunQuery({required this.timer, required this.service});

  final String timer;
  final String service;
}

/// The newest [lines] job starts cron logged (JOB-05), answered by
/// [CronRunsPayload].
final class CronRunsQuery extends JobHistorySpec {
  const CronRunsQuery({this.lines = 50});

  final int lines;
}

/// Reads [target] on [serverId] for an edit (03 §8.5, SAF-12), answered
/// by one [EditRead] with [requestId]: the content and its SHA-256,
/// which an [EditFile] names, and who owns it. A file the login user
/// cannot read is read through admin mode when it is on.
final class ReadEditable extends EngineRequest {
  const ReadEditable({
    required this.serverId,
    required this.requestId,
    required this.target,
  });

  final String serverId;
  final String requestId;
  final EditTarget target;
}

/// Verifies [serverId]'s footprint again (SAF-14, P13): answered by a
/// [FootprintState]. The engine also verifies it on every connect, and
/// root's part when admin mode turns on.
final class FootprintQuery extends EngineRequest {
  const FootprintQuery(this.serverId);

  final String serverId;
}

/// Runs one read-only Docker Engine query on [serverId]'s engine (03
/// §7.12 to §7.14, §10.1), answered by one [DockerResult] with [queryId].
/// The first query for a server has the engine find its route and
/// negotiate the API (03 §5.8, §5.9), which [DockerEndpointState] then
/// reports. Mutations go through [PlanAction]/[RunAction] so every write
/// is previewed and confirmed.
final class DockerQuery extends EngineRequest {
  const DockerQuery({
    required this.serverId,
    required this.queryId,
    required this.query,
  });

  final String serverId;

  /// The app's own id for the query, which its [DockerResult] carries.
  /// The engine echoes it and does not check it for reuse.
  final String queryId;

  final DockerQuerySpec query;
}

/// Runs one read-only host query on [serverId] over its link (03 §7.6),
/// answered by one [HostResult] with [queryId]. A server without a ready
/// link is answered at once with [HostQueryFailure.noLink].
final class HostQuery extends EngineRequest {
  const HostQuery({
    required this.serverId,
    required this.queryId,
    required this.query,
  });

  final String serverId;

  /// The app's own id for the query, which its [HostResult] carries.
  final String queryId;

  final HostQuerySpec query;
}

/// What a [HostQuery] reads.
@immutable
sealed class HostQuerySpec {
  const HostQuerySpec();
}

/// The regular files under `/var/log`, two levels deep (LOG-08), as
/// [VarLogFiles].
final class VarLogQuery extends HostQuerySpec {
  const VarLogQuery();
}

/// The journal's boots (LOG-09), as [JournalBoots]: `journalctl
/// --list-boots` as JSON on systemd 251 and later, the text table on
/// older ones and where the probe found no version.
final class BootsQuery extends HostQuerySpec {
  const BootsQuery();
}

/// Redacts [lines] the app holds for an export (LOG-10, 03 §8.9) through
/// the engine's secret redactor, which the app cannot import, answered
/// by [RedactedLines] with [requestId].
final class RedactLines extends EngineRequest {
  const RedactLines(this.requestId, this.lines);

  final String requestId;
  final List<String> lines;
}

/// Watches [lists] on [serverId]'s engine (03 §7.12 DKE-02, CST-01), as
/// [DockerListChanged] events, until [DockerUnwatch] or the session
/// ends. While any watch holds, the engine follows the engine's
/// `/events` and reads a list again when an event changes it; with
/// [DockerWatchList.stats] it reads one-shot stats for [statsFor]'s
/// containers at the list cadence. A watch with a [watchId] the server
/// already holds replaces it, which is how a view reports the rows it
/// shows now. Like a [DockerQuery], it opens the server's endpoint, and
/// it starts once the endpoint is ready. A watch the engine cannot hold
/// is answered with a [DockerQueryFailed] list for each of its [lists].
final class DockerWatch extends EngineRequest {
  const DockerWatch({
    required this.serverId,
    required this.watchId,
    required this.lists,
    this.statsFor = const {},
  });

  final String serverId;

  /// The app's own id for the watch, unique per server.
  final String watchId;
  final Set<DockerWatchList> lists;

  /// The containers, by id, whose stats [DockerWatchList.stats] reads:
  /// the rows on screen (CST-01). At most [kDockerStatsForMax].
  final Set<String> statsFor;
}

/// Ends the [DockerWatch] [watchId] on [serverId]. The last one ends the
/// server's `/events` stream and stats reads; ending a watch the server
/// does not hold does nothing.
final class DockerUnwatch extends EngineRequest {
  const DockerUnwatch({required this.serverId, required this.watchId});

  final String serverId;
  final String watchId;
}

/// Sets which engine socket [serverId]'s Docker endpoint uses (CN-09,
/// D54): the app's per-server choice from `settings.json` (03 §4.10),
/// sent as the user changes it and again each time the server's link
/// comes up. The engine keeps it until another arrives or the server
/// leaves the fleet or changes endpoint (SYN-08), and a session that
/// holds an endpoint resolves again with it at once; the same choice
/// again changes nothing. A socket choice is the ladder's first
/// candidate, ahead of the sockets the probe found (03 §5.4), so one
/// that answers on no rung gives way to them; [DockerEndpointState]
/// carries the choice and the route found, which tell the two apart. A
/// path [dockerSocketPathProblem] refuses fails the endpoint with
/// [DockerEndpointFailure.invalidChoice]. Ignored for a server outside
/// the fleet.
final class SetDockerEndpoint extends EngineRequest {
  const SetDockerEndpoint({required this.serverId, required this.choice});

  final String serverId;
  final DockerEndpointChoice choice;
}

/// Previews an operation: the engine answers [ActionPlanned], or
/// [ActionRefused], and nothing runs until [RunAction] carries the
/// matching plan id (03 §8.5, §10.1).
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

/// The safety preferences the app keeps in `settings.json` (03 §4.10, M4
/// plan M4), sent at spawn and on every change. The engine enforces them:
/// until the first one arrives, every server is observe-only.
final class SetSafetyPolicy extends EngineRequest {
  const SetSafetyPolicy(this.policy);

  final SafetyPolicy policy;
}

/// Opens a shell in [containerId] on [serverId] (03 §7.13, CTX-07): an
/// exec with a TTY over the API upgrade (03 §5.7). [shell] null runs
/// `/bin/bash` where the container has it and `/bin/sh` otherwise;
/// [user] null runs as the container's user. Refused, as an action is,
/// on an observe-only or read-only server. Answered by [TerminalOpened],
/// then [TerminalBytes], and by [TerminalClosed] once, also when the
/// shell never starts. The id is the app's and must be new.
final class OpenTerminal extends EngineRequest {
  const OpenTerminal({
    required this.terminalId,
    required this.serverId,
    required this.containerId,
    this.shell,
    this.user,
    required this.columns,
    required this.rows,
  });

  final String terminalId;
  final String serverId;
  final String containerId;
  final String? shell;
  final String? user;

  /// The terminal's size, at most [kTerminalDimensionMax] each.
  final int columns;
  final int rows;
}

/// Keystrokes and pastes for [terminalId]'s shell, as the terminal
/// encoded them.
final class TerminalInput extends EngineRequest {
  const TerminalInput(this.terminalId, this.bytes);

  final String terminalId;
  final Uint8List bytes;
}

/// [terminalId]'s terminal changed size. The engine passes each size on
/// in the order it came, columns as Docker's `w` and rows as its `h`.
final class TerminalResize extends EngineRequest {
  const TerminalResize(
    this.terminalId, {
    required this.columns,
    required this.rows,
  });

  final String terminalId;
  final int columns;
  final int rows;
}

/// Ends [terminalId]'s input: stdin EOF as a half-close (03 §5.7), while
/// its output keeps coming until the shell exits.
final class TerminalEndInput extends EngineRequest {
  const TerminalEndInput(this.terminalId);

  final String terminalId;
}

/// Closes [terminalId]'s shell; [TerminalClosed] follows with
/// [TerminalCloseReason.closed]. An id with no open shell does nothing.
final class CloseTerminal extends EngineRequest {
  const CloseTerminal(this.terminalId);

  final String terminalId;
}

/// The device's "sync passwords" switch (03 §4.5, SYN-02), which the app
/// keeps in `settings.json` as `klabautermann.sync.secrets`, sent at spawn
/// and on every change. Until it arrives the switch is off: sync rounds
/// apply no pulled `secret:` record to the vault.
final class SetSyncSecrets extends EngineRequest {
  const SetSyncSecrets({required this.enabled});

  final bool enabled;
}

/// The suite release whose Séance carries the #56 fix (D15, FL-22): the
/// release a pin publication assertion names. Null until a suite release
/// carries the fix (M5 plan Q1), so no assertion is offered and the
/// engine publishes no pin.
const String? kPinPublicationRelease = null;

/// Asserts that every device on the account runs the release
/// [PinPublicationState.release] names or later, or withdraws that with
/// [asserted] false (D15, M5 plan M07). While asserted, a pin the user
/// confirms is published; a withdrawal stops publication, and pins sent
/// stay. Refused while no release is offered.
final class SetPinPublication extends EngineRequest {
  const SetPinPublication({required this.asserted});

  final bool asserted;
}

/// How a [ServerDraft]'s server signs in, as the server editor offers it
/// (`GhostAuthMethod`, ghost-servers-part2.md section 3).
enum ServerDraftAuth { agent, password, privateKey }

/// A synced server as the server editor shows it (FL-03,
/// ghost-servers-part2.md section 3): the shown fields of its
/// `ServerConfig`, in their stored forms, with colour and icon as the
/// protocol's enum names. [SaveServer] maps it onto the stored config, so
/// a field the editor does not show, such as the jump route, the
/// credential reference or the creation time, keeps its stored value
/// (03 §4.4, "Write semantics").
@immutable
final class ServerDraft {
  const ServerDraft({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.username,
    required this.auth,
    this.syncSecret = false,
    this.excludeFromSync = false,
    this.identityFilePath,
    this.group,
    this.colorName,
    this.customColor,
    this.iconName,
    this.iconEmoji,
    this.iconImage,
    this.loginScript,
    this.startDirectory,
  });

  /// The server's id: a stored server's, or a new UUID for one to add.
  final String id;
  final String label, host, username;
  final int port;
  final ServerDraftAuth auth;

  /// Whether the server's credential syncs with it (SYN-02).
  final bool syncSecret;

  /// Whether the server stays on this device only: a save retracts it
  /// from the account.
  final bool excludeFromSync;

  /// A private key file on this device, read by its path.
  final String? identityFilePath;
  final String? group, colorName, customColor;
  final String? iconName, iconEmoji, iconImage;
  final String? loginScript, startDirectory;

  List<Object?> get _fields => [
    id,
    label,
    host,
    port,
    username,
    auth,
    syncSecret,
    excludeFromSync,
    identityFilePath,
    group,
    colorName,
    customColor,
    iconName,
    iconEmoji,
    iconImage,
    loginScript,
    startDirectory,
  ];

  @override
  bool operator ==(Object other) =>
      other is ServerDraft && _sameItems(_fields, other._fields);

  @override
  int get hashCode => Object.hashAll(_fields);
}

/// A [SaveServer]'s credential boxes as the user typed them
/// (`GhostCredentialEntry`, ghost-servers-part2.md section 3). The engine
/// plans the vault entry from them with `seance_protocol`'s
/// `plannedCredential`, reading the stored entry where a referenced key
/// keeps it, so a stored private key never crosses to the UI isolate.
/// Blank boxes keep what is stored.
final class ServerCredentialEntry {
  const ServerCredentialEntry({
    this.referenceKeyFile = false,
    this.password = '',
    this.keyPem = '',
    this.keyPassphrase = '',
  });

  /// Whether the key is read from [ServerDraft.identityFilePath] rather
  /// than pasted.
  final bool referenceKeyFile;
  final String password, keyPem, keyPassphrase;
}

/// Reads the synced server [serverId] as the editor shows it, answered by
/// [ServerDraftRead] (FL-03).
final class ReadServerDraft extends EngineRequest {
  const ReadServerDraft({required this.requestId, required this.serverId});

  final String requestId;
  final String serverId;
}

/// Saves [draft] as a synced server and seals its `serverConfig` record,
/// with the credential [credential] plans, for the next round to push
/// (03 §4.4, FL-03). The saved endpoint counts as confirmed on this
/// device (M5 plan P16). Answered by [CatalogWritten] or
/// [CatalogWriteRefused]; a written one sends the fleet and the
/// preferences just before its answer, and a round's [SyncStatus] after.
final class SaveServer extends EngineRequest {
  const SaveServer({
    required this.requestId,
    required this.draft,
    this.credential,
  });

  final String requestId;
  final ServerDraft draft;

  /// The boxes as typed; null writes no credential.
  final ServerCredentialEntry? credential;
}

/// Deletes the synced server [serverId]: its tombstone is persisted
/// before its row drops, and its credential's record is retracted unless
/// another synced server shares it (03 §4.4). Answered as [SaveServer].
final class DeleteServer extends EngineRequest {
  const DeleteServer({required this.requestId, required this.serverId});

  final String requestId;
  final String serverId;
}

/// Sets the synced server [serverId]'s preferences and seals its `pref`
/// record (03 §4.8, SYN-04); null seals a removal, so every device falls
/// back to its defaults. Answered as [SaveServer], and with a
/// [ServerPrefsChanged].
final class SetServerPrefs extends EngineRequest {
  const SetServerPrefs({
    required this.requestId,
    required this.serverId,
    required this.prefs,
  });

  final String requestId;
  final String serverId;
  final ServerPrefs? prefs;
}

/// Seals the alert rule [ruleId] as its `rule` record (03 §4.8); no
/// surface sends it yet. Answered as [SaveServer].
final class PutRule extends EngineRequest {
  const PutRule({
    required this.requestId,
    required this.ruleId,
    required this.rule,
    this.target,
  });

  final String requestId;

  /// The rule's UUID.
  final String ruleId;
  final ThresholdRule rule;

  /// The server id or group name a `server` or `group` scoped rule names.
  final String? target;
}

/// Seals the removal of the alert rule [ruleId] (03 §4.8). Answered as
/// [SaveServer].
final class RemoveRule extends EngineRequest {
  const RemoveRule({required this.requestId, required this.ruleId});

  final String requestId;
  final String ruleId;
}

/// Turns admin mode on or off for [serverId] (03 §8.2, SAF-02). Turning
/// it on detects how to elevate and asks for the password only when that
/// needs one; [AdminModeState] reports each step.
final class SetAdminMode extends EngineRequest {
  const SetAdminMode(this.serverId, {required this.enabled});

  final String serverId;
  final bool enabled;
}

/// Reads [serverId]'s device audit log (03 §8.10, SAF-11): up to [limit]
/// records ended before [before] (newest first; all when null), answered
/// by [AuditRecords].
final class AuditQuery extends EngineRequest {
  const AuditQuery(this.serverId, {this.before, this.limit = 100})
    : assert(limit > 0, 'limit must be positive');

  final String serverId;
  final DateTime? before;
  final int limit;
}

/// Says the app has shown the result of [serverId]'s finished detached
/// operation [id] (03 §7.17): the engine audits the result and deletes
/// the operation's files, those in the root directory once admin mode is
/// on. An [OperationsChanged] follows; an operation that is not listed
/// as finished is a [RequestRejected].
final class AcknowledgeOperation extends EngineRequest {
  const AcknowledgeOperation(this.serverId, this.id);

  final String serverId;
  final String id;
}

/// Reads every user's crontab on [serverId] (JOB-03, 03 §7.7, M14): in
/// admin mode only, tier 0 and never cached. One [UserCrontabs] with
/// [requestId] answers it.
final class ReadUserCrontabs extends EngineRequest {
  const ReadUserCrontabs(this.serverId, {required this.requestId});

  final String serverId;
  final String requestId;
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
    this.auditInMemory = false,
    this.pinPublication,
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

  /// The audit log lives in memory only: another instance may write the
  /// support directory (03 §4.10), so this one writes no audit file. The
  /// app says so once (M4 plan M12).
  final bool auditInMemory;

  /// The pin publication state the engine started with (D15, M5 plan
  /// M07), or null while no release is offered. Later changes arrive in
  /// [PinPublicationState].
  final PinPublicationState? pinPublication;
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
    this.prefixBudget,
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

  /// How much of the account the `klabautermann:` records take, after a
  /// succeeded operation; null otherwise.
  final SyncPrefixBudget? prefixBudget;
}

/// The account budget of the `klabautermann:` records (03 §4.8): at most
/// [kSyncPrefixBudgetBytes] of sealed blobs, with a warning from
/// [kSyncPrefixWarnFraction] of it (SYN-09's account size view).
@immutable
final class SyncPrefixBudget {
  const SyncPrefixBudget(this.usedBytes);

  /// The sealed blobs of every live `klabautermann:` record the account
  /// holds, as this device last pulled them.
  final int usedBytes;

  /// Whether the records take [kSyncPrefixWarnFraction] of the budget or
  /// more.
  bool get warns =>
      usedBytes >= kSyncPrefixBudgetBytes * kSyncPrefixWarnFraction;

  /// Whether the records take the whole budget or more.
  bool get full => usedBytes >= kSyncPrefixBudgetBytes;
}

/// The `klabautermann:` prefix's account budget [E] (03 §4.8).
const int kSyncPrefixBudgetBytes = 1024 * 1024;

/// The share of [kSyncPrefixBudgetBytes] from which the budget warns [E]
/// (03 §4.8).
const double kSyncPrefixWarnFraction = 0.8;

/// One server's synced preferences, its `pref` record (03 §4.8, SYN-04).
/// Every field defaults to what a server without a record has.
@immutable
final class ServerPrefs {
  const ServerPrefs({
    this.readOnly = false,
    this.cadence,
    this.pinnedUnits = const [],
    this.pinnedContainers = const [],
    this.marks = const {},
    this.panelOrder = const [],
    this.hostAuditLine = true,
    this.stackScanDirs = const [],
  });

  /// The server's own read-only switch (SAF-06).
  final bool readOnly;

  /// The cadence preset chosen for the server; null leaves the device's.
  final CadenceProfile? cadence;

  /// Units and containers pinned to the top of their lists, by name.
  final List<String> pinnedUnits, pinnedContainers;

  /// Targets the user marked protected (SAF-22): unit, container and
  /// stack names.
  final Set<String> marks;

  /// The server's panels in the user's order, by name; a panel it does
  /// not name keeps its place after them.
  final List<String> panelOrder;

  /// Whether a run writes its syslog line on the host (SAF-13).
  final bool hostAuditLine;

  /// Absolute directories the stack scan looks in (STK-01).
  final List<String> stackScanDirs;

  /// These preferences with the safety fields replaced (M5 plan M06).
  ServerPrefs copyWith({bool? readOnly, Set<String>? marks}) => ServerPrefs(
    readOnly: readOnly ?? this.readOnly,
    cadence: cadence,
    pinnedUnits: pinnedUnits,
    pinnedContainers: pinnedContainers,
    marks: marks ?? this.marks,
    panelOrder: panelOrder,
    hostAuditLine: hostAuditLine,
    stackScanDirs: stackScanDirs,
  );
}

/// Whether pins the user confirms publish (D15, M5 plan M07): [release]
/// is the release an assertion names, null while none is offered, and
/// [asserted] whether this device's enrollment holds the assertion for
/// it. [EngineReady.pinPublication] holds the state at start; this is
/// sent after each [SetPinPublication] while a release is offered.
final class PinPublicationState extends EngineEvent {
  const PinPublicationState({this.release, this.asserted = false});

  final String? release;
  final bool asserted;
}

/// The synced preferences of the fleet server [serverId] changed (03
/// §4.8): a pulled `pref` record applied, was removed, or its server
/// arrived or left. [prefs] is null when the server has no record, or a
/// sealed removal dropped it, so the device's defaults apply. The engine
/// sends every server's after [EngineReady] and then only changes.
final class ServerPrefsChanged extends EngineEvent {
  const ServerPrefsChanged(this.serverId, this.prefs);

  final String serverId;
  final ServerPrefs? prefs;
}

/// The answer to a [ReadServerDraft]: [draft] is null when the fleet
/// has no synced server by that id, or the catalog cannot be read.
final class ServerDraftRead extends EngineEvent {
  const ServerDraftRead({required this.requestId, required this.draft});

  final String requestId;
  final ServerDraft? draft;
}

/// A catalog write ([SaveServer], [DeleteServer], [SetServerPrefs],
/// [PutRule], [RemoveRule]) is sealed on this device; the round the
/// engine runs next pushes it.
final class CatalogWritten extends EngineEvent {
  const CatalogWritten({
    required this.requestId,
    this.serverId,
    this.credentialWritten = false,
  });

  final String requestId;

  /// The server written, or null for a rule.
  final String? serverId;

  /// Whether a [SaveServer] stored a credential in the vault, which the
  /// editor's recovery offer needs.
  final bool credentialWritten;
}

/// Why a catalog write was refused (03 §4.4).
enum CatalogWriteFailure {
  /// Another process may hold the support directory (D63), or this
  /// session has no device id.
  directoryShared,

  /// No sync account is enrolled: editing needs one (M5 plan P16).
  notEnrolled,

  /// The keystore holds no account key, or could not answer.
  keystoreUnavailable,

  /// The fleet has no synced server, or the account no rule, by that id;
  /// or the server is excluded from sync, so its preferences stay local.
  unknownTarget,

  /// A field is missing or out of range, such as a blank host or a port
  /// outside 1 to 65535.
  invalidDraft,

  /// The account holds as many records of the type as 03 §4.8 allows.
  tooMany,

  /// The sealed record would be larger than 03 §4.8 allows its type.
  tooLarge,

  /// A sync state file is left as it is this session (D62), so the write
  /// could not be saved.
  storeUnavailable,

  /// Anything else; [CatalogWriteRefused.detail] says what.
  other,
}

/// A catalog write was refused, and nothing was written.
final class CatalogWriteRefused extends EngineEvent {
  const CatalogWriteRefused({
    required this.requestId,
    required this.failure,
    this.detail,
  });

  final String requestId;
  final CatalogWriteFailure failure;
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
             (stream == SampleStream.cron && result is CronResult) ||
             (stream == SampleStream.userUnits && result is UnitsResult) ||
             (stream == SampleStream.userTimers && result is TimersResult),
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

/// The answer to the [UnitQuery] [requestId] on [serverId]: what it read,
/// or [UnitQueryFailed] with why, plus the parser's warnings.
final class UnitQueryResult extends EngineEvent {
  UnitQueryResult({
    required this.serverId,
    required this.requestId,
    required this.payload,
    Iterable<String> warnings = const [],
  }) : warnings = List.unmodifiable(warnings);

  final String serverId;
  final String requestId;
  final UnitPayload payload;
  final List<String> warnings;
}

/// What a [UnitQuery] found.
@immutable
sealed class UnitPayload {
  const UnitPayload();
}

/// A unit's file and drop-ins as `systemctl cat` prints them, each after
/// a `# <path>` line, with `Environment=` values and secrets in `Exec`
/// lines masked (03 §8.9).
final class UnitFilePayload extends UnitPayload {
  UnitFilePayload(Iterable<MaskedValue> text) : text = List.unmodifiable(text);

  final List<MaskedValue> text;
}

final class UnitResourcesPayload extends UnitPayload {
  const UnitResourcesPayload(this.resources);

  final UnitResources resources;
}

final class UnitSocketsPayload extends UnitPayload {
  UnitSocketsPayload(Iterable<UnitSocket> sockets)
    : sockets = List.unmodifiable(sockets);

  final List<UnitSocket> sockets;
}

/// Why a [UnitQuery] read nothing.
enum UnitQueryFailure {
  /// The server is not in the fleet, or has no ready link or probe.
  noLink,

  /// The unit name is not a unit's (03 §8.8).
  invalidUnit,

  /// The manager has no such unit.
  notFound,

  /// The login user's manager could not be reached: no user session and
  /// no linger (SVC-09).
  managerUnavailable,

  /// The command failed otherwise; the detail says how.
  failed,
}

final class UnitQueryFailed extends UnitPayload {
  const UnitQueryFailed(this.failure, {this.detail});

  final UnitQueryFailure failure;

  /// The host's error text, for [UnitQueryFailure.failed].
  final String? detail;
}

/// The answer to the [JobHistoryQuery] [requestId] on [serverId]: what
/// it read, or [JobHistoryFailed] with why, plus the parser's warnings.
final class JobHistoryResult extends EngineEvent {
  JobHistoryResult({
    required this.serverId,
    required this.requestId,
    required this.payload,
    Iterable<String> warnings = const [],
  }) : warnings = List.unmodifiable(warnings);

  final String serverId;
  final String requestId;
  final JobHistoryPayload payload;
  final List<String> warnings;
}

/// What a [JobHistoryQuery] found.
@immutable
sealed class JobHistoryPayload {
  const JobHistoryPayload();
}

/// anacron's jobs, their commands masked (03 §8.9).
final class AnacronPayload extends JobHistoryPayload {
  AnacronPayload(Iterable<AnacronJob> jobs) : jobs = List.unmodifiable(jobs);

  final List<AnacronJob> jobs;
}

final class TimerLastRunPayload extends JobHistoryPayload {
  const TimerLastRunPayload(this.lastRun);

  final TimerLastRun lastRun;
}

/// cron's logged job starts, newest first, their commands masked.
final class CronRunsPayload extends JobHistoryPayload {
  CronRunsPayload(Iterable<LoggedCronRun> runs)
    : runs = List.unmodifiable(runs);

  final List<LoggedCronRun> runs;
}

/// Why a [JobHistoryQuery] read nothing.
enum JobHistoryFailure {
  /// The server is not in the fleet, or has no ready link.
  noLink,

  /// A timer or unit name is not a unit's (03 §8.8).
  invalidTarget,

  /// The host has no `/etc/anacrontab`, so anacron is not installed.
  notInstalled,

  /// The command failed otherwise; the detail says how.
  failed,
}

final class JobHistoryFailed extends JobHistoryPayload {
  const JobHistoryFailed(this.failure, {this.detail});

  final JobHistoryFailure failure;
  final String? detail;
}

/// The answer to the [DockerQuery] [queryId] on [serverId] (03 §10.1):
/// what it read, or [DockerQueryFailed] with why, plus the parser's
/// warnings (03 §3.4's ParseResult convention).
final class DockerResult extends EngineEvent {
  const DockerResult({
    required this.serverId,
    required this.queryId,
    required this.payload,
    this.warnings = const [],
  });

  final String serverId;
  final String queryId;
  final DockerPayload payload;
  final List<String> warnings;
}

/// The answer to the [HostQuery] with [queryId]. [warnings] name the rows
/// the parser skipped.
final class HostResult extends EngineEvent {
  const HostResult({
    required this.serverId,
    required this.queryId,
    required this.payload,
    this.warnings = const [],
  });

  final String serverId;
  final String queryId;
  final HostPayload payload;
  final List<String> warnings;
}

/// What a [HostResult] carries.
@immutable
sealed class HostPayload {
  const HostPayload();
}

/// [VarLogQuery]'s files, sorted by path.
final class VarLogFiles extends HostPayload {
  const VarLogFiles(this.files);

  final List<LogFileEntry> files;
}

/// [BootsQuery]'s boots, oldest first, as journalctl lists them.
final class JournalBoots extends HostPayload {
  const JournalBoots(this.boots);

  final List<JournalBootEntry> boots;
}

/// A [HostQuery] that read nothing; [detail] is the end of its stderr,
/// or the text of an error the read threw (a timeout or a lost link).
final class HostQueryFailed extends HostPayload {
  const HostQueryFailed(this.failure, {this.detail});

  final HostQueryFailure failure;
  final String? detail;
}

/// Why a [HostQuery] read nothing.
enum HostQueryFailure {
  /// The server has no ready link.
  noLink,

  /// The host refused the read.
  denied,

  /// The tool the query runs is absent on the host.
  missing,

  /// The read failed otherwise: a timeout, a lost link, or an exit the
  /// query does not expect.
  failed,
}

/// [RedactLines]' lines, redacted, joined with newlines.
final class RedactedLines extends EngineEvent {
  const RedactedLines(this.requestId, this.text);

  final String requestId;
  final String text;
}

/// What the engine knows of [serverId]'s Docker endpoint (03 §5.8, §5.9),
/// so the server header names the transport in every mode (E4). Sent
/// once a [DockerQuery] has named the server, and whenever the phase,
/// route or negotiated version changes.
final class DockerEndpointState extends EngineEvent {
  const DockerEndpointState({
    required this.serverId,
    required this.phase,
    this.route,
    this.negotiatedApi,
    this.lowSession = false,
    this.failure,
    this.noRouteReason,
    this.choice = const DockerEndpointAuto(),
  });

  final String serverId;
  final DockerEndpointPhase phase;

  /// The route found: always while [DockerEndpointPhase.ready], and
  /// while failed when the engine answered over it but its API version
  /// was refused.
  final DockerEndpointRoute? route;

  /// The API version every path uses (03 §5.8); set while ready.
  final ApiVersion? negotiatedApi;

  /// Whether 03 §5.2's low-session mode holds: the server's link learned
  /// a session limit (M9). On a relay the events stream gives way to
  /// re-lists and the follows share one slot with the host's; on every
  /// rank the host follows are held to one and stats are read one at a
  /// time. The state goes out again when it changes, and a new link ends
  /// it.
  final bool lowSession;

  /// Why the endpoint failed; set exactly while failed.
  final DockerEndpointFailure? failure;

  /// Why no rung reached an engine; set with [DockerEndpointFailure.noRoute].
  final DockerNoRouteReason? noRouteReason;

  /// The endpoint choice (CN-09) this state was found with: the last
  /// [SetDockerEndpoint] for the server, or automatic.
  final DockerEndpointChoice choice;

  /// The header label (03 §5.9): the route's, or none.
  DockerRouteLabel get label => route?.rank.label ?? DockerRouteLabel.none;
}

/// [list] on [serverId], as a [DockerWatch] asked for it (03 §7.12
/// DKE-02, CST-01): the whole list each time, read at [at] by the
/// engine's clock. The payload is [DockerContainersPayload],
/// [DockerImagesPayload], [DockerStacksPayload] or [DockerStatsPayload]
/// by [list], or [DockerQueryFailed] when the read failed.
final class DockerListChanged extends EngineEvent {
  const DockerListChanged({
    required this.serverId,
    required this.list,
    required this.payload,
    required this.at,
    this.fullRelist = false,
  });

  final String serverId;
  final DockerWatchList list;
  final DockerPayload payload;
  final DateTime at;

  /// Whether the list was read from nothing rather than after events: a
  /// watch's first read, or one after the events stream was lost for
  /// over 60 s or could not resume, so changes in between went unseen.
  final bool fullRelist;
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

/// The answer to the [ReadEditable] with [requestId].
final class EditRead extends EngineEvent {
  const EditRead({
    required this.serverId,
    required this.requestId,
    required this.result,
  });

  final String serverId;
  final String requestId;
  final EditReadResult result;
}

/// What an [EditRead] carries.
@immutable
sealed class EditReadResult {
  const EditReadResult();
}

/// The target's [text], whose UTF-8 bytes hash to [sha256]. A file has
/// its numeric [uid], [gid] and permission [mode]; a crontab has none.
/// [privileged] says a write needs admin mode: the file belongs to
/// another account, or the crontab is another account's.
final class EditContent extends EditReadResult {
  const EditContent({
    required this.text,
    required this.sha256,
    required this.privileged,
    this.uid,
    this.gid,
    this.mode,
  });

  final String text;
  final String sha256;
  final bool privileged;
  final int? uid, gid, mode;
}

/// A [ReadEditable] that read nothing; [detail] is the end of stderr.
final class EditReadFailed extends EditReadResult {
  const EditReadFailed(this.failure, {this.detail});

  final EditReadFailure failure;
  final String? detail;
}

/// Why a [ReadEditable] read nothing.
enum EditReadFailure {
  /// The server has no ready link.
  noLink,

  /// The engine refused the target before reading (03 §8.8).
  invalidTarget,

  /// The file does not exist.
  notFound,

  /// Only root may read it, and admin mode is off.
  adminRequired,

  /// The file is larger than the editor takes (`kEditReadCap`).
  tooLarge,

  /// The file is not UTF-8 text.
  notText,

  /// A [StackFileTarget]'s project is not a verified source (STK-07).
  stackUnverified,

  /// The read failed otherwise.
  failed,
}

/// What Klabautermann keeps on [serverId] (SAF-14, 03 §8.11, P13): the
/// manifest rows and whether each is there, and every backup the indexes
/// record with whether its content still has the recorded hash. Root's
/// part is [rootUnchecked] until admin mode reads it.
final class FootprintState extends EngineEvent {
  const FootprintState(
    this.serverId, {
    this.files = const [],
    this.backups = const [],
    this.rootUnchecked = false,
    this.warnings = const [],
  });

  final String serverId;
  final List<FootprintFile> files;
  final List<FootprintBackup> backups;
  final bool rootUnchecked;
  final List<String> warnings;
}

/// One manifest row and whether its path exists.
@immutable
final class FootprintFile {
  const FootprintFile(this.scope, this.row, {required this.present});

  final FootprintScope scope;
  final FootprintRow row;
  final bool present;
}

/// One backup an index records, and what verification found.
@immutable
final class FootprintBackup {
  const FootprintBackup(this.scope, this.entry, this.status);

  final FootprintScope scope;
  final BackupEntry entry;
  final FootprintBackupStatus status;
}

/// What verification found of a backup.
enum FootprintBackupStatus {
  /// Its content has the hash its index records.
  intact,

  /// Its content changed on the host ("modified on host").
  modified,

  /// The index records it, but the file is gone.
  missing,
}

/// A plan finished, one way or another (03 §10.1). A failed plan says
/// why in typed facts the app words (D35): which step, its exit status or
/// HTTP status, and what re-validation found.
final class ActionFinished extends EngineEvent {
  const ActionFinished({
    required this.planId,
    required this.outcome,
    this.failure,
    this.failedStep,
    this.exitCode,
    this.httpStatus,
    this.revalidation,
    this.operationId,
    this.output,
  });

  final String planId;

  /// For a detached plan, [ActionOutcome.succeeded] means its operation
  /// started; it then runs on the host as [operationId] (03 §7.17).
  final ActionOutcome outcome;
  final ActionFailure? failure;

  /// The index of the step that failed, in the preview's steps.
  final int? failedStep;

  /// A failed shell step's exit status, or a [ContainerExec]'s whether
  /// it failed or not; null when the channel ended without one.
  final int? exitCode;

  /// A failed API step's HTTP status.
  final int? httpStatus;

  /// What re-validation found, with [ActionFailure.revalidation].
  final RevalidationFailure? revalidation;

  /// The detached operation a started plan runs as, which
  /// [OperationsChanged] lists.
  final String? operationId;

  /// What a [ContainerExec] or a [RunCronJob] printed, whether it
  /// succeeded or failed.
  final ExecOutput? output;
}

/// A one-off command's output (CTX-08, JOB-19), with secrets redacted as the
/// audit log redacts them, at most [kExecOutputMax] bytes in all.
@immutable
final class ExecOutput {
  const ExecOutput({
    required this.stdout,
    required this.stderr,
    this.truncated = false,
  });

  final String stdout;
  final String stderr;

  /// Whether the command printed more than [kExecOutputMax] bytes, the
  /// rest of which was read and dropped.
  final bool truncated;
}

/// The most a one-off command's output keeps [E] (CTX-08).
const int kExecOutputMax = 1024 * 1024;

/// Why a plan failed.
enum ActionFailure {
  /// The server's link is gone.
  noLink,

  /// The target changed since the preview (03 §8.5); nothing ran.
  revalidation,

  /// Elevation refused a step: admin mode ended or the password changed.
  elevationRefused,

  /// A step exited non-zero or answered an HTTP error; later steps did
  /// not run.
  stepFailed,

  /// The link failed or timed out during a step.
  transport,

  /// The engine has no runner for an API step yet (M4 E15).
  unsupportedStep,

  /// polkit refused a step run without elevation: admin mode would run
  /// it (03 §7.5).
  adminRequired,

  /// A detached operation ended before it recorded a result (03 §7.17):
  /// its wrapper was killed, at logout or by a reboot.
  interrupted,

  /// A detached operation did not start: its directory could not be
  /// resolved, or `systemd-run` or `setsid` failed, with [exitCode].
  launchFailed,
}

/// What re-validation found changed (03 §8.5).
enum RevalidationFailure {
  /// The unit no longer loads.
  unitMissing,

  /// The process exited.
  processGone,

  /// The PID now names another process: its start time differs.
  processReused,

  /// The container id or the stack's configuration changed.
  targetChanged,

  /// An edited file or crontab no longer has the hash the edit started
  /// from: someone else changed it (03 §8.5). The app reads it again and
  /// shows the difference.
  contentChanged,

  /// The check could not read what it compares.
  unreadable,
}

/// The engine will not plan [intent] or run plan [planId] (03 §8.5): the
/// one carries the request it answers, so the app matches it to what it
/// asked. Nothing ran.
final class ActionRefused extends EngineEvent {
  const ActionRefused(this.reason, {this.intent, this.planId})
    : assert((intent == null) != (planId == null), 'one of intent, planId');

  final ActionRefusalReason reason;

  /// The refused [PlanAction]'s intent.
  final ActionIntent? intent;

  /// The refused [RunAction]'s plan.
  final String? planId;
}

/// Why an [ActionRefused] refused; the app words each (D35).
enum ActionRefusalReason {
  /// The action has no planner in this engine.
  notImplemented,

  /// No previewed plan has the id, or it already ran.
  unknownPlan,

  /// The plan outlived its five minutes; plan again.
  expiredPlan,

  /// The server's link was re-established since the preview; plan again.
  stalePlan,

  /// The confirmation does not meet the plan's tier, or does not name
  /// the target.
  confirmationMismatch,

  /// The server is observe-only: management is off for it (SAF-01).
  observeOnly,

  /// Read-only mode is on, for the server or for every server (SAF-06).
  readOnly,

  /// The plan needs admin mode, which is off for the server (03 §8.2).
  adminRequired,

  /// The intent names no valid target: a unit name outside systemd's
  /// grammar, a verb the MVP does not offer, a timer that activates
  /// nothing.
  invalidTarget,

  /// The target changed since the app saw it: the process exited, or its
  /// PID now names another process.
  targetChanged,

  /// The server has no ready link to plan over.
  noLink,

  /// The server's Docker endpoint could not be reached (M4 E15).
  engineUnavailable,

  /// Containers use the image, and the removal did not ask to force it
  /// (IMG-02).
  imageInUse,

  /// The stack's services depend on each other in a cycle, so there is no
  /// order to act in (STK-03).
  dependencyCycle,

  /// A manager's labels mark the stack, and a redeploy offers no act
  /// anyway (STK-06, 03 §8.7).
  stackManaged,

  /// The stack's files are not verified as its source (STK-01), so its
  /// commands cannot be rebuilt from them (STK-06).
  stackUnverified,

  /// Only the legacy `docker-compose` is installed, which stays read-only
  /// (STK-05).
  legacyComposeOnly,

  /// The detached operation needs root and the account's passwordless
  /// sudo reaches only `docker`, which cannot start a root runner (03
  /// §7.17).
  sudoRightMissing,
}

/// Why [UserCrontabs] read no crontab.
enum UserCrontabsFailure {
  /// The server has no ready link.
  noLink,

  /// Admin mode is off for the server.
  adminRequired,

  /// Elevation refused, so nothing ran.
  elevationRefused,

  /// Neither spool directory exists (`kCrontabSpools`).
  noSpool,

  /// The spool exists but cannot be listed.
  spoolDenied,

  /// The listing did not read as a spool.
  unreadable,

  /// The link failed while reading.
  transport,
}

/// The answer to [ReadUserCrontabs]: the listed users' crontab lines as
/// jobs rows, commands masked (8.9), with their next runs as the `cron`
/// stream's rows have them. A user whose crontab could not be read is in
/// [unreadable]; one that was removed since the listing is left out.
final class UserCrontabs extends EngineEvent {
  UserCrontabs({
    required this.serverId,
    required this.requestId,
    this.directory,
    Iterable<JobEntry> jobs = const [],
    Iterable<String> unreadable = const [],
    this.skipped = 0,
    this.notRead = 0,
    this.zoneName,
    this.zoneFallback,
    this.failure,
  }) : jobs = List.unmodifiable(jobs),
       unreadable = List.unmodifiable(unreadable);

  final String serverId;
  final String requestId;

  /// The spool directory the listing found.
  final String? directory;

  final List<JobEntry> jobs;
  final List<String> unreadable;

  /// Spool file names that are not user names, which are never read.
  final int skipped;

  /// Users past `kUserCrontabsRead`, whose crontabs were not read.
  final int notRead;

  /// As [CronResult.zoneName].
  final String? zoneName;

  /// As [CronResult.zoneFallback].
  final CronZoneFallback? zoneFallback;

  /// Why nothing was read, or null.
  final UserCrontabsFailure? failure;
}

/// A detached operation's state as the engine sees it (03 §7.17).
enum DetachedOperationState {
  /// Its wrapper runs.
  running,

  /// Its wrapper recorded the command's exit status.
  done,

  /// Its record says running but its wrapper is gone, or its PID now
  /// names another process: it was killed before it could record a
  /// result (at logout, or by a reboot).
  lost,

  /// Its record says running and the engine could not check the wrapper.
  unknown,
}

/// One detached operation of a server (03 §7.17), from its record and
/// what this device remembers of it.
@immutable
final class DetachedOperation {
  const DetachedOperation({
    required this.id,
    required this.directory,
    required this.state,
    this.unit,
    this.startedAt,
    this.endedAt,
    this.exitCode,
    this.action,
    this.targetName,
    this.acknowledged = false,
  });

  final String id;

  /// The user directory for work that needs no root, the root one
  /// otherwise.
  final OpDirectoryKind directory;

  final DetachedOperationState state;

  /// `klabautermann-op-<id>.service` for a systemd runner.
  final String? unit;

  /// UTC; null where the host's `date` has no `%s`.
  final DateTime? startedAt, endedAt;

  /// The command's exit status, set when [state] is
  /// [DetachedOperationState.done].
  final int? exitCode;

  /// The intent's kind and target, as the audit log names them, when this
  /// device launched the operation; null for one another device launched.
  final String? action, targetName;

  /// The result was shown and acknowledged here, and the files wait for
  /// admin mode to be deleted: the login user cannot unlink in the root
  /// directory.
  final bool acknowledged;
}

/// [serverId]'s detached operations (03 §7.17), sent after each `ops`
/// read, each acknowledgement and each cleanup: the full list, so the app
/// replaces what it had. [directories] says how far each directory was
/// read; a directory that is denied or incomplete may hold operations
/// the list lacks.
final class OperationsChanged extends EngineEvent {
  OperationsChanged(
    this.serverId, {
    Iterable<DetachedOperation> operations = const [],
    Map<OpDirectoryKind, OpDirectoryListing> directories = const {},
    this.unavailable,
  }) : operations = List.unmodifiable(operations),
       directories = Map.unmodifiable(directories);

  final String serverId;
  final List<DetachedOperation> operations;
  final Map<OpDirectoryKind, OpDirectoryListing> directories;

  /// Why the `ops` collector read nothing, or null.
  final CollectorUnavailable? unavailable;
}

/// The answer to an [AuditQuery]: [records] newest first, and whether
/// older ones remain.
final class AuditRecords extends EngineEvent {
  AuditRecords(
    this.serverId,
    Iterable<AuditRecord> records, {
    this.more = false,
  }) : records = List.unmodifiable(records);

  final String serverId;
  final List<AuditRecord> records;
  final bool more;
}

/// One finished or refused run in the device audit log (03 §8.10): the
/// plan's steps as the preview showed them with secrets redacted, the
/// tier, and the result.
@immutable
final class AuditRecord {
  AuditRecord({
    required this.serverId,
    required this.action,
    required this.targetName,
    required Iterable<String> steps,
    required this.tier,
    required this.outcome,
    required this.startedAt,
    required this.endedAt,
    this.deviceId,
    this.failure,
    this.failedStep,
    this.exitCode,
    this.httpStatus,
  }) : steps = List.unmodifiable(steps);

  final String serverId;

  /// The intent's kind, such as `UnitAction`.
  final String action;
  final String targetName;
  final List<String> steps;
  final ConfirmationTier tier;
  final ActionOutcome outcome;
  final DateTime startedAt, endedAt;

  /// This device, when sync enrolled it (03 §4.3).
  final String? deviceId;

  final ActionFailure? failure;
  final int? failedStep;
  final int? exitCode;
  final int? httpStatus;

  /// The record as the Activity page's export carries it (SAF-11): every
  /// field, its steps redacted as stored, times in UTC.
  Map<String, Object?> toJson() => {
    'serverId': serverId,
    'action': action,
    'target': targetName,
    'steps': steps,
    'tier': tier.name,
    'outcome': outcome.name,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'deviceId': ?deviceId,
    'failure': ?failure?.name,
    'failedStep': ?failedStep,
    'exitCode': ?exitCode,
    'httpStatus': ?httpStatus,
  };
}

/// [terminalId]'s shell started: [command] is what runs, as the exec
/// was created.
final class TerminalOpened extends EngineEvent {
  TerminalOpened(this.terminalId, Iterable<String> command)
    : command = List.unmodifiable(command);

  final String terminalId;
  final List<String> command;
}

/// Output of [terminalId]'s shell, raw as the TTY wrote it, in order.
/// The engine sends at most 20 a second, as it does [LogBatch]es.
final class TerminalBytes extends EngineEvent {
  const TerminalBytes(this.terminalId, this.bytes);

  final String terminalId;
  final Uint8List bytes;
}

/// [terminalId]'s shell ended, or never started, and why. Sent once;
/// the id may be used again after it.
final class TerminalClosed extends EngineEvent {
  const TerminalClosed(
    this.terminalId,
    this.reason, {
    this.exitCode,
    this.detail,
  });

  final String terminalId;
  final TerminalCloseReason reason;

  /// The shell's exit code, with [TerminalCloseReason.exited] when the
  /// daemon reported one.
  final int? exitCode;

  /// The daemon's message or the error, for the app to show as is.
  final String? detail;
}

/// Why a container shell ended or never started.
enum TerminalCloseReason {
  /// The shell exited; [TerminalClosed.exitCode] says how.
  exited,

  /// [CloseTerminal] closed it.
  closed,

  /// The server is observe-only (SAF-01).
  observeOnly,

  /// Read-only mode is on (SAF-06).
  readOnly,

  /// The server is not in the fleet.
  notInFleet,

  /// The server's Docker endpoint could not be reached.
  endpointUnavailable,

  /// No session channel was free on the server's relay (03 §5.2).
  noChannel,

  /// The server already holds [kTerminalsPerServerMax] shells.
  tooMany,

  /// The container is gone, or the daemon refused the exec.
  refused,

  /// The server's link was lost.
  linkLost,

  /// Admin mode ended, and with it the sudo relay the shell ran over.
  adminEnded,

  /// Anything else; [TerminalClosed.detail] says what.
  failed,
}

/// Where admin mode stands on [serverId] (03 §8.2, M4 plan M5). The app
/// shows the chip and its countdown from [expiresAt] while [phase] is
/// [AdminModePhase.on]. No field ever holds the password.
final class AdminModeState extends EngineEvent {
  const AdminModeState(
    this.serverId,
    this.phase, {
    this.expiresAt,
    this.retry = false,
    this.failure,
    this.ended,
  });

  final String serverId;
  final AdminModePhase phase;

  /// When inactivity ends admin mode, while it is on.
  final DateTime? expiresAt;

  /// While awaiting the password: the previous one was wrong.
  final bool retry;

  /// Why turning it on failed, with [AdminModePhase.failed].
  final AdminFailure? failure;

  /// Why it ended, with [AdminModePhase.expired].
  final AdminEnd? ended;
}

/// The admin-mode state machine's phases (M4 plan M5).
enum AdminModePhase {
  off,
  detecting,
  awaitingPassword,
  validating,
  on,
  expired,
  failed,
}

/// Why admin mode could not start; the app words each (D35).
enum AdminFailure {
  /// The server is observe-only (SAF-01).
  observeOnly,

  /// Read-only mode is on (SAF-06): admin mode is hidden.
  readOnly,

  /// The server has no link to elevate over.
  noLink,

  /// The host has not been probed yet, so how to elevate is unknown.
  notProbed,

  /// No elevation rung applies (03 §8.3).
  unavailable,

  /// Only a terminal could elevate: `requiretty`, or doas with a password
  /// (rung 5, which spike S3 left for later).
  ttyRequired,

  /// The account may not elevate.
  notInSudoers,

  /// The password was refused three times.
  wrongPassword,

  /// The password prompt was cancelled or withdrawn.
  cancelled,
}

/// Why admin mode ended (03 §8.2).
enum AdminEnd {
  /// No elevated action or read for the expiry period.
  inactivity,

  /// The app went to the background.
  background,

  /// The server's link dropped.
  linkLost,

  /// The server left the fleet or changed endpoint.
  serverRemoved,
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

/// The port SSH uses when a config names none (RFC 4253, section 4.1).
const int kSshDefaultPort = 22;

/// Where a [FleetEntry] came from, which decides what may happen to it.
enum FleetEntryOrigin {
  /// A `serverConfig` record pulled from the shared Séance sync account
  /// (D13); read-only in the MVP (D14), edited through [SaveServer] and
  /// [DeleteServer] since v1.
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
    this.excludedFromSync = false,
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

  /// Whether a synced server stays on this device only, so its
  /// preferences do not sync (03 §4.8); false for an import.
  final bool excludedFromSync;

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
      endpoint == other.endpoint &&
      excludedFromSync == other.excludedFromSync;

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
    excludedFromSync,
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
/// older"; SVC-04's unit logs are one window), except a container's,
/// which arrive oldest first as Docker's `tail` sends them. A follow
/// delivers up to [window] earlier records oldest first, then each new
/// record as the host writes it, until [CloseStream]. With [afterCursor]
/// it resumes after a record the app already holds instead (LOG-02): it
/// delivers every record after that one, so a reconnect leaves no gap,
/// and [window] does not apply.
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
         afterCursor == null ||
             (source is! FileLogSource && source is! ContainerLogSource),
         'a file tail and a container log have no cursor',
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
  /// it. File tails, `dmesg` and container logs have no cursor: a
  /// container follow resumes after its newest line itself, as long as
  /// the stream stays open. Null starts at the newest
  /// record. journalctl refuses `--since` together with a cursor, so with
  /// one the engine applies [JournalLogSource.since] itself: a window ends
  /// with [LogStreamEndReason.oldestReached] at the first record older
  /// than it, and a follow skips such records, as it does without one.
  final String? afterCursor;
}

/// Where an [OpenLogStream] reads (03 §7.6, §7.12): the host's journal,
/// kernel log or a file over its link, or a container's logs over its
/// Docker endpoint.
@immutable
sealed class LogSource {
  const LogSource();
}

/// The systemd journal through `journalctl -o json`, read as
/// [JournalRecord]s, with LOG-01's filters; SVC-04's unit logs filter by
/// [unit]. A null filter matches every record. LOG-05 searches the
/// records the view holds; [grep] has journalctl match them (LOG-06).
final class JournalLogSource extends LogSource {
  const JournalLogSource({
    this.unit,
    this.identifier,
    this.priority,
    this.currentBootOnly = false,
    this.boot,
    this.since,
    this.until,
    this.grep,
  });

  /// A systemd unit name (`-u`).
  final String? unit;

  /// A syslog identifier (`-t`).
  final String? identifier;

  /// The least urgent priority shown (`-p`): records at it or more urgent.
  final LogPriority? priority;

  /// Only the current boot's records (`-b`).
  final bool currentBootOnly;

  /// Only [boot]'s records (`-b <boot>`, LOG-09), picked from a
  /// [BootsQuery]; not with [currentBootOnly]. A follow reads the
  /// current boot, so it takes no [boot].
  final JournalBoot? boot;

  /// The time range (`--since`, `--until`). A follow takes no [until],
  /// since it reads up to the present.
  final DateTime? since, until;

  /// A PCRE2 pattern journalctl matches against each record's message
  /// (`-g`, LOG-06), case-insensitive while it is all lower case. A
  /// journalctl built without pattern matching ends the read
  /// [LogStreamEndReason.searchUnsupported].
  final String? grep;
}

/// The kernel's messages for the current boot (LOG-03), or for [boot]
/// (LOG-09): `journalctl -k`, read as [JournalRecord]s, with
/// `dmesg --json --decode` only as the current boot's fallback, read as
/// [KernelRecord]s.
final class KernelLogSource extends LogSource {
  const KernelLogSource({this.boot});

  /// A past boot, picked from a [BootsQuery]; null for the current one.
  /// A follow reads the current boot, so it takes none.
  final JournalBoot? boot;
}

/// One file's lines as [FileRecord]s (LOG-22): `tail -n` for a window,
/// and `tail -F`, which follows the file by name across rotation, for a
/// follow. A [compressed] rotated file (LOG-08) reads as a window only.
final class FileLogSource extends LogSource {
  const FileLogSource(
    this.path, {
    this.redacted = false,
    this.elevated = false,
    this.compressed = false,
  });

  /// The absolute path, typed or picked from the common paths; the engine
  /// validates it (03 §8.8) before it quotes it into the command.
  final String path;

  /// Each line passes the secret redactor before it crosses, as a
  /// detached operation's output does.
  final bool redacted;

  /// The read runs through admin mode's elevation (LOG-22, M4 E16b), for
  /// a file only root may read; the app asks for it after a read ended
  /// [LogStreamEndReason.denied]. Without admin mode it ends denied, and
  /// a follow ends so when admin mode does.
  final bool elevated;

  /// [path] is a rotated `.gz` or `.xz` file, read through `zcat` or
  /// `xzcat` (LOG-08): its last [LogStreamSpec.window] lines, within the
  /// engine's output cap, never followed. A decompressor the host lacks
  /// ends the read [LogStreamEndReason.missing].
  final bool compressed;
}

/// A detached operation's output (03 §7.17): the engine reads its
/// `<id>.log` in the directory the latest `ops` read listed it in, as a
/// [FileLogSource] whose lines are redacted, so a follow keeps showing
/// output across the operation's end. An operation the engine does not
/// list ends the stream as [LogStreamEndReason.invalid].
final class OperationLogSource extends LogSource {
  const OperationLogSource(this.operationId);

  final String operationId;
}

/// One container's logs through the Docker Engine API (CTX-01, 03 §5.6),
/// read as [ContainerRecord]s: `GET /containers/{id}/logs` with
/// `timestamps=1`, its last [LogStreamSpec.window] lines, then the new
/// ones for a follow. A follow outlasts the container's stops: it reads
/// on, after the newest line it delivered, once the container runs
/// again. The read waits for the server's Docker endpoint
/// ([DockerEndpointState]) as [LogStreamWaitReason.link].
final class ContainerLogSource extends LogSource {
  const ContainerLogSource(this.containerId);

  /// The container's id, or its name; the engine validates it before it
  /// puts it in a path.
  final String containerId;
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

/// One line of a container's log (CTX-01), as the engine assembled it
/// from the API's frames (03 §5.6): a line the engine split across
/// frames arrives whole, without its line break.
final class ContainerRecord extends LogRecord {
  const ContainerRecord({required this.stream, required this.text, this.at});

  final ContainerLogStream stream;

  /// When the engine received the line, by the daemon's clock, to the
  /// microsecond; null when the line carried no timestamp.
  final DateTime? at;
  final String text;
}

/// The container stream a [ContainerRecord] came from. A TTY container
/// has one stream, read as [stdout].
enum ContainerLogStream { stdout, stderr }

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
/// characters stripped, the daemon's message for a container's logs, the
/// driver's name for [LogStreamEndReason.logDriverUnreadable], or null.
final class LogStreamEnded extends LogStreamStatus {
  const LogStreamEnded(this.reason, {this.detail});

  final LogStreamEndReason reason;
  final String? detail;

  @override
  List<Object?> get _values => [reason, detail];
}

/// What a [LogStreamWaiting] stream waits for.
enum LogStreamWaitReason {
  /// The server's link; [LinkState] says why it is not ready. Container
  /// logs also wait here for the Docker endpoint over it, which
  /// [DockerEndpointState] reports.
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

  /// The tool, file or container the source reads is absent on the
  /// host.
  missing,

  /// The host refused the read, such as a file only `adm` or root may
  /// read; with admin mode on, an elevated [FileLogSource] reads it.
  denied,

  /// The read failed otherwise.
  failed,

  /// The container's logging driver keeps no logs the API can read (03
  /// §7.12 CTX-01): `none`, or a remote driver with Docker's dual-logging
  /// cache disabled, or on Podman, which has no such cache, any but
  /// `k8s-file`, `json-file` and `journald`. [LogStreamEnded.detail] names the driver.
  logDriverUnreadable,

  /// The host's journalctl cannot match a [JournalLogSource.grep]
  /// pattern: it was built without PCRE2, or cannot load it (LOG-06).
  /// The view's own search (LOG-05) still works.
  searchUnsupported,
}

/// What a [DockerQuery] reads (03 §7.12 to §7.14).
@immutable
sealed class DockerQuerySpec {
  const DockerQuerySpec();
}

/// The engine panel (DKE-01): `/info`, with the `/version` the endpoint
/// negotiated over. Answered by [DockerEnginePayload].
final class DockerEngineQuery extends DockerQuerySpec {
  const DockerEngineQuery();
}

/// Every container, stopped ones too (CTR-01). Answered by
/// [DockerContainersPayload].
final class DockerContainersQuery extends DockerQuerySpec {
  const DockerContainersQuery();
}

/// One container's inspect (CTR-03, CTR-04). Answered by
/// [DockerContainerPayload].
final class DockerContainerQuery extends DockerQuerySpec {
  const DockerContainerQuery(this.containerId);

  /// The container's id or name.
  final String containerId;
}

/// The image list (IMG-01). Answered by [DockerImagesPayload].
final class DockerImagesQuery extends DockerQuerySpec {
  const DockerImagesQuery();
}

/// Disk use by type (02 OV-05): `/system/df` without `verbose`, which
/// the daemon computes by walking images, containers, volumes and the
/// build cache, so the app asks for it only on demand. Answered by
/// [DockerSystemDfPayload].
final class DockerSystemDfQuery extends DockerQuerySpec {
  const DockerSystemDfQuery();
}

/// One file of the compose project [project] (03 §7.16 STK-04, M11):
/// a config file or an environment file its containers recorded, or the
/// `.env` in its working directory, read over SFTP once the project's
/// source is verified. Answered by [DockerStackFilePayload] or
/// [DockerStackFileFailed].
final class DockerStackFileQuery extends DockerQuerySpec {
  const DockerStackFileQuery({required this.project, required this.path});

  /// The compose project name.
  final String project;

  /// The file's absolute path, as the project's labels name it.
  final String path;
}

/// The profiles a verified project's files name (03 §7.16 STK-09), for
/// STK-23's `--profile` choices: `compose config --profiles`. Answered
/// by [DockerStackProfilesPayload], by [DockerStackFileFailed] when the
/// project is unknown or unverified, or by [DockerQueryFailed] when the
/// CLI could not list them.
final class DockerStackProfilesQuery extends DockerQuerySpec {
  const DockerStackProfilesQuery(this.project);

  final String project;
}

/// The compose files in [directories] and the folders right below them
/// (03 §7.16 STK-08): `find <dir> -maxdepth 2` for `compose*.y*ml` and
/// `docker-compose*.y*ml`, run as the login user, for stacks with no
/// containers. Answered by [DockerStackScanPayload].
final class DockerStackScanQuery extends DockerQuerySpec {
  DockerStackScanQuery(Iterable<String> directories)
    : directories = List.unmodifiable(directories);

  /// Absolute paths, at most [kStackScanDirectoriesMax].
  final List<String> directories;
}

/// The most folders one [DockerStackScanQuery] searches [E].
const int kStackScanDirectoriesMax = 16;

/// The compose CLIs on the server (03 §7.16 STK-05), for the Access tab's
/// compose row (CN-24) without a stacks watch: looked for once per
/// endpoint in one exec, as stack verification does. Answered by
/// [DockerComposePayload].
final class DockerComposeQuery extends DockerQuerySpec {
  const DockerComposeQuery();
}

/// A list a [DockerWatch] follows (03 §7.12 to §7.14).
enum DockerWatchList {
  /// Every container (CTR-01), as [DockerContainersPayload].
  containers,

  /// The image list (IMG-01), as [DockerImagesPayload].
  images,

  /// The containers grouped by compose project (STK-01), as
  /// [DockerStacksPayload].
  stacks,

  /// One-shot stats for the watch's `statsFor` (CST-01), as
  /// [DockerStatsPayload].
  stats,
}

/// The most watches one server holds [E]: a Docker view holds one or two.
const kDockerWatchesMax = 16;

/// The most containers one watch reads stats for [E]: more rows than a
/// screen shows.
const kDockerStatsForMax = 64;

/// What a [DockerResult] or [DockerListChanged] carries.
@immutable
sealed class DockerPayload {
  const DockerPayload();
}

/// The engine's `/info` and `/version` (DKE-01).
final class DockerEnginePayload extends DockerPayload {
  const DockerEnginePayload(this.info, this.version);

  final EngineInfo info;
  final DockerServerVersion version;
}

/// The container list (CTR-01), labels masked by key. Each
/// [ContainerSummary.command] is null: the list's command line can hold
/// a secret, and [ContainerDetails] carries it masked (03 §8.9).
final class DockerContainersPayload extends DockerPayload {
  const DockerContainersPayload(this.containers);

  final List<ContainerSummary> containers;
}

/// One inspected container, masked (03 §8.9).
final class DockerContainerPayload extends DockerPayload {
  const DockerContainerPayload(this.container);

  final ContainerDetails container;
}

/// The image list (IMG-01), labels masked by key.
final class DockerImagesPayload extends DockerPayload {
  const DockerImagesPayload(this.images);

  final List<ImageSummary> images;
}

/// `/system/df`'s totals per type (02 OV-05), read in the shape the
/// negotiated version gates; a type the daemon did not cover is null.
final class DockerSystemDfPayload extends DockerPayload {
  const DockerSystemDfPayload(this.df);

  final SystemDf df;
}

/// The containers grouped by compose project (STK-01), from the same
/// list [DockerContainersPayload] carries, with each project's source
/// verdict and the compose CLI the host has (STK-05). A project's
/// managed-by badge (STK-10) is its [ComposeProject.ownership].
final class DockerStacksPayload extends DockerPayload {
  const DockerStacksPayload(
    this.grouping, {
    this.verdicts = const {},
    this.composeCli,
  });

  final ComposeGrouping grouping;

  /// The verdict for each project in [grouping], by name; a project the
  /// engine has not checked yet reads [StackVerifying], and the list is
  /// sent again once it has.
  final Map<String, StackVerdict> verdicts;

  /// The compose CLI found, once the engine has looked.
  final DockerComposeCli? composeCli;
}

/// The compose CLIs a [DockerComposeQuery] found.
final class DockerComposePayload extends DockerPayload {
  const DockerComposePayload(this.composeCli);

  final DockerComposeCli composeCli;
}

/// Whether a compose project's files are its source (03 §7.16 STK-01).
@immutable
sealed class StackVerdict {
  const StackVerdict();
}

/// The engine is checking the project's files, or waits to: [waiting]
/// says why a check could not start yet.
final class StackVerifying extends StackVerdict {
  const StackVerifying({this.waiting});

  final StackWait? waiting;
}

/// Why a stack check has not started (M4 plan M6).
enum StackWait {
  /// The link has no session channel left at its learned limit: the
  /// samplers hold them, and a background check does not borrow one.
  channel,
}

/// Every config file exists and `compose config --hash '*'` over them
/// matches the `config-hash` label of every service's containers: the
/// files are the project's source.
final class StackVerified extends StackVerdict {
  const StackVerified();
}

/// "Unverified source", for [reason].
final class StackUnverified extends StackVerdict {
  const StackUnverified(this.reason);

  final StackUnverifiedReason reason;
}

/// "Source not on host": a config file the containers name is missing.
/// A manager that runs compose in its own container records paths
/// inside it (Dockge's rule), so [deployedBy] names the manager the
/// project's labels mark, when they mark one.
final class StackSourceNotOnHost extends StackVerdict {
  const StackSourceNotOnHost({this.deployedBy});

  final ExternalManager? deployedBy;
}

/// Why a project's files are not its verified source.
enum StackUnverifiedReason {
  /// The containers record no config files.
  noSourceLabels,

  /// A recorded project name or path fails 03 §8.8's validation, so no
  /// command names it.
  unsafeLabels,

  /// A service's container carries no `config-hash` label.
  noHashLabels,

  /// The host has no compose CLI.
  noComposeCli,

  /// The host has only the standalone `docker-compose`, which is
  /// read-only (STK-05) and does not verify.
  standaloneComposeOnly,

  /// The compose CLI did not print service hashes for `config --hash
  /// '*'`, as one without that flag form would not.
  cliCouldNotHash,

  /// `compose config` failed over the files: a file it cannot read or
  /// parse, or a variable it cannot interpolate.
  configFailed,

  /// A service's hash differs from its containers' label, or the files
  /// define no such service: the files changed since the deploy, or
  /// are not the ones it used.
  hashMismatch,

  /// The check could not run: the link failed or timed out.
  checkFailed,
}

/// The compose CLIs on the host (03 §7.16 STK-05), each version as it
/// printed it without a leading `v`.
@immutable
final class DockerComposeCli {
  const DockerComposeCli({this.pluginVersion, this.standaloneVersion});

  /// `docker compose version`; null without the plugin.
  final String? pluginVersion;

  /// `docker-compose version`; null without the standalone binary.
  final String? standaloneVersion;

  /// Whether the standalone binary is the Python Compose v1, unmaintained
  /// since 2023 and read-only here (STK-05).
  bool get standaloneLegacy => standaloneVersion?.startsWith('1.') ?? false;
}

/// One stack file (03 §7.16 STK-04, M11) as spans whose
/// [MaskedValue.display]s joined are the file with its secrets masked
/// (03 §8.9); the app reveals one span at a time. Read fresh for each
/// query, and never cached or logged by the engine.
final class DockerStackFilePayload extends DockerPayload {
  const DockerStackFilePayload({
    required this.project,
    required this.path,
    required this.text,
    required this.size,
    this.truncated = false,
  });

  final String project;
  final String path;
  final List<MaskedValue> text;

  /// The file's size in bytes, as SFTP reported it.
  final int size;

  /// Whether the file is over [kStackFileMaxBytes], so [text] holds only
  /// its complete lines within that many bytes.
  final bool truncated;
}

/// The profiles a [DockerStackProfilesQuery] found, sorted.
final class DockerStackProfilesPayload extends DockerPayload {
  DockerStackProfilesPayload({
    required this.project,
    required Iterable<String> profiles,
  }) : profiles = List.unmodifiable(profiles);

  final String project;
  final List<String> profiles;
}

/// The compose files a [DockerStackScanQuery] found, sorted.
final class DockerStackScanPayload extends DockerPayload {
  DockerStackScanPayload(Iterable<String> files, {this.incomplete = false})
    : files = List.unmodifiable(files);

  /// Absolute paths; a stack's folder is a file's directory.
  final List<String> files;

  /// Whether a folder could not be read, or the list was cut at the
  /// output cap, so stacks may be missing.
  final bool incomplete;
}

/// The most bytes of a stack file the engine reads (M11 [E]).
const kStackFileMaxBytes = 1024 * 1024;

/// A [DockerStackFileQuery] the engine did not answer with the file.
final class DockerStackFileFailed extends DockerPayload {
  const DockerStackFileFailed(this.failure);

  final StackFileFailure failure;
}

/// Why a [DockerStackFileQuery] read no file.
enum StackFileFailure {
  /// No container belongs to the project.
  unknownStack,

  /// The project's source is not verified ([StackVerdict]).
  notVerified,

  /// The path is none of the project's files.
  notStackFile,

  /// SFTP found no file at the path.
  notFound,

  /// The login user cannot read the file; admin mode's elevated read
  /// arrives with M4.
  permissionDenied,

  /// The path is a symbolic link, directory or other non-regular file.
  notRegularFile,

  /// SFTP failed, or the file changed while it was read.
  readFailed,
}

/// One stats round over a watch's `statsFor` (CST-01): a row for each
/// running container that answered, in no set order.
final class DockerStatsPayload extends DockerPayload {
  const DockerStatsPayload(this.stats);

  final List<ContainerListStats> stats;
}

/// One container's list stats (03 §7.12 CST-01), read at [at] by the
/// engine's clock.
@immutable
final class ContainerListStats {
  const ContainerListStats({
    required this.containerId,
    required this.at,
    this.cpuPercent,
    this.memoryUsed,
    this.memoryLimit,
  });

  final String containerId;
  final DateTime at;

  /// CPU % by the spec formula over the time since the previous read,
  /// so null on a container's first one, on the first after a read of it
  /// failed, and on the first after a [DockerListChanged.fullRelist]
  /// (one-shot `precpu_stats` is not meaningful, 03 §5.6).
  final double? cpuPercent;

  /// Bytes in use less `inactive_file` (cgroup v2) or the cache (v1).
  final int? memoryUsed;
  final int? memoryLimit;
}

/// The query read nothing, for [failure]; [detail] is the daemon's own
/// message or the transport error, for diagnostics.
final class DockerQueryFailed extends DockerPayload {
  const DockerQueryFailed(this.failure, {this.detail});

  final DockerQueryFailure failure;
  final String? detail;
}

/// Why a [DockerQuery] or a watched list read nothing.
enum DockerQueryFailure {
  /// The server is not in the fleet.
  notInFleet,

  /// The server has no ready link.
  linkUnavailable,

  /// The server's capability probe has not answered on this link, so
  /// the engine cannot look for its sockets yet (03 §5.4).
  profileUnknown,

  /// The endpoint failed; its [DockerEndpointState] says why. A later
  /// query looks for it again.
  endpointUnavailable,

  /// The server already holds the most queries waiting for its endpoint,
  /// or the most watches.
  tooManyQueries,

  /// The query names no container, or the watch names more stats
  /// containers than [kDockerStatsForMax].
  invalidQuery,

  /// The object is gone (404); a list query shows what remains.
  notFound,

  /// The daemon refused or failed the call.
  daemonError,

  /// The connection to the daemon failed, timed out or carried malformed
  /// HTTP, or a command the query runs on the server failed.
  connectionFailed,

  /// The endpoint closed before the query ran: its link went, the app
  /// disconnected, or the server left the fleet or changed endpoint.
  cancelled,
}

/// Where a [DockerEndpointState] is.
enum DockerEndpointPhase {
  /// The server has no ready link, or its capability probe has not
  /// answered on it.
  waiting,

  /// The engine runs the ladder and negotiates over the route found.
  resolving,

  /// Queries run over the route.
  ready,

  /// No route reached an engine that answers with an API version this
  /// client takes.
  failed,
}

/// Why a [DockerEndpointState] failed.
enum DockerEndpointFailure {
  /// No rung reached an engine socket (03 §5.9).
  noRoute,

  /// Routes opened, but the engine answered `_ping` and `/version` over
  /// none of them.
  unreachable,

  /// The engine's newest API version is below the client floor 1.41
  /// (03 §5.8).
  belowClientFloor,

  /// The engine's `MinAPIVersion` is above every version this client was
  /// tested against.
  belowServerMinimum,

  /// The engine reported no API version this client can read.
  apiVersionUnknown,

  /// The link failed while the ladder ran.
  linkError,

  /// The endpoint choice names a socket path [dockerSocketPathProblem]
  /// refuses, so the ladder did not run.
  invalidChoice,
}

/// The route a [DockerEndpointState] names (03 §5.4, §5.9; SAF-08).
@immutable
final class DockerEndpointRoute {
  const DockerEndpointRoute({
    required this.rank,
    required this.socketPath,
    required this.runtime,
    required this.rootEquivalence,
    this.mode,
  });

  final DockerRank rank;
  final String socketPath;

  /// The engine as its API names it: Podman when `_ping` carries
  /// `Libpod-API-Version` or `/version` names a Podman component, even
  /// behind a Docker path (M13), otherwise Docker.
  final EngineRuntime runtime;

  /// Rootful or rootless by the path; null for a custom path.
  final EngineMode? mode;

  final DockerRootEquivalence rootEquivalence;
}

/// Which engine socket a server's Docker endpoint uses (CN-09, D54).
@immutable
sealed class DockerEndpointChoice {
  const DockerEndpointChoice();
}

/// The engine finds the socket itself (03 §5.4's discovery).
final class DockerEndpointAuto extends DockerEndpointChoice {
  const DockerEndpointAuto();

  @override
  bool operator ==(Object other) => other is DockerEndpointAuto;

  @override
  int get hashCode => (DockerEndpointAuto).hashCode;
}

/// A socket the user named, tried first.
sealed class DockerEndpointSocket extends DockerEndpointChoice {
  const DockerEndpointSocket(this.socketPath);

  /// The socket's absolute path on the server.
  final String socketPath;
}

/// One of the sockets the probe found (03 §5.4).
final class DockerEndpointDetected extends DockerEndpointSocket {
  const DockerEndpointDetected(super.socketPath);

  @override
  bool operator ==(Object other) =>
      other is DockerEndpointDetected && other.socketPath == socketPath;

  @override
  int get hashCode => Object.hash(DockerEndpointDetected, socketPath);
}

/// A path the user typed, such as a socket outside 03 §5.4's list.
final class DockerEndpointCustom extends DockerEndpointSocket {
  const DockerEndpointCustom(super.socketPath);

  @override
  bool operator ==(Object other) =>
      other is DockerEndpointCustom && other.socketPath == socketPath;

  @override
  int get hashCode => Object.hash(DockerEndpointCustom, socketPath);
}

/// One inspected container as it crosses (03 §7.12 CTR-03, CTR-04): the
/// inspect fields the panels use, with the command line and the health
/// checks' output masked by the engine (03 §8.9), so a secret reaches the
/// app only behind [MaskedValue]. Env and label values are masked by key.
@immutable
final class ContainerDetails {
  const ContainerDetails({
    required this.id,
    this.name,
    this.created,
    this.image,
    this.platform,
    this.restartCount,
    this.path,
    this.args = const [],
    this.state,
    this.config,
    this.hostConfig,
    this.mounts = const [],
    this.networkSettings,
  });

  final String id;
  final String? name;
  final DateTime? created;

  /// The image id; [ContainerDetailsConfig.image] names what it was
  /// created from.
  final String? image;
  final String? platform;
  final int? restartCount;

  /// The program the container runs (`Path`), as it is: 03 §8.9 never
  /// reads a program as an option.
  final String? path;

  /// `Args`, masked as the command line after [path].
  final List<MaskedValue> args;

  final ContainerDetailsState? state;
  final ContainerDetailsConfig? config;
  final ContainerHostConfig? hostConfig;
  final List<ContainerMount> mounts;
  final ContainerNetworkSettings? networkSettings;
}

/// An inspected container's `State` (CTR-03, CTR-04).
@immutable
final class ContainerDetailsState {
  const ContainerDetailsState({
    this.status,
    this.running = false,
    this.paused = false,
    this.restarting = false,
    this.oomKilled = false,
    this.dead = false,
    this.pid,
    this.exitCode,
    this.error,
    this.startedAt,
    this.finishedAt,
    this.health,
  });

  final String? status;
  final bool running;
  final bool paused;
  final bool restarting;
  final bool oomKilled;
  final bool dead;
  final int? pid;
  final int? exitCode;
  final String? error;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final ContainerDetailsHealth? health;
}

/// `State.Health` (CTR-04).
@immutable
final class ContainerDetailsHealth {
  const ContainerDetailsHealth({
    this.status = HealthStatus.none,
    this.failingStreak,
    this.log = const [],
  });

  final HealthStatus status;
  final int? failingStreak;
  final List<ContainerHealthCheck> log;
}

/// One health check's result (`State.Health.Log[]`), its output masked
/// (03 §8.9): a check command can print what it was given.
@immutable
final class ContainerHealthCheck {
  const ContainerHealthCheck({
    this.start,
    this.end,
    this.exitCode,
    this.output,
  });

  final DateTime? start;
  final DateTime? end;
  final int? exitCode;
  final MaskedValue? output;
}

/// The inspect `Config` fields the panels use, with `Entrypoint` and
/// `Cmd` masked as one command line (03 §8.9).
@immutable
final class ContainerDetailsConfig {
  const ContainerDetailsConfig({
    this.hostname,
    this.image,
    this.user,
    this.workingDir,
    this.stopSignal,
    this.tty = false,
    this.env = const [],
    this.entrypoint = const [],
    this.cmd = const [],
    this.labels = const {},
  });

  final String? hostname;
  final String? image;
  final String? user;
  final String? workingDir;
  final String? stopSignal;

  /// `Tty`, which decides the log framing (03 §5.6).
  final bool tty;
  final List<EnvVar> env;
  final List<MaskedValue> entrypoint;
  final List<MaskedValue> cmd;
  final Map<String, MaskedValue> labels;
}

/// What the user wants done (03 §10.1 `intent`, M4 plan M3): one variant
/// per MVP action. The engine validates every value again before it builds
/// a plan from it.
@immutable
sealed class ActionIntent {
  const ActionIntent(this.serverId);

  final String serverId;
}

/// Signals process [pid] (PRC-02), only while its start time still reads
/// [startTicks], so a reused PID is never hit (03 §8.5).
final class KillProcess extends ActionIntent {
  const KillProcess(
    super.serverId, {
    required this.pid,
    required this.startTicks,
    this.signal = KillSignal.sigterm,
  });

  final int pid;
  final int startTicks;
  final KillSignal signal;
}

/// Starts, stops, restarts or reloads a system unit (SVC-03).
final class UnitAction extends ActionIntent {
  const UnitAction(
    super.serverId, {
    required this.unit,
    required this.verb,
    this.scope = UnitScope.system,
  });

  final String unit;
  final SystemctlVerb verb;
  final UnitScope scope;
}

/// Runs a timer's service now (JOB-08), the system's or the login
/// user's.
final class StartTimer extends ActionIntent {
  const StartTimer(
    super.serverId, {
    required this.timer,
    this.scope = UnitScope.system,
  });

  final String timer;
  final UnitScope scope;
}

/// Which systemd manager a unit action or query addresses (03 §7.5,
/// SVC-09).
enum UnitScope {
  /// The system manager.
  system,

  /// The login user's own manager (`systemctl --user`). Its actions run
  /// as the login user, never through sudo, which would address root's
  /// manager instead.
  user,
}

/// Runs a cron line's command once, now, as the user cron runs it as
/// (03 §7.7, JOB-19): `sh -c` with the line's `%` text on standard input,
/// and its output in [ActionFinished.output]. [source] and [raw] name the
/// line as the jobs list shows it, masked; the engine reads the source
/// again and finds the line by its masked form.
final class RunCronJob extends ActionIntent {
  const RunCronJob(super.serverId, {required this.source, required this.raw});

  /// [CronJob.source]: `crontab`, `crontab -u <user>`, `/etc/crontab` or
  /// an `/etc/cron.d/` file.
  final String source;

  /// The line as the jobs list shows it, masked.
  final String raw;
}

/// What [ContainerAction] does to a container (CTR-02).
enum ContainerVerb { start, stop, restart, pause, unpause, kill }

/// Changes a container's state (CTR-02); [signal] only with
/// [ContainerVerb.kill], whose default is the engine's (`SIGKILL`).
final class ContainerAction extends ActionIntent {
  const ContainerAction(
    super.serverId, {
    required this.containerId,
    required this.verb,
    this.signal,
  });

  final String containerId;
  final ContainerVerb verb;
  final KillSignal? signal;
}

/// Runs [argv] once in [containerId] without a TTY (03 §7.13, CTX-08), as
/// [user] where set, and reports its output and exit code in
/// [ActionFinished.output] and [ActionFinished.exitCode].
final class ContainerExec extends ActionIntent {
  ContainerExec(
    super.serverId, {
    required this.containerId,
    required Iterable<String> argv,
    this.user,
  }) : argv = List.unmodifiable(argv);

  final String containerId;
  final List<String> argv;
  final String? user;
}

/// Removes a container (CTR-05), its anonymous volumes with [volumes],
/// a running one with [force].
final class RemoveContainer extends ActionIntent {
  const RemoveContainer(
    super.serverId, {
    required this.containerId,
    this.volumes = false,
    this.force = false,
  });

  final String containerId;
  final bool volumes;
  final bool force;
}

/// Removes an image by reference or id (IMG-02); one in use only with
/// [force].
final class RemoveImage extends ActionIntent {
  const RemoveImage(super.serverId, {required this.image, this.force = false});

  final String image;
  final bool force;
}

/// What [StackAction] does to a Compose project (STK-03).
enum StackVerb { start, stop, restart }

/// Starts, stops or restarts a Compose project's containers (STK-03), or
/// only [service]'s (STK-23). [actAnyway] confirms acting on a stack
/// another manager owns (03 §8.7).
final class StackAction extends ActionIntent {
  const StackAction(
    super.serverId, {
    required this.project,
    required this.verb,
    this.service,
    this.actAnyway = false,
  });

  final String project;
  final StackVerb verb;
  final String? service;
  final bool actAnyway;
}

/// What [StackComposeAction] runs on a Compose project (STK-23).
enum StackComposeVerb {
  /// Pull one service's image.
  pullService,

  /// Recreate one service's containers even when unchanged.
  recreateService,

  /// Set one service's replica count.
  scaleService,

  /// Take the whole stack down, never with its volumes.
  down,
}

/// A compose operation on a verified, unmanaged stack (STK-23), run as
/// one detached operation as STK-06's redeploy is: [service] for every
/// verb but [StackComposeVerb.down], and [replicas] for
/// [StackComposeVerb.scaleService].
final class StackComposeAction extends ActionIntent {
  const StackComposeAction(
    super.serverId, {
    required this.project,
    required this.verb,
    this.service,
    this.replicas,
  });

  final String project;
  final StackComposeVerb verb;
  final String? service;
  final int? replicas;
}

/// Pulls a verified, unmanaged stack's images and recreates it (STK-06),
/// removing orphan containers with [removeOrphans].
final class RedeployStack extends ActionIntent {
  const RedeployStack(
    super.serverId, {
    required this.project,
    this.removeOrphans = false,
  });

  final String project;
  final bool removeOrphans;
}

/// What an edit reads and writes (03 §8.5, SAF-12, X-05).
@immutable
sealed class EditTarget {
  const EditTarget();
}

/// A file by its absolute, normalized path (03 §8.8).
final class FileTarget extends EditTarget {
  const FileTarget(this.path);

  final String path;

  @override
  bool operator ==(Object other) => other is FileTarget && other.path == path;

  @override
  int get hashCode => path.hashCode;
}

/// A crontab (JOB-04 to JOB-07): the login user's, or [user]'s, which
/// another account's needs admin mode.
final class CrontabTarget extends EditTarget {
  const CrontabTarget({this.user});

  final String? user;

  @override
  bool operator ==(Object other) =>
      other is CrontabTarget && other.user == user;

  @override
  int get hashCode => Object.hash(CrontabTarget, user);
}

/// One file of the compose project [project] (03 §7.16 STK-07): a config
/// or environment file its containers recorded, or the `.env` in its
/// working directory, as [DockerStackFileQuery] reads them. Only a
/// verified project's files are read or written, and a write checks the
/// candidate with `compose config -q` before it replaces the file.
final class StackFileTarget extends EditTarget {
  const StackFileTarget({required this.project, required this.path});

  final String project;

  /// The file's absolute path, as the project's labels name it.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is StackFileTarget &&
      other.project == project &&
      other.path == path;

  @override
  int get hashCode => Object.hash(StackFileTarget, project, path);
}

/// Replaces [target]'s content with [text] (SAF-12, X-05), only while the
/// target still has [baseSha256], the hash its [ReadEditable] read. The
/// plan backs the target up first, writes a temp file beside it, carries
/// its owner, mode, ACL and xattrs over (D67) and renames it over the
/// target; a crontab goes through `crontab -`.
final class EditFile extends ActionIntent {
  const EditFile(
    super.serverId, {
    required this.target,
    required this.text,
    required this.baseSha256,
  });

  final EditTarget target;
  final String text;
  final String baseSha256;
}

/// Whose backups a footprint action or row is (03 §8.11): the login
/// user's, under its home, or root's under `/var/lib`, which needs admin
/// mode.
enum FootprintScope { user, root }

/// Keeps the newest [count] backups of each file in [scope]'s backup
/// directory and removes the rest, with their index lines (SAF-14,
/// "keep last N"; tier 1).
final class KeepLastBackups extends ActionIntent {
  const KeepLastBackups(super.serverId, {required this.scope, this.count = 5})
    : assert(count >= 1, 'keep at least one');

  final FootprintScope scope;
  final int count;
}

/// Removes every backup of [source], a path or `crontab:<user>`, from
/// [scope]'s backup directory (SAF-14). They are the only undo of the
/// edits they back up, so this needs the typed confirmation.
final class RemoveBackups extends ActionIntent {
  const RemoveBackups(
    super.serverId, {
    required this.scope,
    required this.source,
  });

  final FootprintScope scope;
  final String source;
}

/// The app's safety preferences (M4 plan M4, SAF-01, SAF-06): per server,
/// whether management is on and whether it is read-only, plus the global
/// read-only switch and admin mode's inactivity expiry.
@immutable
final class SafetyPolicy {
  const SafetyPolicy({
    this.globalReadOnly = false,
    this.servers = const {},
    this.adminExpiry = kDefaultAdminExpiry,
  });

  final bool globalReadOnly;

  /// By server id; a server without an entry has the default: management
  /// off.
  final Map<String, ServerSafety> servers;

  /// One of [kAdminExpiryChoices].
  final Duration adminExpiry;
}

/// One server's safety preferences. Management is off by default
/// (SAF-01): the server is observed, never changed.
@immutable
final class ServerSafety {
  const ServerSafety({
    this.management = false,
    this.readOnly = false,
    this.marks = const {},
  });

  final bool management;
  final bool readOnly;

  /// Targets the user marked protected on this device (SAF-22): unit,
  /// container and stack names. They stay device-local until v1's `pref`
  /// records (M4 plan Q1).
  final Set<String> marks;
}

/// Admin mode's default inactivity expiry [E] (03 §8.2).
const kDefaultAdminExpiry = Duration(minutes: 15);

/// The expiries the Safety tab offers (M4 plan M5).
const kAdminExpiryChoices = [
  Duration(minutes: 5),
  kDefaultAdminExpiry,
  Duration(minutes: 30),
  Duration(minutes: 60),
];

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

/// What [PlanAction] previews before anything runs (03 §8.5, SAF-04):
/// the exact steps the plan will run, the host writes they cause, who runs
/// them, the typed risk facts the app words (D35), and the tier
/// [RunAction] must satisfy. The engine's plan and this preview share the
/// step list, so what the user confirms is what runs.
@immutable
final class ActionPreview {
  const ActionPreview({
    required this.intent,
    required this.targetName,
    required this.steps,
    required this.requiredLevel,
    required this.runner,
    required this.requiredTier,
    this.hostWrites = const [],
    this.detached = false,
    this.danger = const [],
    this.impact,
    this.ownership,
    this.protected,
    this.followUnit,
    this.orphans = const [],
    this.warnings = const {},
  });

  final ActionIntent intent;

  /// What a typed confirmation repeats.
  final String targetName;

  final List<PlanStep> steps;
  final RequiredLevel requiredLevel;
  final RunnerFacts runner;
  final ConfirmationTier requiredTier;
  final List<HostWriteRow> hostWrites;

  /// The steps run as a detached operation (03 §7.17).
  final bool detached;

  /// What DangerLinter found in the shell steps.
  final List<DangerFinding> danger;

  final PlanImpact? impact;
  final PlanOwnership? ownership;

  /// Why the target is protected, or null when it is not.
  final ProtectedReason? protected;

  /// The unit whose journal shows the run's effect, from the run's start:
  /// JOB-08's timer service (03 §7.7).
  final String? followUnit;

  /// The stack's containers whose service its files no longer name,
  /// which `--remove-orphans` would remove (STK-06).
  final List<String> orphans;

  final Set<PlanWarning> warnings;
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

/// The login password for [user] (03 §4.5): asked on a connect the user
/// started, for a server whose password the vault does not hold.
final class CredentialPromptRequest extends PromptRequest {
  const CredentialPromptRequest({
    required this.user,
    this.retry = false,
    this.canSave = false,
  });

  final String user;

  /// Whether the server refused the previous answer to this question.
  final bool retry;

  /// Whether the answer can be kept in the vault ([PromptSecretAnswer.save]):
  /// the server names a vault entry and the engine may write the vault.
  final bool canSave;

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
  const PromptSecretAnswer(this.secret, {this.save = false});

  final String? secret;

  /// Keep [secret] in the vault once the server accepts it; honoured only
  /// for a [CredentialPromptRequest] whose `canSave` is set.
  final bool save;
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
  /// The connection was refused, or the host had no route or no address,
  /// or its SSH service closed the connection before the handshake began.
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

  /// The login user's own systemd units, from its user manager
  /// ([UnitsResult], 7.5, SVC-09).
  userUnits,

  /// The login user's own systemd timers ([TimersResult], 7.7, JOB-08).
  userTimers,
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
