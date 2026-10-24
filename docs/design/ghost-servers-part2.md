# Shared package design: `ghost_servers` part 2, the server editor

Scope: Klabautermann extraction row F5a (03-ARCHITECTURE.md section 3.5,
`docs/design/klabautermann/03-ARCHITECTURE.md:1832`; decisions D3, D8,
D18; the M5 plan's F5a section and decision P4). Part 2 of
`planchette/packages/ghost_servers`: the add/edit server form, a neutral
draft model, the delegate the form talks to, and a strings bag, with
Poltergeist switched. Klabautermann adopts it in M09a (FL-03,
`02-FEATURES.md:358`). Séance's switch is a follow-up with a delegate over
`AppState` (03:1832), optional and outside M5. Transfer limits stay in
Poltergeist; identity-file picking stays a host callback. The credential
save rules move to `seance_protocol` (section 6, F5a-1a).
Dependencies: `ghost_ui`, `ghost_marks`, `seance_protocol` (D8). No
`seance_core`, `poltergeist_core` or `dartssh2` edge.

Status: proposed for Klabautermann v1 (M5, F5a); approval under the owner's instruction of 2026-10-13 to implement the plan (`docs/design/klabautermann/06-EXECUTION.md:13-14`).

Main commit read: `11ee9db7`.

## 1. Inventory

### 1.1 Production files

| File | Lines | Contents |
|---|---|---|
| `poltergeist/app/poltergeist_app/lib/ui/server_editor.dart` | 1,491 | Port of Séance's editor (header :1-11). `ServerEditorDelegate` (:32-79), save rules (:81-215), `confirmSyncExclusion` (:223-243), `showServerEditor` (:247-261), `_ServerEditorState` (:272-1318), `_TransferLimitChoice` (:1323-1335), Return intent/action (:1339-1362), colour swatches (:1367-1491) |
| `poltergeist/app/poltergeist_app/lib/services/server_editor_backend.dart` | 269 | `ServerEditorBackend extends ServerEditorDelegate` (:28-247): catalog reads (:60-61), `FilePicker` (:70-77), vault read (:80-81), secret-then-config save (:90-93), transfer limits (:95-107), `testConnection` over `runConnectionTest` with a frozen jump-route snapshot (:115-199) and part 1 prompts (:212-246); `_EditorCredentialSource` (:252-269). Stays app-side |
| `seance/app/seance_app/lib/ui/server_editor.dart` | 1,297 | Séance original. Save rules (:17-159), `confirmSyncExclusion` (:167-190), `showServerEditor` with the recovery offer (:197-211), `_ServerEditorState` over `AppState` (:222-1143), Return intent/action (:1147-1170), swatches (:1175-1297) |
| `planchette/packages/ghost_servers/lib/src/*` | 1,949 | Part 1 as built: `server_status.dart` (371), `server_grouping.dart` (371), `host_key_dialog.dart` (231), `keyboard_interactive_dialog.dart` (265), `credential_dialog.dart` (711). Barrel exports these five (`ghost_servers.dart:12-16`) |
| `planchette/packages/ghost_marks/lib/src/*` | 1,951 | Already shared since 2026-10-08: `ServerTint` (:129-166), `ServerBadge`, `ServerAccentBar`, `serverColorLabel` (:786), `showServerColorPicker` (`server_color_picker.dart:16-23`), `showServerMarkPicker` (`server_mark_picker.dart:118-127`) |
| `poltergeist/app/poltergeist_app/lib/ui/server_color_picker.dart`, `server_mark_picker.dart` | 28, 22 | Thin wrappers that pass ARB strings and `poltergeistMonoTextStyle` to ghost_marks. Only lib caller: the editor (:952, :966) |
| `klabautermann/packages/klabautermann_core/lib/src/engine/protocol.dart` | 4,210 | `CatalogReplaced` (:677-682), `FleetEntry` (:1667-1733). No `ServerDraft`, `ServerSummary`, `SaveServer`, `DeleteServer` or `TestConnection` (0 matches anywhere in the repo) |

Editor anatomy, side by side (Poltergeist / Séance), with the destination
of each part:

| Part | Poltergeist | Séance | Destination |
|---|---|---|---|
| Imports | :12-27 | :1-15 | rewritten per PR |
| Host seam | `ServerEditorDelegate` :32-79 | `AppState` fields :214 | neutral `GhostServerEditorDelegate` (GS) |
| `excludingNeedsConfirmation` | :95-98 | :35-38 | GS, over the neutral draft |
| `plannedCredential` | :129-172 | :70-112 | `seance_protocol` (F5a-1a) |
| `plannedCredentialReadsStored` | :183-191 | :124-131 | `seance_protocol` (F5a-1a) |
| `nextUpdatedAt` | :214-215 | :158-159 | `seance_protocol` (F5a-1a) |
| `confirmSyncExclusion` | :223-243 (ARB) | :167-190 (literals) | GS |
| `showServerEditor` | :247-261 | :197-211 | GS `showGhostServerEditor`; app wrappers keep the old names |
| State fields, ids | :273-328 (`uuidV4` :312, :320) | :223-280 (:256, :264; bookmark :279-280) | GS; ids from `delegate.newId()` |
| `initState` | :330-358 | :283-313 (bookmark load :297-305) | GS, from a `GhostServerDraft` |
| `_fields`, `_connectionFields`, `_dropTestResult`, `dispose` | :361-426 | :316-380 | GS, verbatim |
| `_returnSaves`, `build`, shortcuts | :449-488 | :403-442 | GS, verbatim |
| `_body` (title, identity fields, auth dropdown, buttons, disclaimer, live-region report) | :490-664 | :444-597 | GS |
| `_authFields` | :666-739 | :599-668 | GS |
| `_startDirectoryFields` | :745-767 | none | GS, optional field |
| `_loginScriptFields` | :773-797 | :674-698 | GS |
| `_transferFields` + `_TransferLimitChoice` | :802-842, :1323-1335 | none | stays in Poltergeist as an editor section |
| `_appearanceFields`, `_pickMark`, `_pickCustomColor` | :848-977 | :704-825 | GS (calls ghost_marks directly) |
| `_syncSecretToggle`, `_syncFields`, `_confirmExclusion` | :988-1049 | :835-887 | GS |
| `_browseForKey` | :1053-1057 | :891-899 | GS, through the delegate |
| Validators | :1059-1079 (ARB, instance) | :901-908 (literals, static) | GS, bag strings |
| `_formConfig` | :1084-1128 | :913-956 | split: draft built in GS, `ServerConfig` built by the host mapping |
| `_bookmarkFor` | none | :966-971 | Séance follow-up, host side |
| `_testConnection` | :1134-1196 | :977-1039 | GS (attempt counter, gating); log ownership moves to the host |
| `_save` | :1198-1317 | :1041-1142 | GS (validate, snapshot, toast, pop); stamp and credential plan move to the host |
| Swatches, geometry | :1367-1491 | :1175-1297 | GS, verbatim |

### 1.2 Call sites and wiring

Poltergeist: `main.dart:509` builds `ServerEditorBackend`; `app.dart:60`,
`:185` and `workspace_shell.dart:272` carry it as `ServerEditorDelegate?`;
`workspace_shell.dart:3708` calls `showServerEditor(context, editor,
server)` for add (null) and edit; the duplicate flow reuses it. The test
harness double `InertServerEditor` (`test/ui/compact/compact_harness.dart:115`)
and the editor test's `_FakeDelegate` (`test/ui/server_editor_test.dart:38`)
extend the app delegate.

Séance: `server_list_pane.dart:721` and `terminal_pane.dart:1684` call
`showServerEditor(context, state, server)`. The editor reaches
`state.servers`, `services.isSyncConfigured`,
`services.settings.identityFileBookmarks`, `services.identityBookmarks.pick()`,
`services.vault.getSecret`, `state.testServerConnection`
(`app_state.dart:634`) and `state.saveServer` (`app_state.dart:829`);
`offerRecoveryCode` (`recovery_prompt.dart:14`) follows a save that wrote a
credential (`server_editor.dart:208-210`).

Klabautermann: the app depends on `ghost_servers` already (pubspec, F4
status dots) and not on `ghost_marks`. The architecture contract forbids
`dartssh2`, `poltergeist_core`, `seance_core` and `seance_protocol` in the
app's pubspec and imports
(`klabautermann/app/klabautermann_app/test/architecture_contract_test.dart:11-16`,
`:49-78`). The app reaches `seance_core` names only through
`klabautermann_core`'s curated barrel (03:1625).

### 1.3 Divergences between the Séance and Poltergeist editors

The two files share their structure, their comments (mostly verbatim) and
these bodies byte for byte: `excludingNeedsConfirmation`,
`plannedCredential`, `plannedCredentialReadsStored`, `nextUpdatedAt`,
`_dropTestResult`, `_returnSaves`, the shortcut map, the test attempt
counter, the read-every-field-before-the-first-await snapshot in `_save`,
and both swatch widgets. Every difference:

| Area | Séance | Poltergeist |
|---|---|---|
| Host coupling | `AppState` and `AppServices` directly | `ServerEditorDelegate`, 11 members (:32-79) |
| Fields | 10 controllers (:316-327) | 11, adds `_startDirectory` (:361-373); plus `_transferLimit`/`_storedTransferLimit` (:303-304) |
| Start folder | not shown; carried from the saved config (:949-951) | field, hint, note (:745-767); validator `normalizeServerStartDirectory` (:1074-1079); normalized on save (:1123) |
| Transfer limit | none | device-local dropdown (:802-842) stored after the config, own failure toast, editor stays open to retry (:1295-1315) |
| Identity file | Browse mints a macOS security-scoped bookmark (:891-899); test passes `draftIdentityBookmark` (:1007), save passes `identityFileBookmark` (:1088, :1133) | Browse returns a plain path (:1053-1057; `FilePicker` in the backend :70-77); no bookmark (header :6-9) |
| Validation | `_required`, `_validatePort` static, literals `Required`, `1–65535` (:901-908) | instance methods over ARB (:1059-1070), plus the start-folder rule |
| Strings | literals | ARB (D20); every shared value is identical to Séance's literal (section 4) |
| Stored-secret read | `services.vault.getSecret` (:1099) | `delegate.readSecret` (:1252) |
| Save | `state.saveServer(config, secret:, identityFileBookmark:)` (:1130-1134) | `delegate.save(config, secret:)` (:1285), then the transfer write (:1298) |
| Test | `state.testServerConnection(..., draftIdentityBookmark:, log:)` (:992-1009) | `delegate.testConnection(..., log:)` (:1149-1166); the backend snapshots the jump route before any secret read (:127-131, :155-199) |
| Dialog result | `pop(secret != null)` (:1141), then the recovery-code offer | `pop()` (:1316) |
| Styles | `SeanceTheme.mono` (:652, :682); seed `SeanceTheme.seed` (:820); colour picker `hexStyle: seanceHexStyle`, default strings | `poltergeistMonoTextStyle` (:721, :782); `delegate.themeSeed` (:971); ARB picker strings through the wrappers |
| Draft ids | `uuidV4` from `seance_core` (re-exported protocol crypto) | `uuidV4` over `package:uuid` (`services/uuid.dart:4`) |
| Layout order | identity, auth, sync, login script, appearance, buttons | same, plus start folder after sync (:576) and transfer limit after the login script (:580) |
| Formatting | short `dart format` style; a few comment wordings differ (e.g. :713-714 vs :856-858) | tall style |

Async checks are the same in both: every `await` is followed by a
`mounted` check; a superseded test attempt is dropped (`attempt !=
_testAttempt`); Cancel stays live during a test; Save is gated on `_busy`
only; a vault-read failure and a save failure show the same toast and
re-enable the form.

### 1.4 What is shared already, and what has not landed

- `ghost_marks` holds the accent, badge and both pickers. The editor's
  appearance section can move with the form; only the app wrappers'
  inputs (ARB strings, mono hex style) are per app. `ghost_marks`
  depends on `file_picker: ^11.0.2` (its pubspec, "the mark picker's
  default image reader").
- Part 1's PR 5 (connection log view and test report,
  `ghost-servers-part1.md:640`) has not landed: the barrel exports no
  report, and both apps still own `connection_test_report.dart`. The
  editor mounts the report (`server_editor.dart:654-659`), and the
  neutral delegate returns part 1's `GhostTestReport`, so PR 5 is a
  prerequisite (section 7).
- Part 1's PR 7 boundary check (`ghost-servers-part1.md:642`) has not
  landed either. `tool/guards.yaml:76` forbids `seance_core` for
  `ghost_*`; there is no allowlist for `ghost_servers`.
- Part 1's `GhostCredentialRequest` takes `seance_protocol`'s
  `AuthMethod` (`credential_dialog.dart:17`, `:58-72`), so the
  Klabautermann app cannot build one without breaking its contract.
  This part introduces `GhostAuthMethod`; switching the request to it is
  a separate part 1 follow-up.

### 1.5 Klabautermann's server types

The protocol has no server write path yet. `FleetEntry` carries id, label,
host, port, user, group, origin, jump route, auth kind, search text,
locator conflicts and endpoint confirmation (:1667-1733): no appearance,
login script, start folder, identity file or sync flags. The M5 plan adds
`ServerDraft` and `SaveServer(draft, secret?)`/`DeleteServer(id)` in M05.
The catalog store already re-stamps a local save to `max(now, stored + 1)`
(`seance_core/lib/src/catalog/server_config_store.dart:44-48`) and
`CatalogWriter.saveServer` (`catalog_writer.dart:120`) seals it, so the
engine needs no editor-side stamp. 03 section 4.4 requires the editor to
keep unshown and unknown fields from the stored config
(`03-ARCHITECTURE.md:2054-2057`).

### 1.6 What stays app-side

- Poltergeist: `ServerEditorBackend` whole (catalog reads, vault, audited
  identity reads, `runConnectionTest`, jump-route snapshot, prompts),
  `FilePicker`, the transfer-limit section and
  `transfer_limits_controller.dart`, the ARB strings, the
  `ServerEditorDelegate` interface (kept so the backend, the harness and
  the editor tests compile unchanged), the jump-route ARB messages
  (`app_en.arb:8151-8169`).
- Séance (follow-up): identity bookmarks, the recovery-code offer, the
  `AppState` delegate.
- Klabautermann (M09a): the engine requests, the ARB strings, delete and
  duplicate confirmation, the enrollment gate (P16).
- Every host: the stored-secret read and the credential plan (section 3),
  the `updatedAt` stamp, the jump route and other unshown fields.

### 1.7 Tests and pixel baselines

| Surface | Séance | Poltergeist |
|---|---|---|
| Editor widget | `server_editor_test.dart` (420, real `AppState`) | `test/ui/server_editor_test.dart` (785, fake delegate; groups save :167, start folder :278, transfers :364, Return :475, exclude :537, test connection :579) |
| Save rules | `planned_credential_test.dart` (203), `server_exclude_from_sync_test.dart` (221) | same file, groups :614-785 |
| Backend | none | `test/services/server_editor_backend_test.dart` (371) |
| Pickers | ghost_marks tests | `server_color_picker_test.dart`, `server_mark_picker_test.dart` |
| Pixel | none of the editor | none of the editor: no `POLTERGEIST_CAPTURE` test mentions it |

D3 asks for real-font captures before and after a move. The editor has
none in either app, so F5a-1b adds one first, as the credential dialog
did before its move (commit `19b07be6`).

### 1.8 Bookkeeping anchors

- Poltergeist localization allowlist: `lib/services/server_editor_backend.dart`
  (`localization_contract_test.dart:2441-2444`) and `lib/ui/server_editor.dart`
  (:2445-2459: `''`, the port seed, `'$error'`, `'$e'`, the two
  `ValueKey` names, `'$files'`). Dead entries fail the suite
  (:2594-2596), so each move edits them in the same PR.
- `poltergeist/docs/PORTS.md`: backend (:1453), editor (:1570), editor
  test (:1614). Precedent for moving editor-adjacent pure logic into
  `seance_protocol`: duplication (:1447-1450, :1609-1611).
- `scripts/test.sh:179`, `:185`, `:192` and `ci.yml:1286`, `:1321`
  already list `ghost_servers`; no new package is created.
- Changes under `seance/` merge one at a time with merge commits for the
  pin audit (`06-EXECUTION.md:54-55`).

## 2. Package proposal

New files in `planchette/packages/ghost_servers`:

```
lib/src/server_editor/draft.dart        GhostServerDraft, GhostAuthMethod, entries (F5a-1c)
lib/src/server_editor/delegate.dart     GhostServerEditorDelegate, GhostServerEditorSection (F5a-1c)
lib/src/server_editor/strings.dart      GhostServerEditorStrings (F5a-1b)
lib/src/server_editor/server_editor.dart  the form, swatches, intents (F5a-2a)
lib/server_config_draft.dart            protocol-typed mapping, not in the barrel (F5a-1c)
```

The barrel exports the four `src/server_editor/` files. The second
library, `package:ghost_servers/server_config_draft.dart`, holds the
`ServerConfig`/`AuthMethod` mapping for hosts that may import
`seance_protocol` (Poltergeist, later Séance). Keeping it out of the
barrel keeps protocol types out of every name the Klabautermann app can
see, and F5a-1c extends the app's contract test to forbid importing it.

`pubspec.yaml` gains `ghost_marks` in F5a-2a, when the appearance section
moves (part 1 deferred it until a consumer exists,
`ghost-servers-part1.md:287-289`). 03 section 3.2 already draws `GS -->
GM` and `APP --> GM` (03:1609, 03:1595). Through it, `file_picker`
becomes a transitive plugin of the Klabautermann app in that PR (section 9,
risk 3).

## 3. Neutral models (the `seance_*` boundary)

| Core or app type | Neutral model | Mapping owner |
|---|---|---|
| `ServerConfig` (`seance_protocol/.../server_config.dart:53-200`) | `GhostServerDraft`: the shown fields only, with colour and icon as protocol enum names | Poltergeist: `ghostServerDraftOf` / `serverConfigOfGhostDraft` in `server_config_draft.dart`; Klabautermann: protocol `ServerDraft`, same field names, mapped by the engine (M05) |
| `AuthMethod` (:5) | `GhostAuthMethod {agent, password, privateKey}` | same libraries; exhaustive switches |
| `ServerTint`, `ServerMark` (ghost_marks, protocol enums) | none; internal to the form | the form builds them from draft names exactly as `ServerTint.of` (:143-146) and `ServerConfig.mark` do |
| `Secret` (`seance_protocol/.../secret.dart:11`) | none: the form sends `GhostCredentialEntry` (the boxes as typed) | host plans with `plannedCredential` (F5a-1a) |
| `SshConnectionLog`, `ConnectionTestResult` (`seance_core`) | `GhostTestReport` (part 1 section 5) | host creates and freezes the log and converts the result |
| `List<ServerConfig> servers` | `Iterable<String?> serverGroups` | host; the form runs `existingServerGroups`' rule over them (`server_config.dart:511-520`) |
| `TransferConcurrency` | none; `GhostServerEditorSection` | Poltergeist section |

Rules the mapping must keep (each one is today's `_formConfig`,
`server_editor.dart:1084-1128`):

- The form normalizes `group`, `loginScript` and `startDirectory` with the
  protocol functions (`server_config.dart:439-497`) and sets
  `identityFilePath` only for a referenced, non-blank key (:1103-1108),
  so the draft holds stored forms.
- `serverConfigOfGhostDraft(draft, existing:, secretRef:, now:)` takes
  `jumpHostId` and `createdAt` from the config the editor opened with
  (not the freshest copy), sets `updatedAt: now`, and decodes names with
  `ServerColor.values.asNameMap()` and `ServerIcon.values.asNameMap()`. An
  unknown name reads as none, as `ServerConfig.fromJson` already does
  (:44-51).
- A hidden optional field (Séance's start folder) keeps the draft's
  initial value, which is the stored one, so a save preserves it as
  Séance does today (:949-951).
- No new `ServerConfig` fields (03:2057).

Why the credential plan moves to the host. The referenced-key branch of
`plannedCredential` carries the stored PEM into the new entry (:153-171),
so it reads the vault. In Poltergeist the editor reads it through
`readSecret` today. Klabautermann's vault lives in the engine isolate
(M03); sending a stored private key to the UI isolate only to send it
back is avoidable, and D18 already makes the request plain data. So the
form sends the raw boxes and the host runs `plannedCredential`: the
Poltergeist adapter in-process, the Klabautermann engine on `SaveServer`.
Both call the one implementation in `seance_protocol` (F5a-1a). The
save's `bool` result tells the form whether a credential was written,
which Séance's recovery offer needs.

## 4. String injection

`GhostServerEditorStrings` is a `final class` with a const constructor
and defaulted fields, like part 1's bags (`credential_dialog.dart:150-174`);
parameterized members are function fields. Defaults are Séance's
literals. I compared every shared literal with Poltergeist's ARB value:
all are identical, so D3's canonical-wording step has nothing to decide.
Poltergeist-only members default to Poltergeist's English ARB text.

| Bag member | Default (Séance literal, `server_editor.dart`) | Poltergeist ARB key (`app_en.arb`) |
|---|---|---|
| addTitle / editTitle | `Add server` / `Edit server` (:453) | `serverEditorAddTitle` (:7957), `EditTitle` (:7961) |
| label / host / port / username | (:458, :467, :475, :484) | `serverEditorLabel`, `Host`, `Port`, `Username` (:7965-7977) |
| authentication / authAgent / authPassword / authPrivateKey | (:490-497) | `serverEditorAuthentication` ... `AuthPrivateKey` (:7981-7993) |
| agentInfo / passwordLabel | (:603, :610) | `serverEditorAgentInfo` (:7997), `PasswordLabel` (:8001) |
| referenceKeyTitle / referenceKeySubtitle | (:618-619) | (:8005, :8009) |
| identityFilePath / identityFileHint / browse | (:637-638, :644) | (:8017, :8013, :8021) |
| privateKeyPem / keyPassphrase | `Private key (PEM/OpenSSH)`, `Key passphrase (optional)` (:654, :661) | (:8025, :8029) |
| startDirectory / Hint / Note / Invalid | none | (:8033-8045) |
| loginScript / Hint / Note | (:684-692) | (:8049-8057) |
| appearance / group / groupHint / colour / mark / chooseMark / defaultMarkTooltip | (:719-792) | (:8087-8111) |
| syncSecretTitle / Excluded / Subtitle | (:837-841) | (:8115-8123) |
| excludeTitle / OnSubtitle / OffSubtitle | (:857-861) | (:8127-8135) |
| test / testing / testingSemantic / testFailedSummary | (:542-546, :1025) | (:8139-8147, :8198) |
| cancel / save / testDisclaimer | (:558, :568, :573-575) | (:8178-8186) |
| required / portRange | (:902, :906) | (:8190, :8194) |
| saveFailed(error) | `Could not save: $e` (:1105, :1138) | `serverEditorSaveFailed` (:8202) |
| excludeConfirmTitle / Body / Cancel / Action | (:171-184) | (:8212-8224) |
| customColour / customColourValue(hex) | (:1259-1260) | (:8228, :8232) |
| appearanceStrings, colorPickerStrings | ghost_marks / ghost_ui defaults | `PoltergeistServerAppearanceStrings`, `PoltergeistColorPickerStrings` (`server_appearance_strings.dart:10`, `:107`) |

Not in the bag: the transfer-limit keys (:8061-8078) and the jump-route
keys (:8151-8169), which stay with Poltergeist's section and backend, and
`serverColorLabel` tooltips, which are vocabulary in both apps today
(`server_appearance.dart:783-787`).

## 5. Public API

```dart
// src/server_editor/draft.dart
enum GhostAuthMethod { agent, password, privateKey }
enum GhostServerOptionalField { startDirectory }

final class GhostServerDraft {
  const GhostServerDraft({required this.id, required this.label,
      required this.host, required this.port, required this.username,
      required this.authMethod, required this.syncSecret,
      required this.excludeFromSync, this.identityFilePath, this.group,
      this.colorName, this.customColor, this.iconName, this.iconEmoji,
      this.iconImage, this.loginScript, this.startDirectory});
  final String id, label, host, username;
  final int port;
  final GhostAuthMethod authMethod;
  final bool syncSecret, excludeFromSync;
  final String? identityFilePath, group, colorName, customColor,
      iconName, iconEmoji, iconImage, loginScript, startDirectory;
}

/// The credential boxes as typed, read before the first await of a Save.
final class GhostCredentialEntry {
  const GhostCredentialEntry({required this.referenceKeyFile,
      required this.password, required this.keyPem,
      required this.keyPassphrase});
}

/// What a connection test may use: each box only under its own method
/// (today's gating, server_editor.dart:1151-1164).
final class GhostCredentialDraft {
  const GhostCredentialDraft({this.password, this.privateKeyPem,
      this.keyPassphrase});
}

final class GhostServerSave {
  const GhostServerSave({required this.draft, required this.credential,
      required this.draftSecretId});
}

/// Body unchanged from server_editor.dart:95-98, over the neutral draft.
bool ghostExcludingNeedsConfirmation(
    {required GhostServerDraft? existing, required bool syncConfigured});

// src/server_editor/delegate.dart
abstract class GhostServerEditorDelegate {
  Iterable<String?> get serverGroups;
  bool get syncConfigured;
  Color get themeSeed;

  /// A fresh id; called twice per editor (server, then secret entry).
  String newId();

  bool get canPickIdentityFile => true;   // false: Browse is not shown
  Future<String?> pickIdentityFile();

  /// Plans and writes the credential, then the server. Throws on failure
  /// (the form shows strings.saveFailed). True when a credential was
  /// written.
  Future<bool> save(GhostServerSave save);

  /// Expected not to throw; an unexpected error becomes a failed report.
  /// The form still catches as a last resort, with an empty log.
  Future<GhostTestReport> testConnection(
      GhostServerDraft draft, GhostCredentialDraft credential);
}

/// A host's own section, drawn after the login script. Poltergeist's
/// transfer limit is the one user.
abstract class GhostServerEditorSection {
  Widget build(BuildContext context);

  /// Read synchronously when Save is pressed, with the form's fields;
  /// null when nothing changed. Run after the server saved.
  Future<void> Function(String serverId)? capture();

  /// The toast for a failed run; the editor stays open to retry.
  String failureMessage(Object error);
}

// src/server_editor/strings.dart
final class GhostServerEditorStrings { /* section 4 */ }

// src/server_editor/server_editor.dart (F5a-2a)
/// Resolves to true when a credential was written (Séance's recovery
/// offer); Poltergeist ignores it.
Future<bool> showGhostServerEditor(BuildContext context,
    GhostServerEditorDelegate delegate, GhostServerDraft? existing,
    {GhostServerEditorStrings strings = const GhostServerEditorStrings(),
    required TextStyle monoStyle, TextStyle? hexStyle,
    Set<GhostServerOptionalField> fields = const {
      GhostServerOptionalField.startDirectory},
    List<GhostServerEditorSection> sections = const []});
Future<bool> showGhostSyncExclusionConfirmation(BuildContext context,
    {GhostServerEditorStrings strings = const GhostServerEditorStrings()});

// lib/server_config_draft.dart (protocol-typed; not exported by the barrel)
GhostServerDraft ghostServerDraftOf(ServerConfig server);
ServerConfig serverConfigOfGhostDraft(GhostServerDraft draft,
    {required ServerConfig? existing, required String? secretRef,
    required int now});
GhostAuthMethod ghostAuthMethodOf(AuthMethod method);
AuthMethod authMethodOfGhost(GhostAuthMethod method);

// seance_protocol: src/models/server_editing.dart (F5a-1a), moved verbatim
Secret? plannedCredential({required AuthMethod auth,
    required bool referenceKeyFile, required String password,
    required String keyPem, required String keyPassphrase,
    required String secretId, Secret? stored});
bool plannedCredentialReadsStored({required AuthMethod auth,
    required bool referenceKeyFile, required String keyPassphrase});
int nextUpdatedAt(int? existingUpdatedAt, {required int now});
```

`@visibleForTesting` is dropped from the three moved functions:
`seance_protocol` has no `meta` dependency (its pubspec), and the
functions become production API for the adapters and the engine.

As built in F5a-1b and F5a-1c, the API differs from the sketch above in
these ways:

- `GhostServerEditorDelegate.serverGroups` is `List<String>`: the distinct
  names to offer, in display order. Poltergeist's session answers
  `existingServerGroups`, so the dedupe stays in `seance_protocol`.
- The form keeps the protocol's `AuthMethod` for its dropdown and maps it
  at the draft's edge. Poltergeist's editor test finds the dropdown by that
  type, and the form already uses the protocol's colour, icon and mark
  types inside.
- `GhostServerEditorStrings` also carries `testStrings` and `logStrings`
  for the report the form mounts.
- The mark picker's `ServerAppearanceStrings` comes in as a form parameter,
  since `ghost_servers` declares `ghost_marks` only in F5a-2a. The form
  also takes `onCopyError` for the report's transcript.

## 6. Per-app adapters

Poltergeist (`lib/ui/server_editor.dart`, which keeps its path and the
names `ServerEditorDelegate`, `showServerEditor`, `confirmSyncExclusion`
and `excludingNeedsConfirmation`, so `app.dart`, `workspace_shell.dart`,
the backend, the harness and the editor tests do not change):

- `showServerEditor(context, delegate, existing)` builds a per-editor
  session adapter `_PoltergeistEditorSession(delegate, existing, strings)`
  implementing `GhostServerEditorDelegate`, an ARB-backed
  `GhostServerEditorStrings`, the transfer section, and calls
  `showGhostServerEditor(..., monoStyle: poltergeistMonoTextStyle,
  hexStyle: poltergeistMonoTextStyle)`.
- `save`: today's `_save` tail in today's order (:1205-1285): freshest
  `updatedAt` over `delegate.servers`, `nextUpdatedAt`,
  `serverConfigOfGhostDraft` with `existing.secretRef`, the stored read
  only when `plannedCredentialReadsStored`, `plannedCredential`, the
  `secretRef` adoption, `delegate.save`. No `await` precedes the stamp or
  the config build, and the form snapshots draft and entry before calling,
  so the snapshot rule of :1216-1241 holds.
- `testConnection`: creates the `SshConnectionLog`, maps the draft with
  `existing?.secretRef` (:1143-1146), calls `delegate.testConnection`,
  freezes the log, and turns a thrown error into today's failed report
  (:1167-1186, summary `serverEditorTestFailedSummary`).
- `newId`: `uuidV4` from `services/uuid.dart`. `serverGroups`:
  `delegate.servers.map((s) => s.group)`.
- The transfer section owns `_transferLimit`/`_storedTransferLimit`, the
  dropdown (:802-842) and the write with
  `serverEditorTransferLimitSaveFailed` (:1298-1315).
- `excludingNeedsConfirmation` stays as a delegate over
  `ghostExcludingNeedsConfirmation(existing: ghostServerDraftOf(...))`
  so its unit test (:747-775) is unchanged.

Klabautermann (M09a and M09b, outside F5a; recorded so the API fits):

- `GhostServerEditorDelegate` over the engine: groups from
  `CatalogReplaced`, `syncConfigured` from the enrolled account, theme
  seed from `ghost_theme`, `canPickIdentityFile` false until M09b adds
  `file_picker`, `save` as `SaveServer(ServerDraft, ServerCredentialEntry)`,
  `testConnection` as `TestConnection(draft, credentialDraft)` (M09b).
- The engine maps `ServerDraft` to `ServerConfig` over the stored config
  (unshown fields kept, 03:2054-2057), runs `plannedCredential` against
  its vault, and saves through `CatalogWriter` (which re-stamps).
- `newId` needs a UUID the app can mint: a reviewed `show uuidV4` on the
  `klabautermann_core` barrel, or an engine-minted id. M09a decides.
- Load drafts with a request (`LoadServerDraft(serverId)` answered by
  `ServerDraftLoaded`) rather than widening `FleetEntry`: an image mark is
  up to 192 KiB (`server_mark.dart:170`) and every `CatalogReplaced`
  copies every entry (:672-682, :1735-1736).
- Show the start folder (default field set): it is a synced field, and
  hiding it changes nothing about what Klabautermann stores.
- The app adds `ghost_marks` (03:1595) for the appearance and colour
  picker string bags, through its ARB adapter.

Séance follow-up (optional, outside M5): a delegate over `AppState`;
`fields: {}` (start folder hidden, preserved); `monoStyle:
SeanceTheme.mono`, `hexStyle: seanceHexStyle`; default strings; the
`bool` result drives `offerRecoveryCode`. The identity bookmark needs one
additive change then: `pickIdentityFile` returns a path plus an opaque
grant, and `save`/`testConnection` receive it. Poltergeist ignores the
grant, so the follow-up does not touch it.

## 7. Staged PRs

Prerequisite: part 1's PR 5 (log view and test report) lands first, as
part 1 designed it; F5a-1c's delegate returns its `GhostTestReport`.

Each PR switches Poltergeist and runs its full suite unchanged (D3).
Behaviour changes ride separate PRs; none is planned.

| PR | Contents | Switches | Gates | Size |
|---|---|---|---|---|
| F5a-1a [S] | `seance_protocol/lib/src/models/server_editing.dart`: the three save rules moved verbatim, exported from the protocol barrel; `poltergeist_core`'s `show` list gains the three names; Poltergeist's and Séance's copies deleted; tests merged into `seance_protocol/test/server_editing_test.dart` from Séance's `planned_credential_test.dart` and Poltergeist's groups :614-746, :777-785, no case dropped | Poltergeist and Séance (pure functions, identical bodies) | Both app suites; `dart test` in `seance_protocol`; pin-audit record; merge commit | S, ~600 |
| F5a-1b | `GhostServerEditorStrings` in GS; Poltergeist's in-place editor reads the bag through an ARB-backed subclass; validators become instance reads of the bag; picker calls go straight to ghost_marks with the bag's appearance and colour strings and `poltergeistMonoTextStyle`; the two wrappers are deleted and their tests call ghost_marks with `PoltergeistServerAppearanceStrings`; first commit adds `test/ui/server_editor_capture_test.dart` | Poltergeist | Poltergeist suite; capture PNGs at the first commit and at the head byte-identical (`POLTERGEIST_CAPTURE=1`), recorded in the PR; allowlist edits | M, ~700 |
| F5a-1c | `draft.dart`, `delegate.dart`, `server_config_draft.dart`; the in-place editor holds a `GhostServerDraft`, talks to `GhostServerEditorDelegate` through the session adapter, builds drafts instead of configs; transfer limit becomes a `GhostServerEditorSection`; Klabautermann contract test forbids `package:ghost_servers/server_config_draft.dart` | Poltergeist | Poltergeist suite including `server_editor_test.dart` (785) and `server_editor_backend_test.dart` (371) unchanged; capture PNGs unchanged; GS mapping tests; allowlist entries `'$error'`, `'$e'` move to the adapter's path | M, ~800 |
| F5a-2a | Move-only: the form, swatches, intents and `confirmSyncExclusion` body from Poltergeist's file to `GS/lib/src/server_editor/server_editor.dart`; only the library header and imports change; Poltergeist's file keeps the adapter and wrappers; GS declares `ghost_marks`; Klabautermann's lock and generated plugin files regenerated with `file_picker` pinned to 11.0.3 | Poltergeist | Poltergeist suite unchanged; capture PNGs byte-identical; Klabautermann suite and five CI builds; license and local-dependency gate; dead allowlist entries removed | L, ~1,250 moved |
| F5a-2b | New GS widget tests with a neutral fake delegate (section 8) | none (tests) | GS suite | M, ~450 |
| F5a-3 [R] | `PORTS.md`: editor and editor-test entries marked moved, wrapper deletions, backend entry note, `seance_protocol` rules; `tool/guards.yaml` dependency allowlist for `ghost_servers` (`ghost_ui`, `ghost_marks`, `seance_protocol`, Flutter); `scripts/test.sh` lines verified | none | Both suites; guards green | XS, ~200 |

Split seam for F5a-2a, if GLM cannot finish: none inside the move (the
private swatches and intents are used by the state class), so the tests
were already split out into F5a-2b.

Why the editor tests stay in Poltergeist (the plan proposed moving them):
the unchanged 785-line suite, driving the shared form through the real
adapter, is the D3 proof that saves still produce the same `ServerConfig`
and `Secret`. The package gets its own tests instead.

## 8. Tests

- F5a-1a: every existing case of both apps, merged; the fuzz property that
  `plannedCredential` ignores `stored` wherever
  `plannedCredentialReadsStored` is false moves with them.
- F5a-1b: the capture test (add with agent auth, edit with a referenced
  key, password with the sync switch, the appearance section with a
  custom colour); a bag test asserting each ARB-backed member returns
  its `AppLocalizations` getter.
- F5a-1c: a round trip `ServerConfig` -> draft -> `ServerConfig` with
  every field set equals the original; `jumpHostId` and `createdAt` come
  from `existing`; unknown colour and icon names read as none; a hidden
  start folder survives; `ghostExcludingNeedsConfirmation` truth table.
  Poltergeist's suite runs unchanged.
- F5a-2b: Return saves from a one-line field and not from the login script,
  the chord saves anywhere, an open IME composition declines; the
  exclusion confirmation shows only for an existing, included server with
  sync configured, and dismissing it reads as no; typing in a connection
  field drops a running test and its late result; a test failure renders
  the report in the live region; required and port validation; Browse
  hidden when `canPickIdentityFile` is false; a hidden optional field
  keeps its draft value; a section's failed write toasts its own message
  and keeps the editor open; `save` throwing toasts `saveFailed`.
- F5a-3: the guards fixture for the new allowlist.

## 9. Risks

1. Snapshot order. Moving the stamp and the credential plan into the
   adapter must not put an `await` before the config is built; the form
   passes a draft and entry read synchronously. Risk of a field typed
   during a slow keyring prompt being saved unvalidated (:1216-1222).
2. Name mapping. Colour and icon travel as enum names. Known values round
   trip exactly; the F5a-1c test covers every enum value.
3. Plugin drift. `ghost_marks` brings `file_picker` into the
   Klabautermann app at F5a-2a, earlier than P15's M09b. Pin it to
   Poltergeist's 11.0.3 in that PR and run the license gate; M09b then
   only starts calling it.
4. Contract bypass. The protocol-typed library is importable by any
   package user. The Klabautermann contract test forbids it (F5a-1c), and
   the barrel exports no protocol name.
5. Credential carry-over drift. A second implementation of the
   referenced-key rule in the engine would let Klabautermann write a
   different entry than Poltergeist for the same form. F5a-1a gives one
   home.
6. Localization bookkeeping. Each of F5a-1b, F5a-1c and F5a-2a kills or
   moves allowlist entries; the dead-entry check enforces same-PR edits.
7. Part 1 ordering. F5a-1c cannot compile before part 1's PR 5.
8. Séance compatibility. The bookmark grant and the recovery offer must
   stay additive; the `bool` result exists now, the grant is an additive
   field later.
9. Size. F5a-2a is close to the GLM budget at about 1,250 moved lines.

## 10. Corrections to the plan

1. The appearance pickers are not Poltergeist-only: `ghost_marks` has held
   them since 2026-10-08 (wrapper headers, `server_color_picker.dart:1-2`,
   `server_mark_picker.dart:1-2`). The editor's appearance section moves;
   only the wrappers' inputs are per app, and the wrappers can go.
2. `ghost_marks` depends on `file_picker`, so declaring it in
   `ghost_servers` changes the Klabautermann app's plugin set (risk 3).
3. Part 1's PR 5 and PR 7 have not landed (section 1.4);
   `GhostTestReport` does not exist yet.
4. There is no `ServerDraft`, `SaveServer` or `TestConnection` in the
   protocol yet; M05 adds them. `SaveServer` should carry the raw
   credential entry rather than `secret?`, because the referenced-key
   branch needs the stored PEM, which the UI isolate should not read
   (section 3).
5. Drafts cannot come from `CatalogReplaced` entries: `FleetEntry` lacks
   most editable fields (section 1.5). M09a needs a draft request.
6. The plan's ranges: the editor body is `server_editor.dart:263-1491`,
   but the transfer section (:802-842, :1323-1335) does not move, and the
   save rules (:81-215) go to `seance_protocol`, not `ghost_servers`.
7. The plan moves the widget tests to the package; this design keeps
   Poltergeist's file unchanged as the switch proof and adds package
   tests (section 7).
8. The shared strings need no canonical-wording decision: Séance's
   literals and Poltergeist's ARB values are identical (section 4).
9. Part 1's credential request takes protocol `AuthMethod`, which the
   Klabautermann app cannot name; the `GhostAuthMethod` introduced here
   can replace it in a part 1 follow-up.

## 11. Decided question and estimates

Question: where do the protocol-typed save rules live?

- (a) In `ghost_servers`' protocol-typed library. No `seance/` change, but
  the Klabautermann engine is pure Dart and cannot depend on a Flutter
  package, so M05 or M09a would copy the carry-over rule (the root
  `AGENTS.md` says shared implementations are never copied) or move it a
  second time.
- (b) In `seance_protocol`, beside `Secret` and the duplication helpers
  (the 2026-10-07 precedent), as F5a-1a.

Decided: (b). It is the one module that Poltergeist (through
`poltergeist_core`), the Klabautermann engine and Séance can all import.
The functions are pure, already identical in both apps, and covered by
existing tests. The cost is one more entry in the serial [S] queue (P6)
and a pin-audit record; the PR is small, has no pixels and no Flutter.
If the [S] queue is the bottleneck, F5a-1b can run before F5a-1a; F5a-1c
needs it.

Estimates: `ghost_servers` gains about 1,700 production lines (form
~1,150 moved, draft and delegate ~250, strings ~150, mapping ~100) and
about 650 test lines. Poltergeist loses about 1,330 lines of
`server_editor.dart` and the two wrappers (50), and gains about 300 lines
of adapter, ARB bag and transfer section. `seance_protocol` gains about
120 production and 350 test lines, removed from both apps. Six PRs,
about 4,000 changed lines with moves counted, consistent with 03's M to L
for F5a.
