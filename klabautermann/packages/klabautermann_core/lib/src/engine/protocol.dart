import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;

// Only plain-data host types cross (D52): none here holds a function, as
// `Collector` (its argument validators) and `ServerZone` (`offsetAt`) do.
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        AccountsSnapshot,
        BackupEntry,
        DiskUsageListing,
        FirewallRead,
        FootprintRow,
        HostProfile,
        JobEntry,
        OnCalendarResult,
        OpDirectoryKind,
        OpDirectoryListing,
        PackageCheck,
        RestartCheck,
        SmartDisk,
        SshdPosture,
        ThresholdRule,
        TimerDetail;
import 'package:klabautermann_docker/klabautermann_docker.dart' show ApiVersion;
import 'package:meta/meta.dart';
import 'package:seance_core/seance_core.dart' show Snippet;

import '../catalog/klabautermann_records.dart' show SyncedRule;
import '../certificates/tls_check.dart' show TlsEndpoint, TlsEndpointCheck;
import '../docker/docker_ladder.dart'
    show DockerNoRouteReason, DockerRouteLabel;
import '../history/history_store.dart' show HistoryRange, HistoryTier;
import 'protocol/actions.dart';
import 'protocol/docker.dart';
import 'protocol/equality.dart' show sameItems;
import 'protocol/fleet.dart';
import 'protocol/host_queries.dart';
import 'protocol/host_reports.dart';
import 'protocol/links.dart';
import 'protocol/logs.dart';
import 'protocol/prompts.dart';
import 'protocol/sampling.dart';
import 'protocol/sync.dart';

export 'protocol/actions.dart';
export 'protocol/docker.dart';
export 'protocol/fleet.dart';
export 'protocol/host_queries.dart';
export 'protocol/host_reports.dart';
export 'protocol/links.dart';
export 'protocol/logs.dart';
export 'protocol/prompts.dart';
export 'protocol/sampling.dart';
export 'protocol/sync.dart';

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
///
/// The editor's connection test then joined v3 the same way (FL-03, M5
/// plan M09b): [TestServerConnection], answered by
/// [ServerConnectionTested]. [DuplicateServer] then joined it, answered
/// as [SaveServer].
///
/// The volume list then joined v3 the same way (03 §7.15 VOL-01, M6 plan
/// N10a): [DockerWatchList.volumes], delivered as [DockerVolumesPayload].
/// The [CreateVolume] and [RemoveVolume] intents then joined it (VOL-02,
/// N10b), with the refusals `volumeInUse` and `volumeExists`.
///
/// The network list then joined v3 the same way (03 §7.15 DNW-01, DNW-02,
/// M6 plan N11): [DockerWatchList.networks], delivered as
/// [DockerNetworksPayload], and the [RemoveNetwork] intent with the
/// refusals `networkInUse` and `builtinNetwork`.
///
/// Prune then joined v3 the same way (03 §7.12 DKE-05, IMG-06, M6 plan
/// N12): the [PruneDocker] intent, whose preview carries a
/// [PrunePreview], and the refusal `nothingToPrune`.
///
/// The image pull then joined v3 the same way (03 §7.14 IMG-03, M6 plan
/// N13): the [PullImage] intent, [ImagePullProgress] while it runs, and
/// [CancelAction], which stops it; then [PullRoute], the host's own
/// `docker pull`, in the foreground or detached (REG-01, N13b).
///
/// An image's history then joined v3 the same way (03 §7.14 IMG-04, M6
/// plan N14): [DockerImageHistoryQuery], answered by
/// [DockerImageHistoryPayload] with each layer's instruction masked.
///
/// A container's processes then joined v3 the same way (03 §7.12 CTR-10,
/// M6 plan N17): [DockerContainerTopQuery], answered by
/// [DockerContainerTopPayload] with each command line masked.
///
/// Per-server polling caps then joined v3 the same way (02 SAF-19, M6
/// plan N64): [SetServerCadenceCap].
///
/// Update checks then joined v3 the same way (03 §7.14 IMG-05, M6 plan
/// N15): [DockerImageUpdatesQuery], answered by
/// [DockerImageUpdatesPayload].
///
/// Séance's snippets then joined v3 the same way (03 §7.21 AUT-01, M6
/// plan N65): the engine sends [SnippetsChanged] unasked, and the
/// [RunSnippet] intent runs one, reporting its output as [RunCronJob]
/// does.
///
/// CN-16's docker program then joined v3 the same way: [SetDockerProgram]
/// names the `docker` a server's relays and compose commands run,
/// [DockerEndpointRoute] gained `dockerProgram` and
/// [DockerEndpointFailure] gained `invalidProgram`.
/// Port forwards then joined v3 the same way (03 §5.11 NET-11, DKE-09, M6
/// plan N22): [OpenPortForward] and [ClosePortForward], answered by
/// [PortForwardState].
///
/// The key passphrase prompt then joined v3 the same way (03 §4.5, D70):
/// [KeyPassphrasePromptRequest] asks for the passphrase of an encrypted
/// private key, the server's or a jump host's, and is answered with
/// [PromptSecretAnswer], whose `save` it never honours.
///
/// Vault recovery then joined v3 the same way (03 §4.5, CRED-05):
/// [NewRecoveryCode], [SetRecoveryCode], [RecoveryStatusRequest],
/// [ExportVault] and [RestoreVault], answered by
/// [RecoveryCodeGenerated], [RecoveryStatus], [VaultExported],
/// [VaultRestored] and [VaultRecoveryFailed]. The vault key stays behind
/// the keystore responder, so recovery runs inside the vault's exclusive
/// queue.
///
/// Sync request ids then joined v3 the same way (03 §10.1): [EnrollSync]
/// and [RunSyncRound] gained an optional `requestId` that each
/// [SyncStatus] answering them echoes, so a round the engine starts after
/// a catalog write, which carries none, answers no request.
///
/// [ConfirmEndpoints] then gained `shown`, the endpoints the user looked
/// at as [ShownEndpoint]s, within v3 the same way (03 §4.7, SAF-09): the
/// engine confirms no server whose endpoint changed since.
///
/// Sync sign-out then joined v3 the same way (03 §4.3): the [SignOutSync]
/// request, answered by [SyncStatus] for the new [SyncOperation.signOut].
///
/// Rejections by id and engine faults then joined v3 the same way:
/// [RequestRejected] gained an optional `requestId`, the rejected
/// request's own id where it carries one, so the app settles the one
/// read or open that was refused, and [EngineFault] reports an error the
/// engine caught at its last-resort boundary.
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
    this.requestId,
  });

  /// Echoed by the [SyncStatus] events that answer this request.
  final String? requestId;

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
  const RunSyncRound({this.requestId});

  /// Echoed by the [SyncStatus] events that answer this request.
  final String? requestId;
}

/// Signs this device out of the enrolled account (03 §4.3), as
/// Poltergeist's sign-out does: the engine forgets the session token, the
/// enrollment and the account's records, removes the servers that came
/// from the account with their vault entries, and drops their cached
/// profiles, history and links. The imported servers and the host-key
/// pins stay, and nothing on the sync server changes. Answered by
/// [SyncStatus] events for [SyncOperation.signOut], and the fleet in a
/// [CatalogReplaced] when it succeeds.
final class SignOutSync extends EngineRequest {
  const SignOutSync({this.requestId});

  /// Echoed by the [SyncStatus] events that answer this request.
  final String? requestId;
}

/// Asks for the host-key quarantine diff as it stands (03 §10.1, §4.9):
/// every stored `hostkey:` record whose key differs from the pin this
/// device trusts for the same `host:port`. The app reads it at startup and
/// after a sync; answered by [PinConflictsChanged].
final class ReadPinConflicts extends EngineRequest {
  const ReadPinConflicts();
}

/// Resolves one host-key conflict (03 §10.1, §4.9): [keepLocal] keeps this
/// device's pin and re-pushes it under a fresh tuple, and false trusts the
/// pulled key. The fingerprints are the ones the user saw: a locator that
/// names no current conflict, or whose conflict now holds other keys, is a
/// no-op, so a decision never applies to a key that arrived after it was
/// made. Answered by [PinConflictsChanged] with the diff afterwards, or
/// [RequestRejected].
final class ResolvePinConflict extends EngineRequest {
  const ResolvePinConflict(
    this.locator, {
    required this.keepLocal,
    required this.localFingerprintSha256,
    required this.pulledFingerprintSha256,
  });

  /// `host:port` — the locator spelling a pin's record id carries.
  final String locator;

  /// Whether to keep this device's pin rather than trust the pulled key.
  final bool keepLocal;

  /// The fingerprint this device trusted when the conflict was shown.
  final String localFingerprintSha256;

  /// The fingerprint the pulled key carried when the conflict was shown.
  final String pulledFingerprintSha256;
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
///
/// With [shown], the endpoints the user looked at by server id, a server
/// is confirmed only while its endpoint still matches the one shown: a
/// sync that changed it in the meantime leaves it unconfirmed, and the
/// fleet that answers lists it as waiting again. A hop on a confirmed
/// route is pinned only when [shown] carries it too and it still matches:
/// a hop the user never confirmed in its own row, or one a sync rewrote
/// since, stays unconfirmed, so the servers behind it wait. The app
/// always sends [shown]; without it, as in tests, each endpoint is taken
/// as it stands.
final class ConfirmEndpoints extends EngineRequest {
  const ConfirmEndpoints(this.serverIds, {this.shown});

  final List<String> serverIds;
  final Map<String, ShownEndpoint>? shown;
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

/// Caps [serverId]'s cadence at [cap]'s 03 §6.4 column (SAF-19), such as
/// the cellular saver for a server behind a metered link; null lifts the
/// cap. The slower of the cap and [SetCadenceProfile]'s column wins, so a
/// cap never speeds a server up. Caps outlive the fleet: a server that
/// leaves and returns keeps its own.
final class SetServerCadenceCap extends EngineRequest {
  const SetServerCadenceCap(this.serverId, this.cap);

  final String serverId;
  final CadenceProfile? cap;
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

/// Redacts [lines] the app holds for an export (LOG-10, 03 §8.9) through
/// the engine's secret redactor, which the app cannot import, answered
/// by [RedactedLines] with [requestId].
final class RedactLines extends EngineRequest {
  const RedactLines(this.requestId, this.lines);

  final String requestId;
  final List<String> lines;
}

/// Checks each of [endpoints]' TLS certificate from this device (CRT-01,
/// 03 §7.10): a handshake per endpoint, at once, without SSH. One
/// [TlsEndpointsChecked] with [requestId] answers it.
final class CheckTlsEndpoints extends EngineRequest {
  const CheckTlsEndpoints(this.requestId, this.endpoints);

  final String requestId;
  final List<TlsEndpoint> endpoints;
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

/// Sets the program [serverId]'s Docker relays and compose commands run
/// for `docker` (CN-16): the app's per-server path from `settings.json`
/// (03 §4.10), or null for the `docker` on the exec `PATH`, sent as
/// [SetDockerEndpoint] is. It serves a CLI the non-login `PATH` lacks,
/// such as Snap's `/snap/bin/docker` or a NAS's `/usr/local/bin/docker`.
/// The engine keeps it until another arrives or the server leaves the
/// fleet, and a session that holds an endpoint resolves again with it at
/// once; the same program again changes nothing. A path
/// [dockerProgramPathProblem] refuses fails the endpoint with
/// [DockerEndpointFailure.invalidProgram]. Ignored for a server outside
/// the fleet.
final class SetDockerProgram extends EngineRequest {
  const SetDockerProgram({required this.serverId, this.program});

  final String serverId;
  final String? program;
}

/// The most port forwards the engine holds open at once [E] (03 §5.11):
/// each is a listening socket on the device.
const int kPortForwardsMax = 16;

/// Why a forward's target cannot be used (NET-11, DKE-09).
enum PortForwardTargetProblem {
  /// The host is empty, longer than a DNS name may be, or holds a space or
  /// a control character.
  badHost,

  /// The port is outside 1 to 65535.
  badPort,
}

/// Why [host] and [port] cannot be a forward's target, or null when the
/// engine forwards to them as given. The app checks a typed target with
/// it, and the engine every [OpenPortForward].
PortForwardTargetProblem? portForwardTargetProblem(String host, int port) {
  if (port < 1 || port > 65535) return PortForwardTargetProblem.badPort;
  if (host.isEmpty ||
      host.length > 253 ||
      host.runes.any((r) => r <= 0x20 || r == 0x7f)) {
    return PortForwardTargetProblem.badHost;
  }
  return null;
}

/// Opens a port forward (NET-11, DKE-09, 03 §5.11): a listener on the
/// device's `127.0.0.1` at a port the system picks, each connection to it
/// relayed over [serverId]'s link to [host]:[port] as the server sees
/// them (a container's address for an unpublished port). Answered by
/// [PortForwardState]s under [forwardId], the app's own id: one that
/// listens, or one that ended at once and says why. Only an explicit
/// user action opens one.
final class OpenPortForward extends EngineRequest {
  const OpenPortForward({
    required this.serverId,
    required this.forwardId,
    required this.host,
    required this.port,
  });

  final String serverId;
  final String forwardId;
  final String host;
  final int port;
}

/// Ends [forwardId]'s forward: its listener and every connection close,
/// and a final [PortForwardState] says [PortForwardEnd.closed]. An
/// unknown id is ignored.
final class ClosePortForward extends EngineRequest {
  const ClosePortForward(this.forwardId);

  final String forwardId;
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

/// Stops the running plan [planId] where its step can stop: an image pull
/// (IMG-03), whose request the engine closes, which cancels the pull on
/// the daemon. The plan finishes as [ActionOutcome.cancelled]; a step
/// that cannot stop runs to its end.
final class CancelAction extends EngineRequest {
  const CancelAction(this.planId);

  final String planId;
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

/// Generates a new recovery code for the vault, to be shown once
/// (03 §4.5, CRED-05). Answered by [RecoveryCodeGenerated] with
/// [requestId]. Nothing is stored: the code becomes this device's
/// recovery code only when [SetRecoveryCode] carries it back.
final class NewRecoveryCode extends EngineRequest {
  const NewRecoveryCode({required this.requestId});

  final String requestId;
}

/// Makes [code] this device's recovery code, replacing any earlier one
/// (03 §4.5, CRED-05). The vault key comes from the app's keystore
/// answer, and the write runs inside the vault's exclusive queue beside
/// the sync re-key journal. Answered by [RecoveryStatus] or
/// [VaultRecoveryFailed].
final class SetRecoveryCode extends EngineRequest {
  const SetRecoveryCode({required this.requestId, required this.code});

  final String requestId;
  final String code;
}

/// Asks whether this device has a recovery code an export can use,
/// answered by [RecoveryStatus] or [VaultRecoveryFailed]. With the
/// keystore locked, whether the entry exists, which is all anyone can
/// tell.
final class RecoveryStatusRequest extends EngineRequest {
  const RecoveryStatusRequest({required this.requestId});

  final String requestId;
}

/// Exports the vault, encrypted under the recovery code (03 §4.5,
/// CRED-05). The export is the `seance-secrets` format every app reads.
/// Answered by [VaultExported] or [VaultRecoveryFailed].
final class ExportVault extends EngineRequest {
  const ExportVault({required this.requestId});

  final String requestId;
}

/// What a [RestoreVault] does with a credential this device already
/// holds.
enum VaultRestorePolicy {
  /// Keep this device's copy (the default).
  keepExisting,

  /// Take the export's copy.
  replaceExisting,
}

/// Restores an export into this device's vault (03 §4.5, CRED-05). The
/// bytes are bounded by `SecretsExport.maxBytes` before anything is
/// decoded, and nothing is written unless the export opens with [code].
/// Answered by [VaultRestored] or [VaultRecoveryFailed].
final class RestoreVault extends EngineRequest {
  const RestoreVault({
    required this.requestId,
    required this.export,
    required this.code,
    required this.policy,
  });

  final String requestId;
  final Uint8List export;
  final String code;
  final VaultRestorePolicy policy;
}

/// The name the host syslog line gives this device (SAF-13, M5 plan Q6),
/// sent at spawn and on every change. Until it arrives, or while blank,
/// the line names no device.
final class SetDeviceName extends EngineRequest {
  const SetDeviceName(this.name);

  final String name;
}

/// The suite release whose Séance carries the #56 fix (D15, FL-22): the
/// release a pin publication assertion names. 1.9.3 is the first tag
/// whose Séance changelog lists the fix (M5 plan Q1). An engine started
/// with no release offers no assertion and publishes no pin.
const String kPinPublicationRelease = '1.9.3';

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
      other is ServerDraft && sameItems(_fields, other._fields);

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
/// preferences just before its answer when they can be read (else the
/// next round's refresh does), and a round's [SyncStatus] after.
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

/// Tries [draft] with [credential]'s boxes the way a connect would,
/// saving neither (FL-03, M5 plan M09b): the server's host key, every jump
/// host's and the sign-in, with the connect's prompts, then closes the
/// connection. A host key the user trusts during the test holds for that
/// attempt only, so the first real connect asks again. Answered by
/// [ServerConnectionTested]; refused while links are off.
final class TestServerConnection extends EngineRequest {
  const TestServerConnection({
    required this.requestId,
    required this.draft,
    this.credential = const ServerCredentialEntry(),
  });

  final String requestId;
  final ServerDraft draft;

  /// The boxes as typed; blank ones fall back to the stored credential.
  final ServerCredentialEntry credential;
}

/// Copies the synced server [serverId] as a new one (FL-03, M5 plan M09b):
/// its own id and timestamps, a free "copy" label, and its own copy of
/// the credential, never a vault entry the two share (seance_protocol's
/// `duplicateServerConfig`). Answered as [SaveServer], with the copy's
/// id.
final class DuplicateServer extends EngineRequest {
  const DuplicateServer({required this.requestId, required this.serverId});

  final String requestId;
  final String serverId;
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

/// Seals the alert rule [ruleId] as its `rule` record (03 §4.8); the
/// app's rule editor sends it. Answered as [SaveServer].
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
/// records, newest end first, from [after] on (from the newest when
/// null), answered by [AuditRecords].
final class AuditQuery extends EngineRequest {
  const AuditQuery(this.serverId, {this.after, this.limit = 100})
    : assert(limit > 0, 'limit must be positive');

  final String serverId;

  /// The previous page's [AuditRecords.next].
  final AuditCursor? after;
  final int limit;
}

/// Where the next page of an audit log starts (SAF-11): past the records
/// that ended after [endedAt], and past the first [seen] of those that
/// ended at it. The log is in end order, newest first, and records that
/// ended together in append order, so one appended between two pages
/// lands after those [seen] counted. Records are not appended in end
/// order, since a detached operation's is appended when its result is
/// acknowledged, so a page boundary is not a time alone. A prune between
/// two pages can shorten a tie group; the next page then starts at its
/// remaining records, which may repeat ones already shown.
@immutable
final class AuditCursor {
  const AuditCursor(this.endedAt, {required this.seen})
    : assert(seen > 0, 'a page ends on a record');

  final DateTime endedAt;
  final int seen;
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

/// Reads one folder of [serverId] for the disk space explorer (DSK-07,
/// 03 §7.3): its total and its entries, largest first, on the folder's
/// own filesystem; read-only and never cached. As the login user, or with
/// [elevated] as root through admin mode, which reads what the login user
/// may not, so the sizes are complete. One [DiskUsageReport] with
/// [requestId] answers it.
final class ReadDiskUsage extends EngineRequest {
  const ReadDiskUsage(
    this.serverId,
    this.path, {
    required this.requestId,
    this.elevated = false,
    this.root,
    this.fresh = false,
  });

  final String serverId;

  /// Absolute and normalized, without a trailing slash unless it is `/`.
  final String path;
  final String requestId;
  final bool elevated;

  /// The mount point the explorer started at, in [path]'s form. Where
  /// ncdu or gdu is installed, the engine exports the whole filesystem
  /// under it once and answers each folder under it from that export;
  /// null reads [path] alone.
  final String? root;

  /// Reads again rather than answering from an earlier export: the
  /// explorer's Read again.
  final bool fresh;
}

/// Reads one timer's triggers on [serverId] for its details (JOB-02, 03
/// §7.7, D57): its `OnCalendar=` and monotonic triggers and randomized
/// delay, and each calendar trigger's next runs, as the login user; in
/// the login user's own manager when [user]. Never cached. One
/// [TimerDetailReport] with [requestId] answers it.
final class ReadTimerDetail extends EngineRequest {
  const ReadTimerDetail(
    this.serverId,
    this.unit, {
    required this.requestId,
    this.user = false,
  });

  final String serverId;
  final String unit;
  final String requestId;
  final bool user;
}

/// Reads every drive's SMART health on [serverId] (HW-04, 03 §7.11): in
/// admin mode only, since smartctl needs the device nodes, which are
/// root's on every distribution; never cached, and a spun-down drive is
/// left asleep. One [SmartReport] with [requestId] answers it.
final class ReadSmart extends EngineRequest {
  const ReadSmart(this.serverId, {required this.requestId});

  final String serverId;
  final String requestId;
}

/// Reads [serverId]'s pending updates and reboot flag (PKG-01 to PKG-03,
/// 03 §7.8) as the login user, from the package manager's cached
/// metadata. The engine keeps each server's answer for an hour and
/// answers from it unless [fresh] asks for a new check. One
/// [PackagesReport] with [requestId] answers it.
final class ReadPackages extends EngineRequest {
  const ReadPackages(
    this.serverId, {
    required this.requestId,
    this.fresh = false,
  });

  final String serverId;
  final String requestId;
  final bool fresh;
}

/// Reads [serverId]'s services still running replaced libraries (PKG-04,
/// 03 §7.8): in admin mode only, since the tools read every process's
/// memory maps. One [RestartReport] with [requestId] answers it.
final class ReadRestarts extends EngineRequest {
  const ReadRestarts(this.serverId, {required this.requestId});

  final String serverId;
  final String requestId;
}

/// Reads [serverId]'s firewall rules (NET-06, 03 §7.4): in admin mode
/// only, since ufw, firewalld, nft and iptables-save all need root. One
/// [FirewallReport] with [requestId] answers it.
final class ReadFirewall extends EngineRequest {
  const ReadFirewall(this.serverId, {required this.requestId});

  final String serverId;
  final String requestId;
}

/// Reads [serverId]'s effective sshd configuration for the app's own
/// connection (SEC-01, 03 §7.10): in admin mode only, since `sshd -T`
/// loads the host keys. One [SshdPostureReport] with [requestId] answers
/// it.
final class ReadSshdPosture extends EngineRequest {
  const ReadSshdPosture(this.serverId, {required this.requestId});

  final String serverId;
  final String requestId;
}

/// Reads [serverId]'s accounts, their groups and who is logged in (ACC-01,
/// ACC-02, 03 §7.9) as the login user; never cached. One [AccountsReport]
/// with [requestId] answers it.
final class ReadAccounts extends EngineRequest {
  const ReadAccounts(this.serverId, {required this.requestId});

  final String serverId;
  final String requestId;
}

/// Reads [serverId]'s on-device history in [tier] (HIS-01, 03 §7.20):
/// the buckets and gaps within the tier's span. One [HistoryRead] with
/// [requestId] answers it.
final class ReadHistory extends EngineRequest {
  const ReadHistory(this.serverId, this.tier, {required this.requestId});

  final String serverId;
  final HistoryTier tier;
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
  const RequestRejected(this.requestName, this.reason, {this.requestId});

  final String requestName;
  final String reason;

  /// The rejected request's own id, where it carries one: its
  /// `requestId`, or the query, stream, watch, forward, terminal, plan,
  /// operation or prompt id it names. The app settles that one request
  /// with it instead of waiting on an answer that will not come. Null for
  /// a request that names none.
  final String? requestId;
}

/// The engine caught an error nothing else handled (its last-resort
/// boundary) and goes on running: the work that threw is lost, every
/// link, shell and stream stays up. [error] and [stack] are the error's
/// text and stack trace, for a log and a bug report; they are not
/// redacted, so the app shows them only where the user asks for detail.
final class EngineFault extends EngineEvent {
  const EngineFault(this.error, {this.stack = ''});

  final String error;
  final String stack;
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
/// [SyncPhase.succeeded] or [SyncPhase.failed]. Besides the requested
/// ones, the engine runs a round after each catalog write it took.
final class SyncStatus extends EngineEvent {
  const SyncStatus(
    this.phase, {
    required this.operation,
    this.requestId,
    this.account,
    this.failure,
    this.passphraseUnverified = false,
    this.detail,
    this.prefixBudget,
    this.pinConflicts,
    this.recordsAwaitingSpace = 0,
    this.recordsTooLarge = 0,
  });

  final SyncPhase phase;
  final SyncOperation operation;

  /// The id of the [EnrollSync], [RunSyncRound] or [SignOutSync] this
  /// operation answers; null for a round the engine started itself, or a
  /// request sent without one.
  final String? requestId;

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

  /// The host-key quarantine diff after a succeeded operation, or null when
  /// it is unchanged: a failed round keeps the previous list, as Séance's
  /// settings backend does. A resolution reports through
  /// [PinConflictsChanged], not here.
  final List<SyncPinConflict>? pinConflicts;

  /// After a round: how many records the server refused for the account's
  /// storage quota ([SyncFailure.accountFull]). They stay on this device
  /// and sync once the account has room.
  final int recordsAwaitingSpace;

  /// After a round: how many records the server refused as too large to
  /// store. They stay on this device, offered again each round, until
  /// they shrink or the server's limit grows. A round that refuses only
  /// these still succeeds.
  final int recordsTooLarge;

  /// This status as the answer to the request [requestId].
  SyncStatus answering(String? requestId) => SyncStatus(
    phase,
    operation: operation,
    requestId: requestId,
    account: account,
    failure: failure,
    passphraseUnverified: passphraseUnverified,
    detail: detail,
    prefixBudget: prefixBudget,
    pinConflicts: pinConflicts,
    recordsAwaitingSpace: recordsAwaitingSpace,
    recordsTooLarge: recordsTooLarge,
  );
}

/// The host-key quarantine diff changed (03 §10.1): a [ReadPinConflicts] or
/// a [ResolvePinConflict] answered, carrying the whole list as it stands.
final class PinConflictsChanged extends EngineEvent {
  PinConflictsChanged(Iterable<SyncPinConflict> conflicts)
    : conflicts = List.unmodifiable(conflicts);

  final List<SyncPinConflict> conflicts;
}

/// Why a port forward ended (03 §5.11).
enum PortForwardEnd {
  /// The app closed it, or the engine stopped.
  closed,

  /// The server had no link to forward over.
  noLink,

  /// The server's link went, and its channels with it.
  linkLost,

  /// The system would not open a listener on `127.0.0.1`.
  bindFailed,

  /// The target is one [portForwardTargetProblem] refuses.
  invalidTarget,

  /// [kPortForwardsMax] forwards were open.
  tooMany,

  /// The app's forward id was already open.
  duplicateId,

  /// The server left the fleet, or its endpoint now names another machine
  /// (SYN-08).
  serverForgotten,
}

/// Why the last connection through a forward could not be relayed; the
/// forward keeps listening.
enum PortForwardFailure {
  /// The server refused the `direct-tcpip` channel: `AllowTcpForwarding`
  /// is off, or the server refused it otherwise (03 §5.3).
  forwardingDisabled,

  /// The channel did not open: the target refused or did not answer, or
  /// the link failed.
  connectFailed,
}

/// A port forward's state (03 §5.11), after each change: listening on
/// `127.0.0.1:`[localPort] with [connections] open, the last connection's
/// [failure] if it failed, or [ended] with the reason, its last state.
final class PortForwardState extends EngineEvent {
  const PortForwardState({
    required this.serverId,
    required this.forwardId,
    required this.host,
    required this.port,
    this.localPort,
    this.connections = 0,
    this.failure,
    this.ended,
  });

  final String serverId;
  final String forwardId;
  final String host;
  final int port;

  /// The listener's port on `127.0.0.1`; null once ended or before it
  /// listened.
  final int? localPort;
  final int connections;
  final PortForwardFailure? failure;
  final PortForwardEnd? ended;
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

/// The answer to a [TestServerConnection]. [summary] and [notes] are
/// seance_core's sentences, which Séance's and Poltergeist's editors show
/// too, and [log] the redacted transcript: the report quotes them as the
/// SSH layer wrote them.
final class ServerConnectionTested extends EngineEvent {
  const ServerConnectionTested({
    required this.requestId,
    required this.ok,
    required this.summary,
    required this.log,
    this.notes = const [],
  });

  final String requestId;

  /// Whether the server accepted the sign-in.
  final bool ok;
  final String summary;
  final List<String> notes;
  final String log;
}

/// A catalog write ([SaveServer], [DuplicateServer], [DeleteServer], [SetServerPrefs],
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
             (stream == SampleStream.userTimers && result is TimersResult) ||
             (stream == SampleStream.temps && result is TempsResult) ||
             (stream == SampleStream.gpu && result is GpuResult),
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

/// How far [serverId]'s clock is from this device's (CN-17), measured at
/// each probe answer: the probe's `date +%s` against the engine's clock
/// when the answer arrived. It is good to a second or two: `date` reads
/// whole seconds, and the answer's last areas and its transit come after
/// it, which reads as the server being behind by that much.
final class ServerClock extends EngineEvent {
  const ServerClock(this.serverId, {required this.skew, required this.at});

  final String serverId;

  /// The server's time less this device's: positive when the server is
  /// ahead.
  final Duration skew;

  /// When the probe answered, by the engine's clock in UTC.
  final DateTime at;
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

/// [RedactLines]' lines, redacted, joined with newlines.
final class RedactedLines extends EngineEvent {
  const RedactedLines(this.requestId, this.text);

  final String requestId;
  final String text;
}

/// [CheckTlsEndpoints]' checks, in its order.
final class TlsEndpointsChecked extends EngineEvent {
  TlsEndpointsChecked(this.requestId, Iterable<TlsEndpointCheck> checks)
    : checks = List.unmodifiable(checks);

  final String requestId;
  final List<TlsEndpointCheck> checks;
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

/// Where a running image pull stands (03 §7.14 IMG-03): each layer the
/// daemon reported, in the order it first did, and the latest message
/// about the image as a whole. Sent at most a few times a second.
final class ImagePullProgress extends EngineEvent {
  ImagePullProgress({
    required this.planId,
    required Iterable<PullLayer> layers,
    this.status,
  }) : layers = List.unmodifiable(layers);

  final String planId;
  final List<PullLayer> layers;

  /// The daemon's last message without a layer id, such as
  /// `Pulling from library/nginx` or `Digest: sha256:...`.
  final String? status;
}

/// One layer of an [ImagePullProgress]: the daemon's status for it
/// (`Downloading`, `Extracting`, `Pull complete`, ...) and the bytes done
/// of the total, when it reports them.
@immutable
final class PullLayer {
  const PullLayer(this.id, {this.status, this.current, this.total});

  final String id;
  final String? status;
  final int? current;
  final int? total;
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
    this.resolvedPath,
  });

  /// The content an [EditFile] that ran wrote: [text] with its SHA-256
  /// recomputed, so the next save plans against it before the follow-up
  /// read answers, and still does when that read fails.
  factory EditContent.written(
    String text, {
    required bool privileged,
    int? uid,
    int? gid,
    int? mode,
  }) => EditContent(
    text: text,
    sha256: _sha256OfText(text),
    privileged: privileged,
    uid: uid,
    gid: gid,
    mode: mode,
  );

  final String text;
  final String sha256;
  final bool privileged;
  final int? uid, gid, mode;

  /// The real file a symlinked path names, which was read and which the
  /// edit writes, leaving the link a link; null when the path opened is
  /// the real file.
  final String? resolvedPath;
}

/// [text]'s UTF-8 SHA-256, the hash an [EditFile]'s compare-and-swap names.
String _sha256OfText(String text) =>
    sha256.convert(utf8.encode(text)).toString();

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

  /// The path is a symbolic link the host has no `readlink -f` or
  /// `realpath` to resolve, so the engine cannot tell which file a write
  /// through it would change.
  symlink,

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
    this.skippedSteps = const [],
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

  /// The indexes of best-effort steps that failed without failing the
  /// run, such as the host syslog line (SAF-13).
  final List<int> skippedSteps;

  /// What a [ContainerExec], a [RunCronJob] or a [RunSnippet] printed,
  /// whether it succeeded or failed.
  final ExecOutput? output;
}

/// The engine will not plan [intent] or run plan [planId] (03 §8.5): the
/// one carries the request it answers, so the app matches it to what it
/// asked. Nothing ran.
final class ActionRefused extends EngineEvent {
  const ActionRefused(this.reason, {this.intent, this.planId, this.detail})
    : assert((intent == null) != (planId == null), 'one of intent, planId');

  final ActionRefusalReason reason;

  /// What the failed planning step said, in the server's or engine's
  /// words and not localized: the step, its exit code and error output,
  /// or the error a planner threw. Null where the reason says it all.
  /// Control characters stripped, at most `kRefusalDetailMaxChars`.
  final String? detail;

  /// The refused [PlanAction]'s intent.
  final ActionIntent? intent;

  /// The refused [RunAction]'s plan.
  final String? planId;
}

/// The answer to [ReadDiskUsage]: [path]'s listing, or why nothing was
/// read.
final class DiskUsageReport extends EngineEvent {
  const DiskUsageReport({
    required this.serverId,
    required this.requestId,
    required this.path,
    this.listing,
    this.failure,
  });

  final String serverId;
  final String requestId;
  final String path;
  final DiskUsageListing? listing;
  final DiskUsageReportFailure? failure;
}

/// The answer to [ReadTimerDetail]: [unit]'s triggers and each calendar
/// trigger's `systemd-analyze calendar` result keyed by expression, which
/// `TimerJobEntry.withDetail` merges into the timer's row, or why nothing
/// was read.
final class TimerDetailReport extends EngineEvent {
  TimerDetailReport({
    required this.serverId,
    required this.requestId,
    required this.unit,
    required this.user,
    this.detail,
    Map<String, OnCalendarResult> calendars = const {},
    this.failure,
  }) : calendars = Map.unmodifiable(calendars);

  final String serverId;
  final String requestId;
  final String unit;
  final bool user;
  final TimerDetail? detail;
  final Map<String, OnCalendarResult> calendars;
  final TimerDetailFailure? failure;
}

/// The answer to [ReadAccounts]: what the read found, or why nothing was
/// read.
final class AccountsReport extends EngineEvent {
  const AccountsReport({
    required this.serverId,
    required this.requestId,
    this.snapshot,
    this.failure,
  });

  final String serverId;
  final String requestId;
  final AccountsSnapshot? snapshot;
  final AccountsReportFailure? failure;
}

/// The answer to [ReadSmart]: each drive smartctl opens, at most
/// `kSmartDrivesRead`, with its health.
final class SmartReport extends EngineEvent {
  SmartReport({
    required this.serverId,
    required this.requestId,
    Iterable<SmartDisk> disks = const [],
    this.notRead = 0,
    this.failure,
  }) : disks = List.unmodifiable(disks);

  final String serverId;
  final String requestId;
  final List<SmartDisk> disks;

  /// Drives past `kSmartDrivesRead`, which were not read.
  final int notRead;

  /// Why nothing was read, or null.
  final SmartReportFailure? failure;
}

/// The answer to [ReadRestarts]: what the check found, or why nothing.
final class RestartReport extends EngineEvent {
  const RestartReport({
    required this.serverId,
    required this.requestId,
    this.check,
    this.failure,
  });

  final String serverId;
  final String requestId;
  final RestartCheck? check;
  final RestartReportFailure? failure;
}

/// The answer to [ReadFirewall].
final class FirewallReport extends EngineEvent {
  const FirewallReport({
    required this.serverId,
    required this.requestId,
    this.read,
    this.failure,
  });

  final String serverId;
  final String requestId;
  final FirewallRead? read;
  final FirewallReportFailure? failure;
}

/// The answer to [ReadSshdPosture].
final class SshdPostureReport extends EngineEvent {
  const SshdPostureReport({
    required this.serverId,
    required this.requestId,
    this.posture,
    this.failure,
    this.detail,
  });

  final String serverId;
  final String requestId;
  final SshdPosture? posture;
  final SshdPostureFailure? failure;

  /// sshd's error lines for [SshdPostureFailure.refused].
  final String? detail;
}

/// The answer to [ReadPackages]: what the check found at [checkedAt], by
/// the engine's clock, or why there was no check.
final class PackagesReport extends EngineEvent {
  const PackagesReport({
    required this.serverId,
    required this.requestId,
    this.check,
    this.checkedAt,
    this.failure,
  });

  final String serverId;
  final String requestId;

  /// What the check found; its own failure says when the host's package
  /// manager could not answer.
  final PackageCheck? check;

  final DateTime? checkedAt;
  final PackagesReportFailure? failure;
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
  /// names another process, in two listings in a row: it was killed
  /// before it could record a result (at logout, or by a reboot).
  lost,

  /// Its record says running and the engine could not check the wrapper,
  /// or found it gone once: it may have ended after the listing was read,
  /// which the next listing, 15 s later, shows.
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

/// The answer to an [AuditQuery]: [records] newest end first, and where
/// the next page starts.
final class AuditRecords extends EngineEvent {
  AuditRecords(
    this.serverId,
    Iterable<AuditRecord> records, {
    this.next,
    this.unreadable = false,
  }) : records = List.unmodifiable(records);

  final String serverId;
  final List<AuditRecord> records;

  /// The next page's [AuditQuery.after], or null when no records remain.
  final AuditCursor? next;

  /// Whether older records remain.
  bool get more => next != null;

  /// The server's log file could not be read, so [records] lacks what it
  /// holds; the file is left as it is for a later read.
  final bool unreadable;
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
    Iterable<int> skippedSteps = const [],
  }) : steps = List.unmodifiable(steps),
       skippedSteps = List.unmodifiable(skippedSteps);

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

  /// The best-effort steps that failed without failing the run (SAF-13).
  final List<int> skippedSteps;

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
    if (skippedSteps.isNotEmpty) 'skippedSteps': skippedSteps,
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

/// A new recovery code, to be shown once (03 §4.5, CRED-05). The code
/// crosses the protocol because the app shows it; the engine stores
/// nothing until [SetRecoveryCode].
final class RecoveryCodeGenerated extends EngineEvent {
  const RecoveryCodeGenerated({required this.requestId, required this.code});

  final String requestId;
  final String code;
}

/// Whether this device has a recovery code an export can use (03 §4.5,
/// CRED-05).
final class RecoveryStatus extends EngineEvent {
  const RecoveryStatus({required this.requestId, required this.configured});

  final String requestId;
  final bool configured;
}

/// The vault's encrypted export (03 §4.5, CRED-05), in the
/// `seance-secrets` format every app reads.
final class VaultExported extends EngineEvent {
  const VaultExported({required this.requestId, required this.bytes});

  final String requestId;
  final Uint8List bytes;
}

/// What a restore did (03 §4.5, CRED-05), by [requestId].
final class VaultRestored extends EngineEvent {
  const VaultRestored({
    required this.requestId,
    required this.added,
    required this.replaced,
    required this.kept,
    required this.unreadable,
  });

  final String requestId;
  final int added;
  final int replaced;
  final int kept;
  final int unreadable;
}

/// Why a recovery operation failed. [failure] is a fixed kind the app
/// words through its ARB catalog; no diagnostic text, code, key material
/// or exception message crosses with it.
final class VaultRecoveryFailed extends EngineEvent {
  const VaultRecoveryFailed({required this.requestId, required this.failure});

  final String requestId;
  final VaultRecoveryFailure failure;
}

/// Why a recovery operation could not be done (03 §4.5, CRED-05). Each
/// kind is actionable on its own; the engine carries no raw exception
/// text.
enum VaultRecoveryFailure {
  /// This process may not write the support directory (D63).
  directoryShared,

  /// The keystore holds no vault key or could not answer, so the vault
  /// cannot be opened. Nothing was changed and no key was minted.
  keystoreUnavailable,

  /// This device has no recovery code, so there is nothing to export.
  notSetUp,

  /// The stored recovery entry does not open under this vault's key.
  damaged,

  /// The typed code is not a recovery code.
  invalidCode,

  /// The code is well formed but is not the one the export was made with.
  wrongCode,

  /// The export was altered after it was made.
  tampered,

  /// The export is not a secrets export or is damaged.
  malformed,

  /// The export was written by a newer format version.
  unsupportedVersion,

  /// The export exceeds the size or entry limit.
  tooLarge,

  /// Anything else; the app shows a generic failure.
  failed,
}

/// One in-app threshold alert raised or cleared (ALR-01, 03 §7.19, D29):
/// the engine evaluates every synced rule on the live samples of the
/// servers it applies to, on this device while Klabautermann is open. A
/// rule that is removed or changed, or a server that leaves its scope,
/// clears a raised alert at once.
final class LocalAlertChanged extends EngineEvent {
  const LocalAlertChanged({
    required this.serverId,
    required this.ruleId,
    required this.metric,
    required this.severity,
    required this.raised,
    required this.at,
    this.value,
    this.since,
  });

  final String serverId;

  /// The `rule` record's id.
  final String ruleId;

  /// The rule's metric id, such as `cpu.busy`.
  final String metric;

  final AlertSeverity severity;

  /// True when the alert went up, false when it cleared.
  final bool raised;

  /// The reading that raised or cleared it, by the engine's clock in UTC.
  final DateTime at;

  /// The value that reading had; null for a clear without a reading.
  final double? value;

  /// When the breach behind a raise began, as the rule's `for` counts it.
  final DateTime? since;
}

/// The account's alert rules (03 §4.8, §7.19) changed: a pulled or
/// written `rule` record applied or was removed. [rules] is every live
/// rule. The engine sends it only on a change, starting from none, so an
/// account without rules never hears it.
final class AlertRulesChanged extends EngineEvent {
  const AlertRulesChanged(this.rules);

  final List<SyncedRule> rules;
}

/// Séance's snippets the account carries (03 §7.21, AUT-01) changed: a
/// pulled `snippet:` record applied or a tombstone removed one. [snippets]
/// is every live snippet, by title. As with [AlertRulesChanged], the
/// engine sends it only on a change, starting from none.
final class SnippetsChanged extends EngineEvent {
  const SnippetsChanged(this.snippets);

  final List<Snippet> snippets;
}

/// The answer to [ReadHistory]: [serverId]'s buckets in [tier], oldest
/// first, the one still filling included, and the gaps the engine saw
/// within their span; empty before the engine opens its store.
final class HistoryRead extends EngineEvent {
  const HistoryRead({
    required this.requestId,
    required this.serverId,
    required this.tier,
    required this.range,
  });

  final String requestId;
  final String serverId;
  final HistoryTier tier;
  final HistoryRange range;
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

/// A running plan's end state (03 §10.1).
enum ActionOutcome { succeeded, failed, cancelled }

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
