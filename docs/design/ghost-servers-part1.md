# Shared package design: `ghost_servers` part 1 and the IEC formatters

Scope: Klabautermann foundations row F4 (03-ARCHITECTURE.md D8 and the
section 3.5 table; 04-IMPLEMENTATION.md "F4"). New package
`planchette/packages/ghost_servers` part 1: the status-dot vocabulary, the
server sectioning rules, the host-key (TOFU), keyboard-interactive and
credential prompts, the connection log view and the connection test report,
with one adapter per app. Plus the IEC binary byte and rate formatters in
`ghost_ui`; `ghostFormatFileSize` keeps its current platform convention.
Dependencies: `ghost_ui`, `ghost_marks`, `seance_protocol` only. No
`seance_core` or `poltergeist_core` edge, no `dartssh2`.

Status: proposed for the Klabautermann foundations (F4); approval under the owner's instruction of 2026-10-13 to implement the plan.

Main commit read: `20acafc7`.

## 1. Inventory

### 1.1 Production files

| File | Lines | Contents |
|---|---|---|
| `seance/app/seance_app/lib/ui/server_status_dot.dart` | 120 | `ServerDot` enum (:29-36), `description`/`detail`/`style`/`color` projections (:40-74), `serverDotFor` rule (:84-103), `aggregateSessionStatus` (:108-119) |
| `seance/app/seance_app/lib/ui/server_grouping.dart` | 301 | Section keys and labels, `ServerGroupSection`/`ServerSidebarSections`, `groupServers`, `serverListRows`, `sectionsHoldingLive`, `hiddenByHeader`. Flutter-free; imports `seance_core` only for `ServerConfig`, `normalizeServerGroup`, `serverGroupKey`, all of which live in `seance_protocol` |
| `seance/app/seance_app/lib/ui/host_key_dialog.dart` | 106 | `showHostKeyDialog(BuildContext, HostKeyDecision)` (:7-84), `_Fingerprint` (:86-106) |
| `seance/app/seance_app/lib/ui/keyboard_interactive_dialog.dart` | 143 | `showKeyboardInteractiveDialog(BuildContext, KeyboardInteractiveChallenge)` (:6-16), `_trustedTarget` IPv6 bracketing (:18-25), one obscured field per prompt (:111-125) |
| `seance/app/seance_app/lib/ui/credential_prompt.dart` | 179 | `showMissingCredentialDialog` (:12-24), pasted-PEM + file-pick key flow (:55-68, :117-148), `MissingCredential` replies |
| `seance/app/seance_app/lib/ui/connection_log_view.dart` | 109 | `ConnectionLogView({required String text})`: ExpansionTile, copy button with `showTopToastIn`, empty placeholder, mono selectable text; copy errors to `dart:developer` (:43-68) |
| `seance/app/seance_app/lib/ui/connection_test_report.dart` | 66 | `ConnectionTestReport({required ConnectionTestResult})` (:14-65), embeds `ConnectionLogView` (:62) |
| `seance/app/seance_app/lib/services/private_key_file.dart` | 37 | `pickPrivateKeyText` file_picker wrapper (:12-36). App-side, see 1.7 |
| `seance/app/seance_app/lib/ui/server_filter.dart` | 26 | `serverMatchesQuery`/`filterServers` over `serverSearchHaystack`. App-side, see 1.7 |
| `poltergeist/app/poltergeist_app/lib/ui/server_state_indicator.dart` | 228 | `ServerIndicatorGlyph` (:9-31), `ServerIndicatorAppearance` (:36-39), `serverIndicatorOf` list rule (:51-67), `railIndicatorOf` (:76-88), `_outranksProbe` (:99-104), `ServerStateGlyph` painter (:166-227) |
| `poltergeist/app/poltergeist_app/lib/ui/sidebar/sidebar_servers_section.dart` | 927 | Inline sectioning: `_ServerGroup` (:10-17), catalog grouping loop (:30-50), group headers (:99-131), hidden-live logic (:75-77, :95-97, :105-113, :158-170, :173), `_hiddenLive` (:338-363), `_liveStatus` (:295-303). Rest is sidebar presentation, app-side |
| `poltergeist/app/poltergeist_app/lib/ui/prompts/host_key_dialog.dart` | 126 | `showHostKeyDialog(BuildContext, HostKeyPromptData, {dialogKey})` (:15-100); ARB strings; `changed` = `pinnedFingerprintSha256 != null` (:20) |
| `poltergeist/app/poltergeist_app/lib/ui/prompts/keyboard_interactive_dialog.dart` | 161 | `showKeyboardInteractiveDialog(..., KeyboardInteractivePromptData, {dialogKey})` (:12-23); ARB; adds `textInputAction`/`onSubmitted` focus chain (:126-131) |
| `poltergeist/app/poltergeist_app/lib/ui/prompts/credential_dialog.dart` | 258 | `CredentialDialogResult` (:11-26), `showCredentialDialog(..., CredentialPromptData, {readKeyFile, vaultUnavailable, dialogKey})` (:33-50); identity-file path field, vault banner (:174-188), save-in-vault checkbox (:231-240), audited submit path (:88-136) |
| `poltergeist/app/poltergeist_app/lib/ui/connection_log_view.dart` | 109 | Line-for-line twin of Séance's file except `AppLocalizations` strings (:37+) and copy errors to `ApplicationErrorReporter` (:58) |
| `poltergeist/app/poltergeist_app/lib/ui/connection_test_report.dart` | 71 | Twin of Séance's with ARB strings (:41-43), embeds `ConnectionLogView` (:67) |
| `poltergeist/app/poltergeist_app/lib/ui/connection_status_panel.dart` `_ConnectionLogView` | ~52 (:247-298) | Third copy: takes `List<String> lines`, joins with `'\n'`, `reverse: true` scroll (:283), no font fallback list, silent copy via `_copyLog` (:241-243). The panel itself is constructed only by `test/ui/connection_status_panel_test.dart`; no production mount site exists under `lib/` |
| `poltergeist/app/poltergeist_app/lib/ui/activity/activity_format.dart` | 193 | `formatTransferRate` (:20-24), `formatTransferLimit` (:29-33), `formatTransferEta` (:38-47), `maxTransferRateBytesPerSecond` (:16), `parseTransferRate` (:54-79), `_ratePattern` (:81-84); rest is path/task helpers, app-side |
| `poltergeist/app/poltergeist_app/lib/ui/panes/pane_format.dart` | 122 | `formatPaneSize` (:81-82) delegates to `ghostFormatFileSize`; `paneUnevaluated` (:19). App-side wrapper |
| `planchette/packages/ghost_ui/lib/src/ghost_file_format.dart` | 151 | `ghostFormatFileSize` (:23-50): divisor 1000 on macOS/Linux, 1024 on Windows; units B/KB/MB/GB/TB. Stays unchanged |

Call sites. Séance: `main.dart:148-158` wires `HostKeyPrompter` and the
keyboard responder; `terminal_pane.dart:1522-1528` raises
`showMissingCredentialDialog`, `:1697-1712` wraps `session.log.toString()`
in a `_ConnectionLogView` (wrapper stays app-side); `server_editor.dart`
raises `ConnectionTestReport` after `testServerConnection`
(`app_state.dart:621-629`); `server_list_pane.dart` consumes
`serverListRows` (:207-210, :434-449), `groupServers` (:223),
`sectionsHoldingLive` (:445-448), `hiddenByHeader` (:454), `serverDotFor`
(:364-367, :589-595, aggregate at :872); `server_tile.dart` consumes
`ServerDot.style`/`color`/`description`/`detail` (:96-128, :146-154).
Poltergeist: `prompt_coordinator.dart` dispatches `EnginePromptKind` at
:158-190 and calls the three dialogs at :241, :262, :314-318;
`server_editor_backend.dart:269-279` and :286-299 already convert
`HostKeyDecision`/`KeyboardInteractiveChallenge` into the sendable prompt
records (this is the adapter precedent); `server_editor.dart:646-658`
mounts the test report; `sidebar_view.dart:939-984` resolves rail dots,
`:836-838` row haystacks; `pane_tabs_view.dart:1182-1204` uses
`ServerStateGlyph` for the tab strip; rate-format callers are
`activity_rows.dart:397-402` and `bandwidth_popover.dart:77,87,106,276`.

### 1.2 Status-dot vocabulary

The two files are not copies.

Séance `server_status_dot.dart`: `ServerDot` {none, connected, connecting,
failed, blocked, reachable, unreachable}. `serverDotFor({TerminalStatus?
session, required ProbeStatus probe, bool hostKeyBlocked})` (:84-103): any
live session state paints (connected > connecting > error, and error reads
blocked iff `hostKeyBlocked`); a clean `disconnected` or no session defers
to the probe (online = ring reachable, offline = ring unreachable,
unknown = none, whose `description` is null, :41).
`aggregateSessionStatus` ranks connecting > connected > error >
disconnected across terminal tabs (:108-119). Colors come from
`StatusColors` {online, offline, connecting, unknown}
(`theme.dart:755-768`).

Poltergeist `server_state_indicator.dart`: `ServerIndicatorGlyph` {none,
probe, pending, connected, idle, failed, blocked} with two rules.
`railIndicatorOf` (:76-88) lets every non-idle connection state outrank
the probe, then delegates to the list rule: identical to Séance.
`serverIndicatorOf` (list rule, :51-67) keeps the probe's own indicator
wherever connection truth does not contradict it: blocked/failed always
outrank, connected outranks only when the probe is not online, and
pending/idle never outrank (`_outranksProbe`, :99-104). `ServerStateGlyph`
paints pending as a spinner, idle as a `statusUnknown` dot, failed as a
`statusFailed` dot, blocked as `Icons.gpp_bad`, and probe as nothing (the
caller paints the reachability dot). Colors from `PoltergeistChrome`
statusConnected / statusConnecting / statusFailed / statusUnknown
(`app_theme.dart:314-330`, fields :351-354). The rail paint map in
`sidebarServerIndicator` (`sidebar_view.dart:948-968`) is Séance's
`style`/`color` map (:60-74) verbatim.

What is shared: the precedence algebra and the paint vocabulary
(`SidebarDotStyle`/`SidebarStatusDot` already live in `ghost_ui`,
`sidebar_kit.dart:1210-1230`). The algebra is not one rule: Séance's dot
paints connected > connecting > error, its `aggregateSessionStatus` ranks
connecting > connected, Poltergeist's list rule preserves the probe and
its rail rule lets connection truth override it. The package exposes each
as a named rule and every app surface maps to exactly the rule it uses
today, so no surface changes behaviour in the move. What diverges: the truth inputs
(`TerminalStatus` is seance_app `app_state.dart:34`; `ServerStatus`/
`ServerConnectionState` are poltergeist_core `connection_manager.dart:18-58`;
`ProbeStatus` is seance_core `probe_service.dart:14`), the list-vs-rail
rule split, and Poltergeist's pending spinner / blocked icon, which belong
to the pane-tab surface and stay app-side. None of the three truth types
is in the permitted dependency set, so the shared rule consumes neutral
inputs (§3).

### 1.3 Server sectioning

Séance `server_grouping.dart` is Flutter-free and already neutral except
its `seance_core` import, used only for protocol symbols. Rules: pinned
section first (`kPinnedKey = ' pinned'`), pinned servers removed from
their ordinary groups rather than duplicated, ungrouped before named
groups, groups keyed by `normalizeServerGroup`/`serverGroupKey`
(case-insensitive, leading-space keys cannot collide with real group
names), sorted, display spelling from the first member; `serverListRows`
flattens sections to row models; `sectionsHoldingLive` keeps headers that
hide live rows during filtering; `hiddenByHeader` computes the collapsed
count.

Poltergeist's sectioning is inline in `sidebar_servers_section.dart`: the
same key function and sort (:30-50, :99), the same pinned de-dup, plus
app-owned concerns (ad-hoc live sessions, favorites, saved-remote
filtering, `_hiddenLive` aggregation :338-363) and sidebar-only row types.
Its collapse keys are namespaced `srv:` + group key by
`SidebarCollapseKeys.serverGroup` (`sidebar_controller.dart:22`, migrate
:56-72).

Constraint: Séance persists `serverGroupKey` values including `' pinned'`
and `' servers'` in `collapsedServerGroups`; the literal key values must
not change in the move.

### 1.4 Prompts

Host key: near-identical. Both render first-use vs changed-key variants
with host/port, key type, SHA-256 fingerprint and prior fingerprint, a
route-current guard before popping, `AlertDialog(scrollable: true)`, and
the same changed-key decision at the dialog boundary: Séance reads
`decision.isChanged` (`host_key_dialog.dart:9`, verdict-based at
`tofu.dart:25`), Poltergeist reads `data.pinnedFingerprintSha256 != null`
(:20). The two agree because trusted decisions never reach the dialog
(`ssh_session.dart:130` returns before prompting) and first-use carries no
pinned key (`tofu.dart:47`). Poltergeist adds
`dialogKey` for coordinator dismissal and ARB strings. `PORTS.md` records
the file as a Séance port whose route-guard and scrollable fixes were
ported back; no divergence remains except payload type, strings, and the
dialog key.

Keyboard-interactive: structurally the same dialog (title, trusted
endpoint, request source, optional name/instruction, one obscured field
per prompt with reveal toggle, Cancel/Submit). Divergences: Séance builds
the endpoint inline with IPv6 bracketing (:18-25); Poltergeist formats via
`credentialEndpoint` ARB (:25-36); Poltergeist adds `textInputAction` +
`onSubmitted` next-focus/submit (:126-131) and `dialogKey`.

Credential: not a copy. Séance `showMissingCredentialDialog` returns
`MissingCredential?` ({MissingPassword} / {MissingPrivateKey(pem,
passphrase)}); key material is pasted PEM or picked via
`private_key_file.dart`; saving is implicit in the recovery flow
(`terminal_pane.dart:1522-1548` -> `app_state.dart:2739+`). Poltergeist
`showCredentialDialog` returns `CredentialDialogResult` with
password/privateKeyPem/keyPassphrase/saveToVault; key material is an
identity-file path read on submit through an injected `readKeyFile`
(audited by `identity_file_reader.dart:10-57`), with a vault-unavailable
banner and an opt-in save-to-vault checkbox gated on `secretRef` (:157,
:231-240). One parameterized shared dialog covers both: the key-input mode
(pasted PEM vs file path), the vault affordances, and the I/O callbacks
are the seams; the result types stay app-side.

### 1.5 Connection log view and test report

The two dedicated copies are verbatim twins: `ExpansionTile` titled
"Connection log", copy button, `(no log captured)` placeholder, monospace
`SelectableText` in nested scroll views. Differences: strings source
(literals vs ARB) and copy-failure reporting (`dart:developer` vs
`ApplicationErrorReporter`); both toast via `showTopToastIn` (already in
`ghost_ui`). A third copy lives inside
`connection_status_panel.dart:247-298` and differs further: line-list
input, `reverse: true` (follow-the-tail), no font fallback, silent copy.
The redaction contract is producer-side (`SshConnectionLog` is written
through `redactConnectionTrace`, `ssh_session.dart:318`); the widget only
ever sees text.

Test report: 66 vs 71 lines, identical layout (success/failure icon +
summary + notes + embedded log); only strings differ.

### 1.6 Byte and rate formatters

`ghostFormatFileSize` (ghost_ui, `ghost_file_format.dart:23-50`) is
decimal on macOS/Linux and binary-divisor on Windows; it stays as is
(F4's "stays decimal" means its platform convention is preserved).

Poltergeist's app-local rate formatter is `activity_format.dart:18-84`:
`formatTransferRate`/`formatTransferLimit` format through `formatPaneSize`
(i.e. `ghostFormatFileSize`) plus `/s`; `formatTransferEta` renders
`s`/`m s`/`h m`/`d h`; `parseTransferRate` parses `[magnitude][unit][/s]`
with an over-range rejection contract (`activity_format_test.dart`
asserts `'9'*400` parses to null). `TransferRateTracker`
(`services/transfer_rate_tracker.dart`, 109 lines) is measurement state,
not presentation; it stays app-side. Klabautermann needs true IEC binary
formatters (`KiB`/`MiB`/`GiB`, divisor 1024 on every platform), which do
not exist anywhere today.

### 1.7 What stays app-side

- Truth types and their producers: `TerminalStatus`/`TerminalSession`
  (seance_app), `ServerStatus`/`ServerConnectionState`/`ProbeStatus` (the
  cores), `hostKeyBlocked`/`missingCredentialServerId` bookkeeping
  (`app_state.dart:156-161, :1589-1590, :2438-2439`).
- Poltergeist prompt lifecycle: `PromptCoordinator` queue/dismissal/
  `dialogKey` ownership (442 lines), `PromptBridge`, engine protocol
  types (`protocol.dart:129-168, :262-387`).
- Credential policy: `private_key_file.dart` (file_picker), audited
  `identity_file_reader.dart`, vault save and its failure handling,
  `provideMissingCredential` recovery, the "Use SSH agent" and
  open-server-editor actions (`terminal_pane.dart:1620`).
- Sidebar presentation: collapse state (`SidebarCollapseKeys`), ad-hoc
  sessions, favorites/bookmarks, `countRow`/`sidebarQueryMatches`
  (`sidebar_facts.dart:159`, `sidebar_view.dart:836-838`), `server_tile`
  mark ring and semantics, `ServerStateGlyph` paint (spinner, blocked
  icon), `_PaneRemoteIndicator`.
- Session/log wiring: `terminal_pane.dart:1697-1712` notifier wrapper,
  `connection_status_panel.dart:101-117` event subscription,
  `ConnectionLogEvent` batching (`protocol.dart:132-143`).
- `server_filter.dart` (Séance) and `sidebarQueryMatches` (Poltergeist):
  haystacks differ per app and `serverSearchHaystack` is already
  protocol-level; nothing to move.
- `parseTransferRate`'s cap `maxTransferRateBytesPerSecond` (policy) and
  `TransferRateTracker`.

### 1.8 Tests and pixel baselines

| Surface | Séance | Poltergeist |
|---|---|---|
| Status dots | `server_status_dot_test.dart` (150) | `server_state_indicator_test.dart` (375), `sidebar_server_dot_test.dart` (130) |
| Sectioning | `server_grouping_test.dart` (422), `server_group_header_test.dart` (190) | `sidebar_catalog_test.dart` (849), `sidebar_view_test.dart` (2660) |
| Host key | `host_key_dialog_test.dart` (312), `host_key_blocked_test.dart` (235) | `prompts/host_key_dialog_test.dart` (162) |
| Keyboard | `keyboard_interactive_dialog_test.dart` (321) | `prompts/keyboard_interactive_dialog_test.dart` (285) |
| Credential | `credential_prompt_test.dart` (129), `credential_required_test.dart` (201) | `prompts/credential_dialog_test.dart` (371), `prompt_coordinator_test.dart` (912), `identity_file_reader_test.dart` (175) |
| Log + report | `connection_test_report_test.dart` (133) | `connection_status_panel_test.dart` (410) |
| Formatters | none | `activity_format_test.dart` (36), `pane_format_test.dart` (274) |
| Pixel/golden | `server_list_capture_test.dart` (454), `server_tile_test.dart` (592), `server_list_pane_test.dart` (907) | `sidebar_capture_test.dart` (445), `activity_panel_capture_test`, `sidebar_view_test.dart` |

Both apps gate on `flutter analyze` + the full `flutter test` suite per
product AGENTS; the capture suites above are the pixel baselines that must
pass unchanged in each switch PR.

### 1.9 Shared anchors

- `seance_protocol` already owns every type the shared code needs:
  `ServerConfig`/`AuthMethod` (`server_config.dart:5`),
  `normalizeServerGroup` (:439), `serverGroupKey` (:507),
  `existingServerGroups` (:511), `serverSearchHaystack` (:527), `HostKey`
  (`host_key.dart:13`). `ghost_marks` already depends on it.
- `ghost_ui` owns `SidebarDotStyle`/`SidebarStatusDot`,
  `SidebarKitStrings`, `showTopToastIn`, and `ghostFormatFileSize`.
- `localization_contract_test.dart` scans `Directory('lib')` (:2738)
  against an allowlist (:17); a keep-live test (:2686-2693) asserts every
  allowlisted literal still exists in its file, so moved literals force
  same-PR allowlist edits rather than leaving silent dead entries.
- `poltergeist/docs/PORTS.md` ledger entries exist for the host-key
  (:464), keyboard-interactive (:512), connection log (:1045) and test
  report (:1054) ports, and already mark earlier extractions as moved to
  `ghost_ui` (e.g. :999).

## 2. Package proposal

New package `planchette/packages/ghost_servers` (Flutter, like `ghost_ui`):

```yaml
dependencies:
  flutter:
    sdk: flutter
  ghost_ui:
    path: ../ghost_ui
  seance_protocol:
    path: ../../../seance/packages/seance_protocol
dev_dependencies:
  flutter_test:
    sdk: flutter
```

`ghost_marks` is permitted by D8 but nothing in part 1 draws a server
badge; do not declare it until a consumer exists (the shared row widget is
part 2). No plugin deps: file picking and identity-file reads are
injected callbacks. Add the package to `scripts/test.sh`'s Flutter package
lists (:141-151) and to both app pubspecs as a path dependency.

Barrel `ghost_servers.dart` exports `server_status.dart`,
`server_grouping.dart`, `host_key_dialog.dart`,
`keyboard_interactive_dialog.dart`, `credential_dialog.dart`,
`connection_log_view.dart`, `connection_test_report.dart`.

`ghost_ui` gains `src/ghost_rate_format.dart` (exported from the barrel):
new IEC binary formatters, used by Klabautermann, plus the moved
transfer-rate helpers, which keep formatting through `ghostFormatFileSize`
and its platform convention, so Poltergeist's strings stay byte-identical;
`ghostParseByteRate` takes the cap as a required parameter, so the cap
stays app policy while the over-range contract (`'9'*400` parses to null)
moves with the function and its test. The boundary
holds: every `seance_core`/`poltergeist_core` type crosses as a neutral
record or a callback; §3 proves the VM shapes are sufficient because
Poltergeist's isolate boundary already requires exactly this shape.

## 3. Neutral view models (the `seance_core` boundary)

| Core/app type (location) | Neutral model | Mapping owner |
|---|---|---|
| `HostKeyDecision` (`seance_core/lib/src/hostkey/tofu.dart:9-26`) | `GhostHostKeyPrompt {host, port, keyType, fingerprintSha256, pinnedFingerprintSha256?; bool get isChanged => pinnedFingerprintSha256 != null}` | Séance: `decision.presented` (a protocol `HostKey`) + `decision.pinned?.fingerprintSha256`; Poltergeist: `HostKeyPromptData` field-for-field (`server_editor_backend.dart:269-279` already does this) |
| `KeyboardInteractiveChallenge` (`ssh_session.dart:95-107`) | `GhostKeyboardPrompt {username, host, port, name, instruction, prompts: List<String>}` | Séance: `challenge.server` fields; Poltergeist: `KeyboardInteractivePromptData` (:306-322) |
| `SshConnectionLog` (`ssh_session.dart:143-197`) / `ConnectionLogEvent` (`protocol.dart:132-143`) | plain `String` (`log.toString()` / `lines.join('\n')`) | adapter at each call site; the widget never sees the log object, preserving the producer-side redaction contract |
| `ConnectionTestResult` (`test_connection.dart:120-147`) | `GhostTestReport {ok, summary, notes, log}` | field-for-field at `server_editor` call sites in each app |
| `TerminalStatus`+`hostKeyBlocked` / `ServerStatus` / `ProbeStatus` | `GhostSessionState {none, connecting, connected, idle, failed, blocked}` + `GhostProbeState {unknown, online, offline}` | per-app adapters, table below |
| `MissingCredential` / `CredentialDialogResult` | `GhostCredentialReply {password?, privateKeyPem?, keyPassphrase?, saveToVault}` | app types stay; adapters convert the reply |

Session-state mapping (preserves today's behavior exactly):

- Séance: `connecting`->connecting, `connected`->connected,
  `error`+`hostKeyBlocked`->blocked, `error`->failed,
  `disconnected`->idle, no session->none.
- Poltergeist: `connecting`/`reconnecting`->connecting,
  `connected`->connected, `disconnected` with detail->failed, without
  detail->idle, `blocked`->blocked.
- Probe: `online`/`offline`/`unknown` 1:1.

Resolution rules carried verbatim (`GhostIndicatorRule` selects between
them):

- rail rule (Séance's only rule, `serverDotFor` :89-102; Poltergeist
  `railIndicatorOf` :76-88): any session state other than idle/none paints
  its glyph (connected; connecting, which Poltergeist pending and
  reconnecting map into; failed; or blocked, reached by Séance `error` +
  `hostKeyBlocked`); idle or no session defers to the probe: online ->
  reachable, offline -> unreachable, unknown -> none.
- list rule (Poltergeist `serverIndicatorOf` :51-67 plus `_outranksProbe`
  :99-104): blocked/failed always outrank; connected outranks only when
  the probe is not online (a connected transport beside a "reachable" ring
  would be redundant); connecting/idle/none never outrank, so probe truth
  renders, and where no probe exists the connection appearance or none
  does. This is why a Poltergeist list row shows the reachability ring for
  a connected, probe-online server where Séance shows a solid dot; the
  divergence is preserved, not unified.
- paint map, identical in both apps (Séance `style`/`color` :60-74 and
  Poltergeist `sidebarServerIndicator` :948-968): connected -> solid·online,
  connecting -> solid·connecting, failed -> solid·offline, blocked ->
  blocked-style·offline, reachable -> ring·online, unreachable ->
  ring·offline, idle/none/unknown-probe -> no dot. Labels differ only
  through the strings bag: Séance has no probe-unknown or idle label
  (`none` -> null), Poltergeist has `probeStatusUnknown` and
  `connectionStateNotConnected`.

## 4. String injection

Each strings bag is a plain final class; defaults are Séance's current
literals so the Séance adapter passes nothing. Poltergeist's adapter maps
members to ARB getters. The endpoint formatter member receives the host
already bracketed by the package (IPv6), so the `[`/`]`/`:` literals move
out of both apps.

| Bag member | Séance literal | Poltergeist ARB key |
|---|---|---|
| `GhostHostKeyStrings`: unknownTitle | `Unknown host key` (:30) | `hostKeyUnknownTitle` (:68) |
| changedTitle | `HOST KEY CHANGED` | `hostKeyChangedTitle` (:72) |
| changedWarning(host) | same text (:44-46) | `hostKeyChangedWarning` (:76) |
| endpoint(host, port) | `{host}:{port}` (:50) | `hostKeyEndpoint` (:85) |
| fingerprint/newKey/previous labels | (:53, :58-59) | `hostKeyFingerprintLabel`/`NewLabel`/`PreviousLabel` (:97-105) |
| cancel / trustConnect / trustNewKey | (:68, :77) | `hostKeyCancel`/`TrustConnect`/`TrustNewKey` (:109-117) |
| `GhostKeyboardInteractiveStrings`: title | `Authentication` (:77) | `keyboardAuthTitle` (:121) |
| requestFrom / serverMessage | (:83, :94) | `keyboardRequestFrom`/`ServerMessage` (:125, :129) |
| submit / cancel / showAnswer / hideAnswer | (:138, :134, :118) | `keyboardSubmit`/`Cancel`/`ShowAnswer`/`HideAnswer` (:133-145) |
| endpoint(username, host, port) | `'$u@$h:$p'` (:18-25) | `credentialEndpoint` (:153) |
| `GhostCredentialStrings`: title(label) | `Private key for …`/`Password for …` (:89-93) | `credentialTitle` (:149) + `credentialEndpoint` line |
| explanation | `Saved on this device…` (:101-104) | none (null) |
| passwordField / passphraseField | `Password`, `Key passphrase (if it has one)` | `credentialPasswordField` (:168), `credentialPassphraseField` (:180) |
| keyPemField / chooseKeyFile | `Private key (PEM)`, `Choose key file…` | none (path mode) |
| keyFileField / keyFileRequired / keyFileUnreadable / keyFileReadError(e) | pick error `That file could not be opened.` (:66) | `credentialKeyFileField`/`Required`/`Unreadable`/`ReadError` (:172-204) |
| saveInVault / vaultUnavailable | none | `credentialSaveInVault` (:184), `credentialVaultUnavailable` (:196) |
| connect / cancel | `Save and connect`, `Cancel` (:171-175) | `credentialConnect`/`credentialCancel` (:188, :192) |
| `GhostConnectionLogStrings`: title/copy/copied/copyFailed/empty | (:32-90) | `connectionLogTitle`/`Copy`/`Copied`/`CopyFailed`/`Empty` (:233-243, :8388-8404) |
| `GhostConnectionTestStrings`: succeeded/failed | (:36-38) | `connectionTestSucceeded`/`Failed` (:8408-8412) |
| `GhostServerStatusStrings`: connected/connecting/failed/blocked/notConnected/probe*/hidden*/blockedDetail | `Connected`, `Connecting`, `Connection failed`, `Connection blocked`, `Host reachable`, `Host unreachable`, blocked detail (:40-56) | `connectionStateConnected` (:642), `Connecting` (:213), `Reconnecting` (:217), `NotConnected` (:646), `connectionFailedTitle` (:221), `connectionBlockedTitle` (:225), `probeStatus*` (:630-638), `sidebarHidden*` (:7829-7837) |
| `GhostServerSectionLabels`: pinned/servers | `Pinned`, `Servers` | `sidebarPinnedSection` (:9852), `sidebarServersSection` (:9844) |

No wording is unified: where the two apps say the same thing differently
(e.g. Séance's blocked detail vs `connectionsBlockedWarning`), each keeps
its string through the bag.

Dead allowlist bookkeeping (same PR as the file move, enforced by the
keep-live test :2686-2693):

- `lib/ui/prompts/keyboard_interactive_dialog.dart` (:20-25): dies
  entirely (`':'`, `'['`, `']'`, `'[$rawHost]'` all move into the
  package's endpoint formatter).
- `lib/ui/prompts/host_key_dialog.dart` (:649): dies (`'monospace'`,
  `'$type\n$value'` move into the shared `_Fingerprint` row).
- `lib/ui/prompts/credential_dialog.dart` (:622): dies (`''`,
  `'monospace'`).
- `lib/ui/connection_log_view.dart` (:2476-2480): dies (`'monospace'`,
  `'Consolas'`, `'Menlo'`, `'Courier New'`).
- `lib/ui/connection_status_panel.dart` (:621): shrinks to `{"'\\n'"}`
  (the panel still joins lines itself).
- `lib/ui/activity/activity_format.dart` (:1869-1897): shrinks; the two
  `/s` interpolations, three ETA literals, `','`, `'.'`, the eight unit
  literals and the regex move to `ghost_ui`; the path/route literals
  (`'/'`, `'\\'`, `'$candidate/'`, `'$path/'`, the endpoint/path
  interpolations, `'→'`) stay.
- Unchanged: `server_state_indicator` (:1448-1451; assert strings stay
  with `ServerStateGlyph`), `sidebar_servers_section` (:1546+; all keys
  and endpoint joins stay app-side), `prompt_coordinator` (:615-618).

## 5. Public API

```dart
// src/server_status.dart
enum GhostSessionState { none, connecting, connected, idle, failed, blocked }
enum GhostProbeState { unknown, online, offline }
enum GhostIndicatorRule { list, rail }
enum GhostServerGlyph { none, connecting, connected, idle, failed, blocked, reachable, unreachable }
enum GhostStatusTone { online, connecting, offline, unknown }

final class GhostServerIndicator {
  const GhostServerIndicator({required this.glyph, required this.style,
      required this.tone, required this.label, this.detail});
  final GhostServerGlyph glyph;
  final SidebarDotStyle style;      // ghost_ui: solid | ring | blocked
  final GhostStatusTone? tone;
  final String label;
  final String? detail;
}

GhostServerIndicator ghostServerIndicator(GhostServerStatusStrings strings,
    GhostIndicatorRule rule, {required GhostSessionState session,
    required GhostProbeState probe});
GhostSessionState ghostAggregateSession(Iterable<GhostSessionState> states);
GhostServerIndicator? ghostHiddenLiveIndicator(GhostServerStatusStrings strings,
    Iterable<GhostSessionState> live);

final class GhostStatusColors {        // host palette; adapters map
  const GhostStatusColors({required this.online, required this.connecting,
      required this.offline, required this.unknown});
  final Color online, connecting, offline, unknown;
}
SidebarStatusDot? ghostStatusDot(GhostServerIndicator i, GhostStatusColors c);

// src/server_grouping.dart: moved verbatim from Séance; names kept.
const String kPinnedKey = ' pinned';
const String kServersKey = ' servers';
final class GhostServerSectionLabels {
  const GhostServerSectionLabels({this.pinned = 'Pinned', this.servers = 'Servers'});
  final String pinned, servers;
}
ServerSidebarSections groupServers(List<ServerConfig> servers,
    {Set<String> pinnedIds = const {}});
// Added for Klabautermann's fleet rows (plan P3): the neutral input. The
// sections and rows are generic over the row type, and the Server... names
// are typedefs of their ServerConfig instantiations.
final class GhostServerEntry {
  const GhostServerEntry({required this.id, this.group});
  final String id; final String? group;
}
GhostServerSections<T> groupServerEntries<T>(List<T> servers,
    GhostServerEntry Function(T server) entryOf,
    {Set<String> pinnedIds = const {}});
List<GhostServerListRow<T>> serverListRows<T>(
    {required GhostServerSections<T> sections,
    required Set<String> collapsed, ...,
    GhostServerSectionLabels labels = const GhostServerSectionLabels()});
Set<String> sectionsHoldingLive<T>(...);  int hiddenByHeader(...);

// src/host_key_dialog.dart
Future<bool> showGhostHostKeyDialog(BuildContext context,
    GhostHostKeyPrompt prompt,
    {GhostHostKeyStrings strings = const GhostHostKeyStrings(),
    GlobalKey? dialogKey});

// src/keyboard_interactive_dialog.dart
Future<List<String>> showGhostKeyboardInteractiveDialog(BuildContext context,
    GhostKeyboardPrompt prompt,
    {GhostKeyboardInteractiveStrings strings = const GhostKeyboardInteractiveStrings(),
    GlobalKey? dialogKey, bool submitOnEnter = true});

// src/credential_dialog.dart (as built in PR 6a and 6c; see the notes
// after this block)
enum GhostKeyField { pastedPem, filePath, passphraseOnly }
final class GhostCredentialRequest {
  const GhostCredentialRequest({required this.authMethod,    // AuthMethod, seance_protocol
      required this.endpointLabel, required this.keyField,
      this.username, this.host, this.port, this.initialKeyPath,
      this.offerVaultSave = false, this.vaultUnavailable = false});
}
sealed class GhostCredentialReply { final bool saveToVault; }
final class GhostPasswordReply extends GhostCredentialReply {
  final String password; }
final class GhostPrivateKeyReply extends GhostCredentialReply {
  final String privateKeyPem; final String? keyPassphrase; }  // never ''
final class GhostKeyPassphraseReply extends GhostCredentialReply {
  final String keyPassphrase; }                                // never ''
Future<GhostCredentialReply?> showGhostCredentialDialog(BuildContext context,
    GhostCredentialRequest request,
    {GhostCredentialStrings strings = const GhostCredentialStrings(),
    Future<String?> Function()? pickKeyText,          // Séance: file_picker
    Future<String> Function(String path)? readKeyFile, // Poltergeist: audited read
    required TextStyle monoStyle, GlobalKey? dialogKey,
    bool barrierDismissible = false});
// The injector matching request.keyField is required: pastedPem needs
// pickKeyText, filePath needs readKeyFile; a missing one throws
// ArgumentError before the dialog opens, and the other is ignored.
// passphraseOnly takes neither: passing either throws ArgumentError, as
// does a privateKey request without an initialKeyPath to show.

// src/connection_log_view.dart
class GhostConnectionLogView extends StatelessWidget {
  const GhostConnectionLogView({required this.text,
      this.strings = const GhostConnectionLogStrings(),
      this.reverse = false, this.followTail = false,
      this.onCopy, this.onCopyError})
      : assert(!reverse || !followTail,
            'reverse (newest first) and followTail are exclusive');
  /// Poltergeist's panel renders newest-first (`reverse: true`,
  /// `connection_status_panel.dart:283`) and never passes followTail;
  /// Séance's views follow the tail with reverse left false.
  final bool reverse;
}

// src/connection_test_report.dart
final class GhostTestReport {
  const GhostTestReport({required this.ok, required this.summary,
      required this.log, this.notes = const []});
}
class GhostConnectionTestReport extends StatelessWidget {
  const GhostConnectionTestReport({required this.report,
      this.strings = const GhostConnectionTestStrings(),
      this.logStrings = const GhostConnectionLogStrings(), this.onCopyError});
}

// ghost_ui: src/ghost_rate_format.dart
String ghostFormatBinarySize(int? bytes);                    // 1024, B/KiB/MiB/GiB/TiB
String ghostFormatBinaryRate(num bytesPerSecond);            // binary size + '/s'
String ghostFormatByteRate(num bytesPerSecond,               // moved: platform
    {required TargetPlatform platform});                     //   convention + '/s'
String ghostFormatCompactEta(Duration eta);                  // moved formatTransferEta
int? ghostParseByteRate(String input, {required int maxBytesPerSecond});
```

The credential prompt as built differs from the first draft above in
these ways (PR 6a; the amendment came with PR 6c):

- Each key field carries its app's whole form, not only the key input.
  The two prompts differ in more than §1.4 lists: the layout (a fixed
  520-wide content with an inner scroll, or a scrollable `AlertDialog`),
  the secret fields' IME flags, when the answer is enabled, whether the
  verbs check that the dialog's route is current, and how an error
  renders. Converging them is a behaviour change, so every divergence is
  an exhaustive `switch` on the key field.
- The reply is sealed, not the §3 record of nullable fields, so each
  adapter switches exhaustively and an unmapped later variant fails to
  compile.
- `keyField` is required rather than defaulting to `filePath`: it picks
  the whole form and the injector that must be passed.
- `GhostCredentialStrings` has one `keyFileError(Object error)` member
  instead of `keyFileUnreadable` plus `keyFileReadError(e)` (§4). The
  package cannot see Poltergeist's `IdentityFileReadException`, so the
  host decides what of an error it shows. The default is Séance's rule:
  a `FormatException`'s message, otherwise "That file could not be
  opened."
- `barrierDismissible` defaults to false, like the other two shared
  prompts and Poltergeist; Séance passes true to keep its behaviour.
  `monoStyle` is required and injected (the host's monospace stack).
- The endpoint line receives the host as configured, without IPv6
  brackets, because Poltergeist's credential dialog shows the raw host.

`GhostKeyField.passphraseOnly` (PR 6c) is for a host whose engine reads
key files itself, as Klabautermann's does (its credential source records
each read in `identity_reads.jsonl`), so the UI never sends key text
across the isolate. It shows `initialKeyPath` read-only, in the mono
style under the `keyFileField` label, and asks only for the passphrase;
the answer is `GhostKeyPassphraseReply`, which carries no key text. It is
a new form, so it decides each detail the other two keep from their
apps:

- Layout and verbs: a scrollable `AlertDialog`; Cancel and the answer act
  only while the dialog's route is current.
- Secret field: obscured, autofocused, suggestions, autocorrect and IME
  learning off, and no reveal toggle, as in the other two forms.
- Empty input: the answer is disabled, and Enter does nothing, until the
  secret is typed. A key without a passphrase never needs this prompt,
  and an empty passphrase cannot open one that has one.
- Injectors: rejected rather than ignored, since a host passing a picker
  or reader expects key text back.
- A password request in this mode is the same form with a password field
  and a `GhostPasswordReply` under the same empty-input rule, so one host
  form serves both methods.
- Words: `keyPassphraseTitle(label)` ("Key passphrase for …") and
  `keyPassphraseField` ("Passphrase") join the bag; the existing
  `passphraseField` says "(if it has one)", which does not fit a required
  passphrase. The vault offer and banner behave as in the other forms.
- Séance's adapter maps the new reply to a `StateError`, since it only
  ever asks for a pasted key. Klabautermann's adapter comes with K45b.

Adapters. One per app, holding the bags and every core-type conversion:

- `seance_app/lib/ui/ghost_servers_adapter.dart`: `seanceGhostServerStrings`
  (defaults; no bag needed beyond the consts), `serverDotFor` reimplemented
  as TerminalStatus/ProbeStatus/hostKeyBlocked -> neutral ->
  `ghostServerIndicator(rail)`, `aggregateSessionStatus` ->
  `ghostAggregateSession`, `showHostKeyDialog(context, HostKeyDecision)` ->
  VM + `showGhostHostKeyDialog`, same for keyboard challenge and
  `showMissingCredentialDialog` (reply -> `MissingCredential`), log/report
  wrappers injecting `onCopyError: developer.log`.
- `poltergeist_app/lib/ui/ghost_servers_adapter.dart`: `ServerStatus`/
  `ProbeStatus` mapping, `serverIndicatorOf`/`railIndicatorOf` delegates
  resolving labels through `AppLocalizations`, `HostKeyPromptData`/
  `KeyboardInteractivePromptData`/`CredentialPromptData` -> VM (replacing
  the dialog bodies; coordinator call sites unchanged), ARB-backed bags,
  `ApplicationErrorReporter` copy-error hook.

Former per-surface files become thin delegates at their existing paths
(export shims where call sites are many: `server_grouping.dart`, the two
connection views, `server_state_indicator.dart`), so intra-app imports do
not churn.

## 6. Migration plan (one monorepo, staged PRs)

Each PR moves code and switches at least one shipped app with its full
suite and pixel baselines unchanged (D3). Behavior changes ride separate
PRs; the only deliberately deferred one is the keyboard `submitOnEnter`
flag (Séance passes `false` in PR 4 to keep its current focus behavior,
flips in a follow-up with its own test).

| PR | Contents | Switches | Gates |
|---|---|---|---|
| 1. Formatters | `ghost_ui` `ghost_rate_format.dart` + tests; Poltergeist `activity_format.dart` delegates rate/limit/ETA/parse (cap stays app policy); allowlist :1869-1897 shrinks in the same PR | Poltergeist | Poltergeist full suite; `activity_panel_capture_test`, `pane_format_test` unchanged; `activity_format_test` rate/ETA cases move to ghost_ui tests |
| 2. Sectioning | `ghost_servers` skeleton; `server_grouping.dart` moves verbatim (import repoint to `seance_protocol`); `serverListRows` gains `labels`; Séance file -> export shim; Poltergeist adopts `groupServers` in `sidebar_servers_section.dart:30-50` (`_ServerGroup` deleted; collapse keys unchanged via `SidebarCollapseKeys.serverGroup`) | Both | Séance suite + `server_list_capture_test`; Poltergeist suite + `sidebar_capture_test`/`sidebar_catalog_test`; `server_grouping_test` (422) moves to the package |
| 3. Status dots | `server_status.dart` + `ghostStatusDot` + bags; both adapters; `serverDotFor`/`aggregateSessionStatus`/`serverIndicatorOf`/`railIndicatorOf` become delegates; `ServerStateGlyph` stays app-side (pane-tab paint) | Both | Séance suite (status/dot/list/tile tests + captures); Poltergeist suite (`server_state_indicator_test` splits: resolution cases to package, ARB/paint stay); `sidebar_capture_test` unchanged |
| 4. Host-key + keyboard prompts | VMs, dialogs, bags; `dialogKey` for both; Séance `main.dart:148-158` and `terminal_pane` wiring call adapters; Poltergeist `prompt_coordinator:241,262` maps `*PromptData` -> VM; Séance passes `submitOnEnter: false` | Both | Séance suite (dialog tests move to package; `host_key_blocked_test`/`credential_required_test` unchanged); Poltergeist suite (prompt tests keep adapter+ARB coverage); allowlist :20-25 and :649 removed in this PR |
| 5. Log view + test report | `GhostConnectionLogView`/`GhostConnectionTestReport` + bags; panel `_ConnectionLogView` delegates with `reverse: true` + silent `onCopy`; dedupe the duplicate `connectionLog*` ARB block (:233-243, keep :8388-8404); allowlist :2476-2480 removed, :621 shrunk | Both | Séance suite (`connection_test_report_test` moves); Poltergeist suite (`connection_status_panel_test` unchanged); PORTS entries updated to the "now live in ghost_servers" wording |
| 6. Credential prompt | Parameterized dialog + bags + reply; Séance adapter (`pastedPem`, `pickKeyText` injected, reply -> `MissingCredential`); Poltergeist adapter (`filePath`, `readKeyFile`, `vaultUnavailable`, `saveToVault`, reply -> `CredentialDialogResult`); allowlist :622 removed | Both | Séance suite (`credential_prompt_test` moves, `credential_required_test` unchanged); Poltergeist suite (`credential_dialog_test` adapts to the shim signature; `prompt_coordinator_test`/`identity_file_reader_test` untouched); no vault/audit/file code moves |
| 7. Audit | `PORTS.md` ledger updates; record `ghost_servers` as a new path consumer of `seance_protocol`; `scripts/test.sh` lists verified (:141-151); boundary check as an allowlist: the only package imports under `planchette/packages/ghost_servers/` are `ghost_ui` and `seance_protocol` besides the Flutter and Dart SDKs, which also excludes `seance_core`, `poltergeist_core` and `dartssh2` | none | Both full suites; contract test green; Séance pin-audit not required (no `seance/` lineage change) |

Poltergeist switches per surface inside PRs 2-6 rather than in one big PR,
because its adapters are per-surface and the capture suites then bisect
any pixel drift to a single surface.

## 7. Risks

1. Status precedence: the list-vs-rail split and the
   `disconnected`-with-detail distinction are easy to collapse
   accidentally; both rules move with their tests, and the neutral enum
   keeps `idle`/`reconnecting`->connecting explicit.
2. Changed-key semantics: `isChanged` as `pinnedFingerprintSha256 != null`
   is only valid because trusted decisions never reach the dialog
   (`ssh_session.dart:130`); the VM doc comment must state that invariant.
3. Credential divergence: forcing one UX would break either the recovery
   flow or the vault contract; the parameterization (key field, vault
   flags, injected I/O) is load-bearing, not optional.
4. Redaction: the log view accepts `String` only; a `List<String>` or
   log-object API would invite unredacted writes past
   `redactConnectionTrace`.
5. Persisted keys: `' pinned'`/`' servers'`/`srv:` prefixes live in user
   prefs on both apps; the literals move unchanged.
6. Localization: duplicate `connectionLog*` ARB keys (§8.6) and the
   keep-live allowlist test make same-PR bookkeeping mandatory.
7. Pixel drift: rail dots already paint through `SidebarStatusDot`, so the
   shared vocabulary should reproduce pixels exactly; the panel gains the
   font fallback list (`'monospace'` resolves on capture hosts, so
   baselines hold; flagged here as the one intentional normalization).
8. Boundary: `ghost_servers` must not gain a `seance_core` edge; every
   app-core symbol it consumes is protocol-level (§1.9), verified above.
   Its other dependencies are Flutter and `ghost_ui` (§2); PR 7's boundary
   check asserts that `ghost_ui` and `seance_protocol` are its only
   package dependencies.

## 8. Corrections to the plan

1. F4's row lists Poltergeist's sectioning as an equivalent of
   `server_grouping.dart`; no such file exists. It was ported, pruned, and
   deleted 2026-10-08 when `existingServerGroups` moved into
   `seance_protocol` (`PORTS.md` ledger, :810-846). The live logic is
   inline in `sidebar_servers_section.dart:10-363`. The shared helpers it
   uses (`normalizeServerGroup`, `serverGroupKey`) are already
   protocol-level, so the move only adds section/row models, not new
   dependencies.
2. "The status-dot vocabulary" is two vocabularies: `ServerDot`
   (7 values, one rule) vs `ServerIndicatorGlyph` (7 different values,
   two rules, a marker `probe` glyph and a spinner paint). The extraction
   is a neutral model plus adapters, not a file move; and none of the
   truth inputs (`TerminalStatus`, `ServerStatus`, `ProbeStatus`) is in
   the permitted dep set, which D8's wording does not mention.
3. The credential prompts are not copies and were never ported
   (no `PORTS.md` entry exists for them, unlike the other prompts):
   pasted-PEM + implicit save vs identity-path + audited read + opt-in
   vault. One parameterized dialog, not a verbatim port.
4. Three connection-log copies exist, not two: the panel's
   `_ConnectionLogView` (:247-298) diverges (lines input, `reverse: true`,
   silent copy, no font fallback), and `ConnectionStatusPanel` currently
   has no production mount site under `lib/` (only
   `connection_status_panel_test.dart` constructs it).
5. `ghostFormatFileSize` is not purely decimal: divisor is 1000 except on
   Windows where it is 1024 (`ghost_file_format.dart:23-30`). "Stays
   decimal" should read "keeps its per-platform convention"; it is not to
   be re-based on the new IEC formatter.
6. `app_en.arb` declares `connectionLogTitle`/`connectionLogCopy`/
   `connectionLogEmpty` twice (:233-243 and :8388-8404) with identical
   values and different `@` descriptions; the generated accessors exist
   once. The earlier block is dead weight, removed in PR 5.
7. The localization allowlist is not passive bookkeeping: the keep-live
   test (:2686-2693) fails on dead entries, so removal must land in the
   same PR as each move (already D3 policy; now with the mechanism named).
8. `transfer_rate_tracker.dart` is rate measurement state (109 lines, no
   UI); the formatter F4 targets is `activity_format.dart:18-84`. The
   tracker stays app-side.

## 9. Estimates and recommendation

- `ghost_servers` production: ~1,500 lines (grouping 301 verbatim; status
  resolution ~150 condensed from both apps; host-key ~120; keyboard ~165;
  credential ~270; log ~120; report ~80; VMs + strings bags ~300).
- `ghost_ui`: +~150 formatter lines, +~250 tests.
- Removed from apps: Séance ~1,024 production lines (all listed files
  become delegates/shims, ~140 adapter lines net new); Poltergeist ~915
  (725 dialog/view lines plus ~190 indicator/grouping internals, ~300
  adapter lines net new).
- Tests moving to packages: ~1,470 Séance lines (150+422+312+321+129+133)
  plus new package tests ~300; Poltergeist tests stay largely in place as
  adapter/ARB coverage.
- Sizing: PR 1 S, PR 2 M, PR 3 M, PR 4 M, PR 5 S-M, PR 6 L, PR 7 XS;
  total consistent with the plan's M (3-4 engineer-weeks).

Recommendation: proceed as staged. Two open points the plan left are
resolved here: the credential dialog is parameterized rather than unified
(Séance keeps paste/pick UX, Poltergeist keeps path + vault UX), and
`ghost_marks` is not declared until part 2 needs it. The one deferred
behavior change is Séance's keyboard `submitOnEnter`, flipped in a
follow-up PR with its own test per D3.
