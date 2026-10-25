# Catalog library design: `seance_core/catalog.dart`, pure stores, `ghost_keystore`, Séance #56

Status: proposed for the Klabautermann foundations (F3 and S9); approval under the owner's instruction of 2026-10-13 to implement the plan.

F-step: F3 of `docs/design/klabautermann/04-IMPLEMENTATION.md` section 13
(rows F3a to F3d of `03-ARCHITECTURE.md` section 3.5; decisions D3, D6, D7,
D13 to D17; sections 4.1 to 4.10 and 11.2; owner decisions 3 and 12 of
`04-IMPLEMENTATION.md` section 15). This document is also spike S9
(section 12).

Commit read: `20acafc7` (`git rev-parse --short HEAD` on this worktree's
main). All `path:line` references below are against that commit.
Abbreviations: `SC` = `seance/packages/seance_core`, `SP` =
`seance/packages/seance_protocol`, `PC` =
`poltergeist/packages/poltergeist_core`, `SA` = `seance/app/seance_app`,
`PA` = `poltergeist/app/poltergeist_app`.

## 1. Inventory

### 1.1 Poltergeist files that move into the catalog library

All under `PC/lib/src/`. None imports Flutter; the union of their
third-party imports is `dart:async`, `dart:convert`, `dart:io`, `dart:math`
and `package:seance_core/seance_core.dart` (verified by reading every
`import` line in both directories). Two seams must be resolved during the
move, both listed in the table.

| File | Lines | Public types | Role | Notes for the move |
|---|---|---|---|---|
| `bookmarks/bookmark_coordinator.dart` | 1543 | `BookmarkCoordinator` | The sync coordinator: re-seal, push loop, delta pull, prefix dispatch, LWW apply, quarantine, catalog rebuild | Becomes `RecordCoordinator`. Bookmark-specific members leave for `BookmarkHandler` (1.2). |
| `sync/persistent_record_store.dart` | 463 | `SyncRecordStore` interface (`:20`, extends `LocalRecordStore`), `PersistentLocalRecordStore` (`:101`) | `sync_records.json`: opaque `EncryptedRecord` mirror, dirty set, `displaced` map, `highWaterSeq`/`lastAppliedSeq` cursors (`:132-133`) | Injectable `atomicWriter` defaulting to `TransferJournalIo().atomicRewrite` (`:111`, impl `transfer/transfer_journal.dart:1352`). The default writer must move too (2.2). Format header `:86-91`. Corrupt file quarantines and restarts empty `:94-102`. |
| `sync/server_store.dart` | 450 | `FileServerConfigStore`, `ServerSyncTuple` (alias `:32`) | `servers.json` `{version, servers, syncTuples}` (`:124-126`) | Imports `BookmarkSyncTuple` from `bookmarks/bookmark_store.dart` (`:24`); the move generalizes it to `SyncTuple` (5.1). Row-preserving decode `:142-144`, `:368-375`, `:398-411`. Tombstone stamp `:74`. `atomicWriter` seam `:116`. |
| `sync/enrollment.dart` | 384 | `SyncAccount`, `SyncCredentialStore`, `SyncEnrollmentState`, `SyncEnrollmentApi` (`:68`), result/exception types | Enrollment state machine and credential seams | `SyncEnrollmentApi implements SyncApi` (`:68`): the enrollment transport stays an app-supplied implementation. |
| `sync/host_key_mutations.dart` | 94 | `ConflictAwareHostKeyStore` (`:10`), `HostKeyInstallResult` (`:4`), `HostKeyMutationGate` (`:24`), `InMemoryConflictAwareHostKeyStore` (`:35`) | Conditional pin writes (`putIfNoConflict` `:11`, `replaceIfCurrent` `:14`) and the cross-rebuild mutation gate | The quarantine handler (F3d) consumes these interfaces. |
| `sync/record_crypto.dart` | 43 | `RecordCrypto` (`:17`), `isDecryptableSyncId` (`:38`) | Throw-only `RecordCodec` wrapper; decryptable-prefix policy for enrollment trials | Comment at `:11` says AES-256-GCM + HKDF-SHA256; the codec is XChaCha20-Poly1305 (`SP/src/crypto/vault.dart:121,126-127`). Fix the comment in the move PR (15). |
| `sync/seance_server_catalog.dart` | 51 | `SeanceServerCatalog` (`:16`) | Read-only materialized server list rebuilt after each apply; `replace` setter plus `onReplaced` callback | Splits in two: `CatalogSnapshot` is the read-only interface apps consume (`servers`, `byId`); `CatalogController`, which adds `replace` and the change notification, is constructed and held only by `RecordCoordinator` (4). The shared write path is `CatalogWriter` (5.1). |
| `sync/server_order.dart` | 8 | `compareServersByLabel` | Label ordering for the catalog | Shared verbatim. |
| `sync/sync_verdicts.dart` | 111 | `PinVerdictStore` (`:22`), `SyncTripwireStore` (`:48`), in-memory impls (`:63`,`:96`) | Negative pins, kept verdicts, tripwire counters | Interfaces move to the catalog; durable implementations stay app-side (4). |

`SyncApi`, `HttpSyncClient`, `PullResponse`, `PushResponse` and
`PushLimits` are not in this list: Poltergeist already consumes Séance's
transport (`SC/src/sync/http_sync_client.dart`, 253 lines) through the
`poltergeist_core` barrel. There is no `sync_transport.dart` in
Poltergeist; the single push call is `bookmark_coordinator.dart:899`
(section 15 corrects a stale reference).

### 1.2 Bookmark-specific code that stays in Poltergeist

| File | Lines | Why it stays |
|---|---|---|
| `bookmarks/bookmark_store.dart` | 911 | `Bookmark`, `BookmarkStore`, `FileBookmarkStore`, `BookmarkSyncTuple` (the type `server_store.dart` aliases at `:32`). `bookmark:` payload shape and store are product data, not catalog mechanics. `atomicWriter` seam `:254`. |
| `bookmarks/bookmark_groups.dart` | 73 | Bookmark grouping for the browser UI. |
| `bookmarks/sort_key.dart` | 145 | Fractional sort keys for bookmark ordering. |
| `bookmark_coordinator.dart` remainder | n/a | After the move, the bookmark payload handlers, `bookmark:` id dispatch, group/version reconciliation and the `BookmarkSyncTuple` projection stay as `BookmarkHandler`, the per-prefix `RecordHandler` Poltergeist registers (5.2). |

Poltergeist's `excludeFromSync` uses are all in
`bookmark_coordinator.dart` (`:239,307,396,439,694,717,841,1346,1384,1479`);
the ones that guard bookmark writes move with `BookmarkHandler`, the ones
that guard generic record handling move with `RecordCoordinator`.

### 1.3 Séance reference implementation (does not move)

`SC/src/sync/` is the second implementation the divergences are measured
against. It is not extracted: Séance keeps its own coordinator until F7
(D6), and nothing here is copied into a third implementation (D3 cut
line).

| File | Lines | Role |
|---|---|---|
| `sync/sync_coordinator.dart` | 1243 | Séance `SyncCoordinator`. `applyToStores` `:527`; per-kind switch `:666-855`; hostKey case `:700-718` with the unguarded `hostKeyStore.put(pin)` at `:718` (#56, section 7); secrets collected during dispatch and applied last via `_applySecretRecords` (`:863`, `:949`); local-only locator set `:139-147`, applied at `:717`; `secret:`/`hostkey:` tombstone no-op `:576-594`; `RecordKind.bookmark`/`unknown` skip `:854-855`. |
| `sync/sync_engine.dart` | 249 | Push/pull loop driver. `RefusedRecord` `:26-70`; `_pullOnce` `:159-204` (full pull each round); `_pushOnce` calls `batchForPush(dirty, limits)` at `:216`. |
| `sync/push_batcher.dart` | 71 | `batchForPush` `:24`; enforces `PushLimits.maxBodyBytes`/`maxRecordsPerPush`/`maxBlobBytes` (`:8-15`, `:42-53`). Not currently exported by the `seance_core` barrel; F2e exports it and F3a depends on that export. |
| `sync/local_record_store.dart` | 69 | Séance's in-memory per-round record mirror. |
| `sync/http_sync_client.dart` | 253 | `SyncApi` and `HttpSyncClient` transport, already shared. |
| `sync/sync_enrollment_validation.dart` | 54 | Shared-account enrollment preflight. |
| `store/stores.dart` | 393 | `ConfigStore` `:12`, `SnippetStore` `:20`, `TombstoneStore` `:42`, `AssistantSettingsStore` `:75`, `VaultStore` `:132`, `SecretVault` `:171`, `InMemory*` `:286-378`. The catalog's store interfaces extend or parallel these. |
| `store/file_permissions.dart` | 24 | `restrictFileToOwner` (`:12`): the 0600 primitive the moved `atomicRewrite` needs (2.2). |

### 1.4 App-side composition and adapters (stay)

- `PA/lib/services/bookmark_backup_service.dart`: builds
  `BookmarkCoordinator` (`:471-486`, `deviceId` at `:477`); owns the
  shared-account switch whose step 9 re-seals non-held pins into
  `hostkey:` records (`:762-776`), the only path by which Poltergeist
  pins reach the account today (section 6, divergence 2).
- `PA/lib/services/engine_session.dart`: `_onPinPinned` persists engine
  `HostKeyPinnedEvent`s into the pin store (`:519-523`); the `pinStore`
  getter (`:509-511`) documents the single-store-over-`host_keys.json`
  invariant.
- `PA/lib/services/sync_credentials.dart`: `poltergeist.sync.deviceId`
  settings key (`:151`), `deviceId()` mint-once (`:167-171`).
- `PA/lib/main.dart`: constructs `FileBookmarkStore`,
  `FileServerConfigStore`, `FileVaultStore`,
  `PersistentLocalRecordStore`, pin/verdict/tripwire stores,
  `BookmarkBackupService`, enrollment state.
- `PA/lib/services/sync_account_gate.dart`: shared-account gate with
  `kMinimumSharedAccountSeanceVersion = 'v0.9.0'` (`:19`) and
  `kMinSharedVersionIncludesSeance56Fix = false` (`:27`, with the
  `v0.9.0`-predates-#56 comment `:22`). F3d flips this constant.
- `SA/lib/services/file_stores.dart` (616 lines) and
  `PA/lib/services/file_stores.dart`: F3b sources (section 8).
- `SA/lib/services/atomic_file.dart` (94): `writeStringAtomically` `:33`,
  owner-only variant `:94` (#80).
- `SA/lib/services/secure_master_key.dart` and
  `PA/lib/services/secure_master_key.dart`: F3c sources (section 9).

### 1.5 Tests that move or are added

Existing Poltergeist tests that move with the code (paths under
`PC/test/`): `sync/bookmark_coordinator_test.dart` 1796,
`sync/persistent_record_store_test.dart` 393, `sync/server_store_test.dart`
278, `sync/enrollment_test.dart` 738 (+ `fake_enrollment_api.dart` 179,
`fake_sync_api.dart` 107), `sync/push_revision_test.dart` 234,
`bookmarks/bookmark_store_test.dart` 1056, `bookmarks/sort_key_test.dart`
162, `integration/sync_server_convergence_test.dart` 511 (5,454 lines
total). Séance: `SC/test/sync_coordinator_test.dart` 3285,
`SC/test/sync_test.dart` 658. App-side: both apps carry
`keystore_resilience_test.dart` and `vault_rekey_journal_test.dart`;
Séance additionally `file_stores_test.dart` and
`vault_store_atomicity_test.dart`; Poltergeist `file_stores_test.dart`
and `settings_store_test.dart`.

## 2. Package proposal

### 2.1 Layout

`package:seance_core/catalog.dart` (D6) is a secondary library export of
`seance_core`, sources under `SC/lib/src/catalog/`:

```
catalog.dart                    secondary barrel (package:seance_core/catalog.dart)
record_coordinator.dart         RecordCoordinator (was BookmarkCoordinator)
record_handler.dart             RecordHandler, ApplyPhase, ApplyOutcome, ApplyContext (03 4.4)
push_policy.dart                PushPolicy { none, normal }
sync_tuple.dart                 SyncTuple (was BookmarkSyncTuple)
sync_record_store.dart          SyncRecordStore interface
persistent_record_store.dart    PersistentLocalRecordStore
server_config_store.dart        FileServerConfigStore (servers.json)
catalog_snapshot.dart           CatalogSnapshot: the read-only interface apps consume
catalog_controller.dart         CatalogController: CatalogSnapshot plus replace/onReplaced, held only by RecordCoordinator
catalog_writer.dart             CatalogWriter: the shared write path (03 4.4 "Write semantics")
endpoint_pin_store.dart         EndpointPin, EndpointPinStore (new, D16/4.7)
enrollment.dart                 SyncEnrollment, SyncEnrollmentApi, SyncAccount,
                                SyncAccountMode, SyncCredentialStore,
                                SyncEnrollmentState, EnrollmentResult,
                                SyncEnrollmentException, KdfDowngradeException,
                                RegistrationClosedException, the notice keys and
                                two message constants (enrollment.dart:15-384)
host_key_handler.dart           HostKeyHandler: quarantine apply and publication seam
server_config_handler.dart      ServerConfigHandler
secret_handler.dart             SecretHandler (publication and excluded-server shield)
pin_verdicts.dart               PinVerdictStore, SyncTripwireStore,
                                InMemoryPinVerdictStore, InMemorySyncTripwireStore
host_key_mutations.dart         ConflictAwareHostKeyStore, HostKeyInstallResult,
                                HostKeyMutationGate, InMemoryConflictAwareHostKeyStore
record_crypto.dart              RecordCrypto, isDecryptableSyncId
atomic_file_writer.dart         temp+rename+fsync default for the store seams
server_order.dart               compareServersByLabel
```

The in-memory implementations move with their interfaces because the
moved tests construct them: `enrollment_test.dart:111,113-114,138-141`
builds `InMemoryConflictAwareHostKeyStore`, `InMemoryPinVerdictStore` and
`InMemorySyncTripwireStore`, and `bookmark_coordinator_test.dart` and
`push_revision_test.dart` do the same. `SyncEnrollmentApi` and the
enrollment result and exception types move in full (they are the
enrollment surface, not an app seam); what stays app-side is only the
durable storage behind the interfaces: Poltergeist's
`SettingsPinVerdictStore`/`SettingsSyncTripwireStore`
(`PA/services/sync_verdict_stores.dart`) and both apps' settings-backed
`SyncEnrollmentState`/`SyncCredentialStore`, plus the app-rendered copy of
the enrollment messages (the `sync*Message` constants move; each app's ARB
string stays).

Under `SC/lib/src/store/` (F3b): `file_vault_store.dart`
(`FileVaultStore`, `VaultRekeyJournal`, `VaultRekeyOutcome`) and
`file_host_key_store.dart` (`FileHostKeyStore`). Beside them,
`file_endpoint_pin_store.dart` (`FileEndpointPinStore`,
`EndpointPinsNewerVersionException`, `endpointPinsFileName`) is the
first `EndpointPinStore` (section 2.2).

Under `planchette/packages/ghost_keystore/` (F3c): a Flutter package
wrapping `flutter_secure_storage`, so it cannot live in pure-Dart
`seance_core`. It exports `MasterKeyManager` parameterized by entry
prefix plus `MasterKeyUnavailableException`. Registration follows
`04-IMPLEMENTATION.md` 12.2: owned pubspec at suite version, release-tool
  owned-list entry, CI resolve/analyze/test/format lines, `scripts/test.sh`
  entry, and `poltergeist/docs/PORTS.md` ledger entries. The Séance
  follow-up PR switches only Séance's keystore construction (its vault
  master-key entry and `apikey` namespace) onto the package, not its sync
  coordinator, which stays Séance's own until F7 (D6); that PR changes
  `seance/` lineage and so runs the Séance pin-audit check (11, 13).

### 2.2 Dependency check

Allowed `seance_core` deps today
(`seance/packages/seance_core/pubspec.yaml:14-27`): `seance_protocol`
(path), `dartssh2` (exact 4.1.0), `http`, `crypto`, `ffi`, `meta`,
`posix`. The moved code needs only `dart:*` and `seance_protocol` types
(`EncryptedRecord`, `DecryptedRecord`, `RecordCodec`, `RecordKind`,
`HostKey`, `ServerConfig`, `SyncApi` DTOs, `PushLimits`), plus `meta` for
annotations. No `dartssh2`, no Flutter, no `dart:ui`; the catalog stays
outside D4's confinement zone question entirely.

One boundary break exists today and is fixed in the move:
`persistent_record_store.dart:14`, `server_store.dart:25` and
`bookmark_store.dart:27` import `TransferJournalIo` from
`PC/src/transfer/transfer_journal.dart`, which itself imports
`package:path` and Poltergeist checkout/fs files (`:33-38`). The stores
use only `TransferJournalIo().atomicRewrite`
(`transfer_journal.dart:1352-1393`: temp+rename, `fsyncDirectory` `:1331`).
Recommendation: carry a minimal `AtomicFileWriter` in
`src/catalog/atomic_file_writer.dart` implementing the same write order
(temp sibling, fsync, rename, directory fsync) and the same permission
model. Two owner-restriction primitives exist today and they differ:

- `restrictFileToOwner` (`SC/src/store/file_permissions.dart:12-16`):
  Linux and macOS only; in-process `posix.chmodWithMode` to 0600 (0700
  through `restrictDirectoryToOwner`, `:20-24`); a failed chmod is
  ignored; a no-op elsewhere, so Windows and mobile keep their per-user
  storage ACLs.
- `restrictLocalPathPermissions` (`PC/src/fs/local_fs_safety.dart:204-233`):
  Linux and macOS only; runs `chmod` resolved by absolute path
  (`/usr/bin/chmod`, `/bin/chmod`) so a PATH-hijacked shim cannot silently
  defeat it; throws `FileSystemException` when chmod is unavailable or
  exits nonzero, so the write aborts rather than landing lax; a no-op
  elsewhere.

Both target the same bits (0600 file, 0700 directory) and both leave
Windows and mobile to their ACLs, so neither widens Windows. They differ
in failure handling. `atomicRewrite`'s `restrictToOwner` path uses
`restrictLocalPathPermissions`, restricting the empty temp before any
content lands and the destination again after the rename
(`transfer_journal.dart:1360-1380`); `writeStringAtomically(ownerOnly)`
uses `restrictFileToOwner` on the temp only
(`SA/services/atomic_file.dart:61-64`, `PA/services/atomic_file.dart:27-30`).

The writer uses the fail-closed behaviour of
`restrictLocalPathPermissions`, which moves with the stores into
`SC/src/store/file_permissions.dart` beside `restrictFileToOwner` (a
`seance_core` file cannot import `poltergeist_core`;
`local_fs_safety.dart` keeps its name as a re-export, so Poltergeist's
other callers do not change), and it keeps the caller's privacy choice. Today Poltergeist's
sync stores write with `restrictToOwner: false`
(`server_store.dart:116`, `persistent_record_store.dart:111`), so
`servers.json` and `sync_records.json` stay at the process default, and
the F3b vault store keeps `ownerOnly`
(`PA/services/file_stores.dart:135-139`), so `vault.json` stays 0600. Every
file is therefore at least as restricted as today, and a chmod failure
aborts the write instead of leaving a lax file; Poltergeist's bytes and
crash semantics are otherwise identical, and the `atomicWriter`
constructor seam stays for deterministic tests.

Layering: app adapters implement `SyncCredentialStore`,
`PinVerdictStore` and `SyncTripwireStore` persistence, and supply
their prefix handlers (`BookmarkHandler` for Poltergeist, the
`klabautermann:` handler for the new app).
`CatalogWriter` is library code the apps call, not a seam they
implement. The catalog depends on `seance_protocol` and app-injected
stores only; apps depend on `catalog.dart`, never the reverse.

`EndpointPinStore` persistence is library code instead:
`FileEndpointPinStore` keeps `endpoint_pins.json` (03 4.10) as
`{"version": 1, "pins": [...]}`, each pin `{serverId, host, port,
username, jumpRouteIds, confirmedAt}` with `confirmedAt` in epoch
milliseconds, sorted by `serverId` and rewritten whole through
`AtomicFileWriter` at the process default mode, with the `atomicWriter`
seam. It follows `FileHostKeyStore`'s conventions: serialized loads and
mutations, a load-once cache that changes only after the write lands,
and `quarantineCorruptFile` for a corrupt file (bad JSON, shape or
version, or any malformed or duplicate entry), after which the store
starts empty. A newer `version` is left in place: lookups find no pin
and changes throw `EndpointPinsNewerVersionException`. Both failures
fail closed, since a server without a pin gets no background
connection. `confirm` replaces a server's pin whole, `drop` of a server
without a pin is a no-op, and `pinFor` answers null for one. The
interface and `EndpointPin` live under `SC/lib/src/catalog/`, the file
store under `SC/lib/src/store/` beside `FileHostKeyStore`; the catalog
barrel exports all of them, so Klabautermann (and later Séance and
Poltergeist, D16) construct the store over their own support directory.

## 3. String injection

No user-facing strings move. `RecordCoordinator` and the stores surface
errors as typed outcomes (`SyncEnrollment` exceptions, quarantine
events, `HostKeyInstallResult`), and each app's existing copy stays
app-side: Poltergeist's Settings/Backup quarantine notices, Séance's
vault and host-key dialogs. `ghost_keystore` reports
`MasterKeyUnavailableException`; the status text each app renders from
it remains in that app's ARB files. No ARB adapter or string bag is
needed for this step.

## 4. Public API

Signatures below are the intended surface of
`package:seance_core/catalog.dart`; member names follow the code they
generalize.

```dart
/// Ordering/push behaviour for one coordinator.
enum PushPolicy { none, normal }

/// One (updatedAt, deviceId) write stamp; was BookmarkSyncTuple
/// (bookmark_store.dart:80-127). The moved type does NOT implement
/// Comparable<BookmarkSyncTuple> and has no compareTo; the total order
/// Poltergeist uses today is the inline guard `_outranksMaterialized`
/// (bookmark_coordinator.dart:1196-1204): a record applies when its
/// `updatedAt` is strictly greater than the materialized tuple's, or
/// `updatedAt` is equal and its `deviceId.compareTo(materialized.deviceId)`
/// is >= 0: a higher lexicographic deviceId wins, and an exact tie (same
/// updatedAt and deviceId) also applies, the same winning envelope
/// arriving again, idempotent by construction. The `deleted` flag rides
/// the tuple but is not part of that order.
final class SyncTuple {
  const SyncTuple({
    required this.updatedAt,
    required this.deviceId,
    this.deleted = false,
  });
  final int updatedAt;
  final String deviceId;
  final bool deleted;                // tombstone tuple (bookmark_store.dart:83)
  /// The same total order `_outranksMaterialized` applies to records,
  /// exposed for tuple-to-tuple comparison; not `Comparable`, matching
  /// today's type.
  bool outranks(SyncTuple other);
  Map<String, Object?> toJson();
  factory SyncTuple.fromJson(Map<String, Object?> json);
}

/// Opaque record mirror (sync_records.json); moves verbatim.
abstract interface class SyncRecordStore implements LocalRecordStore {
  // From LocalRecordStore (SC/src/sync/local_record_store.dart:10-23):
  //   allRecords(), getRecord(id), putLocal()   (marks dirty),
  //   putRemote(), dirtyRecords(), markSynced(id, seq),
  //   highWaterSeq(), setHighWaterSeq(seq)
  Future<EncryptedRecord?> settlePush(EncryptedRecord sent, PushResult result);
  Future<int> lastAppliedSeq();
  Future<void> setLastAppliedSeq(int seq);   // monotone
  Future<void> resetSyncCursors();
  Future<List<EncryptedRecord>> displacedRecords();
}

/// Phase order for one apply pass: configs, then pins, then secrets
/// last (03 4.4). Poltergeist implements the special case today:
/// every non-secret kind in seq order, then secrets
/// (bookmark_coordinator.dart:1096-1112).
enum ApplyPhase { configs, pins, secrets }

/// What one record may do: exactly the three values of the private
/// `_ApplyOutcome` the code has today (bookmark_coordinator.dart:29).
/// `applied` and `skipped` let the apply cursor advance; `deferred` parks
/// the record. The cursor cap is coordinator logic, not an outcome value:
/// the coordinator tracks the lowest deferred seq in a local `blockedAt`
/// and clamps `advanceTo = blocked - 1`, so the cursor never advances past
/// a deferred record (bookmark_coordinator.dart:1073-1088, the clamp at
/// :1125-1130; displaced pulled losers also defer, :1118-1124).
enum ApplyOutcome { applied, skipped, deferred }

/// Per-round state a handler needs; built once per apply pass.
final class ApplyContext {
  final SyncRecordStore records;
  final RecordCrypto crypto;
  final CatalogWriter writer;        // re-dated retractions seal back via sealLocal (the 1347-1358 case)
  final SyncTripwireStore tripwires;
  final bool holdActive;             // passphrase hold (03 4.5)
  final DateTime Function() now;
}

/// Per-prefix record semantics (03 4.4). Dispatch routes on the
/// plaintext id prefix before decrypting; unknown prefixes are skipped
/// undecrypted (bookmark_coordinator.dart:1153-1181).
abstract interface class RecordHandler {
  /// First id segment before ':'; null handles bare ids (serverConfig).
  String? get prefix;
  ApplyPhase get phase;              // configs, then pins, then secrets last
  Future<ApplyOutcome> applyLive(EncryptedRecord record, ApplyContext ctx);
  Future<ApplyOutcome> applyTombstone(EncryptedRecord record, ApplyContext ctx);
}

final class RecordCoordinator {
  RecordCoordinator({
    required SyncRecordStore records,
    required SyncTrackingServerStore servers,
    required RecordCrypto crypto,
    required SyncEnrollmentState enrollment,
    required List<RecordHandler> handlers,
    required ConflictAwareHostKeyStore hostKeys,
    required PinVerdictStore pinVerdicts,
    required SyncTripwireStore tripwires,
    /// Shared mode builds and holds the [CatalogController]; separate
    /// mode has none and never decrypts prefixless ids.
    required CatalogMode catalogMode,
    /// Change notification for [catalog] (today's app-built `onReplaced`,
    /// bookmark_backup_service.dart:252-260). Optional, never a mode
    /// switch; passing it in separate mode throws an ArgumentError.
    void Function(List<ServerConfig> snapshot)? onCatalogReplaced,
    required PushPolicy pushPolicy,
    required String deviceId,
    DateTime Function()? now,
  });
  Future<SyncRoundResult> runRound(SyncApi api);
  /// Read-only view of the server materialization; null in separate mode.
  CatalogSnapshot? get catalog;
  Future<List<PinConflict>> pinConflicts();
  Future<void> keepLocalPin(PinConflict conflict);
  Future<void> acceptPulledPin(PinConflict conflict);
  Future<void> reSealAfterStoreLoss();
  Future<void> rebuildCatalog();
}

/// The shared write path (03 4.4 "Write semantics (v1)"): every
/// change-driven seal goes through here. Replaces BookmarkCoordinator's
/// `on*` methods and `_seal*`/`_publish*`/`_retract*` internals.
final class CatalogWriter {
  CatalogWriter({
    required SyncRecordStore records,
    required SyncTrackingServerStore servers,
    required SecretVault? secrets,
    required RecordCrypto crypto,
    required String deviceId,
    required PushPolicy pushPolicy,
    bool syncSecrets = false,  // Poltergeist's default (bookmark_coordinator.dart:112)
    DateTime Function()? now,
  });
  Future<WriteOutcome> saveServer(ServerConfig server);    // was onServerSaved
  Future<WriteOutcome> deleteServer(ServerConfig server);  // was onServerDeleted
  Future<WriteOutcome> secretSaved(String secretId);       // was onServerSecretSaved
  Future<WriteOutcome> publishPin(HostKey pin);            // deliberate publication (v1; was onHostKeyPinned)
  Future<WriteOutcome> forgetPin(String host, int port);   // was onHostKeyForgotten
  /// crypto.seal + records.putLocal: the single funnel every dirty
  /// record arrives through; PushPolicy.none stops it here.
  Future<WriteOutcome> sealLocal(DecryptedRecord record);
}

/// Whether pulled prefixless `serverConfig` records materialize (04 4.2).
/// Today the app selects shared mode by passing a `SeanceServerCatalog`
/// rather than null (bookmark_coordinator.dart:109,161-164); the
/// coordinator now builds the controller itself, so the mode is explicit.
enum CatalogMode { shared, separate }

/// Result of a [CatalogWriter] mutation. [refusedPullOnly] means
/// `PushPolicy.none`: the call returned before touching any local store,
/// sealing any record, or changing any verdict. [written] means the policy
/// allowed the call to run; it may still be a domain no-op (for example
/// `secretSaved` with `syncSecrets` off, `bookmark_coordinator.dart:304`).
enum WriteOutcome { written, refusedPullOnly }

/// The read-only interface apps consume (the public half of the old
/// SeanceServerCatalog, seance_server_catalog.dart:16-51): `servers`
/// (sorted by `compareServersByLabel`) and `byId`. No mutator and no
/// change registration reach an app.
abstract interface class CatalogSnapshot {
  List<ServerConfig> get servers;
  ServerConfig? byId(String id);
}

/// The mutable controller: [replace] is the coordinator's rebuild (today's
/// `_rebuildCatalog`, bookmark_coordinator.dart:1515-1542) and the
/// notification is the app-supplied callback the coordinator passes in.
/// Constructed and held only by `RecordCoordinator`; apps never see it.
/// It stays a separate type from `CatalogWriter`: reading and writing the
/// catalog are different seams.
final class CatalogController implements CatalogSnapshot {
  CatalogController({void Function(List<ServerConfig> snapshot)? onReplaced});
  @override
  List<ServerConfig> get servers;
  @override
  ServerConfig? byId(String id);
  void replace(Iterable<ServerConfig> servers);
}

/// Confirmed endpoint tuple per serverId (D16, 03 4.7): `EndpointPin`
/// is `{serverId, host, port, username, jumpRouteIds, confirmedAt}`.
/// `FileEndpointPinStore` implements it (section 2.2).
abstract interface class EndpointPinStore {
  Future<EndpointPin?> pinFor(String serverId);
  Future<void> confirm(EndpointPin pin);
  Future<void> drop(String serverId);
}
```

Store interfaces that already exist in `SC/src/store/stores.dart`
(`ConfigStore` `:12`, `VaultStore` `:132`, `HostKeyStore` via
`SC/src/hostkey/tofu.dart`) are reused; `SyncTrackingServerStore` is
the interface `FileServerConfigStore` already declares
(`server_store.dart:37-72`: `save`/`remove`/`byId`/`load`,
`syncTuples()`, `syncTupleOf`, `applySyncedRecord`,
`removeSyncedRecord`). `PinVerdictStore` and
`SyncTripwireStore` remain interfaces; Poltergeist keeps its durable
implementations and Klabautermann writes its own files (03 4.10).

Dispatch rules the coordinator keeps (all in
`bookmark_coordinator.dart`): route by the first `:` segment of the
plaintext record id (`:1153`), unknown prefixes return `skipped`
without decrypting (`:1178-1181`), tombstones dispatch on the prefix
alone (`:1154-1164`), payload id must equal the envelope id
(`:1292,:1332,:1442`), and every applied record clears its tripwire
(`:1229,:1296,:1339,:1449`). `hostkey:`, `secret:` and `snippet:`
tombstones are never honoured: `applyTombstone` for those prefixes
returns `ApplyOutcome.skipped` (the `_dispatch` tombstone table at
`:1154-1164` routes them to the no-op; Séance today applies `snippet:`
tombstones, `sync_coordinator.dart:655-662`, and the kept-behaviors
list in 03 4.4 resolves this to Poltergeist's rule with Séance
unchanged until F7). `klabautermann:` records ignore unsealed
tombstones entirely (sealed `removed` records only, D17).
`ServerConfigHandler` (prefix `null`) and `BookmarkHandler`
(`bookmark:`) honour tombstones through `applyTombstone`
(`:1154-1164`; `_applyServerConfigTombstone` `:1378-1412`,
`_applyBookmarkTombstone` `:1248-1267`).

`CatalogWriter` reproduces the write semantics both apps already
follow (03 4.4 "Write semantics (v1)"; every rule has one Poltergeist
owner today):

- re-stamp `updatedAt = max(now, stored + 1)`:
  `FileServerConfigStore.save` (`server_store.dart:166-184`; the
  doc comment at `:169-171`, the stamp at `:172-174`).
- seal with this install's `deviceId`: every seal call site
  (`bookmark_coordinator.dart:202,220,246,287,326,375,412,481,506`);
  the store's local tuple binds the same id (`server_store.dart:251-255`,
  `syncDeviceId` at `:137`).
- clear a pending tombstone on save: `save` writes a live tuple over
  the tombstone tuple (`server_store.dart:176-182`) and
  `records.putLocal` replaces the stored tombstone record
  (`persistent_record_store.dart:170-186`).
- persist a delete tombstone before dropping the row: `remove` writes
  the tombstone tuple in the same atomic `_writeNext` document as the
  row drop (`server_store.dart:196-206`); `deleteServer` then seals
  the matching tombstone record (`bookmark_coordinator.dart:269-291`,
  `deletionStamp` at `:277-280`).
- retract an orphaned `secret:` unless another non-excluded server
  shares it (`bookmark_coordinator.dart:392-417`; the sharer check at
  `:395-397`, the `server.excludeFromSync` clause at `:396`).
- require a strictly later `updatedAt` for exclusion toggles: the
  toggle flows through `save`'s re-stamp, and the excluded branch
  seals the retraction tombstone at that new stamp
  (`bookmark_coordinator.dart:235-251`); a pulled live record at an
  older stamp is re-dated past it (`:1346-1359`).

The shared editor (F5a, not this step) copies unknown and unshown
fields from the stored config; the writer receives the full
`ServerConfig` the editor assembled (`_formConfig` carries
`jumpHostId`, `server_editor.dart:1095-1098`, and `startDirectory`),
and undecodable rows stay verbatim through `_preserved`
(`server_store.dart:142-144,368-375,424`).

Under `PushPolicy.none` (D14, 03 4.4 "Pull-only mode") sealing,
catalog writes, pin publication and secret publication are disabled.
Every `CatalogWriter` mutating call (`saveServer`, `deleteServer`,
`secretSaved`, `publishPin`, `forgetPin`) checks the policy at entry and
returns `WriteOutcome.refusedPullOnly` before it touches any local store:
`saveServer` does not reach `servers.save`, `deleteServer` does not reach
`servers.remove` or the row drop, `secretSaved` does not read
`servers.load`, and `forgetPin` does not add its negative pin. Refusing
before any write is the point: today `onServerSaved` persists the row and
then seals (`bookmark_coordinator.dart:235-267`), so under `none` a
device-local edit would survive with no record behind it and the next
pulled `serverConfig` would silently undo it. The MVP app offers no server
editing, so no call is made; the typed refusal is what proves nothing
changed. `CatalogWriter.sealLocal` is the second funnel and the same
one-gate shape `_publishSecret` uses for `_syncSecrets`
(`bookmark_coordinator.dart:336-346`): under `none` it returns
`refusedPullOnly` before `crypto.seal`, so `records.putLocal` never runs
and no record is marked dirty. `runRound`'s push branch
(`bookmark_coordinator.dart:894-933`) is skipped under `none` as it
already is under `_pushesHeld()`, so nothing is pushed even if a record
somehow became dirty. The re-seal paths (`reSealAfterStoreLoss`,
`reSealPendingWrites`, `catchUpSecrets`, the shared-account switch's
step 9), keep-local's re-push of the kept pin
(`bookmark_coordinator.dart:534-546`) and an excluded server's re-dated
retraction during apply (`:1346-1358`) return without sealing for the
same reason: every one of them funnels through `sealLocal`.

Pulling is unaffected. Handlers apply pulled records by writing the
stores directly (`applySyncedRecord`, the host-key store), never through
the mutating `CatalogWriter` calls, so a pull-only round still
materializes pulled servers. Conflict resolution stays available too:
`keepLocalPin` and `acceptPulledPin` are coordinator calls that change
the local pin and verdicts; only keep-local's seal stops at `sealLocal`.
The pull-only test (03 11.2 item 4; section 11) asserts a full round
marks nothing dirty, sends no `api.push` and still materializes the
round's pulled `serverConfig` records in `catalog`; zero dirty marks
transitively proves zero seals.

`ghost_keystore` (section 9):

```dart
final class MasterKeyManager {
  MasterKeyManager({
    required String masterKeyEntry,   // e.g. 'poltergeist.vault.masterKey.v1'
    required String apiKeyPrefix,     // e.g. 'poltergeist.apikey.'
    FlutterSecureStorage? storage,
  });
  Future<Uint8List> loadOrMint({required bool hasExistingVault});
  Future<String?> apiKey(String name);
  Future<void> setApiKey(String name, String? value);
}
final class MasterKeyUnavailableException implements Exception { ... }
```

## 5. Extraction design: what `RecordCoordinator` keeps, what handlers get

### 5.1 The generalization is mechanical

`BookmarkCoordinator` is already prefix-dispatched on record ids and
already does the generic work the shared coordinator owns: apply loop
with deferred-record parking (`bookmark_coordinator.dart:1052-1136`),
cursor rules, secret-last ordering, quarantine resolution
(`:513-635`), push loop (`:866-940`). The move:

1. Rename `BookmarkCoordinator` to `RecordCoordinator`; the constructor
   takes `List<RecordHandler>` instead of a `BookmarkStore`.
2. `BookmarkSyncTuple` becomes `SyncTuple` in
   `src/catalog/sync_tuple.dart`; the `server_store.dart` alias (`:32`)
   dissolves.
3. `SeanceServerCatalog` splits into `CatalogSnapshot` (the read-only
   interface apps consume: `servers`, `byId`) and `CatalogController`
   (`CatalogSnapshot` plus `replace` and the change notification), which
   only `RecordCoordinator` constructs and holds (section 4). The
   coordinator still rebuilds it after each apply (`_rebuildCatalog`,
   `bookmark_coordinator.dart:1515-1542`); the app keeps reading `servers`
   through the snapshot, and its notification callback
   (`seance_server_catalog.dart:16-51`; the app side at
   `bookmark_backup_service.dart:252-260`) becomes the coordinator's
   construction callback. The app's nullable `catalog` argument, today's
   mode switch, becomes the explicit `CatalogMode`. The write path moves
   the other direction: `BookmarkCoordinator`'s `on*`/`_seal*`/`_publish*`/
   `_retract*` members become `CatalogWriter` (section 4).
4. `PushPolicy.none` refuses every mutating call with
   `WriteOutcome.refusedPullOnly` and short-circuits `sealLocal` and the
   push branch, so sealing, catalog writes, pin publication and secret
   publication cannot run (D14; section 4; test in section 11).
5. `isDecryptableSyncId` (`record_crypto.dart:38-43`, today prefixless +
   `bookmark` + `hostkey` only) becomes derived from handler
   registration, so `klabautermann:` records are never trial-decrypt
   candidates.

### 5.2 `BookmarkHandler` (stays in `poltergeist_core`)

Implements `RecordHandler` for prefix `bookmark`: the `bookmark:`
payload shape, `BookmarkSyncTuple` to `SyncTuple` reads, group/version
reconciliation, and the `excludeFromSync` guards
(`bookmark_coordinator.dart:239,307,396,439,694,717,841,1346,1384,1479`)
that pertain to bookmark writes. `FileBookmarkStore`, `bookmark_groups`
and `sort_key.dart` stay under `PC/src/bookmarks/`.

### 5.3 Generic handlers the library ships

- `ServerConfigHandler` (`prefix == null`, `ApplyPhase.configs`): the
  put/delete paths of `bookmark_coordinator.dart:227-417` minus
  credential publication; honours tombstones (`:1378-1412`).
- `HostKeyHandler` (`hostkey`, `ApplyPhase.pins`): pulled-pin apply
  through `ConflictAwareHostKeyStore` quarantine (section 7), the
  deliberate publication seam of divergence 2, and `applyTombstone`
  returning `skipped` (`:1154-1164`).
- `SecretHandler` (`secret`, `ApplyPhase.secrets`): seal `secret:`
  records (`:333` onward), the excluded-server shield (divergence 1
  resolution), secret-last apply ordering matching Séance
  (`sync_coordinator.dart:863`), so exclusion shielding sees the
  round's final server set, and `applyTombstone` returning `skipped`.

## 6. The five divergences (03 4.4; owner approved the resolutions 2026-10-10)

Each lands as its own PR after the move PR, with its own tests and a
`poltergeist/docs/PORTS.md` ledger line where Poltergeist code changes.

### Divergence 1: local-only host-key locators

Séance builds `localOnlyLocators` including locators used only by
`excludeFromSync` servers (`sync_coordinator.dart:139-147`, shield applied
at `:717`; related `:122`, `:246`) and withholds those pins from sync.
Poltergeist has no locator shield: `excludeFromSync` gates bookmark and
secret writes (`bookmark_coordinator.dart` uses listed in 1.2) but a
pulled or locally verified pin for an excluded-only address is not
withheld. Approved resolution: adopt Séance's privacy rule in the shared
`HostKeyHandler`. PR adds shield tests over exclusion toggles.

### Divergence 2: pin publication

`BookmarkCoordinator.onHostKeyPinned` exists
(`bookmark_coordinator.dart:474-487`) but has no app call site; engine
pin events are persisted locally (`engine_session.dart:519-523`), and
pins reach the account only through the shared-account switch re-seal
(`bookmark_backup_service.dart:762-776`). Séance publishes first-seen
pins on verify. Approved resolution: the shared writer supports
deliberate publication; Klabautermann publishes first-seen pins only
from v1 and only after #56 (D15, 03 4.6); Poltergeist behavior is
unchanged by the move. PR wires the seam and its tests; no default
change.

### Divergence 3: push batching

Séance batches dirty records against server-advertised limits:
`sync_engine.dart:216` calls `batchForPush` (`push_batcher.dart:24`)
enforcing `PushLimits` defaults of 1000 records, 8 MiB body, 1 MiB blob
(`SP/src/sync/dtos.dart:105,102,108`). Poltergeist pushes the entire dirty
set in one call (`bookmark_coordinator.dart:895-899`, `api.push(dirty)`
at `:899`). Approved resolution: shared code uses `batchForPush` with
those limits (F2e exports it first). PR adds over-limit batching tests
against a fake `SyncApi`.

### Divergence 4: full versus delta pull

Séance pulls everything each round (`_pullOnce`,
`sync_engine.dart:159-204`; the record mirror is in-memory per round,
`local_record_store.dart`, 69 lines). Poltergeist pulls deltas via the
`since` cursor (`highWaterSeq`/`lastAppliedSeq`,
`persistent_record_store.dart:132-133`; cursor advance rules in the
apply loop `bookmark_coordinator.dart:1052-1136`). Approved resolution:
the shared coordinator retains delta pulls with a full-resync fallback;
Séance is unchanged until F7. PR adds delta/fallback tests.

### Divergence 5: undecodable rows

Séance quarantines the whole file on any decode failure
(`SA/services/file_stores.dart:22-33`). Poltergeist preserves undecodable
rows in place (`server_store.dart:142-144,368-375,398-411`). Approved
resolution: the shared store keeps Poltergeist's row-preserving
behavior; Séance unchanged until F7. PR adds mixed-valid/corrupt file
tests.

## 7. F3d: Séance #56, pulled `hostkey:` records must quarantine

Current path (all `SC/src/sync/sync_coordinator.dart`): `applyToStores()`
(`:527`) iterates pulled records; the `RecordKind.hostKey` case
(`:700-718`) decodes `HostKey.fromJson(dec.data)`, enforces the
id/locator invariant (`:707-716`), skips local-only locators (`:717`),
then calls `await hostKeyStore.put(pin)` at `:718`. That `put`
overwrites whatever pin exists: no `conflictsWith` check, no quarantine,
no verdict consultation. A pulled pin for a locator whose local pin
differs replaces it silently; on a hostile network a forged record wins
TOFU on every Séance device. That is issue #56.

Fix: route the hostKey case through the library's quarantine handler,
`ConflictAwareHostKeyStore.putIfNoConflict`
(`host_key_mutations.dart:11`, returning
`HostKeyInstallResult {installed, conflict}` at `:4`). On `conflict`, the
pulled pin is not written into `host_keys.json`; the conflict is
re-derived on each round from the round's pulled `hostkey:` records
against the live store. Séance's pulled mirror is in-memory per round
(`local_record_store.dart`; the app constructs `InMemoryLocalRecordStore`,
`SA/services/app_services.dart:954`), so like Poltergeist the quarantine
is re-derived rather than stored, and the pulled key never lands in the
pin file. Séance gains a `ConflictAwareHostKeyStore` implementation over
its `FileHostKeyStore` (SA `services/file_stores.dart:554`; F3b extracts
it), or a thin adapter if F3d lands first. This changes only Séance's
pulled-pin conflict check, not its dispatch: Séance's `SyncCoordinator`
stays its own until F7 (D6).

Séance's minimal `PinVerdictStore` implementation lives app-side over its
own settings (`AppSettings`, `SA/services/app_settings.dart`), mirroring
Poltergeist's `SettingsPinVerdictStore`
(`PA/services/sync_verdict_stores.dart:21-92`) with two keys: the
negative-pin set and the kept-verdict map. It persists in settings, never
the record store, for the reason stated in `sync_verdicts.dart:1-6`: the
record store's corruption quarantine would erase the very verdict that
guards it. Séance has no "forget host" removal today (`HostKeyStore` at
`SC/src/hostkey/tofu.dart:30-34` offers no removal; the app builds only
`FileHostKeyStore`, `SA/services/app_services.dart:284`), so
`negativePins()` stays empty and `addNegativePin` is unused until that UI
exists; `removeNegativePin` is exercised by accept-pulled, and the
kept-verdict pair is what stops a resolved conflict re-warning.

Resolution surface: a Settings > Sync list of the re-derived conflicts
(the model is Poltergeist's `backup_enrolled_view.dart:174`), each row
offering **keep local** (record the rejected fingerprint through
`recordKeptVerdict` and re-install the local pin) and **accept pulled**
(install the pulled key and clear any negative pin): the two operations
`RecordCoordinator.keepLocalPin`/`acceptPulledPin` perform today
(`bookmark_coordinator.dart:513-565`). A legitimate key rotation also has
a path through the existing connection flow: the next connect presents the
pulled key as `HostKeyVerdict.changed`, and trusting it pins it
(`showHostKeyDialog`, `SA/ui/host_key_dialog.dart:7-84`; `TofuVerifier.pin`,
`tofu.dart:61-62`), after which the re-derived diff finds no conflict. That
dialog's changed-key branch already shows both fingerprints and the
warning, so F3d reuses its presentation; its Cancel/Trust pair does not
express keep-local, so F3d adds a small pulled-pin resolution sheet built
on the same `_Fingerprint` widgets (`host_key_dialog.dart:86-106`) with
"Keep local key" and "Trust the pulled key". No pin stays quarantined
without a resolution path, and a conflict the user already resolved is not
re-warned.

Regression test (fails before, passes after; 03 11.2 item 7): device A
pins `host:22` to key K1 and pushes; a fake server returns a pulled
`hostkey:host:22` record carrying K2. Assert the device keeps K1, records
a quarantined conflict, and leaves `host_keys.json` unchanged; before the
fix, the store returns K2.

Poltergeist's apply path already quarantines
(`bookmark_coordinator.dart:513-635`), so the shared `HostKeyHandler` is
Poltergeist's logic generalized; F3d is Séance adopting the quarantine
check, not the shared dispatch. After it
ships, `sync_account_gate.dart:27` flips
`kMinSharedVersionIncludesSeance56Fix` in the release that carries it,
and the Séance pin audit (`poltergeist/tool/seance_pin_audit`,
`poltergeist/scripts/audit-seance-pin.sh`) runs because `seance/`
changed, refreshing its record only if it reports a mismatch (section 11).

As built (M4 E06): `SyncCoordinator` takes a `ConflictAwareHostKeyStore`
and an optional `PinVerdictStore`, writes a pulled pin only through
`putIfNoConflict`, and exposes the round's conflicts as `pinConflicts`
(the shared `HostKeyConflict`). `PulledPinResolver`
(`SC/src/sync/pulled_pin_resolver.dart`) performs keep-local and
accept-pulled through `replaceIfCurrent`, so a choice made after the local
pin changed reports `stale` and does nothing. Séance's own
`FileHostKeyStore` gained the two conditional writes rather than an
adapter, and its verdicts live in `settings.json`
(`untrustedPinLocators`, `keptPinVerdicts`) behind
`SettingsPinVerdictStore`. The resolution surface is a card per conflict
in Settings ▸ Sync with both fingerprints and the two buttons, not a
separate sheet. `kMinSharedVersionIncludesSeance56Fix` still flips in the
release that carries the fix.

## 8. F3b: pure stores into `SC/src/store/`

Sources: `PA/services/file_stores.dart`, which holds
`FileVaultStore implements VaultStore, VaultRekeyJournal` (`:68`),
`VaultRekeyOutcome` (`:30`), `VaultRekeyJournal` (`:53`),
`FileHostKeyStore implements ConflictAwareHostKeyStore` (`:372`) and
`_quarantineCorruptFile` (`:15-27`); plus `SA/services/file_stores.dart`
(616) for parity review. Move only pure Dart: JSON codecs; the rekey
journal (`stageRekey` `:304`, `settleRekey` `:341`, staged old/new
snapshots in `vault.json.rekey`, mutation lockout while a journal exists
`:144`); `putSecretBlobs` merge semantics (`:243`); serialized loads and
mutations; conditional writes (`putIfNoConflict` `:438`,
`replaceIfCurrent` `:455`); the `atomicWriter` seam (`:374-382`).
Leave in the apps: settings keys, error reporting, `AppLock`, Flutter
imports (the stores' `app_lock.dart` import cannot move; `dart:developer`
logging can).

Accepted Poltergeist behaviors the extraction preserves:
`putSecretBlobs` merges rather than replaces; the rekey journal stages
both generations before the keystore write; mutations are locked out
while a rekey is staged; host-key loads and mutations are serialized
(#172); conflict-aware conditional writes stay available. Intentional
differences to document: Poltergeist ports only `FileVaultStore` and
`FileHostKeyStore`, not `FileConfigStore`/`FileSnippetStore`; corrupt
quarantine is store-owned and UTC-stamped; serialized-mutation queue
differences between the apps are reviewed per method. Order: extract
into `seance_core`, switch Poltergeist in the same PR, then a Séance
follow-up PR that switches only Séance's vault and host-key stores
(`FileVaultStore`, `FileHostKeyStore`) onto the shared copies (D7); its
sync coordinator is untouched until F7 (D6). Byte-identity of
`vault.json`, `vault.json.rekey` and `host_keys.json` is golden-file
tested.

## 9. F3c: `planchette/packages/ghost_keystore`

Sources: `SA/services/secure_master_key.dart` and
`PA/services/secure_master_key.dart`; both wrap `FlutterSecureStorage`
(imports `flutter/services.dart`, `flutter_secure_storage`) around a
master-key entry and an API-key namespace. Extract `MasterKeyManager`
parameterized by entry prefix so each product keeps isolated keystore
entries (`seance.vault.masterKey.v1`, `poltergeist.vault.masterKey.v1`,
`klabautermann.vault.masterKey.v1` per 04 12.3) and `apikey` prefixes
(`seance.apikey.<name>`, `poltergeist.apikey.<name>`, including
`poltergeist.apikey.sync.token` and
`poltergeist.apikey.sync.token.retained.v1`).

Preserve the `hasExistingVault` contract: if no keystore key is
available but an encrypted vault exists, do not mint a new key
(`seance/AGENTS.md` section 7; 03 D7 rejected the thin-adapter
alternative on exactly this ground). Move `MasterKeyUnavailableException`
(Séance has it; Poltergeist lacks it) and the status/error reporting
surface. Tests assert the literal entry names, not only behavior, plus
the mint/refuse matrix around `hasExistingVault` (both apps'
`keystore_resilience_test.dart` is the model).

Platform notes to carry: macOS uses the legacy login keychain via
`MacOsOptions(usesDataProtectionKeychain: false)`; the restricted
`keychain-access-groups` entitlement blocks ad-hoc-signed launches
(`seance/AGENTS.md` platform notes, `poltergeist/AGENTS.md` gotchas).
The PR records a manual macOS keychain check: automated compilation is
not device/keychain verification (root `AGENTS.md`, releases and
review). Stays app-side: `AppLock` integration (the `AppLock` class
itself moved here later, F5f: `package:ghost_keystore/app_lock.dart`,
with the authentication plugin behind `DeviceAuthenticator` still
app-side), product error copy,
`SyncCredentialStore` bindings (`sync_credentials.dart:151`,
`poltergeist.sync.deviceId` mint-once).

Switch order per 03 3.5 (F3c row) and 04 section 13 (F3): Poltergeist
moves to `ghost_keystore` in the F3c PR; a Séance follow-up PR then moves
only Séance's `MasterKeyManager` (its vault master-key entry and
`apikey` namespace) onto the package, the same "switch the keystore, not
the coordinator" pattern as F3b (D7). Séance's `SyncCoordinator` and its
store wiring stay Séance's own until F7 (D6). The Séance follow-up is the
PR that changes `seance/` lineage and runs the pin audit (section 11).

## 10. Klabautermann's use of the library

The MVP (04 section 13, M1 to M4) consumes only the pull-only subset:

- shared-account enrollment through `SyncEnrollment` /
  `SyncEnrollmentApi`, with the batch onboarding, disclosures and
  fleet assertion of 03 4.3 (the `SyncEnrollmentApi` transport seam is
  the app's; the preflight validation is already shared at
  `SC/src/sync/sync_enrollment_validation.dart`);
- `PushPolicy.none` (D14): the app pulls and applies `serverConfig`,
  `secret:` and `hostkey:` records and never seals (the two funnels in
  section 4);
- `CatalogSnapshot` as the read-only server list (03 4.4);
- `EndpointPinStore` persistence for `endpoint_pins.json` (D16, 03
  4.7): a confirmed `{host, port, username, jump route ids,
  confirmedAt}` per serverId, re-confirmed whenever a synced element
  changes;
- pulled pins through `HostKeyHandler`'s quarantine (section 7) and
  the F3b stores / F3c `ghost_keystore` for vault and key material
  (`klabautermann.vault.masterKey.v1`,
  `klabautermann.apikey.sync.token`, `klabautermann.sync.deviceId` per
  04 12.3).

v1 adds the write path: `PushPolicy.normal`, writes through
`CatalogWriter` under the shared-editor semantics of section 4, and
one `RecordKind.klabautermann` handler registered for the
`klabautermann:` prefix carrying typed sub-records
`klabautermann:<type>:<id>` (D17): `pref` and `rule` at v1, the
remaining types at v1.x (the 03 4.8 table), sealed `removed` records
instead of honored tombstones (D17), the 1 MiB per-prefix budget of 03
4.8, and first-seen pin publication once the fleet assertion covers
the #56 fix (D15).

## 11. Tests and verification

- Move PR: the 5,454 lines of existing Poltergeist sync/bookmark tests
  (1.5) run unchanged through the `poltergeist_core` barrel; compat
  `export` shims keep call sites compiling. Golden files prove
  byte-identical `servers.json` (`{version, servers, syncTuples}`,
  `server_store.dart:124-126`), `sync_records.json`
  (`persistent_record_store.dart:86-91`), settings keys and `deviceId`
  (`sync_credentials.dart:151`). `poltergeist_sync` builds and
  `sync_integration` (`.github/workflows/ci.yml`) stays green against
  the resolved Séance sync server.
- Suite convergence (03 11.2 item 1): a Séance `SyncCoordinator` device
  and a shared `RecordCoordinator` device against a fake server,
  covering server edits, deletes, exclusion toggles, secret publication
  with the switch on and off, first-seen and changed pins quarantined,
  and `klabautermann:` records ignored by Séance
  (`sync_coordinator.dart:854-855`).
- Pull-only (item 4): a full round under `PushPolicy.none`; assert no
  record is marked dirty and no push request is sent (D14), that the
  round's pulled `serverConfig` records still materialize in `catalog`,
  and that each `CatalogWriter` mutating call returns
  `WriteOutcome.refusedPullOnly` with the server store, record store and
  verdicts unchanged.
- #56 regression (item 7): section 7.
- Extraction parity: per-divergence tests named in section 6; rekey
  journal and store atomicity tests move with F3b
  (`vault_rekey_journal_test.dart`, `vault_store_atomicity_test.dart`).
- Per-PR bookkeeping (D3): `poltergeist/docs/PORTS.md` ledger entries
  for every file that leaves `PC/`; release-tool and CI lines only
  where packages are added (`ghost_keystore`). The `seance_pin_audit`
  CI job (`.github/workflows/ci.yml:286-337`) runs on every PR that
  touches `seance/**`, a Poltergeist pubspec/lockfile,
  `poltergeist/docs/PORTS.md`, the audit script/tool, or the workflow
  itself (`ci.yml:300-318`). That includes the move PR, since its
  files land under `seance/packages/seance_core`, and every later PR
  that edits `seance_core` or `seance_protocol`. The job regenerates
  the audit from the committed `seance/` tree and its full lineage and
  compares it to the `SEANCE_PIN_AUDIT_V3` block in
  `poltergeist/docs/PORTS.md:2015-2039`
  (`seance_pin_audit.dart:8-9,925-937,1197-1205`). It fails when the
  recorded provenance no longer matches (a new contributor or
  attribution, a license-scan line, a vendored path, a gitlink, or a
  lineage tip; `seance_pin_audit.dart:942-968`). Ordinary commits by
  contributors already in the record leave it unchanged (the record's
  own preamble, `poltergeist/docs/PORTS.md:2015-2039`), so a PR
  refreshes it only when the job reports a mismatch, for example when
  a new file adds a license line or a vendored path: review
  `poltergeist/scripts/audit-seance-pin.sh --print-findings`, then run
  `poltergeist/scripts/audit-seance-pin.sh --write-record` and commit
  the updated block in the same PR (`seance_pin_audit.dart:12-14`,
  `ci.yml:327-331`). The audit refuses uncommitted `seance/` changes
  (`seance_pin_audit.dart:183-225`), so any refresh happens after the
  seance-side commits within the PR. `scripts/test.sh` also runs
  the audit in verify mode (`scripts/test.sh:111-115`).

## 12. S9 is this document

S9 per 04 section 13 (M0 table): "Design doc recording the five
approved divergence resolutions (4.4, decision 3) and Séance's
pulled-pin conflict check through the quarantine handler (#56,
decision 12)". Its exit criterion is "owner approval of the design
doc; each resolution then lands as its own PR in F3". The five
resolutions are section 6, the #56 routing is section 7, and the
approval is the owner's instruction of 2026-10-13 recorded in the
status line. Each resolution lands as its own PR per section 13.

A pre-move measurement belongs to PR 1 rather than S9: while porting,
PR 1 answers (a) whether the `RecordHandler` split forces public
visibility on `BookmarkCoordinator` internals the tests relied on,
(b) whether the catalog `AtomicFileWriter` reproduces byte-identical
files under the golden diff, and (c) whether `PushPolicy.none`
provably seals nothing (zero `crypto.seal` calls, zero push
requests). PR 1's description names any signature that had to change;
none may require app-visible API changes beyond constructor wiring.

## 13. Staged PR order

| # | PR | Contents | Ledger/audit |
|---|---|---|---|
| 1 | Move | Move the 1.1 files to `SC/src/catalog/`, add the `catalog.dart` barrel and `AtomicFileWriter`, add compat shims in `poltergeist_core`, switch Poltergeist in the same PR. Byte-identical files, golden tests, full suite and pixel baselines unchanged; the pre-move measurement of section 12 runs here. | PORTS.md entries for each moved file; `seance/` lineage changes (the files land under `seance/packages/seance_core`), so the pin-audit job runs and the `SEANCE_PIN_AUDIT_V3` block is refreshed via `poltergeist/scripts/audit-seance-pin.sh --write-record` when `--print-findings` shows provenance drift. |
| 2 | Divergence 1 | Local-only locator shield in `HostKeyHandler`. | PORTS.md; shield tests. |
| 3 | Divergence 2 | Publication seam, no default change. | PORTS.md; seam tests. |
| 4 | Divergence 3 | `batchForPush` adoption (needs the F2e export). | PORTS.md; batching tests. |
| 5 | Divergence 4 | Delta pull with full-resync fallback. | PORTS.md; cursor tests. |
| 6 | Divergence 5 | Row-preserving decode in the shared store. | PORTS.md; corrupt-row tests. |
| 7 | F3b | Extract `FileVaultStore`/`VaultRekeyJournal`/`FileHostKeyStore` to `SC/src/store/`; switch Poltergeist; then a Séance follow-up PR that switches only Séance's vault and host-key stores, not its `SyncCoordinator` (D6). | PORTS.md; golden `vault.json`/`host_keys.json`. |
| 8 | F3c | `planchette/packages/ghost_keystore`; switch Poltergeist's `MasterKeyManager` caller in the same PR; then a Séance follow-up PR that switches only Séance's `MasterKeyManager` (keystore), not its `SyncCoordinator` (D6; 03 3.5 F3c, D7). | PORTS.md; 04 12.2 registration; the F3c PR itself adds a `planchette/` path dep (no `seance/` lineage change), the Séance follow-up PR changes `seance/` and refreshes the audit record; manual macOS keychain check recorded in the PR. |
| 9 | F3d | Route Séance's hostKey case through the quarantine handler (section 7). | `seance/` lineage changes; the audit runs, and the record is refreshed in the same PR if it reports a mismatch; Séance changelog; flips `kMinSharedVersionIncludesSeance56Fix` in the shipping release. |
| 10 | Ledger close | Final `poltergeist/docs/PORTS.md`, pin-audit and compatibility updates. | - |

Every divergence PR (rows 2 to 6) edits the moved library inside
`seance/packages/seance_core`, so each is audit-relevant: the CI job
verifies the `SEANCE_PIN_AUDIT_V3` block and the PR refreshes it when
provenance drifts (section 11). F3b (row 7) touches `seance/` in both
halves (the extraction lands in `seance_core`, the follow-up switches
`seance_app` onto it), so its audit runs apply to both PRs. F3c (row 8)
lands in `planchette/packages/ghost_keystore`, so only its Séance
follow-up changes `seance/` lineage and runs the audit. F3d (row 9)
changes Séance's `SyncCoordinator` too, but only its pulled-pin conflict
check, not its dispatch; Séance adopts the shared
`RecordCoordinator` only in F7 (D6).

Publication stays disabled until #56 ships: the MVP is pull-only (D14)
and publishes nothing; from v1 Klabautermann publishes first-seen pins
once the enrollment fleet assertion covers the first Séance release with
the fix (D15; 03 4.6 and 4.3).

## 14. Risks

- Coordinator split surface. `BookmarkCoordinator` is 1,543 lines of
  intertwined logic; a premature handler boundary would leak internals.
  Mitigation: PR 1's pre-move measurement (section 12) checks the split
  before the move lands; `RecordHandler` gets the minimal
  apply/dispatch surface above (03 4.4).
- Byte drift in the move. `servers.json`/`sync_records.json` writers
  change hands. Mitigation: golden files gate PR 1; `AtomicFileWriter`
  preserves `atomicRewrite`'s write order
  (`transfer_journal.dart:1352-1393`).
- `EndpointPinStore` is new, not extracted: no implementation existed
  in either app (03 4.7). Its file store landed in `seance_core`
  (section 2.2) ahead of its first consumer, Klabautermann's endpoint
  confirmation (SAF-09).
- Keystore prefix regressions destroy vaults (a wrong entry mints over
  an existing vault). Mitigation: literal-name tests, `hasExistingVault`
  contract tests, the manual macOS keychain check.
- #56 sequencing. If F3d lands before F3b's Séance store switch, Séance
  needs a small `ConflictAwareHostKeyStore` adapter over its existing
  `FileHostKeyStore`; budgeted in the F3d PR rather than blocking on
  F3b.

## 15. Corrections to the plan

Where `03-ARCHITECTURE.md`, `04-IMPLEMENTATION.md` or the c1 research doc
describe the current code wrongly:

1. Poltergeist does publish `secret:` and `serverConfig` records, not
   only `bookmark:`/`hostkey:`: `bookmark_coordinator.dart:8-11` and the
   save/seal paths at `:227-417`. c1's claim that Poltergeist only reads
   `serverConfig` and writes `bookmark:`/`hostkey:` is stale.
2. Pulled `hostkey:` tombstones are no-ops in both implementations
   (`bookmark_coordinator.dart:1154-1164`;
   `sync_coordinator.dart:576-594`), not "remove the local pin". D17's
   sealed-removal rule for `klabautermann:` types stands on its own.
3. `record_crypto.dart:11` misdescribes the cipher as AES-256-GCM +
   HKDF-SHA256; the record codec seals XChaCha20-Poly1305
   (`SP/src/crypto/vault.dart:121,126-127`). Fixed in PR 1.
4. Séance's local record store is not SQLite-backed; it is an in-memory
   per-round mirror (`local_record_store.dart`, 69 lines). Poltergeist's
   is the JSON file (`persistent_record_store.dart`).
5. There is no `sync_transport.dart` in Poltergeist. The one-push
   evidence for divergence 3 is `bookmark_coordinator.dart:895-899`;
   the transport is Séance's `HttpSyncClient` (`http_sync_client.dart`).
6. `onHostKeyPinned` has no call site (divergence 2): pins are persisted
   from engine events (`engine_session.dart:519-523`) and reach the
   account through the switch re-seal
   (`bookmark_backup_service.dart:762-776`). Any wording that pins
   "publish through `onHostKeyPinned` today" is wrong.
7. `kMinSharedVersionIncludesSeance56Fix` is `false`
   (`sync_account_gate.dart:27`) with
   `kMinimumSharedAccountSeanceVersion = 'v0.9.0'` (`:19`). The plan's
   "share from the start" phrasing was superseded by D14's pull-only MVP
   and owner decision 12 (04 section 15); publication begins at v1
   gated on the #56 fleet assertion (03 D15 owner-decision note, still
   open item 6 in 04 section 15).

## 16. Estimates and recommendation

Move PR: L (coordinator split plus byte-parity proof and the pre-move
measurement of section 12). Each divergence PR: S to M. F3b: M. F3c: M
plus the manual keychain check. F3d: S once the handler exists. S9 is
this document (04 section 13's M0 row, S).

Recommendation: proceed in the order of section 13. The move is the
only step that must be perfect (byte-identical files); every behavior
change is isolated, tested and ledgered behind it, and #56 is fixed
before any publication path exists.
