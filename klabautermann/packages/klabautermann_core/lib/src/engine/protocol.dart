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

part 'protocol/requests.dart';
part 'protocol/events.dart';

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
/// [OpenTerminal], [TerminalInput], [TerminalResize] and [CloseTerminal]
/// run one, answered by [TerminalOpened], [TerminalBytes] and
/// [TerminalClosed]. One-off commands joined next
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
///
/// Version 4 drops the requests no client sends: `DockerContainersQuery`
/// and `DockerImagesQuery`, whose lists the app reads through a watch
/// instead, and `TerminalEndInput`, which nothing sends now that a shell
/// closes with `CloseTerminal` (03 §10.1). The list payloads a watch
/// delivers stay.
const int kEngineProtocolVersion = 4;

/// The most container shells one server holds open at once [E]: each on a
/// relay holds a session channel (03 §5.2).
const int kTerminalsPerServerMax = 4;

/// The largest terminal [OpenTerminal] and [TerminalResize] take, in
/// either dimension.
const int kTerminalDimensionMax = 1000;

/// Every message the UI isolate sends the engine (03 §10.1, D18). Plain data
/// only: no function-typed fields, no Futures, no `dartssh2` types; the
/// `seance_core` value types the barrel shows are plain data too, so values
/// cross `SendPort`s untouched.
@immutable
sealed class EngineRequest {
  const EngineRequest();
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

/// What a [RestoreVault] does with a credential this device already
/// holds.
enum VaultRestorePolicy {
  /// Keep this device's copy (the default).
  keepExisting,

  /// Take the export's copy.
  replaceExisting,
}

/// The suite release whose Séance carries the #56 fix (D15, FL-22): the
/// release a pin publication assertion names. 1.9.3 is the first tag
/// whose Séance changelog lists the fix (M5 plan Q1). An engine started
/// with no release offers no assertion and publishes no pin.
const String kPinPublicationRelease = '1.9.3';

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

/// Every message the engine sends the UI isolate (03 §10.1, D18). Same plain
/// -data rules as [EngineRequest].
@immutable
sealed class EngineEvent {
  const EngineEvent();
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
