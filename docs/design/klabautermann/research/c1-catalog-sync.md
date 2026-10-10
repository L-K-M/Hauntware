# C1: Server catalog, sync and sharing (for a fourth app)

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Read-only investigation of the Hauntware repository at `bf1da58` (main, 2026-10-10).
Suite version 1.9.0 (`pubspec.yaml:16`). Every claim cites a file and line range.
The code is the authority. Where docs and code disagree, that is called out in §5.

Abbreviations:
`SP` = `seance/packages/seance_protocol/lib/src`,
`SC` = `seance/packages/seance_core/lib/src`,
`SRV` = `seance/packages/seance_sync_server/lib/src`,
`SA` = `seance/app/seance_app/lib`,
`PC` = `poltergeist/packages/poltergeist_core/lib`,
`PA` = `poltergeist/app/poltergeist_app/lib`,
`P04` = `poltergeist/docs/plan/04-SEANCE-INTEGRATION.md`.

---

## 0. Executive summary

- **There is no shared local server list.** Each app keeps its own `servers.json`,
  `vault.json`, host-key file and OS-keystore entries in its own support directory.
  The only path for "the same server list" is the **E2E-encrypted sync account**:
  Séance's `serverConfig` records (bare UUID ids), which Poltergeist reads and writes
  only in **shared-account mode** (logging into the user's Séance account).
- **The sync server is kind-agnostic.** It stores `(username, id) -> {updatedAt,
  deviceId, deleted, seq, blob}` rows and resolves conflicts with the shared `Lww`
  (`SRV/sqlite_storage.dart:51-60,183-206`). The record kind is inside the ciphertext
  (`SP/records/record_codec.dart:27-32`). A fourth app can add its own record kinds
  (per-server dashboard prefs, saved log queries, alert rules, Docker hosts) **with no
  server change and no `kProtocolVersion` bump**. It must add enum values to
  `RecordKind` in `seance_protocol` to seal them through `RecordCodec`.
- **Two independent implementations of the catalog sync rules already exist:**
  Séance's `SyncCoordinator` (collect-everything, ephemeral in-memory mirror, full
  pull every round) and Poltergeist's `BookmarkCoordinator` (change-driven,
  persistent store, delta pulls, quarantine). They already diverge in at least three
  observable ways (§3.3). A fourth app should not write a third. The sanctioned path
  is extracting a shared pure-Dart catalog/sync package (§3.4). Root `AGENTS.md`
  says "shared library implementations are never copied".
- **Security posture to inherit:** the account key decrypts every record, secrets
  included. Tombstones are unsealed, so the server can forge deletes of servers,
  snippets and bookmarks. Record ids are plaintext (`hostkey:<host:port>`). Séance
  still auto-trusts pulled host-key pins (Séance #56 open). Shared mode requires
  Séance >= v0.9.0 on every device.

---

## 1. Data flow: sync server -> local store -> UI server list

### 1.1 Shared protocol pieces (both apps)

| Piece | Where | Notes |
|---|---|---|
| `ServerConfig` model | `SP/models/server_config.dart:54-433` | Non-secret metadata. `secretRef` names a vault entry (`:62-64`). `jumpHostId` names another config (`:70-71`). `syncSecret` is the per-server credential opt-in (`:73-74`). `excludeFromSync` is a privacy switch with retraction semantics (`:170-202`). `startDirectory` is carried by Séance for Poltergeist (`:160-168`). |
| Appearance | `SP/models/server_config.dart:24-50,91-143`; `ServerMark` in `SP/models/server_mark.dart` | Stored as names, and unknown names decode to null (`:37-50`). Re-pushing drops values this build does not know (`:95-99`). |
| `HostKey` | `SP/models/host_key.dart:13-112` | Identity is the SHA-256 fingerprint, because dartssh2 surfaces only that (`:5-12`). Record id is `hostkey:<host>:<port>` (`:67-75`). The host string is verbatim, with no normalization (`:110-120`). |
| `Secret` | `SP/models/secret.dart:10-78` | Has its own `updatedAt` (`:15-18`). Reserved vault ids start with `recovery:` (`SP/crypto/recovery.dart:33,40`). |
| Envelope | `SP/records/record.dart:81-166` | `{id, updatedAt, deviceId, deleted, seq?, blob}` (`:124-131`). A tombstone has an empty blob (`:100-110`). |
| Kinds | `SP/records/record.dart:22-46` | `serverConfig, hostKey, secret, snippet, bookmark, assistantSettings, inboxApp, inboxStatus, unknown`. Unknown names map to `unknown` and must be skipped, never rewritten (`:16-21`). Kinds are matched by name, never by index. |
| Codec | `SP/records/record_codec.dart:13-63` | Seals `{'kind': name, 'data': ...}`. Refuses to encrypt `unknown` (`:18-24`). Decrypts a tombstone as `unknown` without opening anything (`:44-52`). |
| LWW | `SP/records/lww.dart:14-44` | Higher `updatedAt` wins. Then the lexicographically larger `deviceId`. Then higher `seq`. Client and server run the same code. |
| Crypto | `SP/crypto/vault.dart:117-204` | Argon2id, HKDF-split vault key and auth verifier, XChaCha20-Poly1305 with a 24-byte nonce (`:121-127`). |
| Wire version | `SP/version.dart:1-4` | `kProtocolVersion = 1`. "Bump only on a breaking change to the record envelope or endpoints." |
| Limits | `SP/sync/dtos.dart:102-108` | 8 MiB push body, 1000 records per push, 1 MiB per blob. Advertised on every pull (`:215-249`). |

Record-id namespace in use today (plaintext on the server):

| Id form | Kind | Minted at |
|---|---|---|
| bare UUID (no `:`) | serverConfig | `SC/sync/sync_coordinator.dart:185-191`, `PC/src/bookmarks/bookmark_coordinator.dart:319-331` |
| `hostkey:<host>:<port>` | hostKey | `SP/models/host_key.dart:75` |
| `secret:<vaultId>` | secret | `SC/sync/sync_coordinator.dart:16,211-217` |
| `snippet:<id>` | snippet | `SC/sync/sync_coordinator.dart:17,305-312` |
| `bookmark:<uuid>` | bookmark | `SP/models/bookmark.dart:8,237-245` |
| `assistant:settings` | assistantSettings | `SP/models/assistant_settings.dart:97` |
| `inboxapp:<appId>`, `inboxstatus:<appId>:<proposalId>` | inbox kinds | `SP/inbox/inbox.dart:53-54,484-487` |

### 1.2 The sync server

- Routes: `register`, `prelogin`, `login`, `GET /v1/sync?since=`, `PUT /v1/records`
  and `DELETE /v1/account`, plus the command-inbox routes (`SRV/server.dart:101-127`).
- Register, login and push require `protocolVersion == kProtocolVersion`
  (`SRV/server.dart:159-165,236-238,293-295`). Pull does not check it (`:270-282`).
- Schema: `records(username, id, updated_at, device_id, deleted, seq, blob, PRIMARY KEY
  (username,id))`, with a per-account monotonic `seq` (`SRV/sqlite_storage.dart:51-69`).
- Push runs a server-side LWW per record. A loser is reported `accepted:false` with
  the winner's seq (`SRV/sqlite_storage.dart:183-206`).
- Ids are not validated beyond JSON shape (`SP/sync/dtos.dart:292-300`). The only
  size checks are blob and record count (`SRV/server.dart:296-305`).
- There is no tombstone GC, no per-kind awareness and no per-account quota. Records
  are deleted only by account deletion (`SRV/sqlite_storage.dart:159`).
- Tokens never expire, and login rate limiting is keyed by username
  (`SRV/server.dart:241-243`). See also P04 §7.3, lines 1537-1572.

### 1.3 Séance: server -> store -> list

1. **Bootstrap.** Files live in `getApplicationSupportDirectory()`
   (`SA/services/app_services.dart:228-229`):
   `servers.json` (FileConfigStore), `deleted_records.json` (TombstoneStore),
   `vault.json`, `known_hosts.json`, `snippets.json`, `settings.json`
   (`:252-285`). The `deviceId` is minted once into settings (`:291-293`).
2. **Local edit.** `AppState.saveServer` writes the credential through
   `vault.putLocalSecret`, then `configStore.putServer`, then clears any pending
   tombstone. It refreshes `servers` and the probe set, then schedules an auto-sync
   (`SA/app_state.dart:816-865`). Delete writes a tombstone stamped
   `max(now, prior+1)` into `TombstoneStore` before dropping the row
   (`SA/app_state.dart:1031-1070`).
3. **Round.** `AppServices._runSync` reads the token `seance.apikey.sync.token`
   (`SA/services/assistant_settings_sync.dart:49`,
   `SA/services/secure_master_key.dart:213,238`) and the vault key. It builds a
   `SyncCoordinator` over a **fresh `InMemoryLocalRecordStore` every round**
   (`SA/services/app_services.dart:904-981`, store at `:954`). `run()`:
   - `collectLocal`: re-seals **every** server, opted-in secret, pending tombstone,
     host-key pin, snippet, assistant record and inbox record as dirty
     (`SC/sync/sync_coordinator.dart:153-338`). Excluded servers are retracted with
     tombstones (`:395-418`). Pins for addresses only excluded servers use are
     withheld (`:139-147,238-255`).
   - `SyncEngine.sync`: pulls from the mirror's high-water mark (0 every round, since
     the mirror is new, so every round is a **full pull**). It merges with LWW and
     pushes dirty records in batches sized by the advertised limits
     (`SC/sync/sync_engine.dart:181-318`, batching via `SC/sync/push_batcher.dart:24`).
   - `applyToStores`: decrypts **every** record (`SC/sync/sync_coordinator.dart:572-575`).
     Tombstones are routed by id: a bare id deletes a server unless excluded, or
     revives this device's own retraction (`:595-627`). Own `secret:` tombstones
     revive (`:642-648`). `snippet:` tombstones delete (`:655-662`). Other prefixed
     tombstones are no-ops. Live records switch on kind: `serverConfig` goes to
     `configStore.putServer`, after the exclusion shield, the id-match check and the
     reserved-ref check (`:666-699`). `hostKey` goes to `hostKeyStore.put`
     **unconditionally**, except for local-only locators (`:700-718`). `secret` is
     deferred to `_applySecretRecords` (shield plus freshness floor, `:949-1065`).
     `bookmark` and `unknown` are skipped (`:854-856`).
   - Re-dating passes (`rescheduleOutranked`, `_revive`, `_reviveSecrets`) can trigger
     one extra pass. Then confirmed tombstones are pruned (`:1177-1221`).
4. **UI.** After the round, `servers = configStore.listServers()`
   (`SA/app_state.dart:1830-1832`). On load the list comes from
   `SA/app_state.dart:732`. It renders through `server_list_pane.dart` and the
   ghost_ui sidebar kit.
5. **Triggers.** Startup, a 2 s debounce after edits, every 5 min, and manual
   (`SA/app_state.dart:523-525,2068-2092`).

### 1.4 Poltergeist: server -> store -> list

1. **Account modes** (`PC/src/sync/enrollment.dart:46-48`):
   - `separate` (Design B): Poltergeist's own account. No `serverConfig` records
     exist, and bookmarks carry an `EmbeddedHostIdentity`.
   - `shared` (Design A): Poltergeist logs into the user's Séance account with the
     same passphrase and so the same vault key. Gated on Séance >= `v0.9.0`
     (`PA/services/sync_account_gate.dart:9-27`) plus a user fleet assertion.
2. **Files** (`PA/main.dart:106-133,141,427-470`): `servers.json`
   (FileServerConfigStore, `{version, servers, syncTuples}`), `sync_records.json`
   (PersistentLocalRecordStore), `vault.json`, `host_keys.json`
   (`PA/services/engine_session.dart:22`) and `settings.json`. The `deviceId` lives
   at settings key `poltergeist.sync.deviceId` (`PA/services/sync_credentials.dart:151`).
3. **Coordinator wiring.** In shared mode, `BookmarkBackupService` builds a
   `BookmarkCoordinator` with `catalog`, `servers` and `secrets`. In separate mode
   those are null (`PA/services/bookmark_backup_service.dart:455-501`).
4. **Round.** `BookmarkCoordinator.runRound` (`PC/src/bookmarks/bookmark_coordinator.dart:874-953`):
   - It pulls a **delta** from `highWaterSeq`, with a full-resync fallback
     (`:1025-1043`).
   - `PersistentLocalRecordStore.putRemote` merges with LWW and parks displaced
     winners (`PC/src/sync/persistent_record_store.dart:20-53`).
   - It pushes **all** dirty records in one request (`:895-899`). Rejected pushes
     restore the displaced winner (`:905-931`).
   - The apply pass covers records with `seq > lastAppliedSeq`, in seq order, and
     never advances past a deferred record (`:1060-1136`). Dispatch is **by plaintext
     prefix before decrypting** (`:1148-1183`):
     - A bare id goes to `_applyServerConfigRecord`, then
       `FileServerConfigStore.applySyncedRecord` under a materialized-tuple guard
       (`:1315-1370`). An excluded row never re-materializes. Its retraction re-dates
       once (`:1340-1361`).
     - A bare-id tombstone goes to `removeSyncedRecord`. The exceptions are an
       excluded row and this device's own reversed retraction (`:1378-1412`).
     - `hostkey:` goes to `putIfNoConflict`. Conflicts are quarantined, and negative
       pins block installation (`:1270-1313`).
     - `secret:` is applied last, under the shield and the freshness floor. It is
       gated by the device switch (`:1096-1112,1421-1469`).
     - Unknown prefixes and `snippet:` are skipped undecrypted. So are `hostkey:`,
       `secret:` and `snippet:` tombstones (`:1154-1165,1181`).
   - Catalog rebuild (`:1515-1542`): `SeanceServerCatalog.replace(store.load())`
     (`PC/src/sync/seance_server_catalog.dart:44-50`). `onReplaced` publishes the
     snapshot to the engine routes and the UI
     (`PA/services/bookmark_backup_service.dart:251-264`).
5. **Local edit.** `ServerEditorBackend.save` calls `saveServerSecret` and then
   `saveServer` (`PA/services/server_editor_backend.dart:75-79`). That reaches
   `coordinator.onServerSaved`: `store.save` re-stamps to `max(now, prior+1)`
   (`PC/src/sync/server_store.dart:165-184`), then a bare-id record is sealed dirty
   and opted-in secrets are published (`PC/src/bookmarks/bookmark_coordinator.dart:235-261`).
   Delete goes through `onServerDeleted`, which writes a tombstone with
   `deletionStamp` and retracts the orphaned secret (`:269-294`).
6. **UI.** The SERVERS section reads `view.catalog?.servers`
   (`PA/ui/sidebar/sidebar_servers_section.dart:32,150-152`). The server editor's
   list is `_backups.catalog?.servers` (`PA/services/server_editor_backend.dart:48-50`).
   **Without shared mode there is no server list.** SERVERS then shows only Quick
   Connect sessions (`sidebar_servers_section.dart:147-152`). `saveServer` and
   `deleteServer` silently return when no coordinator exists
   (`PA/services/bookmark_backup_service.dart:320-341`), and `onServerSaved` is a
   no-op without a server store (`bookmark_coordinator.dart:235-237`).

---

## 2. What a fourth app must implement or reuse

### 2.1 To show and edit the same server list

Hard requirement: **shared-account enrollment into the user's Séance account**.
Separate mode cannot see `serverConfig` records. There is also no local
cross-app path:
- Mobile and sandboxed apps have per-app support directories and per-app keystores
  (§4.6).
- Even on unsandboxed desktop, reading another app's `servers.json` would bypass LWW
  bookkeeping, and the formats differ (Séance writes a JSON list,
  `SA/services/file_stores.dart:14-40`; Poltergeist writes a versioned object,
  `PC/src/sync/server_store.dart:124-127,413-435`).

The fourth app needs, at minimum:

| Need | Reuse today | Gap |
|---|---|---|
| Models, codec, LWW, DTOs, `uuidV4`, group/search helpers (`existingServerGroups`, `serverSearchHaystack`, `SP/models/server_config.dart:504-530`), `duplicateServerConfig` (`SP/models/server_duplication.dart`) | `seance_core` barrel (`seance/packages/seance_core/lib/seance_core.dart:7`) | none |
| HTTP transport | `HttpSyncClient` (`SC/sync/http_sync_client.dart:12-253`) | none |
| Persistent mirror with delta pulls and real tombstones | `PersistentLocalRecordStore` (`PC/src/sync/persistent_record_store.dart:101-463`) | Lives in `poltergeist_core`, which also drags in transfer, archive, xml and ffi deps (`poltergeist/packages/poltergeist_core/pubspec.yaml:11-43`) |
| Writable server store with tuple bookkeeping | `FileServerConfigStore` (`PC/src/sync/server_store.dart:105-450`) | Same. `ServerSyncTuple` is a typedef of `BookmarkSyncTuple` (`:24,32`) |
| serverConfig, secret and hostkey apply/publish rules | Embedded in `BookmarkCoordinator`, which requires a `SyncTrackingBookmarkStore` (`bookmark_coordinator.dart:100-145`) | Not reusable without bookmarks. This is the main extraction target |
| Catalog view | `SeanceServerCatalog` (`PC/src/sync/seance_server_catalog.dart:16-51`) | trivial |
| Enrollment (prelogin, KDF-downgrade refusal, login, trial-decrypt, push hold) | `SyncEnrollment` (`PC/src/sync/enrollment.dart`) | In poltergeist_core |
| Push batching | `batchForPush` (`SC/sync/push_batcher.dart:24`) | **Not exported** from the `seance_core` barrel (`seance_core.dart:52-56`). Poltergeist does not batch (§3.3) |
| Vault with re-key journal, OS keystore master key | Two app-level copies: `SA/services/file_stores.dart:253` and `PA/services/file_stores.dart:68`; `SA/services/secure_master_key.dart` and `PA/services/secure_master_key.dart` | Flutter-app code, copied with attribution (`poltergeist/docs/PORTS.md:305-379`) |
| Host-key store and TOFU | `TofuVerifier`, `HostKeyStore` (`SC/hostkey/tofu.dart:30-63`); `ConflictAwareHostKeyStore` and `HostKeyMutationGate` (`PC/src/sync/host_key_mutations.dart`); `FileHostKeyStore` copies (`SA/services/file_stores.dart:554`, `PA/services/file_stores.dart:372`) | as above |
| Status dots | `ProbeService` and `TcpBannerProber` (`SC/probe/probe_service.dart:14-301`): tri-state online/offline/unknown, jittered 45 s sweeps, at most 6 concurrent, pause/resume, connected servers skipped | Poltergeist adds probe-eligibility policy (`PA/services/probe_settings_store.dart:4-40`) |
| Badges, marks, sidebar rows | `ghost_marks` and `ghost_ui` (`planchette/packages/ghost_marks/lib/src/*`, `planchette/packages/ghost_ui/lib/src/sidebar_kit.dart`), approved 2026-10-08 (`docs/design/server-appearance-package.md:5-9`) | none |
| Server editor | Two copies: `SA/ui/server_editor.dart` (1297 lines) and `PA/ui/server_editor.dart` (1490 lines, with a `ServerEditorDelegate` seam, `PA/services/server_editor_backend.dart:27-50`) | Extraction candidate |
| SSH connect, exec, SFTP | `openAuthenticatedClient` (`SC/ssh/ssh_session.dart:694`), `SshSessionManager` (`:1095`), `SshSession.runCommand` (`:488`), `RemoteFileSystem` | Reusable today for exec-based observability |

Edit semantics the fourth app must reproduce exactly. Both apps converge only if all
writers agree:
- **Local save.** Re-stamp `updatedAt = max(now, stored+1)`
  (`PC/src/sync/server_store.dart:169-175`). Seal the bare id with this install's
  `deviceId`. Clear any pending tombstone for the id (`SA/app_state.dart:837-852`).
- **Delete.** Tombstone stamp `max(now, prior+1)` (`PC/src/sync/server_store.dart:74-86`,
  `SA/app_state.dart:1031-1037`). Persist it before dropping the row. Retract the
  orphaned `secret:` unless a non-excluded server still shares it
  (`bookmark_coordinator.dart:392-417`, `sync_coordinator.dart:395-408`).
- **Exclusion toggles** need a strictly later `updatedAt`. `copyWith` throws
  otherwise (`SP/models/server_config.dart:273-288`). Exclusion means a retraction
  tombstone, re-dating past an outranking copy, and reviving past this device's own
  retraction on re-inclusion (`sync_coordinator.dart:885-935,1081-1167`;
  `bookmark_coordinator.dart:1340-1361,1378-1412`).
- **Id invariants on apply.** The payload id must equal the record id for configs,
  pins and secrets. A config naming a reserved vault id is refused
  (`sync_coordinator.dart:672-699`; `bookmark_coordinator.dart:1329-1338`).
- **Jump hosts.** `jumpHostId` resolves only within the catalog (Poltergeist:
  `PA/services/server_config_source.dart:42-44`).

### 2.2 To share credentials

- Each app has its own vault file and its own keystore master key:
  `seance.vault.masterKey.v1` (`SA/services/secure_master_key.dart:75`) and
  `poltergeist.vault.masterKey.v1` (`PA/services/secure_master_key.dart:45`).
  Entries are deliberately renamed "so the two apps never share an entry"
  (`poltergeist/docs/PORTS.md:309-311`).
- On enrollment each app **re-keys its vault to the passphrase-derived key**
  (Séance `SA/services/app_services.dart:781-812`; Poltergeist via
  `SyncCredentialStore.writeVaultKey`, `PC/src/sync/enrollment.dart:81-97`). The
  re-key journal is required for this (`poltergeist/docs/PORTS.md:346-360`).
- Credentials travel only as `secret:<vaultId>` records, and only when all of these
  hold: the device switch `syncSecrets` is on on the **publishing** device, the
  server has `syncSecret: true`, it is not excluded, and the ref is not reserved
  (`sync_coordinator.dart:119-129`; `bookmark_coordinator.dart:303-315,344-380`).
  The switch also gates the **pull** side (`sync_coordinator.dart:974-975`;
  `bookmark_coordinator.dart:1426-1430`).
- Otherwise the fourth app must prompt and store locally under the same
  `secretRef`. The `Bookmark.secretRef` precedent is at P04 lines 116-120.
  `AuthMethod.agent` (`SP/models/server_config.dart:3-5`) needs a local agent.
  `identityFilePath` is a per-device path (`:66-68`). On macOS Séance keeps
  security-scoped bookmarks in device-local settings (`SA/app_state.dart:842-850`).
- Apply guards to copy: the exclusion shield and the strictly-newer freshness floor
  (`sync_coordinator.dart:1032-1060`; `bookmark_coordinator.dart:1450-1459`).
  `secret:` tombstones are never honoured (`sync_coordinator.dart:628-648`;
  `bookmark_coordinator.dart:1414-1420`).

### 2.3 To share host keys (TOFU)

- Each app keeps its own local pin file: Séance `known_hosts.json`
  (`SA/services/app_services.dart:284`), Poltergeist `host_keys.json`
  (`PA/services/engine_session.dart:22`). They share only through `hostkey:` records
  in a shared account.
- Séance publishes every local pin each round (`sync_coordinator.dart:238-263`) and
  **applies pulled pins without a conflict check** (`:700-718`;
  `SA/services/file_stores.dart:607-615`). This is Séance #56, still open
  (`PA/services/sync_account_gate.dart:21-27`).
- Poltergeist applies pulled pins only with no conflict, quarantines a conflict
  behind a re-derived diff, and honours negative pins and kept verdicts
  (`bookmark_coordinator.dart:474-635,1270-1313`).
- A fourth app should adopt Poltergeist's quarantine model. Note that any pin it
  pushes overwrites Séance devices' local trust silently until #56 lands.
- Pin locator = `config.host` verbatim plus port (`SP/models/host_key.dart:110-120`).
  The fourth app must pin with the exact `ServerConfig.host` string, or pins will not
  match across apps.

### 2.4 To add its own synced record kinds (no server change)

What the protocol allows without bumping `kProtocolVersion`:
- New kinds inside the sealed payload, new id prefixes, new optional payload fields,
  additive endpoints, and additive tolerant response fields (`SP/version.dart:1-4`;
  P04 lines 66-68).
- Precedents: the inbox endpoints and kinds, and `PullResponse.limits`
  (`SP/sync/dtos.dart:219-247`), were all added at v1.

Steps:
1. **Add enum values** to `RecordKind` (`SP/records/record.dart:22-32`), for example
   `monitorPrefs`, `logQuery`, `alertRule`, `dockerEndpoint`. `RecordCodec.encrypt`
   writes `kind.name` and refuses `unknown` (`SP/records/record_codec.dart:17-32`).
   Dart 3 exhaustiveness will force updates at `SC/sync/sync_engine.dart:39-50`
   (`RefusedRecord._described`) and `SC/sync/sync_coordinator.dart:665-857`
   (Séance's apply switch must `continue` on them).
2. **Pick a unique colon-prefixed id**, for example `<app>:pref:<serverConfigId>` or
   `<app>:rule:<uuid>`:
   - **Never use a bare id.** Séance treats any colon-free tombstone as a server
     delete (`sync_coordinator.dart:596-627`). Poltergeist strictly decodes bare ids
     as `serverConfig` and trips its tripwire otherwise
     (`bookmark_coordinator.dart:1325-1338`).
   - Avoid existing prefixes (table in §1.1). Prefixes are split at the **first**
     colon (`bookmark_coordinator.dart:1185-1191`).
   - Do not put host names, paths or queries in ids. They are plaintext
     (P04 lines 853-859).
3. **Compatibility with deployed clients:**
   - Séance >= v0.9.0 decodes unknown kinds as `unknown` and skips them
     (`record.dart:34-46`, `sync_coordinator.dart:854-856`). It never re-pushes
     records it did not collect, because the mirror is ephemeral.
   - Prefixed tombstones are no-ops in Séance, except `snippet:` and own `secret:`
     (`:628-662`).
   - Poltergeist skips unknown prefixes without decrypting them, tombstones included
     (`bookmark_coordinator.dart:1154-1165,1181`).
   - Pre-v0.9.0 Séance would decode an unknown kind as `serverConfig` and corrupt
     the fleet (P04 lines 861-875). The same fleet gate as Poltergeist's shared mode
     applies.
4. **Design rules for the payloads:**
   - One record per independently edited entity, because LWW replaces whole records
     (`SP/records/lww.dart:14-44`).
   - Reference servers by `serverConfigId`. Handle "absent: pending" separately from
     "tombstoned: removed" (P04 §2.2 lines 351-368).
   - Honour `excludeFromSync`: do not publish per-server records for excluded
     servers. This mirrors the local-only locator rule
     (`sync_coordinator.dart:131-147`).
   - Enforce payload-id == envelope-id on apply.
   - Keep secrets out of `secret:`. Séance would apply unreferenced secrets into its
     vault as orphans (`sync_coordinator.dart:1067-1079` shields only excluded refs).
     Seal them inside the kind's own payload behind an explicit opt-in instead. The
     precedents are assistant keys (`sync_coordinator.dart:39-49`) and inbox app keys
     (`:80-90`).
   - For security-relevant entities (alert rules), do not honour unsealed
     tombstones. Use a sealed `removed` flag, as inbox apps do
     (`sync_coordinator.dart:84-88,800-831`).
   - Do **not** add fourth-app fields to `ServerConfig`. Older builds drop unknown
     fields on re-push (`SP/models/server_config.dart:95-99`). Séance re-seals every
     server each round under its own `deviceId` with the stored `updatedAt`
     (`sync_coordinator.dart:185-191`), so on a deviceId tie-break a stripped copy can
     replace the richer one.
5. **Keep records few and small.** Séance pulls the **entire account every round**,
   every 5 minutes and after each edit. Poltergeist rewrites all of
   `sync_records.json` per mutation. Metrics, log snapshots or container state must
   never be synced. Server caps: 1 MiB per blob, 1000 records and 8 MiB per push
   (`SP/sync/dtos.dart:102-108`, `SRV/server.dart:296-305`).

What the server cannot do: it cannot read, filter, query or expire anything. Every
client receives every record. Alert evaluation cannot run on the sync server.

The command inbox (`seance/docs/INBOX.md:1-60`; `SRV/inbox_handlers.dart:5-19`) is
the only server-mediated channel from a third party into the account, for example a
monitoring agent depositing sealed alerts. It is shaped for command proposals:
- 100 pending items per app.
- 30 deposits per minute.
- At most 50 apps per account.
- The app key lives in Séance's vault as `inbox-key:<appId>`
  (`seance/AGENTS.md:602-606`).

Reusing it for alerts would need a new sealed payload type on clients. The server
would not change, but this is a design decision, not a drop-in.

---

## 3. Duplication and extraction candidates

### 3.1 Duplicated today (catalog, sync and credential area)

| Concern | Séance | Poltergeist |
|---|---|---|
| Sync coordination for serverConfig, secret and hostkey | `SC/sync/sync_coordinator.dart` (1243 lines; collect-everything) | `PC/src/bookmarks/bookmark_coordinator.dart` (1543 lines; change-driven) |
| Local mirror | `InMemoryLocalRecordStore` per round (`SC/sync/local_record_store.dart:28-69`, used at `SA/services/app_services.dart:954`) | `PersistentLocalRecordStore` (463 lines) |
| Server store | `FileConfigStore` (`SA/services/file_stores.dart:14+`) | `FileServerConfigStore` (450 lines) |
| Pending deletes | `TombstoneStore` file (`SC/store/stores.dart:27-46`) | tombstone tuples in stores and records |
| Vault file and re-key journal | `SA/services/file_stores.dart:253` | `PA/services/file_stores.dart:68` (ported, `PORTS.md:327-379`) |
| Host-key file | `SA/services/file_stores.dart:554` | `PA/services/file_stores.dart:372` (adds conditional installs) |
| Keystore wrapper | `SA/services/secure_master_key.dart` (246 lines) | `PA/services/secure_master_key.dart` (162 lines, renamed keys) |
| Enrollment | `SA/services/app_services.dart:781-900` | `PC/src/sync/enrollment.dart` (384 lines) |
| Server editor | `SA/ui/server_editor.dart` (1297 lines) | `PA/ui/server_editor.dart` (1490 lines) plus `server_editor_backend.dart` |
| Duplicate-server service | `SA/services/server_duplication.dart` (69 lines) | `PA/services/server_duplication.dart` (85 lines) |
| Atomic file helpers | `SA/services/atomic_file.dart` | `PA/services/atomic_file.dart` |
| Probe wiring | `services.probe` in AppState | `probe_controller.dart` and `sidebar_probe_owner.dart` (646 lines) |

The appearance cluster has already been extracted to `ghost_marks` and `ghost_ui`
(`docs/design/server-appearance-package.md:1-9`).

### 3.2 Why a third copy is the wrong move

Root `AGENTS.md` says "shared library implementations are never copied". The two
coordinators encode the same subtle rules: exclusion and retraction, revival, the
secret shield, the freshness floor, id invariants and tombstone routing. Those rules
are already drifting (§3.3), and a fourth implementation would multiply that.

### 3.3 Observed divergences between the two implementations (verify before relying on them)

1. **Local-only host-key locators.** Séance withholds and shields pins for addresses
   used only by excluded servers (`sync_coordinator.dart:139-147,238-255,717`).
   Poltergeist has no such rule. Its `excludeFromSync` uses are limited to configs
   and secrets (`bookmark_coordinator.dart:239,307,396,439,694,717,841,1346,1384,1479`).
2. **Pin publication.** `onHostKeyPinned` exists (`bookmark_coordinator.dart:474-487`)
   but has **no call site** in the app. The engine's pin events are only persisted
   locally (`PA/services/engine_session.dart:519-523`). Pins reach the account only
   through the B->A switch re-seal (`PA/services/bookmark_backup_service.dart:762-776`).
   P04 line 733 and `seance/docs/POLTERGEIST.md:415-416` say pins sync both ways.
3. **Push batching.** Séance batches by advertised limits (`sync_engine.dart:273-317`).
   Poltergeist sends every dirty record in one `push` (`bookmark_coordinator.dart:895-899`,
   transport at `PA/services/sync_transport.dart:31-41`). Above 1000 dirty records or
   8 MiB, the server returns 413 (`SRV/server.dart:296-305`). Bookmark scale makes
   this latent, but a fourth app with many records would hit it.
4. **Full vs delta pull.** Séance always pulls everything. Poltergeist pulls deltas.
   This is a bandwidth difference and is fine, but it shapes the size budget in §2.4.
5. **Undecodable rows.** Séance's `FileConfigStore` quarantines the whole file on
   corruption (`SA/services/file_stores.dart:22-33`). Poltergeist preserves
   undecodable rows verbatim (`PC/src/sync/server_store.dart:142-144,368-375,398-411`).

### 3.4 Proposed extraction

**A. Pure-Dart `seance_catalog`** (name tentative), placed in `seance/packages/`
beside `seance_core`, depending only on `seance_core`:
- `SyncTuple` (generalized from `BookmarkSyncTuple`).
- `PersistentLocalRecordStore` and `SyncRecordStore`.
- `FileServerConfigStore` and `SyncTrackingServerStore`.
- `SeanceServerCatalog`.
- A `RecordCoordinator` with pluggable per-prefix handlers. It would own the apply
  cursor and deferral, prefix-before-decrypt dispatch, the tripwire store, the push
  hold and deferred passphrase check, and push batching through `batchForPush`
  (exported). Built-in handlers: `ServerConfigHandler`, `SecretHandler`,
  `HostKeyHandler` with quarantine, negative pins and kept verdicts.
- `SyncEnrollment` and the credential/state seams.

Poltergeist then registers a `BookmarkHandler`, and the fourth app registers its own
handlers. Séance can migrate later. Its current ephemeral model works but costs full
pulls, and its #54/#56 work fits the persistent design.

**B. Flutter package** for the server-management UI, for example `ghost_servers` in
`planchette/packages/` beside `ghost_marks`:
- The editor, behind `ServerEditorDelegate`, using Poltergeist's host-neutral version.
- Server list rows and grouping.
- The sync enrollment sheet.
- Keystore and vault file adapters (`MasterKeyManager` parameterized by a key-name
  prefix, `FileVaultStore` with the re-key journal, `FileHostKeyStore`).

The design doc notes that a shared UI package must not depend on `seance_core`,
because `dartssh2` is confined (`docs/design/server-appearance-package.md`, §1.4 on
`import_guard`). So the I/O adapters belong in a pure-Dart or app-side layer, not in
the widget package.

Risks:
- **Semantic choice.** Extraction forces a decision on each divergence in §3.3. Both
  test suites must be merged. Séance's `sync_test.dart` and `sync_coordinator_test.dart`
  and Poltergeist's core sync tests are the regression nets.
- **Data and identity preservation.** File shapes, keystore names (`seance.*`,
  `poltergeist.*`), settings keys and `deviceId`s must be preserved byte-for-byte
  (root `AGENTS.md`: "Preserve application IDs, keychain names, wire formats and
  user data").
- **Séance migration risk.** Moving Séance off collect-everything changes when
  deletes and exclusions propagate. Do it as a separate PR series after Poltergeist
  and the fourth app are on the package.
- **Barrel churn.** `poltergeist_core` re-exports `seance_core` types as public API
  (`PC/poltergeist_core.dart:11-14,31-144`).
- **Ordering.** Doing the extraction before the fourth app avoids a temporary third
  copy. Doing it after delays the app. Recommended: extract first (Phase 0), since
  `BookmarkCoordinator` cannot be reused as-is.

---

## 4. Constraints and gotchas

### 4.1 Security model
- **Account scope.** Any app in a shared account derives the account key and can
  decrypt every record, `secret` included. Poltergeist's never-decrypt dispatch is a
  courtesy, not a boundary (P04 lines 917-924; `seance/docs/POLTERGEIST.md:443-452`).
- **The sync server is breach-tolerant storage**, not a trust anchor
  (`seance/AGENTS.md:128-131`).
- **Unsealed tombstones.** The server alone can delete servers (bare ids), snippets
  and bookmarks on every device. It cannot strip secrets or pins, because those
  tombstones are no-ops (`sync_coordinator.dart:576-594`;
  `bookmark_coordinator.dart:1154-1165`). Sealed tombstones are the recorded fix.
- **No AEAD binding of the record id.** Relabeling is possible, so both apps check
  payload-id == envelope-id (`sync_coordinator.dart:673-687,702-716`;
  `bookmark_coordinator.dart:1214-1218,1292-1295,1442-1444`; rationale at P04 line 737).
- **Endpoint rewrite.** Any device can LWW-rewrite a server's host. A fourth app that
  connects in the background (polling metrics, logs or Docker) could be redirected to
  an attacker host and hand it a credential. P04 §2.2 (lines 369-427) specifies
  per-device endpoint pins. A grep for `EndpointPin` or "endpoint pin" in Poltergeist
  found only a doc mention (`PC/src/bookmarks/bookmark_store.dart:9`), so treat this
  as unimplemented and verify. Poltergeist gates **probing** of synced servers on a
  local connect (`PA/services/probe_settings_store.dart:4-40`). Séance probes every
  configured server (`SA/app_state.dart:861`).
- **First-seen pins auto-apply.** A compromised peer can mint trust for hosts a device
  has never seen (`seance/docs/POLTERGEIST.md:443-452`).
- **No token revocation, tokens never expire.** `DELETE /v1/account` deletes every
  app's data and must never be exposed in shared mode (P04 lines 970-972,1537-1572).

### 4.2 Retraction and tombstone semantics
- LWW is per record. A later edit beats an earlier delete, and that is intended
  (`SP/records/lww.dart:10-12`).
- Deletion stamps must be `max(now, prior+1)`.
- An `excludeFromSync` change requires a strictly later `updatedAt`
  (`SP/models/server_config.dart:196-201,273-288`).
- Retractions re-date once past an outranking copy and then settle. Reversal revives
  only past **this device's own** retraction. A peer's later exclusion still wins
  (`sync_coordinator.dart:613-626`).
- A pending tombstone whose id is live again is not republished
  (`sync_coordinator.dart:227-237`).
- Pruning happens only after the server sequences the tombstone (`:493-520`).
- Records are never GC'd server-side. Poltergeist retains tombstones forever
  (`bookmark_coordinator.dart:209-213`).

### 4.3 Protocol "never touch" list
- Argon2 and HKDF parameters, the domain salts `seance/v1/vault-encryption-key` and
  `seance/v1/auth-verifier`, and XChaCha20-Poly1305 sealing.
- The blob layout `nonce(24)||ct||mac(16)` (empty for tombstones), the LWW tuple and
  server-assigned seq, and the envelope.
- `kProtocolVersion` semantics, the kind-prefixed id conventions, and the "UI never
  sees dartssh2 types" boundary.

Sources: P04 §1.3 lines 54-72, `seance/docs/POLTERGEIST.md:57-60`,
`seance/AGENTS.md:466-469`.

### 4.4 Keychain naming
- Pattern: `<app>.vault.masterKey.v1` and `<app>.apikey.<name>`, with the sync token
  at `<app>.apikey.sync.token` (`SA/services/secure_master_key.dart:75,213,238`;
  `PA/services/secure_master_key.dart:45,122-143`; `PC/src/sync/enrollment.dart:81-85`).
  A fourth app needs its own prefix.
- macOS uses the legacy login keychain (`MacOsOptions(usesDataProtectionKeychain:
  false)`) because `keychain-access-groups` is a restricted entitlement that ad-hoc
  builds cannot use (`SA/services/secure_master_key.dart:85-96`;
  `seance/app/seance_app/macos/Runner/Release.entitlements:37-42`). Every ad-hoc
  rebuild re-prompts (`seance/AGENTS.md:569-577`).
- `MasterKeyManager.loadOrCreateFromKeystore(hasExistingVault:)` is load-bearing:
  minting a new key over an existing vault destroys it (`seance/AGENTS.md:569-574`).
- The vault re-key journal is mandatory for enrollment re-keys
  (`poltergeist/docs/PORTS.md:346-360`).

### 4.5 Device ids and data directories
- A `deviceId` is per install, minted once and persisted in settings. It is LWW
  authorship and must never be regenerated (`SA/services/app_services.dart:291-293`;
  `PC/src/sync/enrollment.dart:103-105`; P04 lines 638-640). A fourth app must mint
  its own and cannot read Séance's.
- Each app keeps its own `getApplicationSupportDirectory()`. Its location follows the
  platform ids below. Windows `CompanyName` differs between apps (`ch.lkmc` vs
  `L-K-M`; `seance/.../windows/runner/Runner.rc:93`,
  `poltergeist/.../windows/runner/Runner.rc:93`), which path_provider uses for the
  data path. Pick a deliberate value for the new app and never change it.

### 4.6 App ids, Android and iOS
- Android and Linux use `ch.lkmc.<name>`: Séance `build.gradle.kts:8,19`,
  Poltergeist `:55,67`, Linux `CMakeLists.txt:10`.
- Apple uses `ch.lkmc.<name>App`: `AppInfo.xcconfig`
  (`seance/.../macos/Runner/Configs/AppInfo.xcconfig:19`,
  `poltergeist/...:11`, `planchette/...:11`).
- The Android `applicationId` is frozen after the first release
  (`poltergeist/.../android/app/build.gradle.kts:65-67`).
- Keep product names ASCII in bundle file names, because codesign rejects accents
  (`poltergeist/CLAUDE.md`).
- iOS and Android have per-app sandboxes and keystores. No app groups or keychain
  access groups are configured (no iOS `.entitlements` files exist under
  `ios/Runner/`). So cross-app sharing is sync-only.
- On mobile, `agent` auth and `identityFilePath` generally do not work.
- Android keeps sessions alive with a `dataSync` foreground service
  (`seance/docs/STATUS.md:1563`). Background monitoring on mobile would need the same
  kind of OS budget, which is relevant to alerting.

### 4.7 Cross-app launch
- Poltergeist emits `seance://connect?serverId=` links
  (`PA/services/seance_links.dart:1-36`).
- Séance registers **no** URL scheme. There is no `CFBundleURLSchemes` in Séance's
  Info.plist files and no link handler in `SA`. "Open in Séance" from a fourth app
  needs Séance-side work.

---

## 5. Doc and code drift found (relevant to planning)

- `seance/docs/POLTERGEIST.md:412-414,514-516` says Poltergeist reads `serverConfig`
  read-only and writes only `bookmark:` and `hostkey:`. The code writes
  `serverConfig` and `secret:` in shared mode (`bookmark_coordinator.dart:8-11,227-417`).
  P04 line 756 and lines 1513-1515 are likewise superseded by the 2026-09-24
  amendment (P04 lines 928-963).
- `seance/docs/POLTERGEIST.md:462-470` says a pulled `hostkey:` tombstone drops the
  local pin. In code, `hostkey:` tombstones are no-ops in both apps
  (`bookmark_coordinator.dart:1154-1165`; `sync_coordinator.dart:576-594`).
- The `PC/src/sync/record_crypto.dart:9-11` comment says "AES-256-GCM + HKDF-SHA256".
  The actual cipher is XChaCha20-Poly1305 (`SP/crypto/vault.dart:121-127`).
- Pin publication (§3.3 item 2) does not match P04 line 733.
- `SC/sync/local_record_store.dart:26-27` says "the Flutter app backs the same
  interface with SQLite". Séance actually uses an in-memory mirror per round, and
  Poltergeist uses a JSON file.

---

## 6. Checklist for the fourth app's catalog layer

1. Phase 0: extract `seance_catalog` (§3.4A). Export `batchForPush`. Resolve the
   §3.3 divergences with tests.
2. Shared-mode enrollment only, for the server list. Gate it on Séance >= v0.9.0
   with the user's fleet assertion. Disclose that the account key is unscoped and
   that #56 is open.
3. Own keystore prefix, `deviceId`, support directory, vault with re-key journal,
   and pin file.
4. Writable catalog with Séance-identical write semantics (§2.1). Show the catalog
   read-only until the user enrolls in shared mode, or offer ssh_config import for
   local-only use.
5. Credentials: honour the `syncSecrets` switch and per-server `syncSecret`. Prompt
   and store locally otherwise.
6. Host keys: quarantine model, publishing new pins deliberately, negative pins on
   forget.
7. Own kinds: new `RecordKind` values, unique `<app>:` prefix, small records, a
   sealed removal flag for safety-relevant entities, honour exclusion, no new
   `ServerConfig` fields.
8. Background connections, probing and polling only for endpoints this device has
   confirmed locally.
