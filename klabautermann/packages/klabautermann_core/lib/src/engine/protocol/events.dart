part of '../protocol.dart';

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
