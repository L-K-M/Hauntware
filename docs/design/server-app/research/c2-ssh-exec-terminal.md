# C2: SSH, remote-execution and terminal foundations for the fourth app

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Read-only investigation of the Hauntware repository at `bf1da58` (2026-10-10).
Scope: what a server-management/observability + Docker app can build on in
the existing SSH stack, what is missing, where the missing parts should live
under the repo's dependency rules, and what will bite.

All repo paths are relative to the repository root. dartssh2 citations
refer to the 3.0.2 source downloaded from pub.dev
(`pub.dev/api/archives/dartssh2-3.0.2.tar.gz`, SHA-256
`fdc8e5e47c88473525e90ba11fbc2234a47d3788de010061d0b49de7e12a3c24`, which
matches `seance/pubspec.lock:116-123` and `poltergeist/pubspec.lock:124-131`),
cited as `dartssh2:lib/...:line`.

Verification status: code was read and cross-checked; no Dart SDK was
installed in the research environment (`which dart` empty, no
`~/.pub-cache`), so **no tests or analyzers were run**. OpenSSH behaviour claims cite the sshd_config(5) man page
or are explicitly marked "unverified".

---

## 0. Summary

- **Connection establishment is solid and reusable as is.**
  `openAuthenticatedClient` (`seance/packages/seance_core/lib/src/ssh/ssh_session.dart:694`)
  gives an authenticated `SSHClient` with TOFU, ProxyJump (16 hops, cycle
  detection), ssh-agent (Unix + Windows), keyboard-interactive/2FA, a redacted
  connection transcript and actionable failure summaries. A fourth app should
  call this, never fork it.
- **Exec exists only welded to a terminal session.** `SshSession.runCommand`
  (`ssh_session.dart:488-586`) is a good bounded one-shot exec, but it is an
  instance method on the interactive shell session (`SshSession` requires a
  PTY shell and a `TerminalEngine`, `ssh_session.dart:1187-1227`). Poltergeist's
  pooled `SshTransport` only opens SFTP channels
  (`poltergeist/packages/poltergeist_core/lib/src/connection/ssh_transport.dart:30-67`).
  No headless exec, no streaming exec, no stdin/env/PTY options, no signal API.
- **dartssh2 3.0.2 already has what Docker needs at the wire level:**
  `forwardLocalUnix` (`direct-streamlocal@openssh.com`,
  `dartssh2:lib/src/ssh_client.dart:435-445`), `execute(pty:, environment:)`
  (`:447-513`), `SSHSession.kill(signal)` (`dartssh2:lib/src/ssh_session.dart:137`),
  `stdin`, `waitForExit`. None of these is used today except `execute` (no
  options) and `forwardLocal` for ProxyJump (`ssh_session.dart:746-748`).
- **The Docker Engine API over streamlocal is the right primary transport**:
  forwarding channels do not count against OpenSSH `MaxSessions` (default 10;
  "setting it to 0 will prevent all shell, login and subsystem sessions while
  still permitting forwarding", sshd_config(5)). dartssh2's bundled
  `SSHHttpClient` is not usable for it (TCP-only, buffered, no keep-alive, no
  upgrade; `dartssh2:lib/src/http/http_client.dart:14-22,141`), so an HTTP/1.1
  client over a byte duplex must be written.
- **dartssh2 3.0.2 has defects that matter more for a long-lived, streaming,
  many-channel app than for Séance/Poltergeist:** keepalive pings never time
  out (`dartssh2:lib/src/ssh_keepalive.dart:19-31`), a channel can stall forever
  if data arrives before the first listener (`dartssh2:lib/src/ssh_channel.dart:59-61,352-357`,
  fixed upstream in 4.0.1), no chacha20-poly1305 or ML-KEM (documented in
  `poltergeist/docs/M0-DARTSSH2-REPORT.md:106-114`). Upstream is at 4.1.0
  (2026-09-04); the suite pins exactly 3.0.2 everywhere.
- **The terminal stack is reusable for container shells** through the existing
  `TerminalEngine` + `SessionTransport` seams, but the concrete
  `XtermTerminalEngine` lives inside the Séance app
  (`seance/app/seance_app/lib/services/xterm_engine.dart:62`) and must be moved
  into a shared Flutter package before a fourth app can use it (the root rule is
  that shared implementations are never copied, `AGENTS.md:5-6`).
- **The dartssh2 import guard is Poltergeist-only** (`poltergeist/tool/import_guard/lib/import_guard.dart:10-20`),
  hard-coded to Poltergeist paths. A fourth product needs it generalized, not
  copied.
- **The Poltergeist sshd fixture can host a Docker daemon** with a privileged
  `docker:dind` sidecar sharing its Unix socket into the sshd container; the
  fixture's safety checker only forbids host networking and non-loopback
  publishing (`poltergeist/test/integration/check_config.dart:8-50`).

---

## 1. Ground rules that constrain the design (from the docs)

| Rule | Source |
|---|---|
| Shared library implementations are never copied; product specifics stay in subtree `AGENTS.md`. | `AGENTS.md:5-6` |
| Poltergeist consumes the shared SSH/protocol implementation through its core barrel. UI uses host services; shared packages remain host-neutral. | `AGENTS.md:41-44` |
| Preserve application IDs, keychain names, wire formats and user data. | `AGENTS.md:43-44` |
| UI and controllers use application services, never sockets/subprocesses directly; encapsulate low-level mechanics behind domain interfaces. | `AGENTS.md` "Code design" |
| `seance_core` is pure Dart; `TerminalEngine`, `SessionTransport`, `LocalPty` are the extension seams ("extend here, don't fork"). | `seance/AGENTS.md:564-598` |
| Assistant invariants: review-before-run on generated commands, **no execution/file tools in chat**, default-on redaction, scrollback treated as untrusted. | `seance/AGENTS.md:133-135, 670-673` |
| dartssh2 types stop inside `poltergeist_core/lib/src/connection/`; barrel re-exports of Séance types are audited for dartssh2-freeness. | `poltergeist/packages/poltergeist_core/lib/poltergeist_core.dart:1-14` |
| `seance_core` pins dartssh2 exactly ("Pin the pipelined-read cancellation behavior covered by tests"). | `seance/packages/seance_core/pubspec.yaml:17-18` |
| Analyze/test pure-Dart packages with explicit paths; do not resolve dependencies concurrently. | `AGENTS.md` "Layout and toolchains"/"Commands" |

---

## 2. Reusable APIs (signatures and locations)

### 2.1 Connection establishment (`seance_core`, exported from the barrel at `seance/packages/seance_core/lib/seance_core.dart:24`)

| API | Signature (abridged) | Location | Notes for the fourth app |
|---|---|---|---|
| `SshCredentials` | `.password(String?)`, `.privateKey(String? pem, {String? keyPassphrase})`, `.agent()` | `ssh_session.dart:32-52` | Resolved just before connect; never persisted. |
| `ResolvedSshHost`, `SshJumpHostResolver` | `typedef Future<ResolvedSshHost?> Function(String id)` | `ssh_session.dart:55-63` | Jump hosts are other `ServerConfig`s (`ServerConfig.jumpHostId`, `seance/packages/seance_protocol/lib/src/models/server_config.dart:70-71`), so the shared server list carries routing for free. |
| `SshForwardConnector` | `Future<SSHSocket> Function(SSHClient, String host, int port, Duration)` | `ssh_session.dart:66-71` | Test seam; default is `client.forwardLocal(...).timeout(...)` (`:746-748`). |
| `SshAgentIdentityLoader`, `SshAgentClient` | `Future<List<SSHIdentity>> identities()` | `ssh_session.dart:74`, `ssh_agent.dart:54-68` | `SSH_AUTH_SOCK` on Unix, `\\.\pipe\openssh-ssh-agent` on Windows via a worker isolate (`ssh_agent.dart:12-13, 234-320`); one native connection per request; 5 min request timeout (`:18`). |
| `AuthKind` | `key, agent, storedPassword, keyboardInteractive, promptedPassword` | `ssh_session.dart:77-83` | Poltergeist uses it to cap interactive pools at one transport. |
| `HostKeyPrompter` | `Future<bool> Function(HostKeyDecision)` | `ssh_session.dart:88` | |
| `KeyboardInteractiveChallenge` / `KeyboardInteractiveResponder` | carries the trusted `server` separately from peer-supplied prompts | `ssh_session.dart:94-111` | UI must show `server` so a jump host cannot impersonate its target. |
| `SshConnectionLog` | `add(String)`, `freeze()`, `lines`, 400-line bound | `ssh_session.dart:142-196` | Must be frozen after connect or dartssh2's per-packet trace keeps firing (`seance/app/seance_app/lib/app_state.dart:1556-1559`). |
| `redactConnectionTrace` | `String redactConnectionTrace(String line)` | `ssh_session.dart:293-332` | Scrubs keyboard-interactive responses that dartssh2 3.0.2 prints in plaintext; fail-closed on drift. |
| `SshConnectException` | `message`, `cause`, `log`, `isHostKeyRefusal` | `ssh_session.dart:338-370` | |
| **`openAuthenticatedClient`** | `Future<(SSHClient, AuthKind)> openAuthenticatedClient({required ServerConfig config, required SshCredentials credentials, required TofuVerifier tofu, required HostKeyPrompter onHostKey, KeyboardInteractiveResponder? onKeyboardInteractive, connect, SshJumpHostResolver? resolveJumpHost, SshForwardConnector? forward, SshAgentIdentityLoader? loadAgentIdentities, Duration timeout = 15s, Duration? keepAliveInterval = 10s, SshConnectionLog? log})` | `ssh_session.dart:694-823` | **The entry point for the fourth app.** Caller owns the client; on error the client is closed before throwing (`:686-690, 1021-1031`). Pass `keepAliveInterval: null` when a pool owns keepalive (`:692-693, 709-715`). |
| `SshSessionManager.connect` | `Future<SshSession> connect({config, credentials, engine, timeout, log})` | `ssh_session.dart:1095-1227` | Interactive PTY shell + login script. Usable for "open a host shell" in the fourth app. |

Behaviour worth knowing inside `openAuthenticatedClient`:

- **ProxyJump**: route resolved first (`_resolveSshRoute`, `ssh_session.dart:833-904`):
  cycle detection (`:845-852`), `_maxJumpHosts = 16` (`:22, 853-860`), a resolver
  that returns a different id is rejected (`:888-897`). Every hop's credentials
  are prepared before the first network side effect (`:731-741`). Hops connect
  outermost first (`preparedRoute.reversed`, `:752`), each hop's host key is
  verified against that hop's own `host:port` (`_authenticateSshHost`,
  `:984-995`), and `_OwnedJumpSocket` makes the forwarded socket own and close
  the parent chain (`:1038-1079`).
- **Agent identities** load once per connect and are shared across hops (`:725-729`).
- **Identity files** are not read here. `ServerConfig.identityFilePath`
  (`server_config.dart:66-68`) is resolved to PEM by each app:
  Séance `seance/app/seance_app/lib/services/app_services.dart:1075-1150`,
  Poltergeist `poltergeist/app/poltergeist_app/lib/services/server_editor_backend.dart:210-262`
  and its engine `poltergeist/packages/poltergeist_core/lib/src/engine/engine_host.dart:1421-1425`.
  The two app copies are near-identical (see gap G9).
- **Timeouts**: `timeout` bounds TCP connect and each forwarded-channel open;
  authentication waits a fixed 5 minutes (`_sshAuthenticationTimeout`,
  `ssh_session.dart:20, 1014-1019`) to leave room for TOFU and 2FA prompts.
- **Keepalive**: dartssh2's built-in timer at 10 s by default (`:21, 987`).
  See risk R3: it never declares a peer dead.

### 2.2 One-shot exec

| API | Signature | Location |
|---|---|---|
| `SshSession.runCommand` | `Future<RemoteCommandResult> runCommand(String command, {Duration? timeout /* 30s */, int maxOutputBytes = 256 * 1024})` | `ssh_session.dart:488-586` |
| `RemoteCommandResult` | `stdout`, `stderr`, `int? exitCode`, `truncated`, `succeeded` | `seance/packages/seance_core/lib/src/ssh/remote_command.dart:5-24` |
| `RemoteCommandException` | transport-level failure only | `remote_command.dart:30-41` |
| `RemoteCommandRunner` | `typedef Future<RemoteCommandResult> Function(String command, {Duration? timeout})` | `remote_command.dart:48-49` |

What `runCommand` gets right and the fourth app should keep:
fresh non-PTY exec channel beside the shell (`:474-477, 499`); both streams
drained and bounded, reading continues past the cap so the window never stalls
(`:479-482, 513-523`); one deadline across stream completion and channel close
(`:548-564`); abort cancels subscriptions and closes the channel (`:540-546`);
"remote command failed" is a result with a non-zero exit code, "no command ran"
is an exception (`:484-487`); lenient UTF-8 decode (`:569-570`).

What it lacks for a management app: no stdin, no env, no PTY, no streaming,
no `exitSignal` (`RemoteCommandResult.exitCode` is null on signal death,
`remote_command.dart:9-12`), no way to tell "MaxSessions exhausted" from any
other open failure (`ssh_session.dart:498-505` collapses everything into
`'Could not open a command channel: $e'`), and it is only reachable through an
interactive `SshSession`.

### 2.3 `RemoteGit`: the precedent for "CLI over exec channel + parser"

`seance/packages/seance_core/lib/src/ssh/remote_git.dart`:

- Constructor takes a `RemoteCommandRunner` only (`:158-165`), so command
  construction, parsing and classification are unit-testable without a
  transport (`seance/packages/seance_core/test/remote_git_test.dart`).
- One round trip per probe; regions separated with a `printf '\0'` sentinel so
  parsing survives arbitrary entry counts (`:236-258`). The same technique
  protects a collector from stray `.bashrc` output.
- `export LC_ALL=C` so diagnostics are locale-stable (`:252-254`).
- Arguments quoted with `quoteShellWord`, `~` deliberately left unquoted so the
  remote shell expands it (`:209-216, 260-270`).
- Version ladder with a latched rung for old remote tools (`:154-157, 174-190`).
- Failure classification: 127 / "command not found" = not installed, distinct
  from "not a repository", distinct from transport failure, which propagates
  (`:171-173, 279-302`).
- App wiring passes `session.runCommand` and uses a longer timeout for network
  actions (`seance/app/seance_app/lib/services/remote_git_controller.dart:15-25`,
  `app_state.dart:1549-1554`).

This is exactly the shape for `RemoteSystemd`, `RemoteJournal`, `RemoteCron`,
`RemoteProcStats`, `RemoteDockerCli` in the fourth app's core.

### 2.4 Connection test, probe, TOFU, quoting, cleanup

| API | Location | Reuse |
|---|---|---|
| `HostAuthenticator`, `liveHostAuthenticator({hostKeys, onHostKey, ...})`, `runConnectionTest(...)`, `ConnectionTestResult`, `authKindLabel` | `seance/packages/seance_core/lib/src/ssh/test_connection.dart:27, 53-116, 120-147, 168-298, 301` | Server editor "Test connection" as is. |
| `UnpinnedHostKeyStore` | `test_connection.dart:318-350` | Trial approvals never become permanent pins. |
| `ProbeStatus {online, offline, unknown}`, `Prober`, `TcpBannerProber`, `ProbeService` | `seance/packages/seance_core/lib/src/probe/probe_service.dart:14, 18-21, 27-57, 64-287` | Server-list status dots: jittered 45 s sweeps, 6 concurrent probes, pauses in background, skips connected servers (`:69-80, 95-103`). |
| `HostKeyVerdict`, `HostKeyDecision`, `HostKeyStore`, `TofuVerifier` | `seance/packages/seance_core/lib/src/hostkey/tofu.dart:7, 9-27, 30-34, 39-63` | Never auto-repins on change (`:36-38`). Pins keyed by `host:port` only (`seance/packages/seance_protocol/lib/src/models/host_key.dart:112`). |
| `quoteShellWord`, `buildChangeDirectoryCommand`, `RemoteShellKind` | `seance/packages/seance_core/lib/src/terminal/shell_command.dart:2-8, 18-47, 63-70` | Safe across sh/bash/zsh/fish; use to build every remote command. |
| `runSequentialCleanup`, `SingleFlightCleanup`, `CleanupFailureMode` | `seance/packages/seance_core/lib/src/ssh/sequential_cleanup.dart:7-47` | Not exported; Poltergeist reaches it with `// ignore: implementation_imports` (`poltergeist/.../connection/ssh_cleanup.dart:1-20`). |
| `RemoteFileSystem` (SFTP) | `seance/packages/seance_core/lib/src/ssh/remote_file_system.dart:88-153` | Whole-file `download`/`upload` with CAS; **no range/tail read**, runs as the login user. Fine for small config files, not for logs. |
| `isExecutableLaunchName` | `seance/packages/seance_core/lib/src/ssh/executable_launch.dart:126` | Only relevant if the app downloads and opens remote files locally. |

### 2.5 Poltergeist connection pool (`poltergeist_core/lib/src/connection`)

| API | Location | Notes |
|---|---|---|
| `SshTransport` (`authKind`, `isClosed`, `done`, `hasActiveOperations`, `openChannel()`, `ping()`, `close()`) | `ssh_transport.dart:30-67` | `openChannel` returns `SftpChannel` only (`:19-23, 59`). |
| `ConnectPrompting {enabled, disabled}`, `AuthChallengeRequiredError` | `ssh_transport.dart:75, 83-94` | Growth connects never prompt; auth failure on growth means "interactive server, stay at one transport". |
| `SshTransportOpener` typedef, `openDartSshTransport` | `ssh_transport.dart:100-110, 248-289` | Wraps `openAuthenticatedClient` with `keepAliveInterval: null` (`:277`) and suppresses keyboard-interactive when prompting is disabled (`:271-272`). |
| `SshHostKeyPreflight`, `preflightDartSshHostKey` | `ssh_transport.dart:126-231` | Verifies the host key on a pre-auth connection so the trust prompt precedes the password prompt. |
| Late-channel leak guard | `ssh_transport.dart:372-395` | A timed-out open's late channel is closed, not leaked. Reuse the pattern for exec and streamlocal opens. |
| `ConnectionManager`, `PooledConnectionManager`, growth rules 1-4 | `connection_manager.dart:84-140, 224-233, 304-341` | Rule 2: interactive auth caps a pool at one transport. |
| `PoolPolicy` (`maxTransports 2`, `maxChannelsPerTransport 8` "OpenSSH's MaxSessions defaults to 10", keepalive 30 s, reconnect cap 30 s) | `pool_policy.dart:12-76` (comment at `:27-32`) | The 8-of-10 headroom rule applies to the fourth app too. |
| `PoolKey` (host lowercased, username case-sensitive, jump route included, credentials excluded) | `pool_key.dart:18-87` | Same endpoint identity should key the fourth app's transports. |
| Idle-only keepalive with 30 s ping timeout that closes a dead transport | `connection_manager.dart:1893-1960`, `ssh_transport.dart:34-38` | This is the dead-peer detection Séance lacks (R3). |
| Reconnect backoff (1 s base, 30 s cap, 30 % downward jitter) | `reconnect.dart:3-4` | |
| `CredentialResolutionScope` | `credential_resolution.dart:16-29` | Dismisses a pending credential prompt when the pool dies. |

The pool's rules are exactly what a monitoring app needs, but the
implementation is SFTP-typed and sits in `poltergeist_core`, which also drags
in `planchette_core`, `archive`, `xml`, `unorm_dart`
(`poltergeist/packages/poltergeist_core/pubspec.yaml:13-46`). A fourth app
should not depend on `poltergeist_core`.

### 2.6 Terminal stack

| Piece | Location | Notes |
|---|---|---|
| `TerminalEngine` (`feed`, `userInput`, `size`, `resize`, `dispose`), `TerminalSize` (cols, rows) | `seance/packages/seance_core/lib/src/terminal/terminal_engine.dart:5-17, 26-32` | Pure Dart seam. |
| `HeadlessTerminalEngine` | `terminal_engine.dart:37-80` | Tests and harnesses. |
| `SessionTransport` (`resize`, `close` owns disposing the engine, `isClosed`, `onClosed` fires once even if assigned late) | `seance/packages/seance_core/lib/src/terminal/session_transport.dart:16-31` | The contract a container shell or `docker attach` session implements. |
| `SshSession implements SessionTransport` | `ssh_session.dart:373-656` | Pipes stdout and stderr into the engine (`:403-426`), waits up to 2 s for streams to drain after remote close (`:594-615`). |
| `LocalShellSession`, `LocalPty`, `LocalPtyLauncher` | `seance/packages/seance_core/lib/src/terminal/local_shell.dart:190-228` | Local shell only; not needed for remote containers. |
| `XtermTerminalEngine` | `seance/app/seance_app/lib/services/xterm_engine.dart:62-475` | **In the app**, not a package. Adds OSC 7 cwd, OSC 0/2 title, OSC 133 prompt tracking, mobile Ctrl key, platform detection for IME (`:73-160`). |
| Vendored xterm.dart 4.0.0 fork | `seance/third_party/xterm` (path dep at `seance/app/seance_app/pubspec.yaml:28-33`), patches in `seance/third_party/xterm/PATCHES.md` | MIT; selection fixes. |
| Vendored flutter_pty 0.4.2 fork | `seance/third_party/flutter_pty` (`pubspec.yaml:34-42`) | Local PTY only; broken on Windows upstream (`seance/AGENTS.md:450-456`). |

### 2.7 LLM assistant and snippets

| API | Location | Reuse |
|---|---|---|
| `LlmProvider` (`listModels`, `generateCommand(prompt, HostContext)`, `chat(messages, tools)`, `streamChat(messages)`) | `seance/packages/seance_core/lib/src/llm/provider.dart:109-130` | Provider-neutral; Anthropic and OpenAI-compatible implementations exist (`anthropic_provider.dart`, `openai_provider.dart`). |
| `HostContext`, `CommandSuggestion.effectiveDanger` (max of model and linter) | `provider.dart:19-45, 50-74` | Reviewed-command flow for "fix this" suggestions. |
| `kCommandSystemPrompt`, `parseCommandJson` | `provider.dart:133-156` | One-command JSON contract. |
| `DangerLinter.scan/worst` | `seance/packages/seance_core/lib/src/llm/danger_linter.dart:24-127` | 14 rules (rm -rf, dd, mkfs, curl\|sh, iptables -F, shutdown...). **No Docker/systemd/cron rules.** |
| `SecretRedactor.redact` | `seance/packages/seance_core/lib/src/llm/redaction.dart:6-173` | Default-on; PEM blocks, provider tokens, JWTs, `password=` assignments. Logs and `docker inspect` env dumps are prime material for it. |
| `ChatController.send(userText, {terminalContext, sessionTarget, onPaste})` | `seance/packages/seance_core/lib/src/llm/chat_controller.dart:93-338` | Wraps untrusted context in `<<<CONTEXT ... CONTEXT>>>` (`:165-170`). **System prompt is a Séance constant** (`kChatSystemPrompt`, `:10-23`) and the tool set is fixed to `web_search` + `paste_to_prompt` (`:32-59, 240-258`). |
| `Snippet` (`{{placeholder}}` fill), `SnippetStore` | `seance/packages/seance_protocol/lib/src/models/snippet.dart:4-60`, `seance/packages/seance_core/lib/src/store/stores.dart:20-25` | Synced, non-secret. A "runbook" feature could reuse the record kind (check the sync wire format against the c1 report before adding kinds). |

---

## 3. dartssh2: pin, features used, features available, upstream drift

### 3.1 Pin and overrides

- Exact `3.0.2` in `seance/packages/seance_core/pubspec.yaml:18`,
  `poltergeist/packages/poltergeist_core/pubspec.yaml:24`,
  `poltergeist/packages/poltergeist_bench/pubspec.yaml:14`, and as a test-only
  dev dependency in `seance/app/seance_app/pubspec.yaml:82-85`.
- **No override or patch anywhere**: the only `dependency_overrides` in the repo
  is `pdfium_dart` (`poltergeist/app/poltergeist_app/pubspec.yaml:63-68`); no
  `pubspec_overrides.yaml` exists; lockfiles resolve the hosted pub.dev archive.
- Poltergeist's M0 evidence and D9 decision are bound to 3.0.2
  (`poltergeist/docs/STATUS.md:922, 929`). Any bump is a suite-wide, evidence-
  invalidating change, and a fourth app consuming `seance_core` by path inherits
  3.0.2 whether it wants to or not.

### 3.2 Feature matrix (3.0.2)

| Feature | dartssh2 3.0.2 API | Used today | Needed by fourth app |
|---|---|---|---|
| Exec | `SSHClient.execute(cmd, {pty, x11, environment})` `ssh_client.dart:447-513` | Yes, no options (`ssh_session.dart:499`) | Yes, plus PTY/env/stdin |
| Shell + PTY + resize | `shell({pty})`, `SSHSession.resizeTerminal` `ssh_client.dart:515-577`, `ssh_session.dart:92-116` | Yes (`ssh_session.dart:1211-1213, 589-592`) | Host shell |
| stdin / EOF | `SSHSession.stdin` (close sends EOF) `ssh_session.dart:11` | Shell only | `crontab -`, `sudo -S`, `docker exec -i` |
| Exit status / signal | `exitCode`, `exitSignal`, `waitForExit({timeout})` `ssh_session.dart:24-29, 127-133` | `exitCode` only | Both |
| Send signal | `SSHSession.kill(SSHSignal)` fire-and-forget `ssh_session.dart:137-139`, `ssh_channel.dart:179-186` | No | Stop followers, Ctrl-C |
| Env vars | `environment:` -> `sendEnv` with reply; refusal throws and closes the channel `ssh_client.dart:457-467`, `ssh_channel.dart:167-177` | No | Avoid; prefix in command instead (R9) |
| SFTP | `sftp()` `ssh_client.dart:588-600` | Yes | Config file edit |
| Local TCP forward | `forwardLocal(host, port)` `ssh_client.dart:391-406` | ProxyJump only | Port-forward to container ports, web UIs |
| **Unix-socket forward** | `forwardLocalUnix(path)` -> `direct-streamlocal@openssh.com` `ssh_client.dart:435-445, 1424-1437` | No | **Docker/Podman API** |
| Remote forward | `forwardRemote`, `cancelForwardRemote` `ssh_client.dart:334-385` | No | Not needed |
| Dynamic SOCKS | `forwardDynamic` `ssh_client.dart:415-432` | No | Optional (browse container web UIs) |
| Agent forwarding | `agentHandler` `ssh_client.dart:179, 469-475` | No | Not recommended |
| HTTP over SSH | `SSHHttpClient` `http/http_client.dart:26` | No | Not suitable (TCP only, buffered, no keep-alive/upgrade) |
| Keepalive | `keepAliveInterval`, `ping()` `ssh_client.dart:183, 305-306, 708-712` | Séance default 10 s; Poltergeist own clock | Needs timeout (R3) |
| Channel-open failure | `SSHChannelOpenError(reasonCode, description)` `ssh_client.dart:1440-1446` | Collapsed into strings | Classify MaxSessions exhaustion |
| Window | 2 MiB initial, 32 KiB max packet `ssh_client.dart:52-54` | | Log volume, R2 |

### 3.3 Upstream drift relevant to this app (pub.dev, latest 4.1.0, 2026-09-04)

From the 4.1.0 archive's CHANGELOG:

- **3.3.0**: `SSHDisconnectError` exposes the peer's disconnect reason (3.0.2
  logs it and closes "cleanly"). Useful for "why did my monitor drop".
- **3.3.1**: removes the X25519/NIST key-exchange isolate offload that made
  memory-constrained Android devices time out the handshake. 3.0.2 still
  offloads (`dartssh2:lib/src/kex/kex_x25519.dart:4`, `kex_nist.dart:5`,
  `utils/compute_io.dart:7`).
- **4.0.0** (breaking): drops SHA-1 KEX, `ssh-rsa` and CBC from default
  proposals (3.0.2 still proposes `dh1Sha1`, `rsaSha1`, `aes*-cbc`,
  `dartssh2:lib/src/ssh_algorithm.dart:47-75`); detects host-key change on
  rekey; stops logging keyboard-interactive responses in plaintext; random
  padding; constant-time MAC compare; KEX public-value validation.
- **4.0.1**: fixes the "data before first listener" permanent channel stall
  and the window-adjust-per-packet chatter (both present in 3.0.2, see R2).
- **4.1.0**: optional channel-request pipelining (saves round trips per exec).
- Still no chacha20-poly1305 or ML-KEM in 3.0.2 (`ssh_cipher_type.dart:7-16`);
  M0 recorded that a chacha-only server cannot connect
  (`poltergeist/docs/M0-DARTSSH2-REPORT.md:106-114`).

Recommendation: plan the fourth app on 3.0.2 with workarounds (subscribe
before write, own ping timeout, no env), and raise a separate suite-wide
"re-pin dartssh2 to 4.x" task; it touches M0 evidence, pin audits and the
`redactConnectionTrace` audit (`ssh_session.dart:198-208`) and must not be
folded into the new-app work.

---

## 4. The dartssh2 import guard and the fourth app

How it works today:

- `poltergeist/scripts/check-imports.sh` runs `tool/import_guard/bin/check.dart`
  against **the Poltergeist root** (`repo_root` = `poltergeist/`).
- Hard-coded constants: `_coreDirectory = 'packages/poltergeist_core'`,
  `_connectionDirectory = '$_coreDirectory/lib/src/connection'`,
  `_benchPackage = 'packages/poltergeist_bench'`
  (`poltergeist/tool/import_guard/lib/import_guard.dart:10-20`).
- Scans only `packages/` and `app/` under that root (`:13, 33-62`).
- Dependency rule: any package other than core/bench declaring `dartssh2`
  (including in `pubspec_overrides.yaml`) fails (`:136-148`).
- Import rule: any `package:dartssh2` import/export outside the connection
  directory fails, including conditional-import branches (`:184-205`).
- Pure-Dart packages may not import Flutter/plugins (`:150-165, 207-218`).
- Run by CI job `dart_tools` with `working-directory: poltergeist`
  (`.github/workflows/ci.yml:206-236`) and by `scripts/test.sh` (`:103-105`).

Consequences:

- Nothing guards `seance/` or a new product. Séance itself has no such rule
  (`seance_app` tests import dartssh2, e.g. `seance/app/seance_app/test/host_key_blocked_test.dart`).
- `seance_core`'s public API leaks dartssh2 types: `openAuthenticatedClient`
  returns `SSHClient`; `SshSession.client`/`shell` are public fields
  (`ssh_session.dart:374-375`); `SshForwardConnector` mentions `SSHSocket`
  (`:66-71`). Any caller of `openAuthenticatedClient` must import dartssh2, which
  is why Poltergeist confines it to `connection/` and re-exports Séance types
  through explicit `show` lists (`poltergeist_core.dart:20-80`).

What the fourth app must do:

1. Put every dartssh2 import in one module of its pure-Dart core, e.g.
   `<product>/packages/<product>_core/lib/src/connection/`, and expose only
   neutral types (a `ByteDuplex`/`RemoteSocket` interface, `ExecHandle`,
   `RemoteCommandResult`).
2. Re-export Séance types from its own barrel with explicit `show` lists, never
   `export 'package:seance_core/seance_core.dart';` wholesale.
3. Get the guard by **generalizing** `poltergeist/tool/import_guard` (config of
   product root, core dir, sanctioned connection dir, sanctioned extra
   packages) and moving it to root `tool/`, then running it per product.
   A product-local copy would violate `AGENTS.md:5-6`.
4. Keep `implementation_imports` of `package:seance_core/src/...` confined to
   the connection module with an `// ignore:` and a reason, as
   `ssh_transport.dart:7-10` and `ssh_cleanup.dart:1-3` do; better, export what
   is needed from `seance_core` (G1/G4/G7 below) so no implementation import is
   needed.

---

## 5. Terminal reuse for container shells, attach and log tailing

| Use | Recommended path | Fit |
|---|---|---|
| Host shell | `SshSessionManager.connect` + `XtermTerminalEngine` | Direct reuse once the engine is in a shared package. |
| Container shell, CLI route | `client.execute("docker exec -it <id> sh", pty: SSHPtyConfig(...))` wrapped in a new `SessionTransport` (same shape as `SshSession`, minus login script) | Good. Uses one session channel; PTY means SIGHUP on close and resize via `resizeTerminal(cols, rows)`. |
| Container shell, API route | `POST /containers/{id}/exec` (Tty=true) then `POST /exec/{id}/start` with `Upgrade: tcp` hijack over a `forwardLocalUnix` channel; resize with `POST /exec/{id}/resize?h=<rows>&w=<cols>` | Good, does not consume `MaxSessions`; needs the hijack-capable HTTP client (G5). Rows/cols transposition is the same trap the PTY test guards against (`seance/AGENTS.md:383-387`). |
| `docker attach` | API `POST /containers/{id}/attach?stream=1&stdin=1&stdout=1&stderr=1` hijacked, raw if Tty, otherwise multiplexed 8-byte frames | Same as above plus a stdcopy demuxer when Tty=false. Detach keys must not be sent by accident (Ctrl-P Ctrl-Q default). |
| Live log tail | Prefer a dedicated log view over a terminal: `GET /containers/{id}/logs?follow=1&timestamps=1` (stdcopy-framed unless Tty) or `journalctl -f -o json` / `tail -F` over a streaming exec | Terminal emulation is the wrong model for logs (no structured filter, 10 000-line ring in `XtermTerminalEngine`, `xterm_engine.dart:141`). `HeadlessTerminalEngine` or an ANSI-to-spans parser can render colours. |

Gaps to close before any of this:

- Move `XtermTerminalEngine` (and the terminal view/find bar/key bar widgets it
  drives) out of `seance/app/seance_app/lib/services/xterm_engine.dart` into a
  shared Flutter package. Candidates: alongside the existing shared UI packages
  in `planchette/packages/` (`ghost_ui`, `ghost_desktop`, `ghost_marks`), or a
  new `seance/packages/seance_terminal` (Flutter, not a workspace member, like
  the apps). The vendored `xterm` stays where it is; both apps path-depend on it.
- OSC 7/133 shell-integration tracking in the engine is SSH-shell specific;
  container shells rarely emit it. Keep it optional in the extracted engine.
- `paste_sanitizer.dart` (exported) and `DangerLinter` should run on pastes into
  container shells too, as they do for SSH shells.
- flutter_pty is irrelevant (remote PTYs come from sshd), so the fourth app does
  not inherit the Windows flutter_pty breakage or the CocoaPods requirement it
  causes on macOS (`seance/AGENTS.md:270-275`).

---

## 6. LLM reuse for "explain this log/error" and reviewed commands

Reusable as is: `LlmProvider.streamChat` for explanations, `SecretRedactor` on
every log excerpt before it leaves the device, the `<<<CONTEXT ... CONTEXT>>>`
untrusted-context convention (`chat_controller.dart:165-170`),
`generateCommand` + `CommandSuggestion.effectiveDanger` + `DangerLinter` for a
"suggest a fix" button that only stages a command for review.

Needs upstream work in `seance_core` (not a copy):

- Parameterize `ChatController` by system prompt and tool set. Today both are
  Séance constants (`chat_controller.dart:10-23, 32-59`) and tool dispatch is a
  closed `switch` (`:240-258`).
- Add Docker/systemd/cron/firewall rules to `DangerLinter`
  (`danger_linter.dart:25-101`): `docker system prune -a --volumes`,
  `docker volume rm|prune`, `docker rm -f`, `docker compose down -v`,
  `systemctl stop|disable|mask ssh(d)`, `crontab -r`, `ufw reset|disable`,
  `nft flush ruleset`, `kill -9 1`, `userdel`, `chown -R ... /`. Séance benefits too.
- Keep the invariant "no execution tools in chat" (`seance/AGENTS.md:133-135, 670-673`).
  A management app is tempted to let the model run diagnostics; doing so changes
  the product's safety model and needs an explicit owner decision. A safe middle
  ground is a fixed, app-defined, read-only diagnostic catalog whose *output*
  (redacted) the user chooses to attach, never model-chosen commands.

---

## 7. Integration test infrastructure and a Docker daemon fixture

Existing:

- `poltergeist/test/integration/docker-compose.yml` defines sshd services on
  loopback ports 2201-2213: OpenSSH 10.6p1 modern (frozen Alpine base pinned by
  digest, `sshd-modern/Dockerfile:1`, `sshd-modern-base/Dockerfile:1-14`),
  OpenSSH 8.4 legacy by digest (`docker-compose.yml:32-45`), chroot, restricted,
  authmatrix, keyswap, rsa, chacha, ed25519 (`README.md:66-78`).
- `run.sh` owns lifecycle, readiness (real SSH banners), serialized tagged Dart
  tests and teardown (`poltergeist/test/integration/run.sh`, `README.md:1-20`).
- Common sshd config: `AllowTcpForwarding no`, `AllowAgentForwarding no`,
  `PermitRootLogin prohibit-password`, keyboard-interactive on
  (`sshd-common/config/sshd_config.common:1-20`). `AllowStreamLocalForwarding`
  is unset, so it defaults to `yes`.
- Safety checker forbids only host networking and non-`127.0.0.1` publishing
  (`check_config.dart:8-50`).
- CI: `integration` job runs `run.sh` on `ubuntu-latest` (`.github/workflows/ci.yml:397-414`),
  path-filtered to Poltergeist plus the shared `seance_core`/`seance_protocol`/
  `planchette_core` sources (`:350-372`); `sync_integration` builds the sync
  server image and runs tagged tests (`:420-480`).
- Séance has **no live-sshd tests**; `seance_core` SSH tests use in-process
  wire fixtures (e.g. `seance/packages/seance_core/test/ssh_proxy_jump_test.dart:1-40`).

Can it host Docker? Yes, with care:

1. Add a `docker` Compose profile: a `docker:<ver>-dind` service pinned by
   digest, `privileged: true`, **no published ports**, TLS/TCP listener
   disabled, its `/var/run` on a named volume shared read-write into an sshd
   service (e.g. at `/var/run/docker.sock` and a second non-default path to
   test discovery). The checker passes this as is; consider extending it to
   reject a published 2375/2376 and `docker.sock` bind mounts from the host.
2. Socket permissions: sshd opens the socket as the authenticated user, so the
   fixture user needs the socket's group (align GIDs, e.g. `dockerd --group
   <gid>`; unverified exact flag behaviour with numeric GIDs) or a negative test
   that asserts the "permission denied" mapping.
3. The frozen sshd base cannot `apk add docker-cli` at CI time (the reason the
   base is frozen, `README.md:46-56`). The streamlocal route needs no CLI in the
   sshd container; testing the `docker` CLI and `docker system dial-stdio`
   routes needs a new base image through the `Fixture images` workflow
   (`.github/workflows/fixture-images.yml`).
4. Negative fixtures worth adding: `AllowStreamLocalForwarding no`,
   `DisableForwarding yes`, `MaxSessions 2` (to exercise channel budgeting),
   authorized_keys `restrict`.
5. Ownership: this fixture is Poltergeist-owned and its CI filter is
   Poltergeist-scoped. Either lift the sshd fixture to a shared root location
   (preferred under "never copied") or have the fourth product's fixture build
   `FROM` the same published base digest.
6. Only Linux runners: GitHub's macOS and Windows runners do not provide a
   Linux Docker daemon, so Docker integration runs on `ubuntu-latest` only;
   unit tests must cover parsing with recorded API responses.
7. Privileged DinD is effectively root on the runner; acceptable on ephemeral
   CI runners, but `run.sh` users locally should be told.

---

## 8. Gaps and where they should live

Home key: **SC** = upstream into `seance_core` (pure Dart, shared, Séance can use
it), **NC** = new pure-Dart core package of the fourth product
(`<product>/packages/<product>_core`, path-depending on `seance_core` like
`poltergeist_core` does), **UI** = shared Flutter package, **APP** = the
fourth app.

| # | Gap | Why the app needs it | Home | Notes |
|---|---|---|---|---|
| G1 | Headless exec on an authenticated client | Monitoring must not open a PTY shell per server; today exec is only `SshSession.runCommand`. | SC | Extract the body of `runCommand` (`ssh_session.dart:488-586`) into a free function or small class over a neutral handle; `SshSession.runCommand` delegates. Classify `SSHChannelOpenError` (e.g. `RemoteCommandErrorKind.channelLimit`) instead of a string. Surface `exitSignal`. |
| G2 | Long-lived streaming exec | `journalctl -f`, `tail -F`, `docker stats`, `docker events`, `top -b`. | SC (mechanism), NC (parsers) | `Stream<Uint8List>` per stream with pause-driven backpressure (dartssh2 pauses the channel when the controller pauses, `dartssh2:lib/src/ssh_session.dart:69-77, 164-170`), bounded line framer, cancellation = `kill('TERM')` then close then timeout; subscribe before any write (R2). |
| G3 | Exec options: stdin, PTY, env | `crontab -`, `sudo -S`, `docker exec -it`, `systemctl edit`. | SC | Expose `pty` and stdin; avoid `environment:` (R9). |
| G4 | Unix-socket forwarding as a neutral byte duplex | Docker/Podman API without `MaxSessions` cost. | SC (thin, neutral `RemoteSocket` over `forwardLocalUnix`), NC (use) | Must listen before writing (R2); OpenSSH reports every streamlocal open failure as connect-failed "open failed", so map failures to actionable errors with an exec probe: `test -S` fails means missing, `test -w` fails means permission denied, both succeed means forwarding is disabled. |
| G5 | HTTP/1.1 client over a byte duplex with chunked decoding, streaming bodies, keep-alive, `Upgrade: tcp` hijack, Docker stdcopy demux | Docker Engine API (logs follow, attach, exec, events, stats stream, image pull progress). | NC | Options: (a) pure-Dart client over the duplex (works on all 5 platforms, recommended); (b) `dart:io` `HttpClient.connectionFactory` (needs a real `Socket`, so a local loopback/Unix bridge: exposes the root-equivalent Docker socket to other local processes unless carefully scoped; not recommended); (c) `docker system dial-stdio` over exec as a fallback transport when streamlocal is refused (counts as a session channel). |
| G6 | Channel budgeting / multiplexing within `MaxSessions` | Dashboards, followers and shells per server easily exceed 10 session channels. | NC first, SC later | Per-transport semaphore at <= 8 session channels (Poltergeist's headroom, `pool_policy.dart:27-32`); forwarding channels exempt; batch collectors into one exec with sentinel-delimited sections (RemoteGit technique) or one long-lived sampler loop; a second transport only under Poltergeist's growth rules (no second 2FA prompt). Extract the pool core from `poltergeist_core` to `seance_core` once a second consumer exists, rather than writing a third pool. |
| G7 | Dead-peer detection | Monitoring must notice a silently dropped link. | SC | `ping().timeout(30 s)` then close, as `connection_manager.dart:1927-1960` does; dartssh2's keepalive never times out (R3). Séance would benefit. |
| G8 | Privilege escalation | Logs, cron of other users, `systemctl`, Docker without docker-group. | NC (strategy), SC/vault (secret storage) | Detect with `sudo -n true`; run `sudo -S -p '' -- cmd` with the password on stdin for non-interactive commands; support `doas`, `run0`, or a root `ServerConfig` via ProxyJump; never pass the password on the command line; redact it from transcripts. Storing a sudo password needs a vault secret kind decision (wire format, `AGENTS.md:43-44`). |
| G9 | Shared credential resolution | Third copy of the same logic otherwise. | SC | Séance `app_services.dart:1075-1150` and Poltergeist `server_editor_backend.dart:210-262` are near-identical; lift into a `CredentialResolver` over `SecretVault` + an identity-file reader interface. |
| G10 | Shared terminal engine | Container shells. | UI | Section 5. |
| G11 | Parameterized assistant + Docker danger rules | Explain logs; reviewed fixes. | SC | Section 6. |
| G12 | Import guard for more than one product | Section 4. | root `tool/` | Generalize, do not copy. |
| G13 | Docker endpoint discovery and access check | Rootful `/var/run/docker.sock`, rootless `/run/user/<uid>/docker.sock`, Podman `/run/podman/podman.sock` or `/run/user/<uid>/podman/podman.sock`, docker contexts. | NC | Discover with one exec (`id -u`, `test -S`, `docker context inspect` if the CLI exists), then open streamlocal. Warn that docker-group membership is root-equivalent. |
| G14 | Background isolate | Parsing frequent samples and log floods on the UI isolate janks. | NC/APP | Poltergeist runs SSH in an engine isolate behind a guarded protocol (`poltergeist/packages/poltergeist_core/lib/src/engine/*`, `poltergeist/tool/protocol_guard/README.md`); Séance does not. Decide early; it shapes every API (no function-typed fields across the boundary). |
| G15 | Mobile backgrounding | Live monitors on Android/iOS. | APP | Séance's foreground-service keepalive is app-local (`seance/app/seance_app/lib/services/background_keep_alive.dart:1-50`, Android only, native channel `seance/keepalive`). The fourth app needs its own native side; iOS has no equivalent for sideloaded apps. |
| G16 | User-facing port forwarding | "Open container web UI". | SC | dartssh2 supports `forwardLocal`/`forwardDynamic`; nothing in the suite exposes it (`grep` finds only the ProxyJump use). Binding a local listener has its own exposure risk (bind 127.0.0.1 only). |

Proposed dependency shape:

```
<product>_app (Flutter) ──> <product>_core (pure Dart) ──> seance_core ──> seance_protocol
        │                        │  lib/src/connection/  (only dartssh2 importer)
        │                        │  lib/src/docker/      (HTTP/1.1, stdcopy, API models)
        │                        │  lib/src/host/        (procfs/df/systemd/journal/cron parsers)
        └──> shared terminal UI package ──> third_party/xterm (vendored)
```

---

## 9. Risks and gotchas

R1. **`MaxSessions` (default 10) is per TCP connection and counts shell, exec
and SFTP sessions, not forwarding channels** (sshd_config(5)). Exceeding it
fails the channel open; `runCommand` reports that as a generic
"Could not open a command channel" (`ssh_session.dart:498-505`). Budget at 8
(Poltergeist's rule), use streamlocal for Docker, batch collectors.

R2. **dartssh2 3.0.2 stall when data arrives before the first listener.** The
channel's receive controller wires only `onResume` (`dartssh2:lib/src/ssh_channel.dart:59-61`)
and window adjusts are skipped while it reports paused, which it does before
anyone listens (`:352-357`). A peer that fills the 2 MiB window
(`ssh_client.dart:52`) before the subscription leaves the channel at zero
credit forever. `SSHSession` subscribes in its constructor
(`dartssh2:lib/src/ssh_session.dart:47-50`), so exec is safe, but
`SSHForwardChannel.stream` is a lazy `map` (`forward/ssh_forward.dart:62`), so
a streamlocal Docker request written before listening can hang on large
responses. dartssh2's own `SSHHttpClient` writes before subscribing
(`http/http_client.dart:141-143`). Rule: always listen before write. Fixed
upstream in 4.0.1. Also 3.0.2 sends one window adjust per data packet (uplink
chatter on high-volume log follows).

R3. **No dead-peer detection in Séance's path.** dartssh2's keepalive swallows
errors and never times out a ping (`ssh_keepalive.dart:19-31`); an unanswered
ping also blocks all later pings (`_isPinging`). Séance has no other ping
timeout (no `ping()` call in `seance_core/lib` or the app). A monitor would show
stale data until TCP gives up. Use Poltergeist's ping-with-timeout pattern.

R4. **Closing a non-PTY exec channel does not reliably kill the remote
process.** Without a PTY there is no SIGHUP; a follower dies only on its next
write (SIGPIPE), a silent one lingers (unverified against current OpenSSH,
standard POSIX behaviour). Send `kill('TERM')` first (OpenSSH supports the
`signal` request since 7.9, Oct 2018 [LWN]; it is fire-and-forget, no reply,
`ssh_channel.dart:179-186`), or wrap followers as `exec timeout ...`/`setsid`
with a remote watchdog, or use a PTY when stderr separation is not needed.

R5. **Docker socket access is root-equivalent.** Streamlocal opens the socket as
the SSH user; success requires docker-group membership or root. Surface this in
UI. If the user lacks access, `sudo` over streamlocal is impossible; the
fallback is `sudo docker system dial-stdio` (or `socat`) over exec, which
counts against `MaxSessions` and complicates `sudo -S` because stdin is also
the data stream.

R6. **Forwarding can be disabled server-side**: `AllowStreamLocalForwarding no`,
`DisableForwarding yes` (sshd_config(5)), or authorized_keys `restrict` /
`no-port-forwarding` (my reading of OpenSSH's `serverloop.c` is that the latter
also gates streamlocal; unverified). The suite's own fixture sets
`AllowTcpForwarding no` (`sshd_config.common:17`), which also breaks ProxyJump
through it. Detect and fall back to the CLI/dial-stdio route with a clear
message.

R7. **Login shell and rc-file output corrupt parsing.** Commands run in the
account's login shell (could be fish, zsh, tcsh, `nologin`, or a
`ForceCommand`); bash sources `~/.bashrc` for sshd-launched commands and stray
`echo`s land in stdout. Wrap scripts as `sh -c <quoteShellWord(script)>`
(`shell_command.dart:63-70`), use sentinels like RemoteGit's NUL delimiter
(`remote_git.dart:236-258`), force `LC_ALL=C`, disable pagers/colour
(`--no-pager`, `SYSTEMD_PAGER=`, `NO_COLOR=1`), prefer machine formats
(`--format '{{json .}}'`, `journalctl -o json`, `df -P`, `systemctl show -p`).
Non-login PATH may miss `/usr/local/bin`, `/snap/bin`, `/usr/sbin`.

R8. **TOFU pins are keyed by `host:port` only** (`host_key.dart:112`). Two
private hosts with the same address behind different jump routes collide
(e.g. `10.0.0.5:22` in two VPCs). Poltergeist's pool key includes the route
(`pool_key.dart:28-33`), the pin store does not. Pre-existing; affects any app
with many routed servers.

R9. **`environment:` is a trap**: sshd accepts only `AcceptEnv`-listed names
(distribution defaults typically pass only `LANG`/`LC_*`); a refusal makes
dartssh2 close the channel and throw (`ssh_client.dart:457-467`). Put variables
in the command string instead.

R10. **Interactive-auth servers allow exactly one transport** without a second
2FA prompt (Poltergeist growth rule 2, `connection_manager.dart:224-231`).
Everything for such a server (metrics, followers, shells, Docker API) must
share one connection's 10 session slots.

R11. **`MaxStartups` (default 10:30:100) and fail2ban** punish bursts of new
connections (sshd_config(5)). Probe sweeps are already capped at 6 concurrent
(`probe_service.dart:69-73`); a dashboard that connects to every server at
launch needs the same cap and jitter, and must reuse transports instead of
connect-per-sample.

R12. **Algorithm compatibility**: 3.0.2 cannot connect to chacha20-only or
ML-KEM-only servers (`M0-DARTSSH2-REPORT.md:106-114`) and still proposes SHA-1
KEX, `ssh-rsa` and CBC by default (`ssh_algorithm.dart:47-75`). Hardened fleets
are exactly the servers an admin tool targets. Re-pin work is suite-wide.

R13. **Android handshake timeouts** from 3.0.2's KEX isolate offload on
memory-constrained devices (fixed in 3.3.1). Affects all products on Android
until re-pinned.

R14. **`SSHClient.close()` can hang and cannot be forced**: there is no public
destroy (`test_connection.dart:85-98`). Every teardown must be bounded
(`closeSshResource`, `ssh_cleanup.dart:12-20`; `runSequentialCleanup`).
Abandoned channel opens must close their late result
(`ssh_transport.dart:372-395`).

R15. **Rows/cols transposition**: `TerminalSize` is cols-first, the local pty
API rows-first (`seance/AGENTS.md:383-387`), dartssh2 `resizeTerminal(width,
height)`, Docker `resize?h=&w=`. Test each boundary.

R16. **Transcript hygiene**: keep using `SshConnectionLog` and freeze it after
connect; anything that logs exec output or Docker inspect results must pass
`SecretRedactor` before display/copy/LLM, since env vars in `docker inspect`
routinely contain credentials.

R17. **Log volume vs memory**: `runCommand` caps at 256 KiB per stream
(`ssh_session.dart:491`); streaming followers need their own ring buffer and
line-length cap, and must pause the subscription (which propagates to the SSH
window) rather than buffer unboundedly. `SSHSession` buffers stderr without
limit if nobody listens to it (`dartssh2:lib/src/ssh_session.dart:74-77`), so
always drain both streams.

R18. **Wire formats and IDs**: any new synced record kind (e.g. runbooks,
alert rules, sudo secret kind) touches `seance_protocol`
(`records/record.dart:13-44`) and old builds' unknown-kind handling; coordinate
with the sync work before adding kinds.

---

## 10. Sources

Repository files as cited above. External:

- dartssh2 3.0.2 and 4.1.0 package archives and metadata from pub.dev
  (`https://pub.dev/api/packages/dartssh2`, archives under
  `https://pub.dev/api/archives/`), read 2026-10-10.
- [sshd_config(5), OpenBSD manual](https://man.openbsd.org/sshd_config):
  `MaxSessions`, `MaxStartups`, `AllowStreamLocalForwarding`,
  `DisableForwarding`, `AllowTcpForwarding`.
- [LWN: OpenSSH 7.9 released](https://lwn.net/Articles/768991/) (signal
  channel request support).
- [Dart `HttpClient.connectionFactory`](https://api.dart.dev/dart-io/HttpClient/connectionFactory.html)
  (requires a `dart:io` `Socket`; Docker Unix-socket example).
