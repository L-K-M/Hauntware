# seance_core transport and safety (F2)

Scope: Klabautermann prerequisite extraction F2, rows F2a to F2e of
`docs/design/klabautermann/03-ARCHITECTURE.md` section 3.5 with sections
3.6, 5.1, 5.2, 5.3, 5.10, 8.3 and 8.8, decisions D4, D23 and D24, and the
F2 milestone of `docs/design/klabautermann/04-IMPLEMENTATION.md` section
13. Read-only design; no code changed.

Status: proposed for the Klabautermann foundations (F2); approval under the owner's instruction of 2026-10-13 to implement the plan.

Prepared from a read-only pass over this worktree at commit `20acafc7`.
No `.dart_tool` resolution exists in this worktree, so the pinned
`dartssh2: 4.1.0` package source was not read. dartssh2 APIs are cited by
name; where a call site exists in the repository the `path:line` is given,
and where only the plan attests an API the citation is marked `[plan]`.

## 1. Inventory

### 1.1 `seance/packages/seance_core/lib/src/ssh/` (4,613 lines, 11 files)

| File | Lines | Contents | F2 disposition |
|---|---|---|---|
| `ssh_session.dart` | 1,404 | credentials, route resolution, per-hop authentication, `SshSession`, `runCommand`, SFTP open, bounded teardown | re-based on the shared exec core; skeleton reused by `SshLink` |
| `remote_command.dart` | 49 | `RemoteCommandResult` `:5-24`, `RemoteCommandException` `:30-41`, `RemoteCommandRunner` typedef `:48-49` | types reused unchanged by the exec core |
| `remote_git.dart` | 579 | `RemoteGit` `:158` over an injected `RemoteCommandRunner` `:159,165` | precedent: `RemoteGit(link.run)` works once `run` is assignable to the typedef |
| `remote_file_system.dart` | 957 | `RemoteFileSystem` interface `:88`, `RemoteFileException`/`RemoteFileErrorKind` `:10-35`, `DartSshRemoteFileSystem` `:183`, `_guard` SFTP-to-VFS classification `:847-905` | unchanged; `SshLink.openFileSystem` wraps the same adapter |
| `ssh_agent.dart` | 819 | `SshAgentClient` `:54`, bounds `_maxAgentMessageBytes` = 256 KiB `:16`, `_maxAgentIdentities` = 2048 `:17`, `_agentRequestTimeout` = 5 min `:18`, Unix agent `:234`, Windows named-pipe FFI `:293` | unchanged; `openAuthenticatedClient` already injects the loader (`SshAgentIdentityLoader` `ssh_session.dart:75`) |
| `ssh_algorithms.dart` | 78 | `suiteSshAlgorithms` `:53-78` | unchanged; stays out of the barrel (plan 3.4 note 3) |
| `sequential_cleanup.dart` | 47 | `CleanupAction` `:3`, `CleanupFailureMode` `:5`, `SingleFlightCleanup` `:7-25`, `runSequentialCleanup` `:28-47` | F2e: barrel export; reused by the link's bounded close |
| `test_connection.dart` | 350 | `HostAuthenticator` `:27-32`, `liveHostAuthenticator` `:53-117` (5 s close bound `:85`), `ConnectionTestResult` `:120-147`, `runConnectionTest` `:168-298`, `UnpinnedHostKeyStore` `:318-350` | unchanged; already the shared connection-test surface both editors call |
| `executable_launch.dart` | 146 | `LaunchHost` `:70`, extension tables `:20,:80,:106`, `isExecutableLaunchName` `:126` | unrelated to F2; untouched |
| `home_path.dart` | 34 | `expandHomePath` `:17-33` | reused by F2c's identity-file seam (already shared) |
| `identity_audit_log.dart` | 150 | `IdentityReadEvent` `:12`, `IdentityAuditLog` `:77` | unchanged; both apps' identity readers already feed it |

`ssh_session.dart` in detail (anchors verified at `20acafc7`):

- `SshCredentials` `:33-53`, `ResolvedSshHost` `:56-61`, resolver/connector
  typedefs `SshJumpHostResolver` `:64`, `SshForwardConnector` `:67-72`,
  `SshAgentIdentityLoader` `:75`; `AuthKind` `:78-84`; `HostKeyPrompter`
  `:89`; `KeyboardInteractiveChallenge`/`KeyboardInteractiveResponder`
  `:95-112`.
- `_verifyHostKey` `:114-136` (TOFU check, then prompt, then pin);
  `SshConnectionLog` `:143-316`; `redactConnectionTrace` `:318`;
  `SshConnectException` `:374-406`.
- `SshSession` `:409-692`: fields incl. `SingleFlightCleanup _cleanup`
  `:415`; `_wire` `:437-462`; `openRemoteFileSystem` `:466-508` (15 s open
  bound `:467`, late SFTP discard `:496,:500`); `runCommand` `:524-622`
  (default cap `256 * 1024` `:527`, collapsed open error `:540`, one
  stopwatch-bounded wait `:588-600`, bounded `abort` `:576-582`, non-zero
  exit returned as data `:607`); `resize` `:625-628`; `_remoteClosed`
  `:630-651` (2 s stream-drain grace `:636-639`); `_finish`/`_finishOnce`
  `:668-688` (`runSequentialCleanup` over subs, SFTP, shell, client,
  engine, 5 s per action `:686`); `isClosed` `:691`.
- `openAuthenticatedClient` `:730-859`: `keepAliveInterval` parameter
  documented for pool-owned liveness `:728-729`, default 10 s
  `_defaultSshKeepAliveInterval` `:22` bound at `:741`, positivity checked
  `:745-751`; route resolution `:754-759`; credential preparation before
  the first network side effect `:767-777`; injectable `connect` and
  `forward` seams `:779-785`; per-hop auth loop `:788-856`.
- `_PreparedSshHost` `:861-867`; `_resolveSshRoute` `:869-940` (cycle
  detection `:881-888`, 16-hop cap `_maxJumpHosts` `:23` enforced
  `:889-896`); `_prepareSshHost` `:942-996`; `_authenticateSshHost`
  `:998-1071` (`SSHClient` construction `:1020-1050` with
  `suiteSshAlgorithms` `:1025`, `authenticated` bounded at 5 min
  `_sshAuthenticationTimeout` `:21` via `:1053-1058`, bounded cleanup of
  the failed hop `:1065-1068`).
- `_OwnedJumpSocket` `:1077-1118`: a forwarded `SSHSocket` that owns its
  parent client and closes both through `runSequentialCleanup`
  `:1097-1104`, `:1107-1117`.
- `_SshRouteDependencies` `:1120-1130`; `SshSessionManager` `:1134-1404`
  (`connect` `:1226-1266` opens the shell `:1250-1252` then runs the login
  script `:1257`; `loginScriptKeystrokes` `:1193`).

### 1.2 Adjacent `seance_core` files F2 touches

| File | Lines | Contents | F2 disposition |
|---|---|---|---|
| `lib/src/sync/push_batcher.dart` | 71 | `batchForPush` `:24-71`, pure function over `PushLimits` | F2e: barrel export; only `src/sync/sync_engine.dart` consumes it today |
| `lib/src/llm/danger_linter.dart` | 134 | `DangerSeverity` `:2`, `DangerFinding` `:4-14`, 14 rules `:26-100`, `scan` `:104-117`, `worst` `:120-126` | F2d: append rules; `scan`/`worst` untouched |
| `lib/src/terminal/shell_command.dart` | 72 | `quoteShellWord` `:63` | F2b elevation prelude and argv quoting reuse it (8.8 names it the one quoting function) |
| `lib/src/terminal/session_transport.dart` | 31 | `SessionTransport` interface | unchanged; `SshLink` is separate from `SessionTransport` (the shell stays `SshSession`) |
| `lib/src/store/stores.dart` | 393 | `SecretVault` `:171` (`getSecret`), `VaultStore` `:132` | unchanged; F2c's vault seam matches `getSecret`'s signature |
| `lib/seance_core.dart` | 68 | ssh exports `:19-28`, `remote_file_system` show-list `:29-40`, stores `:44-45`, llm `:61-68` | F2e adds `push_batcher.dart`, `sequential_cleanup.dart`, and the new F2 modules |

### 1.3 Poltergeist `lib/src/connection/` (4,725 lines, 9 files; pattern only)

The pool stays in Poltergeist (plan 3.6: frozen by M0 evidence, D19). F2a
copies four of its mechanisms:

| Mechanism | Poltergeist source | What F2a takes |
|---|---|---|
| Idle ping with timeout | `_pingIdleTransport` `connection_manager.dart:1927-1963`: one outstanding ping per transport `:1930`, skipped while `hasActiveOperations` or pending opens/closes `:1934-1935`, `pingOperationTimeout` 30 s `ssh_transport.dart:42`, timeout closes the transport and lets the `done` watcher run death `:1943-1955` | the same rule set on `SshLink`: data in flight is proof of life; a ping unanswered 30 s marks the link lost |
| Channel budget | `PoolPolicy.maxChannelsPerTransport` = 8 `pool_policy.dart:32,:56`, `maxTransferChannelsPerTransport` = 4 `:25,:55` | cap 8 on session channels in `SshLink`; Poltergeist's per-kind split is pool policy, not link policy |
| Reconnect backoff | `reconnect.dart:3-4`: 1 s base, 0.3 downward jitter; cap 30 s `pool_policy.dart:46,:59` | constants only, for the Klabautermann supervisor's backoff and the `SshLinkBackoff(until)` state it drives (§3.2) |
| Late-open cleanup | `_DartSshTransport.openChannel` `ssh_transport.dart:392-401`: the abandoned `_client.sftp()` future is retained and its late channel closed via `closeSshResource` | same "hold the pending future, close the latecomer" inside the exec core and forwarding opens |
| Bounded close | `closeSshResource` `ssh_cleanup.dart:12-20`, 5 s `_closeTimeout` `:6` | already `runSequentialCleanup`; F2e removes the implementation import |

Other pool files are not inputs: `credential_resolution.dart` (29) defines
the dismissal `CredentialResolutionScope` `:16-28`; `pool_key.dart` (87)
the `(host, port, username, jumpHostId, routeContext)` key;
`incident_store.dart` (508) the `IncidentStore` interface `:181-195` and
serialized atomic `FileIncidentStore` `:245,:357,:422`;
`leased_file_system.dart` (240) the 30 s `idleRelease` lease `:28`: the
lease shape informs `openFileSystem`'s 60 s idle release (5.2);
`connection_manager.dart` (2,816) additionally carries
`CredentialOrigin` `:199`, `ResolvedCredentials` `:205-210`, the growth
rules `:224-232`, `_resolveRouteCredentials` `:1386-1421` (resolves the
target first, then every hop, tracking `prompted`), and
`_maximumJumpHosts` = 16 `:202` matching `ssh_session.dart:23`.

### 1.4 Credential resolution in the apps (F2c)

The plan's row cites `app_services.dart:1075-1150` and
`server_editor_backend.dart:210-262` as `[R]`. Current locations:

- Séance, `seance/app/seance_app/lib/services/app_services.dart`:
  `resolveCredentials` `:1075-1153` (agent short-circuit `:1084-1086`;
  orphan-bookmark `ArgumentError` `:1100-1113`; per-method draft-first
  dispatch `:1115-1153`), `_savedSecret` `:1158-1169` (named-but-absent
  entry throws `CredentialMissingException`, declared `:77-99`),
  `_readSavedSecret` `:1172-1175`, `resolveJumpHost` `:1178-1183`,
  `_readIdentityFile` `:1190-1194` (wraps `appLock.read`),
  `_readIdentityFileNow` `:1196-1268` (security-scoped bookmark
  resolution, refresh, audit, `FileSystemException` to
  `IdentityFileException`), `_auditIdentityRead` `:1270-1292`,
  `_expandHome` `:1294-1302`. Call sites:
  `app_state.dart:631` (editor test), `:1503` (connect);
  `resolveJumpHost` at `:644,:1509`.
- Poltergeist, pool path: `_PromptBroker.resolveCredentials`
  `poltergeist/packages/poltergeist_core/lib/src/engine/engine_host.dart:1366-1407`
  mints a `credentialNeeded` prompt (`CredentialPromptData`
  `protocol.dart:328`), races the reply against
  `CredentialResolutionScope.dismissed` `:1383`, maps dismissal and
  cancellation to `RemoteFileException(kind: cancelled)` `:1389-1402`,
  and reduces the reply to `SshCredentials` via `_credentialsOf` `:1409`.
  The UI side, `prompt_coordinator.dart`: `_PendingPrompt` dismissal flag
  `:19-31`, FIFO `_drain` `:147-177`, agent auto-answer
  `_answerWithoutDialog` `:206-221`, `_showCredential` `:273-345`
  (vault-first, kind-matched `:276-298`; dialog `:307-345`),
  `_readIdentityFile` `:351-365`, `_saveToVault` `:367-397`,
  `_secretMatches`/`_storedReply` `:417-432`; wired with
  `identityReader`/`vault` in `engine_session.dart:371-378`.
- Poltergeist, editor path: `server_editor_backend.dart`
  `testConnection` `:104-137`, `_snapshotJumpHosts` `:139-183`,
  `_resolveJumpHost` `:193-201`, `_resolveCredentials` `:210-263`: the
  port of Séance's resolver minus security bookmarks.
- `identity_file_reader.dart`: `IdentityFileReader.read` `:30-67`,
  audit `:69-91`, `IdentityFileReadException`/`IdentityFileReadFailureKind`
  `:94-100`. Stays app-side; `IdentityAuditLog` it feeds is already in
  `seance_core`.

Divergences the shared resolver must settle: Séance throws
`CredentialMissingException` for a named-but-absent vault entry
(`app_services.dart:1156-1169`); Poltergeist's editor copy resolves it to
an empty credential (`server_editor_backend.dart:222-225,:253-258`, the
`secret?.value ?? ''` lines). Séance reads identity files under
`appLock.read` with sandboxed bookmarks; Poltergeist reads the path
directly (not sandboxed). Draft-first ordering and per-method dispatch are
identical in both.

### 1.5 dartssh2 usage and pins

`dartssh2: 4.1.0` is pinned at `seance/packages/seance_core/pubspec.yaml:21`
(the exact-pin comment `:17-20` names the tests written against it),
`poltergeist/packages/poltergeist_core/pubspec.yaml:24`,
`poltergeist/packages/poltergeist_bench/pubspec.yaml:14`, and as a Séance
app **dev** dependency `seance/app/seance_app/pubspec.yaml:85` (under
`dev_dependencies:` `:80`).

Library imports: `ssh_session.dart:7`, `remote_file_system.dart:5`,
`ssh_agent.dart:8`, `ssh_algorithms.dart:1`: four files, the confinement
zone D4 protects. Test imports: nine `*_test.dart` files under
`seance_core/test/` (`remote_activity_test.dart`,
`remote_file_system_test.dart`,
`remote_file_system_upload_cas_test.dart`, `ssh_algorithms_test.dart`,
`ssh_diagnostics_dartssh2_shape_test.dart`, `ssh_diagnostics_test.dart`,
`ssh_host_key_refusal_test.dart`, `ssh_keepalive_controls_test.dart`,
`ssh_proxy_jump_test.dart`) plus the `test/support/ssh_peer.dart` fixture,
and one app test `seance_app/test/host_key_blocked_test.dart:4`. In
Poltergeist, `package:dartssh2` is imported only inside
`lib/src/connection/` (`ssh_transport.dart:4`) and `poltergeist_bench`,
matching `import_guard.dart`'s `_connectionDirectory` `:11` and
`_benchPackage` `:20`.

APIs used in-repo (4.1.0 call sites): `SSHClient` ctor with `algorithms`,
`keepAliveInterval`, `onVerifyHostKey`, `identities`, `onPasswordRequest`,
`onUserInfoRequest`, `printDebug`/`printTrace`
(`ssh_session.dart:1020-1050`); `client.authenticated` `:1053`;
`client.execute` `:535`; `client.shell(pty: SSHPtyConfig)` `:1250-1251`;
`client.sftp()` + `sftp.handshake` `:482-484`;
`client.forwardLocal` `:784`; `client.done`/`isClosed`/`close`;
`SSHSocket` members `stream`, `sink`, `done`, `flush`, `close`, `destroy`
(`_OwnedJumpSocket` `:1084-1117`); `SSHSession` `stdout`/`stderr`/`done`/
`exitCode`/`write`/`close` (`runCommand` `:561-607`);
`SSHUserInfoRequest` `:702`; `SSHKeyPair.fromPem` `:955-959`;
`SSHAuthFailError` (`ssh_transport.dart:289`); `client.ping()`
(`ssh_transport.dart:354`); `SftpClient`/`SftpStatusCode`
(`remote_file_system.dart` `_guard` `:847-905`); the `SSHAlgorithms`/
`SSHKexType`/`SSHHostkeyType`/`SSHCipherType` proposal types
(`ssh_algorithms.dart`).

APIs cited by name only (no in-repo call today):
`client.forwardLocalUnix` for `openUnixStream` (plan 5.4; the "no
`forwardLocalUnix` call anywhere" fact in 04 A.1 is confirmed by grep at
`20acafc7`), `SSHForwardChannel`'s lazy `stream`/`sink`, and
`SSHSession.kill(SSHSignal)`/`SSHSignal` behind `RemoteProcess.signal`.

### 1.6 Tests

Séance `seance_core/test/`: `ssh_proxy_jump_test.dart` (575): the
in-process wire fixture `support/ssh_peer.dart` (325), a `SshPeerSocket`
implementing `SSHSocket` that runs real key exchange and userauth with
dartssh2 internals; `ssh_keepalive_controls_test.dart` (106): proves the
keepalive parameter reaches the client timer and `null` disables it;
`ssh_host_key_refusal_test.dart` (298); `remote_git_test.dart` (436);
`sequential_cleanup_test.dart` (90); `push_batcher_test.dart` (166);
`ssh_algorithms_test.dart`, `ssh_diagnostics_test.dart`,
`ssh_diagnostics_dartssh2_shape_test.dart`, `test_connection_test.dart`
(1,033); `pure_logic_test.dart` hosts the `DangerLinter` group
`:108-159`; `remote_file_system_*` suites.

Poltergeist `poltergeist_core/test/connection/`: ~30 files, ~10,027
lines: pool lifecycle, keepalive, reconnect, teardown, incidents,
leases, waiters, `ssh_cleanup_test`, `ssh_transport_test`, plus
`server_editor_backend_test.dart` (265) and
`identity_file_reader_test.dart` (175) on the app side; Séance app has
`resolve_credentials_test.dart` (202).

### 1.7 Guards and the pin audit

`poltergeist/tool/import_guard/lib/import_guard.dart` encodes the
confinement zone (`_connectionDirectory` `:11`, `_benchPackage` `:20`).
`poltergeist/scripts/audit-seance-pin.sh` delegates to
`tool/seance_pin_audit/bin/audit.dart` → `runSeancePinAudit`; the gate
package set is `{'seance_core','seance_protocol'}`
(`seance_pin_audit.dart:24`), and the recorded verdict is the
`SEANCE_PIN_AUDIT_V3` block in `poltergeist/docs/PORTS.md:2015-2039`,
verified by the `seance_pin_audit` CI job (`.github/workflows/ci.yml`,
paths-filtered on `seance/**`, `poltergeist/**/pubspec.*`, `PORTS.md`,
the audit script/tool, and `ci.yml`). The audit binds provenance
(contributors, attributions, license lines, vendored paths, gitlinks), so
ordinary code changes by known contributors leave the record unchanged;
the refresh path is `scripts/audit-seance-pin.sh --write-record` per the
job's comment.

### 1.8 What stays app-side / Poltergeist-side

Stays in Poltergeist: `PooledConnectionManager` and everything under
`lib/src/connection/` (pooling, growth, reconnect driving, leases,
incidents, prompt bridging); `PromptCoordinator` dialogs and the prompt
queue; `IdentityFileReader` (audit sink type already shared);
`CredentialOrigin`/`ResolvedCredentials` (pool-growth bookkeeping);
`closeSshResource` as a thin local wrapper (it becomes a barrel import
instead of an implementation import, F2e).

Stays in Séance app: `AppLock`/locked-vault gating, security-scoped
`IdentityFileBookmarks`, `Settings` persistence, the host-key and
keyboard-interactive dialogs, `RemoteGitController`, the session model.
`SshSession` remains the shell/terminal transport (`SessionTransport`,
`session_transport.dart`); `SshLink` does not replace it in F2.

## 2. Package proposal

New files, all under `seance/packages/seance_core/lib/src/ssh/`: inside
the existing dartssh2 confinement zone, so no guard change is needed
beyond the F2e export list (D4; plan 3.4):

| New file | Contents | Depends on |
|---|---|---|
| `remote_process.dart` | `RemoteProcess`, `RemoteExit`, `RemoteSignal`, `PtyRequest`, plus the package-private exec core (`_ExecCore`) that `SshSession.runCommand` and `SshLink.run`/`start` share | dartssh2, `remote_command.dart`, `sequential_cleanup.dart`, `channel_budget.dart` |
| `byte_duplex.dart` | `ByteDuplex` interface and the forwarding-channel implementation with listen-before-write buffering | dartssh2, `sequential_cleanup.dart` |
| `channel_budget.dart` | `ChannelBudget` semaphore (cap 8) with labelled, prioritized waiters; `ChannelOpenException` + `ChannelRefusal` classification; `SshLinkSeen` | `meta` only |
| `ssh_link.dart` | `SshLink` interface + factory over `openAuthenticatedClient` (`keepAliveInterval: null`), `SshLinkState` sealed states, idle-ping loop, bounded close, late-open registry | dartssh2, `ssh_session.dart`, the three files above, `remote_file_system.dart` |
| `elevation.dart` | `ElevationProbe`, `ElevatedExecutor`, `ElevationException`/`ElevationFailureKind`, the 8.3 prelude builder and stderr classifier | `shell_command.dart` (`quoteShellWord`), `ssh_link.dart` |
| `credential_resolver.dart` | `CredentialResolver`, `CredentialDraft`, `CredentialSource`, `CredentialMissingException` (moved from `app_services.dart:77`) | `seance_protocol` (`ServerConfig`, `Secret`, `AuthMethod`), `ssh_session.dart` (`SshCredentials`, `ResolvedSshHost`) |

No new package dependencies; nothing new depends on Flutter or dart:io
beyond what `ssh/` already uses. The exec core is package-private: the
public surface is `SshLink`'s methods plus the value types, so
`klabautermann_*` never sees a dartssh2 type: the `connect` and `forward`
seams of `SshLink.connect` (§3.1) name dartssh2's `SSHSocket`, so they are
`@visibleForTesting` and production callers pass neither.

Barrel (`seance_core.dart`) additions: exports for the six files above,
`src/sync/push_batcher.dart`, and `src/ssh/sequential_cleanup.dart`.
`ssh_algorithms.dart` stays unexported (plan 3.4 note 3 records the
deliberate exception both Poltergeist's transport file and its bench
already use as a listed implementation import).

**String injection.** No UI strings move. Waiter reasons, refusal kinds,
link-state reasons and elevation failures are typed values, not text :
each app renders its own copy (Poltergeist via ARB, Séance via literals).
`SshConnectionLog`/`redactConnectionTrace` keep their existing
responsibility for connect transcripts.

## 3. Public API

### 3.1 Link, process, duplex

```dart
abstract interface class SshLink {
  ServerConfig get config;
  SshLinkState get state;                 // current value
  Stream<SshLinkState> get states;        // broadcast; each new listener
                                          // first receives the current state
  SshLinkSeen get seen;

  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,                    // default 30 s, as runCommand
    int maxOutputBytes = 256 * 1024,      // matches ssh_session.dart:527
    List<int>? stdin,                     // password line + payload (8.3)
  });
  Future<RemoteProcess> start(String command, {PtyRequest? pty});
  Future<ByteDuplex> openUnixStream(String socketPath);
  Future<ByteDuplex> openTcpStream(String host, int port);
  Future<RemoteFileSystem> openFileSystem();
  Future<void> close();                   // bounded, idempotent
}

abstract interface class RemoteProcess {
  Stream<List<int>> get stdout;           // subscribed at creation
  Stream<List<int>> get stderr;           // always drained
  StreamSink<List<int>> get stdin;        // close() sends channel EOF
  Future<RemoteExit> get exit;
  void signal(RemoteSignal signal);       // fire-and-forget
  Future<void> close();                   // signal TERM, close, bounded wait
}

abstract interface class ByteDuplex {
  Stream<List<int>> get stream;           // subscribed at creation
  StreamSink<List<int>> get sink;         // close() sends channel EOF
  Future<void> get done;
  Future<void> close();
}

final class PtyRequest { final int cols; final int rows; final String? term; }
final class RemoteExit { final int? exitCode; final String? exitSignal; }
enum RemoteSignal { hup, int_, quit, kill, term, usr1, usr2 } // RFC 4254 names

final class SshLinkSeen {
  final int? learnedSessionLimit;         // set by a below-cap refusal (5.2)
  final bool forwardingRefused;
}
```

`SshLink.run` is deliberately assignable to the `RemoteCommandRunner`
typedef (`remote_command.dart:48-49`): extra optional named parameters do
not break assignability, so `RemoteGit(link.run)` works and
`SshSession.runCommand` keeps its exact signature `:524-528` while
delegating to the same core. Recommendation: keep `timeout` nullable :
the plan's sketch writes `Duration timeout`, which would reject the
typedef's implicit `timeout: null` callers and break the RemoteGit seam.

Construction mirrors `openAuthenticatedClient`'s seams:

```dart
static Future<SshLink> connect({
  required ServerConfig config,
  required SshCredentials credentials,
  required TofuVerifier tofu,
  required HostKeyPrompter onHostKey,
  KeyboardInteractiveResponder? onKeyboardInteractive,
  SshJumpHostResolver? resolveJumpHost,
  Future<SSHSocket> Function(String, int, Duration)? connect,
  SshForwardConnector? forward,
  SshAgentIdentityLoader? loadAgentIdentities,
  Duration timeout = const Duration(seconds: 15),
  Duration idlePingInterval = const Duration(seconds: 15),
  Duration pingTimeout = const Duration(seconds: 30),
  Duration closeTimeout = const Duration(seconds: 5),
  int sessionBudget = 8,
  SshConnectionLog? log,
});
```

The last four knobs are the test seams for fake clocks and refusal
fixtures; production callers take the defaults. Internally it calls
`openAuthenticatedClient` with `keepAliveInterval: null` (its own
documentation at `ssh_session.dart:728-729` prescribes this when an owner
runs liveness) so no second keepalive clock runs: the same choice
Poltergeist's opener makes at `ssh_transport.dart:280-282`.

### 3.2 State model

`sealed class SshLinkState` with the eight states of plan 5.1 as plain,
isolate-crossable data (no Futures, no dartssh2 types):

`SshLinkIdle`, `SshLinkConnecting`, `SshLinkAuthenticating`,
`SshLinkReady(SshLinkSeen seen)`, `SshLinkDegraded(SshLinkDegradedReason reason)`,
`SshLinkBackoff(DateTime until)`, `SshLinkNeedsUser(LinkPrompt prompt)`,
`SshLinkClosed(SshLinkClosedReason reason)`. Reasons are enums (for
example `pingTimeout`, `sessionLimitLearned`, `transportError`,
`closedByOwner`, `linkLost`), never text: each app renders its own copy.
A learned fact (a below-cap session refusal, a forwarding refusal)
re-emits `SshLinkReady` with the updated `SshLinkSeen`, so listeners see
every change without polling `seen`.

The sketch's inline comment `// connecting, ready, degraded, lost,
closed` is reconciled as: "lost" is a transition `ready/degraded →
closed(reason: SshLinkClosedReason.linkLost)` when the link closes itself
after detected loss, or
`→ backoff(until)` when a reconnect owner exists. `SshLink` itself does
not reconnect: per 5.1, reconnect is the caller's policy; the link only
detects, closes and reports. Recommendation: a thin `SshLinkReconnect`
helper is **not** added in F2a; Klabautermann's supervisor implements
1 s base / 30 s cap / 0.3-jitter backoff (constants taken from
`reconnect.dart:3-4`, `pool_policy.dart:59`) because reconnect needs
host-level policy (journal cursors, `since=` resume) that lives outside
`seance_core`. `LinkPrompt` carries `KeyboardInteractiveChallenge`-style
plain data plus a prompt kind enum so isolate crossings stay serializable.

### 3.3 Errors and classification

Reused: `RemoteCommandException` (`remote_command.dart:30-41`) for
`run`/`start` transport failures, `RemoteFileException` for
`openFileSystem`, `SshConnectException` for connect/auth failure.

New, in `channel_budget.dart`:

```dart
enum ChannelRefusal { sessionLimit, forwardDisabled, other }
final class ChannelOpenException implements Exception {
  final ChannelRefusal refusal; final String message; final Object? cause;
}
```

Classification of a refused open follows 5.3: a session-type channel
refused with `SSH2_OPEN_CONNECT_FAILED`/"open failed" while the observed
open count is below the budget sets `SshLinkSeen.learnedSessionLimit` and
throws `ChannelOpenException(sessionLimit)`; refusal at the local cap
cannot happen (the semaphore blocks first: it queues, never fails); a
streamlocal or direct-tcpip refusal maps to `forwardDisabled` for the
endpoint-discovery ladder; everything else is `other`. General transport
failure mid-open stays `RemoteCommandException`/`RemoteFileException`
as today.

### 3.4 Elevation (F2b)

```dart
final class ElevationProbe {                 // filled by the host probe, 6.1
  final String? sudoVersionLine;             // `sudo -V` first line
  final bool sudoIsRs;
  final bool sudoNopasswd;                   // `sudo -n true` succeeded
  final bool doasPresent;                    // `command -v doas`
  final bool doasNopasswd;                   // `doas -n true` succeeded
  final bool run0Present;                    // `command -v run0`
  final bool printfIsBuiltin;                // `command -V printf`
}

enum ElevationFailureKind {
  wrongPassword,        // "Sorry, try again." / "incorrect password attempt"
  notInSudoers,         // "is not in the sudoers file"
  passwordRequired,     // "a password is required" after validation
  ttyRequired,          // "you must have a tty" (requiretty)
  unavailable,          // no ladder rung worked
}
final class ElevationException implements Exception {
  final ElevationFailureKind kind; final String stderr;
}

final class ElevatedExecutor {
  ElevatedExecutor(this.link, this.probe);
  /// The prelude's own exit when `sudo -v` fails (8.3). A rejection needs
  /// this status and a classified sudo text on stderr; 125 alone may be
  /// the elevated command's own status and is then returned as such.
  static const int passwordRejectedExit = 125;
  Future<RemoteCommandResult> run(List<String> argv,
      {String? password, List<int>? stdin, Duration? timeout});
}
```

`run` picks the ladder rung from the probe (root → `sudo -n` or, without
sudo, `doas -n` → prelude → direct-`sudo -S` retry → PTY/doas → run0 →
polkit `systemctl --no-ask-password`), builds `sh -c '<prelude>' elevate <args>`
with each arg through `quoteShellWord` (`shell_command.dart:63`), pipes
the password line first then `stdin`, and classifies exit 125 plus the
stderr texts: never `2>/dev/null`, per D24's rejection record
(`03-ARCHITECTURE.md:478-483`).

### 3.5 CredentialResolver (F2c)

```dart
abstract interface class CredentialSource {
  Future<Secret?> storedSecret(String secretRef);   // vault read
  Future<String> identityFile(ServerConfig config, CredentialDraft? draft);
}

final class CredentialDraft {
  final String? password, privateKeyPem, keyPassphrase;
  final Object? identityBookmark;   // opaque; forwarded to identityFile
}

final class CredentialMissingException implements Exception { ... }

final class CredentialResolver {
  CredentialResolver(this._source,
      {this.missingSecretPolicy = MissingSecretPolicy.fail});

  /// fail (Séance's semantics, the default) or substituteEmpty
  /// (Poltergeist's editor path today). A small explicit switch, deleted
  /// when Poltergeist takes the fail-loud policy.
  final MissingSecretPolicy missingSecretPolicy;

  Future<SshCredentials> resolve(ServerConfig config, {CredentialDraft? draft});

  /// Adapter over a config lookup for `SshJumpHostResolver`
  /// (`ssh_session.dart:64`): identical 3-line wrap both apps repeat.
  SshJumpHostResolver jumpHostResolver(
      Future<ServerConfig?> Function(String id) lookup);
}
```

Both apps construct it once over their own seams: Séance supplies
`_readSavedSecret` + `_readIdentityFile` (which already wraps
`appLock.read`, bookmarks and the audit log); Poltergeist supplies
`vault.getSecret` + `IdentityFileReader.read`. The decision table :
agent short-circuit, per-method draft precedence, the orphan-bookmark
`ArgumentError`, vault-by-`secretRef`: lives once in the resolver.
`CredentialOrigin` stays Poltergeist-side: it is produced by the prompt
path (`_storedReply` `prompt_coordinator.dart:422-432`), not by silent
resolution. Cancellation mapping (`RemoteFileException(kind:
cancelled)`, `engine_host.dart:1389-1402`) likewise stays where the
prompt scope lives.

### 3.6 Danger rules (F2d)

Appended to `_rules` after `danger_linter.dart:100`. Severity calibration
follows the existing split: critical for mass or unbounded destruction,
warning for scoped data loss and lockout-class commands (`iptables -F`
`:96-100`, the power rule `:91-95`).

After F2-4 (review of #156), rows 15 to 19 and 22 to 25 were revised and
row 26 added. The rows use four shorthands: `O` is
`(?:\s+-\S+(?:\s+[^\s-]\S*)?){0,8}`, up to eight options with or
without a value; unbounded, it backtracked over every later option, so
a 40 KB script of repeated `docker -a` took over 20 s to scan. `D` is
`\bdockerO`, `docker` and its global options (`--context prod`,
`-H ssh://h`); `K` is
`(?<![\w-])kill(?![\w-])` plus a negative lookahead that skips a first
argument of `-l`, `-L`, `--list`, `--table` or signal 0 (`-0`, `-s 0`,
`-n 0`, `--signal 0`), forms that send no signal; only the first argument
counts, so a `# -l` comment cannot hide `kill -9 1`; `N` is
`(?<!\s(?:-[snq]|--signal|--queue|--timeout))`, which rejects a word
that is a signal, queue or timeout operand rather than a PID. The code
writes rows 25 and 26 in an equivalent linear form: the operand
lookbehind follows the PID, and only the first `kill` on a line is tried
(for row 26, also a `kill` whose arguments continue on the next line
inside quotes), since a later kill reaches nothing the first one does
not. Trying every kill took about 36 s on a 64 KB line of `kill x`.

| # | Pattern | Severity | Explanation |
|---|---|---|---|
| 15 | `D\s+system\s+prune\b(?=[^\n]*(--volumes\b\|--all\b\|\s-\w*a))` (also `-af`, `-fa`, `docker --context prod system prune -af --volumes`) | critical | `docker system prune --all` deletes every unused image; `--volumes` also deletes unused volumes and their data. Corrected in F2-4: since Docker 23 (API 1.42) volume pruning takes only anonymous volumes, so "all unused data" overstated it |
| 16 | `D\s+volume\s+prune\b` (also `docker -H ssh://h volume prune -f`) | critical | Removes unused volumes and their data (named ones too with `--all` or before Docker 23). Corrected in F2-4: Docker 23 prunes only anonymous volumes by default (23.0.0 release notes; `docker volume prune` reference) |
| 17 | `D\s+volume\s+(?:rm\|remove)\b` | warning | Deletes a named volume and its data. `docker volume remove` is the alias of `rm`; only global options, not arbitrary words, may precede `volume`, so `docker run alpine volume rm x` is not matched |
| 18 | `(?:D\s+compose\|\bdocker-compose)\b[^\n]*\sdown\b(?=[^\n]*(--volumes\b\|\s-\w*v))` (also `compose -f f.yaml down -v`, `docker --context prod compose down -v`) | critical | `compose down -v` drops the stack's volumes |
| 19 | `\bsystemctlO\s+(?:stop\|disable\|mask)\s[^\n]*\bsshd?(?![\w-])\|\bservice\s+sshd?\s+stop\b` | warning | Stopping or masking sshd cuts future SSH access to the host. Options may precede the verb (`systemctl --now disable ssh`, `-q stop sshd`, `-H prod stop sshd`); `service ssh stop` is the SysV form; the unit is `ssh` or `sshd` with an optional suffix (`ssh.socket`, `sshd@1.service`), so `sshfs`, `ssh-agent` and `sshd-keygen` are not matched |
| 20 | `\bcrontab\b[^\n]*\s-\w*r` | warning | `crontab -r` deletes the user's whole cron table |
| 21 | `\bufw\b(?:\s+--?\w[\w-]*)*\s+(?:reset\|disable)\b` (also `ufw --force reset`) | warning | Removes or switches off the firewall |
| 22 | `\bnft\s+flush\s+(?:ruleset\|table\|chain)\b` | warning | Drops nftables rules (a whole ruleset, table or chain); this can leave the host unfiltered or lock you out. A flushed table or chain keeps its base chains' policies, so a drop policy then blocks everything, the `iptables -F` case (`iptables -F INPUT` is the chain form); a flushed ruleset has no tables left and filters nothing |
| 23 | `\buserdel\b(?![^\n]*(\s-\w*r\|--remove\b))`, or `\bdeluser` with exactly one operand, no leading `--group` and neither `--remove-home` nor `--remove-all-files` | warning | Removes a user account. `deluser NAME GROUP` only takes NAME out of GROUP and `deluser --group NAME` removes a group, so a second operand or a leading `--group` rules it out; a `#` comment counts as neither, and neither does text after a shell operator or a newline, which quotes and `$(...)` keep in the segment (`ssh host 'deluser bob; rm -f x'`). An option that takes a value (`--conf FILE`) is read as an operand, a rare form left unflagged |
| 24 | `\buserdel\b(?=[^\n]*(\s-\w*r\|--remove\b))\|\bdeluser\b(?=[^\n]*\s--remove-(?:home\|all-files)\b)` (`-r`, `-rf`, `-fr`) | critical | `userdel -r` and `deluser --remove-home` also delete the home directory; `deluser --remove-all-files` deletes every file the user owns. The deluser flags destroy the same unbounded user data as `userdel -r`, so they share its severity |
| 25 | `K[^\n]*N\s1\b` | warning | Signals PID 1, the init process or a container's main process; this can reboot the host or stop the container. Corrected in F2-4: the plan's `\bkill\b[^\n]*\s1\b` also fired on `tmux kill-session -t 1` and on a 1 that is the operand of `-s`, `-n` or `-l`; systemd re-executes on `TERM` and reboots on `INT` (systemd(1)), and PID 1 receives only signals it handles, so `-9 1` is dropped inside its namespace (pid_namespaces(7)); `kill -9 1` stays the plan's case. Revised after F2-4: `--signal 1 42`, `--list 1` and `kill -0 1` (signal 0 only probes) are not PID 1, while `kill -s KILL 1` still is |
| 26 | `K\s+\S+[^\n]*N\s-1\b` | warning | Signals every process you are allowed to signal; as root that ends every service and session on the host. PID -1 is every process the caller may signal except init (kill(2)); only a `-1` after the first argument is a PID, since a leading `-1` is SIGHUP; `\b` rejects a process group such as `-12345` but accepts a closing quote or parenthesis (`sh -c 'kill -9 -1'`). Warning like rule 25 and the power rule: processes stop, stored data stays |

Overlap with the 14 existing rules, checked rule by rule: `docker`,
`crontab`, `ufw`, `nft`, `userdel`, `kill` have no coverage today (plan's
claim at `03-ARCHITECTURE.md:700-704` verified at
`danger_linter.dart:26-100`). `systemctl` was reachable only through the
power-off rule (`shutdown|reboot|halt|poweroff` `:92`), which still
catches `systemctl reboot`: no double-coverage since the new rule is
verb-scoped. `iptables -F` `:97` stays the iptables rule; the new rules
cover ufw/nft. None of the new patterns intersect the `rm`, `dd`,
`mkfs`, `wipefs`, redirection, fork-bomb, `curl|sh`, `chmod`, `shred`,
`find -delete`, `truncate` or `git clean` rules: `\b`-anchored command
names keep them disjoint, while `rm -rf /var/lib/docker` still flags the
existing critical rule independently.

Benign nonmatches the tests pin: `docker compose up`, `docker volume ls`,
`docker run -v /a:/b`, `docker system df`, `systemctl status sshd`,
`crontab -l`/`crontab -e`, `ufw status`, `nft list ruleset`, `usermod`,
`useradd`, `kill 1000`, `docker compose down` (no `-v`). The revised rows
add `systemctl stop sshfs`, `systemctl --user stop ssh-agent`,
`service ssh restart`, `kill --signal 1 42`, `kill --list 1`,
`kill -0 1`, `kill -1 1234`, `deluser deploy docker` and
`docker run alpine volume rm pgdata`.

**Command segments.** Every rule, the original 14 and the ones above, is
matched against one command at a time rather than the whole line, so a
flag or path from the next command cannot complete a pattern. Before
matching, `scan` removes backslash-newline continuations and splits the
text at unquoted `;`, `&&`, `||`, `&`, `|`, `|&` and newlines. Single
quotes, `$'...'`, double quotes, backslash escapes, `${...}`, `$(...)`,
`<(...)`, `>(...)` and backticks keep a command together, and as in bash,
quotes nest inside `${...}` even within double quotes
(`rm -rf "${D:-"a;b"}" /etc` is one command); `>&`, `<&`, `&>` and `>|`
are redirections; a `#` that starts a word runs to the end of the line
without opening quotes. Each line of a here-document body (after `<<WORD`
or `<<-WORD`, up to the WORD line) is one command with continuations
joined, since the body may be fed to a shell, but its quotes are not
tracked, so an apostrophe in prose (`Don't panic` in a motd) cannot join
the commands after the body or move their findings onto its line. Two
rules need a wider view: `curl|sh` is matched
per pipeline (commands joined by `|` or `|&` stay together) and the fork
bomb, which is built from separators, on the whole text. A finding
carries the line on which its command starts, one finding per rule and
line, so the Command inbox scans a script whole instead of line by line
and a continued command is checked as one.

The splitter is a scanner, not a shell parser, and errs toward keeping
text together: extra text can only add a false positive, while a wrong
split can hide part of a match. Known gaps: a `case` pattern's `)` inside
`$(...)` ends the substitution early; a here-document is recognised only
outside quotes and substitutions, and `<<` in an arithmetic `((...))` is
taken for one; aliases, functions and `eval` are not expanded. Tests pin
that `systemctl stop nginx; ssh deploy@host`, `rm -rf ./build; ls /` and
`git clean -n && rm -f out.o` raise nothing, that `userdel \` + newline +
`-r deploy` is critical, and that `rm -rf \` + newline + `/etc` is caught.

### 3.7 Barrel exports (F2e)

`seance_core.dart` gains, in the ssh group after `:28`:
`src/ssh/ssh_link.dart`, `src/ssh/remote_process.dart`,
`src/ssh/byte_duplex.dart`, `src/ssh/channel_budget.dart`,
`src/ssh/elevation.dart`, `src/ssh/credential_resolver.dart`,
`src/ssh/sequential_cleanup.dart`; and in the sync group:
`src/sync/push_batcher.dart`. Poltergeist's `ssh_cleanup.dart:3` then
imports the barrel and drops its `implementation_imports` suppression;
the `remote_file_system.dart` (`ssh_transport.dart:10`) and
`ssh_algorithms.dart` (`:14`) imports stay as listed exceptions. Export
compatibility is additive only: no existing export changes shape.

## 4. Behaviour specifications

### 4.1 Listen-before-write and backpressure (F2a)

`ByteDuplex` subscribes to the forwarding channel's stream inside its
constructor, before any caller attaches a listener, into a bounded 4 MiB
buffer (5.4's size). The 4.1.0 stall fix (channel grants window credit on
first subscribe) makes the subscription ordering belt-and-braces; the
buffer and pause propagation remain the real mechanism. Backpressure is
end to end: when the duplex's consumer pauses or the buffer hits the
high-water mark, the SSH subscription pauses, so the peer's window
drains instead of memory growing; resume propagates symmetrically.
`sink.close()` sends channel EOF without closing the read side;
`close()` cancels the subscription, closes the channel and returns after
`runSequentialCleanup` bounds it at 5 s (`_cleanupActionTimeout`,
`ssh_session.dart:20`). `RemoteProcess` applies the same rules to exec
channels, with stderr drained unconditionally (5.10: unread stderr
buffers without limit) and stdout subject to the consumer's pause.

### 4.2 Idle ping with timeout

`SshLink` runs its own liveness clock at `idlePingInterval` (15 s). A
tick is skipped while a ping is outstanding or bytes arrived on the
connection within the interval: received data is proof of life
(Poltergeist's `_pingIdleTransport` skips while operations are in flight,
`connection_manager.dart:1927-1935`, which suits its short SFTP
operations). An open channel alone is not proof of life: a quiet log
follower or a long command never suppresses pings, so a silently dropped
path is detected while they run.
`client.ping()` never times itself out (5.10's unchanged defect); the
link wraps it in `pingTimeout` (30 s, matching `pingOperationTimeout`
`ssh_transport.dart:42`). Expiry marks the link lost: state moves to
`closed` (or `degraded`→`backoff` under a reconnecting owner) and
`close()` runs: Poltergeist deliberately closes rather than erroring
the ping so the `done` watcher drives one death path `:1943-1955`; the
link does the same by completing `done` through its own close. Séance's
dartssh2 keepalive (`_defaultSshKeepAliveInterval` 10 s,
`ssh_session.dart:22`) only *sends* keepalives: nothing bounds the
response wait, which is precisely the gap this fills.

### 4.3 Channel budget and refusal

`ChannelBudget` is a counting semaphore over session channels, cap 8
(mirroring `PoolPolicy.maxChannelsPerTransport`,
`pool_policy.dart:32,:56`). Acquisition is by `ChannelWaitPriority`
(sampler, userAction, follow, sftp: 5.2's order) and every waiter
carries a reason string for the "waiting for a free channel" display.
The allocation table of 5.2 stands: fast sampler 1, slow sampler 1,
followers ≤2, short actions ≤2 queued, SFTP 1 lazily with 60 s idle
release (the `LeasedRemoteFileSystem` shape,
`leased_file_system.dart:26-37`, retuned to 5.2's 60 s), compose or
elevated exec 1. Forwarding channels never consume the budget; their own
bound is 16 duplexes per link (5.2). A refused session open below the
cap learns `SshLinkSeen.learnedSessionLimit` and degrades rather than
failing; the `needsUser`/`degraded` state carries the reason.

### 4.4 Bounded close and late-open cleanup

Every open that can be abandoned keeps its pending future and closes
whatever arrives late: the `_DartSshTransport.openChannel` pattern
(`ssh_transport.dart:392-401`) generalized to exec channels, forwarding
opens and SFTP opens inside the link. `close()` is
`SingleFlightCleanup`-guarded and runs `runSequentialCleanup` over:
cancel subscriptions → close open channels/duplexes → close SFTP →
`client.close`, 5 s per action (`_cleanupActionTimeout`, both already the
`SshSession._finishOnce` order `ssh_session.dart:678-687`). A close that
outlives the bound still returns; the late work is owned and destroyed,
never leaked.

### 4.5 `runCommand` / RemoteGit re-base

The exec core reproduces `runCommand`'s contract byte for byte
(`ssh_session.dart:524-622`): fresh non-PTY `client.execute` channel;
independent stdout/stderr capture capped at `maxOutputBytes` with
continued draining after truncation; one stopwatch-bounded deadline
across stream completion *and* `channel.done`; abort on timeout or error;
non-zero exit codes returned as `RemoteCommandResult`, never thrown;
transport/channel/timeout failures as `RemoteCommandException` with the
collapsed open error text (`:540`). The differences land inside the core
only: stdin writing (`run`'s `stdin` parameter: `runCommand` passes
none), budget acquisition before the channel opens, and late-open
cleanup. `SshSession.runCommand` delegates with identical defaults, so
the Séance suite (`remote_git_test.dart`, diagnostics suites,
`test_connection_test.dart`) is the regression proof; `RemoteGit` gains
the shared core transitively, and on an `SshLink` gets it via
`RemoteGit(link.run)` with no signature change.

### 4.6 Elevation prelude (F2b)

The prelude is 8.3's verbatim, preserved exactly:

```sh
IFS= read -r p
printf '%s\n' "$p" | sudo -S -p '' -v || exit 125
p=
sudo -n -- "$@"
exit $?
```

Semantics held by construction: `read` consumes exactly the password
line so remaining stdin reaches the command (`crontab -`,
`dial-stdio`'s HTTP bytes, a privileged `tee`); both sudo invocations are
children of the same shell: no `exec` and no cross-channel validation,
because the timestamp record is per-parent-PID without a tty (8.3's
notes and 04's A.2 local verification); the trailing `exit $?` defeats
bash's implicit exec of the last `-c` command. `printf` must be a shell
builtin: the probe field `command -V printf` gates the rung so the
password never enters a process list. No here-documents (older bash
spills them to temp files). stderr is kept and classified against the
8.3 texts: wrong password (`Sorry, try again.`/`incorrect password
attempt`), `is not in the sudoers file`, `a password is required`,
`you must have a tty`, plus the sudo-rs equivalents the probe's
`sudo -V` line selects. The fallback ladder is 8.3's seven rungs in
order (rung 2 includes `doas -n -- <cmd>` when the probe's `doas -n true`
succeeded and sudo is absent); rung 4 retries once with `sudo -S -p '' -- <cmd>` when validation
passed but the command still reports a required password
(`timestamp_timeout=0`).

### 4.7 Credential resolution

`CredentialResolver.resolve` reproduces `app_services.dart:1075-1153`
exactly: `agent` short-circuits before any read; drafts apply only under
their own auth method; an identity bookmark without `identityFilePath`
under key auth throws `ArgumentError` (the contract documented
`:1087-1099`); vault reads happen only for a named `secretRef` and a
named-but-absent entry honours `missingSecretPolicy`. `identityFile` is
the seam: Séance's implementation keeps `appLock.read`, bookmark
resolution/refresh and `IdentityAuditLog` writes; Poltergeist's keeps
`IdentityFileReader.read`: audit behaviour is preserved by the apps'
own implementations, not moved. `jumpHostResolver` yields the
`SshJumpHostResolver` (`ResolvedSshHost` pair) both apps assemble
identically today (`app_services.dart:1178-1183`,
`server_editor_backend.dart:193-201`). Prompting, dismissal propagation
and `CredentialOrigin` tagging stay in Poltergeist's
`_PromptBroker`/`PromptCoordinator`; the coordinator's vault-first
branch calls the shared resolver over `CredentialPromptData`'s fields
(authMethod, secretRef, identityFilePath), preserving
auto-answer-on-agent and cancel-to-`RemoteFileException` behaviour.

## 5. Migration plan (staged PRs)

D3 order, each PR green on both shipped apps; behaviour changes
isolated. The Séance pin-audit job runs on every PR touching `seance/**`,
Poltergeist's pubspecs and lockfiles, `poltergeist/docs/PORTS.md`, the
audit script and tool, or `ci.yml` (its path filter, `ci.yml:300-314`);
the record refreshes only if provenance changes (a new contributor,
attribution or license line in `seance/`: none is planned), in which
case that PR runs `scripts/audit-seance-pin.sh --write-record` and
commits the regenerated `PORTS.md` block with the diff.

| PR | Contents | Shipped-app switch | Pin-audit implication |
|---|---|---|---|
| F2-1 transport/exec core | `byte_duplex.dart`, `channel_budget.dart`, `remote_process.dart` (with `_ExecCore`), `ssh_link.dart`; `SshSession.runCommand` rebased onto the core; barrel exports the new modules | Séance: `session.runCommand` (`app_state.dart:1550`) unchanged in signature, now shared: suite proves parity. Poltergeist untouched | `seance/**` touched → audit runs; new files by the same contributor leave the record unchanged |
| F2-2 elevation | `elevation.dart`, probe model, executor, classifier; pure tests + the Linux sudo CI test | none: new capability (plan row F2b is `new`; Séance's snippet adoption is a later product PR, plan 7.21) | same as F2-1 |
| F2-3a resolver move | `credential_resolver.dart` + `CredentialMissingException` moved up (deleted from `app_services.dart:77`); Séance switches `resolveCredentials`/`resolveJumpHost` to delegate | Séance: identical semantics, `resolve_credentials_test.dart` green | same |
| F2-3b resolver adopt | Poltergeist's `server_editor_backend._resolveCredentials` and `PromptCoordinator`'s vault-first branch delegate to the shared resolver (`missingSecretPolicy: substituteEmpty` first, or `fail` if the divergence is resolved in this PR: decision in §3.5) | Poltergeist: editor test path + pool prompt path | same; `poltergeist/**` also in the path filter |
| F2-4 danger rules | the 11 rules of §3.6 + tests in `pure_logic_test.dart` | Séance benefits automatically: `DangerLinter` is already consumed via the barrel (`chat_sidebar.dart:307`, `inbox_view.dart:283`, `command_generator.dart:120`) | same |
| F2-5 exports + cleanup | `push_batcher.dart` + `sequential_cleanup.dart` barrel exports; `ssh_cleanup.dart:3` drops the implementation import; `PORTS.md` "Connection cleanup dependency" entry (`:338-349`) updated to record the new mechanism | Poltergeist switches the import in the same PR | `PORTS.md` is in the path filter; the audit verifies the record block, which a prose edit does not touch |

Follow-up PR (per 04 §13's exit note): Séance terminal sessions adopt the
dead-peer detection from `SshLink`'s ping, with its own changelog line.

## 6. Test plan

In-process wire fixtures on the `ssh_peer.dart`/`ssh_proxy_jump_test.dart`
pattern: a `SshPeerSocket` that speaks real key exchange and userauth,
extended with refusal, stall and silence knobs:

- **Budget**: ninth session open queues (priority order observed);
  session-refusal `SSH2_OPEN_CONNECT_FAILED`/"open failed" below the cap
  sets `learnedSessionLimit` and degrades; a streamlocal refusal
  classifies `forwardDisabled`; other refusals classify `other`.
- **Liveness**: the peer answers pings until told to go silent; a ping
  unanswered 30 s moves the link to lost and closes it; pings are skipped
  only while bytes arrive; a quiet follower channel open for minutes does
  not suppress them (the dropped-path case).
- **Close**: a peer that never answers close still sees `close()` return
  within the 5 s bound (mirroring `sequential_cleanup_test.dart`); a
  channel open completing after its timeout is closed on arrival, not
  leaked (the `pending.then` pattern of `ssh_transport.dart:392-401`,
  asserted against the fixture's open accounting).
- **ByteDuplex**: the peer fills the initial window before the consumer
  listens: all bytes still delivered; consumer pause pauses the
  channel's data flow (fixture observes window exhaustion);
  `sink.close()` sends EOF while the read side still delivers.
- **runCommand parity**: the existing suites
  (`remote_git_test.dart`, `test_connection_test.dart`, the diagnostics
  tests) run unchanged; new cases cover stdin piping and per-stream
  truncation.
- **Elevation**: prelude construction unit tests (exact byte shape, argv
  quoting through `quoteShellWord`, password-line framing); classifier
  tests over the recorded stderr texts; a Linux CI test against real
  sudo: the prelude validates, wrong password exits 125 with the
  recorded stderr, `timestamp_timeout=0` exercises rung 4, stdin past the
  password line reaches the command (the `crontab -` case).
- **CredentialResolver**: the decision-table cases of
  `resolve_credentials_test.dart` ported to pure `seance_core` tests
  (agent short-circuit, draft precedence, orphan bookmark, missing
  secret under both policies); the app suites stay green unchanged.
- **Linter**: `pure_logic_test.dart` gains one table per new rule :
  firing string, severity, and the §3.6 benign list.
- **Exports**: `batchForPush` keeps `push_batcher_test.dart` green from
  the barrel import; Poltergeist's `ssh_cleanup_test.dart` is the proof
  the barrel export satisfies it.

## 7. Risks

- **Unverified 4.1.0 API names.** `forwardLocalUnix`, `SSHSession.kill`/
  `SSHSignal` and the lazy-`stream` shape are cited by name; spike S1 (M0)
  verifies them against the resolved 4.1.0 before F2-1 lands. Mitigation:
  the forwarding/exec seams are already injectable, so a renamed API is a
  one-file fix inside the confinement zone.
- **runCommand parity.** A subtle timing difference (channel completion
  vs stream completion order) could change truncation edge cases.
  Mitigation: the rebase PR keeps the old implementation's test suite
  untouched; add a golden comparison test driving both paths over the
  fixture before removal.
- **Credential divergence.** Poltergeist's named-missing secret resolves
  empty today; the fail-loud shared default changes that. Mitigation:
  `missingSecretPolicy` keeps the switch explicit and reversible.
- **Elevation fragility.** The prelude depends on shell and sudo details
  outside dartssh2. Mitigation: the probe gates each rung and the
  Linux-sudo CI test is the contract.
- **Scope creep into the pool.** Poltergeist's pooling is M0-frozen;
  `SshLink` must not grow a second pool. Mitigation: reconnect, leases
  and incidents are documented as caller policy in §3.2.

## 8. Estimates

Per plan 3.5 sizes and the 04 §13 milestone: F2a M, F2b S, F2c S, F2d S,
F2e S: the milestone prices the whole row set at L (5 to 7 engineer-weeks)
with F2a's wire-fixture work the critical path. The F2-3 split adds no
new work; it sequences the same small resolver.

## 9. Corrections to the plan

Verified against the worktree at `20acafc7`:

1. **`ssh_session.dart` anchors are ~36 lines stale.** Plan 3.5/D4/5.1
   cite `runCommand` at `:488-586` (cap `:491`, collapsed error `:504`),
   `openAuthenticatedClient` at `:694` with the keepalive note at
   `:692-693`, and `SshSession` at `:373`. At HEAD: `runCommand`
   `:524-622` (cap `:527`, collapsed open error `:540`),
   `openAuthenticatedClient` `:730-859` (keepalive doc `:728-729`),
   `SshSession` `:409-692`. The shift postdates the plan's `bf1da58`
   verification (the dartssh2 re-pin landed after it); 04's own A.1 still
   prints the old numbers.
2. **04 A.1's dartssh2 import count is stale relative to 03's own §3.4.**
   A.1 says "three `seance_core` library files, eight `seance_core` test
   files". At HEAD: four library files (`ssh_session.dart:7`,
   `remote_file_system.dart:5`, `ssh_agent.dart:8`,
   `ssh_algorithms.dart:1`) and nine `*_test.dart` files plus
   `test/support/ssh_peer.dart`: §3.4's corrected wording ("four
   library files, ten test files" counting the fixture) is accurate;
   A.1 was written before PR #113 and not refreshed.
3. **F2c's Poltergeist anchor points at the secondary path.** The row
   marks `server_editor_backend.dart:210-262` `[R]`; the real connect-time
   resolution is `_PromptBroker.resolveCredentials`
   (`engine_host.dart:1366-1407`) answered by
   `PromptCoordinator._showCredential` (`prompt_coordinator.dart:273-345`).
   `server_editor_backend._resolveCredentials` (`:210-263`) covers only
   the editor's connection test. The shared resolver must serve all three
   surfaces; §3.5 does.
4. **"Séance lacks dead-peer detection" needs the precise reading.** 3.6
   says Séance has "no ping timeout anywhere in its path". True, but
   Séance *does* schedule dartssh2 keepalives
   (`_defaultSshKeepAliveInterval` = 10 s, `ssh_session.dart:22,:741`) :
   what is missing is a response deadline: the keepalive never fails the
   connection. F2a adds the timeout; it does not add keepalives.
5. **The `SshLink.run` sketch's `Duration timeout` breaks the RemoteGit
   seam.** Non-nullable named parameters are not assignable to
   `RemoteCommandRunner` (`remote_command.dart:48-49`), whose callers may
   pass `timeout:` explicitly null. §3.1 uses `Duration?`.
6. **F2e's cited files exist but with nuance.** `batchForPush` is at
   `src/sync/push_batcher.dart:24` (the row's `SC/src/sync/` prefix is
   right); `sequential_cleanup.dart` exists and is already consumed by
   `ssh_cleanup.dart:3` as an implementation import: the "stays"
   exceptions are `ssh_transport.dart:10` (`remote_file_system`) and
   `:14` (`ssh_algorithms`), plus the test/bench imports §3.4 lists. The
   barrel today exports neither file (`seance_core.dart:19-56`).
7. **Bounded close is not absent, it is per-shape.** `SshSession.close`
   and `_OwnedJumpSocket.close` already bound teardown via
   `runSequentialCleanup` (`ssh_session.dart:678-687,:1097-1104`), and
   Poltergeist wraps it in `closeSshResource` (`ssh_cleanup.dart:12-20`).
   F2a generalizes the existing primitive to channels and duplexes; the
   doc does not claim a new mechanism.
8. **`forwardLocalUnix` is genuinely unused.** 04 A.1's "no
   `forwardLocalUnix` call anywhere in the repository" is confirmed at
   `20acafc7`: `openUnixStream` is new surface, cited by name (§1.5).

## 10. Decisions resolved

- **Ping visibility**: the liveness loop is internal; intervals are
  constructor-injected test seams, never public tuning knobs (the
  `keepAliveInterval` precedent at `ssh_session.dart:741`).
- **Reconnect**: kept out of `SshLink`; the supervisor implements
  backoff with Poltergeist's constants, because resume policy lives above
  the transport (§3.2).
- **State stream**: broadcast `states` plus a `state` getter; sealed
  plain-data states so the engine isolate can carry them.
- **`run` signature**: `Duration? timeout` for typedef assignability
  (correction 5).
- **SFTP inside the budget**: `openFileSystem` acquires one budget slot
  lazily and releases it after `sftpIdleRelease` (60 s, a constructor
  seam like the ping intervals); the next file operation re-acquires a
  slot through the budget's normal queue (5.2's table; lease shape from
  `leased_file_system.dart`).
- **Elevation API shape**: `run(List<String> argv)` quoting each element:
  `"$@"` needs real argv, not a shell string; shell constructs are
  `['sh','-c',script]` at the call site.
- **`CredentialMissingException`**: moves to `credential_resolver.dart`
  and is barrel-exported; Séance call sites keep compiling unchanged.
- **Missing-secret divergence**: `enum MissingSecretPolicy { fail,
  substituteEmpty }`, default `fail` (Séance's semantics: fail loud over
  silently authenticating with `''`); Poltergeist passes
  `substituteEmpty` in F2-3b, and its switch to `fail` is a deliberate,
  separate behaviour PR.
- **New linter severities**: graded against the existing 14-rule
  calibration: critical only for mass/unbounded destruction (§3.6).
