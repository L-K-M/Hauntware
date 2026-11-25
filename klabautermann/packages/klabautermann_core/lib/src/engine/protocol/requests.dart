part of '../protocol.dart';

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

/// Asserts that every device on the account runs the release
/// [PinPublicationState.release] names or later, or withdraws that with
/// [asserted] false (D15, M5 plan M07). While asserted, a pin the user
/// confirms is published; a withdrawal stops publication, and pins sent
/// stay. Refused while no release is offered.
final class SetPinPublication extends EngineRequest {
  const SetPinPublication({required this.asserted});

  final bool asserted;
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
