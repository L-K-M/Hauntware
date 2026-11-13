# Séance: engineering and product backlog

Consolidated 2026-09-26. Code base: `origin/main` at `f5570dd` (PRs #132 to
#142 merged; #145 and #146 in review). Review base for new findings: `dd7e105`.
This file is the single forward-looking backlog. It merges two backlogs written
the same day: the sibling reviewer's ANALYSIS.md (built on [tmp.md](tmp.md))
and the backlog from the 2026-09-26 deep review. Nothing from either was
dropped: duplicates were merged into one entry carrying both sets of IDs,
evidence and gates. Completed work is listed only in the compact
[completion ledger](#completion-ledger); older detailed records stay in
[the 2026-09-05 archive](docs/reviews/analysis-2026-09-05.md) and
[the July archive](docs/reviews/analysis-2026-07-25.md).

Incremental macOS reviews on 2026-11-04, including Sol3, used `origin/main` at
`ad1ebfbea`; the Sol consolidation rebased on `eb8be7b49`. Findings
implemented by open PRs were removed as required. Their unimplemented
residuals and the remaining nice-to-haves are consolidated into the existing
entries or the focused sections near the end of this file.

The Sol audit covered all eight requested focus areas with 33 findings: 17
important and 16 nice-to-have, with no blocking finding. Its implemented scope
is in open draft PRs #594, #595, #596, #597, #604, #609, #610, #611, #619,
#621, #623, #627, #631, #635, #636, #638 and #639. Remaining items below fold
in its specific evidence without duplicating provider disposal/history bounds
already covered by other in-review work. Local macOS builds passed; native
keychain, real-device and external-server validation remain separate gates.

## Sources and identifiers

| Source | What it is |
|---|---|
| [tmp.md](tmp.md) | Sibling review of both apps, 2026-09-26, bases Séance `dd7e105` / Poltergeist `913ca3d` (review before implementation). Its PRs #132 to #134 have merged. |
| [docs/reviews/deep-review-2026-09-26.md](docs/reviews/deep-review-2026-09-26.md) | Deep review, 2026-09-26, base `dd7e105`: slices S1 to S5, X and L. |
| [docs/reviews/analysis-2026-09-05.md](docs/reviews/analysis-2026-09-05.md) | Previous backlog and completion ledger (archive, unchanged). |
| [docs/reviews/analysis-2026-07-25.md](docs/reviews/analysis-2026-07-25.md) | July backlog (archive). |
| [astra.md](astra.md) | Earlier review; source of AST identifiers. |

| Prefix | Source | Notes |
|---|---|---|
| SOL, SEA, AST | Earlier reviews ([astra.md](astra.md), archives) | Stable IDs; keep them. |
| SEA26-SEC, UI, BOTH-REV | Sibling review [tmp.md](tmp.md) | Mapped onto the entries below. The sibling's UI identifiers collide with this file's UI area IDs, so they are always written "UI-nn (sibling review)"; a bare UI-nn is an entry here. Sibling UI-01, UI-05, UI-06, UI-07 and UI-11 are Poltergeist-only and live in its ANALYSIS.md. |
| S1 to S5, X, L | [Deep review](docs/reviews/deep-review-2026-09-26.md) (S1 protocol/server/sync, S2 core, S3 app services, S4 UI, S5 backlog audit, X cross-app, L live-app run) | S5 statuses were applied to every old entry. |
| STATUS n | `docs/STATUS.md` "Open items" numbering | Several code comments cite wrong numbers (see DOC-01). |

Poltergeist has a sibling ANALYSIS.md. Items that need a Séance change for
Poltergeist's sake are the XAPP-nn entries below; purely Poltergeist
work is not.

## How to use this file

1. Pull current main. Cut one focused branch per entry slice from
   `origin/main`; one PR per slice. Honour the owner's merge instructions.
2. Pick from the [recommended sequence](#recommended-sequence), or any open
   entry. Findings already implemented in an open PR are omitted; re-check the
   forge before starting to avoid duplicating them.
3. Re-anchor evidence before editing. Line numbers are from `dd7e105` unless
   marked `@9322f6e` or `@f5570dd`. `app_state.dart` moved by about +30 lines
   between `dd7e105` and `9322f6e`. #140 (merged after `9322f6e`) changed
   `sync_engine.dart` and `sync_coordinator.dart`, so re-anchor line numbers in
   those two files; `app_state.dart` gained 10 lines near `:1580`.
   Entries S2-04 to S2-22 came from a review slice that was cut short: they
   have only a one-line finding, so re-trace the evidence first and record what
   you find in the PR.
4. A bug fix starts with the Gate's regression test failing, then the fix.
5. Preserve public protocol/core compatibility with Poltergeist and the service
   boundaries in AGENTS.md. Migrations need compatibility and rollback
   fixtures, never an ad hoc rewrite of existing vaults.
6. When an open PR implements an entry, delete the implemented scope here and
   keep only a genuinely unimplemented residual. After merge, add one line to
   the completion ledger with the PR link.

**Priorities.** Blocking: a trust boundary or major loss risk. Important:
correctness, privacy or reliability. Nice-to-have: substantial usability or
performance, or optional polish and hardening.

**Status values.** Open; Partial (some slices done, listed); In progress
(branch exists, no PR yet). In-review implementation is not duplicated here.

**Verification commands** (AGENTS.md §3; never run bare `dart test` at the root):

```bash
export PATH=/opt/dart-sdk/bin:/opt/flutter/bin:$PATH
dart pub get
dart analyze packages/seance_protocol packages/seance_core packages/seance_sync_server
dart test    packages/seance_protocol packages/seance_core
(cd packages/seance_sync_server && dart test)   # its build hooks bundle SQLite
(cd app/seance_app && flutter pub get && flutter analyze && flutter test)
(cd third_party/xterm && flutter test)          # vendored fork, not analyze-gated
(cd packages/seance_sync_server && dart build cli -o /tmp/seance-sync)
docker build -f packages/seance_sync_server/Dockerfile -t seance-sync .
scripts/test-macos-accessibility.sh             # macOS, after flutter build macos
```

Recorded baselines at `dd7e105` (neither is a claim about later commits):

- Linux container, Flutter 3.47.2 / Dart 3.13.2 (deep review): package
  analysis clean, 778 package tests pass; app analysis clean, 1,083 app tests
  pass.
- macOS, Flutter 3.47.3 / Dart 3.13.3, while CI pins Flutter 3.47.2 (sibling
  review): package analysis and all 778 package tests pass; app analysis clean,
  1,079 app tests pass, two skipped, two desktop capture fixtures fail without
  real fonts. Both capture failures disappeared in a separate 20-test real-font
  capture run; the complete app suite was not rerun after that.

Not verified anywhere: real macOS/Windows/iOS/Android devices, signed Apple
keychains and keystores, physical mobile IME and Back, Docker at runtime,
native assistive technology, sustained frame timing, Windows agent behaviour,
power-loss recovery. Prior version counts and historical CI stay in the
archive.

## Assessment

The code is careful and heavily tested; remaining defects sit at subsystem
seams and in failure and recovery paths. Rare I/O, keystore or protocol errors
can still become permanent loss, and adversarial input (a hostile server,
terminal output, odd file names) reaches code that assumed friendly input. Do
not call account sync production-ready until the gates in
[Invariants and release gates](#invariants-and-release-gates) pass. Both
reviews agree that trust reconciliation, durable sync settlement, and account
activation and recovery are the largest remaining risks.

**Visual QA record (sibling review).** Baseline source and light/dark sidebar
fixtures were inspected at `dd7e105`: twenty capture tests produce 30 PNGs and
pass using local Arial/Courier through the fixtures' font aliases. These are
widget renders, not release-font or native-device QA. The composed status
badges and the quiet coloured glyph vocabulary are coherent. Supplemental QA
on main `5c02fe0`: a temporary copy of the capture fixture used
`SeanceTheme.build(ThemePresets.initial, brightness, platform: platform)`
instead of `SeanceTheme.light`/`dark` (which still select Séance/Automatic).
Four representative capture tests passed and produced nine Terminal-palette
PNGs. Comfortable and compact 200 dp rails, a 280 dp rail, a 390 dp phone and
the menu showed no obvious new layout or contrast blocker; status colours stayed
distinct and explicit host colours survived. Endpoint elision remains. Twelve
existing Terminal/default/preset-contrast assertions passed sequentially after
a concurrent native-assets codesign race. The temporary harness was removed;
this is supplemental render evidence, not new stock-fixture coverage. The
phone FAB note is under UI-10.

Implemented foundations to preserve (do not reimplement): the vault re-key
journal (`FileVaultStore.stageRekey/settleRekey`), server/snippet deletion
tombstones (#84), independent secret timestamps, the `AppState._mutate` queue,
agent and ProxyJump transport (#131), editable themes (#128), KDF resource
ceilings, the 64 KiB unfinished-sequence cap (#49), window-state persistence
(#47), transactional record push/pull (#71), unknown-kind preservation (#58),
and everything in the completion ledger.

## Recommended sequence

The backlog contains only work not already implemented in main or an open PR.
A practical order for the remaining risk is:

1. **Trust and durable sync:** TRUST-01 conflict reconciliation; SYNC-03's
   remaining acknowledgement validation and typed deletes; SYNC-05 account
   epochs; SYNC-06 recent re-authentication; CRED-02 through CRED-05 recovery.
2. **Destructive-state boundaries:** APP-02's service close policy, STORE-01
   failure paths and SYNC-09 monotonic edits.
3. **Server operations:** SRV-01's remaining pre-auth/body controls, then
   SRV-02 migration registry/backups and SRV-03 drain/diagnostics.
4. **Measured terminal work:** TERM-02's remaining controls, TERM-03 reflow,
   TERM-04 input hints and SSH-01/SSH-02 liveness, using PERF-01 before larger
   architectural changes.
5. **Release gates:** REL-01/REL-02, SSH-06's macOS sandbox decision and
   REL-04 Developer ID/notarization and platform metadata.
6. **Daily workflow and UI:** UI-01 adaptive layout, WF-01 action palette,
   WF-02 quick connect, TERM-08 disconnect recovery and the smaller
   accessibility/theme residuals.

Independent UI fixes may run in parallel with protocol work.

## In review

Findings wholly implemented by an open PR are deliberately omitted from this
backlog. When an open PR implements only one slice, the surviving entry below
describes only its unimplemented residual and must not be used to duplicate the
in-review work.

---

## Blocking

### TRUST-01: Serialize TOFU approval and canonicalize pin identity

bugs — blocking

**IDs:** AST-008, SOL-023, SEA26-SEC-03, SEA26-SEC-04, S2-14, issue #56 ·
**Status:** Open

**Problem.** Synced pins already use conflict-aware reconciliation, but
`TofuVerifier.check/pin`
(`packages/seance_core/lib/src/hostkey/tofu.dart:44-67`) has no serialization
or compare-and-set, so concurrent first connections or a stale dialog can
overwrite a newer decision. `hostKeyLocator` is `'$host:$port'` without
canonicalization
(`models/host_key.dart:112`). ProxyJump (#131) verifies each hop against its
own `host:port`, so pins for one name reached through different jump routes
collide (S2-14, table row only: re-trace). #56 is still open and is the
pin-trust gate for Poltergeist shared accounts.

**Next.** Add `pin(expected:)` CAS against the pin the dialog showed and
serialize first approval per endpoint. Canonicalize the locator (lowercase,
strip trailing dot, IDNA, IP literals including bracketed IPv6, port) before
lookup, with a migration of existing pins; decide whether route identity
belongs in the locator for S2-14. Validate imported key algorithm and encoding.

**Gate.** Concurrent first connections; stale repin dialog; equivalent
endpoint spellings; jump-routed collision. Never replace silent overwrite with
a silent skip that reports success. Coordinate the public policy and its
conflict tests with Poltergeist and authenticated records (SYNC-01), building
both consumers before changing shared interfaces (this folds part of the
former XAPP-03).

### CRED-04: A missing keystore key is not a first run

bugs — blocking

**IDs:** SOL-031, SEA26-SEC-07, S3-04, X-10 (Séance half) · **Status:** Open

**Problem.** Locked-keystore errors already degrade safely; a genuinely
missing key is a different state that the code treats as a first run.
`secure_master_key.dart:94-109` `probeKeystore` mints a key after a null read
without checking existing `vault.json` ciphertext; `app_services.dart:166` (@9322f6e) calls it at bootstrap before
looking at `vault.json`. A non-minting `readKeystoreKey` exists (`:130`).
Concrete triggers (S3-04, LIKELY):
- Android: `AndroidManifest.xml` has no `allowBackup`, so Auto Backup restores
  `vault.json` and the plugin prefs without the Keystore key.
  `flutter_secure_storage` 10's `AndroidOptions.resetOnError` defaults to true:
  it wipes, returns null, and a new key is minted. Auto Backup also uploads
  `sftp-checkouts/`, `command_stats.json` and `identity_reads.jsonl`, and a
  cloned `settings.json` gives two devices one `deviceId` (this breaks the
  own-retraction logic at `sync_coordinator.dart:564,585`).
- Windows: `flutter_secure_storage_windows` 4.1.0 deletes its DPAPI store when
  decryption fails, returns `{}` on any read error and writes non-atomically,
  so a transient read error plus the mint replaces the whole store (the sync
  token and API keys are lost too).
- Concurrency: `unlockVaultFromKeystore` (`app_services.dart:242-265`) is not
  single-flight; two callers can mint two keys.

**Next (first PR).** Manifest `android:allowBackup="false"`,
`android:fullBackupContent="false"` and `android:dataExtractionRules`
excluding everything (API 31+); `AndroidOptions(resetOnError: false)`;
`probeKeystore(mayCreate:)` with `mayCreate: !(await vaultStore.hasEntries())`
(add `FileVaultStore.hasEntries`); a distinct "vault key missing" locked state;
single-flight unlock. **Then** the recovery/unlock UI (leave ciphertext
untouched), a README note ("reinstall and sign in to sync to move phones"),
and verification of iOS entitlements under signed builds. Do not add macOS
restricted keychain groups that break ad-hoc builds (AGENTS.md §3). Exclude
keystore-dependent data from incompatible backup restore and verify upgrade
data retention.

**Gate.** `MasterKeyManager` over a fake storage: a null read with
`mayCreate: false` writes nothing; `AppServices.initialize` with a non-empty
`vault.json` and an empty keystore starts locked with keystore and vault
untouched; two concurrent unlocks make one write and return the same key; a
Dart test parses the manifest for `allowBackup="false"`. Manual: signed Apple
relaunch/update, code-signing and container migration, keystore loss,
Android backup restore, empty first run. Never synthesize replacement keys over
encrypted data. Preserve the current keystore migration behaviour (and the
sandbox, unless SSH-06 decides to drop it).

---

## Important

### CRED-02: Recover interrupted enrollment and unreadable vault entries

bugs — important

**IDs:** SOL-030 residual, SEA26-SEC-08, BOTH-REV-005, S3-02, STATUS 4.

Enrollment now verifies the account key, disconnects before re-keying, publishes
credentials only after durable local writes, and serializes against sync in
#594 and #638. The remaining recovery gap is a complete account-activation
journal: after an interrupted local write, users must sign in again rather
than resume a clearly identified pending activation. Unreadable or orphaned
vault entries are retained byte-for-byte without a listing or recovery UI.

Suggested fix: journal the pending account transition around the existing
two-generation vault journal, reconcile it against the actual keystore after
restart, and expose a previewable list of unreadable/orphaned entries with
explicit discard or recovery actions. Add a local key-consistency check before
sync if the keystore changes outside enrollment. Preserve ciphertext and
recovery material until reconciliation is complete. Cover failure and restart
at settings, token, journal, key-write and vault-promotion boundaries; never
upload under the wrong key or present a disconnected recovery as success.


### SYNC-01: Opaque record IDs and key-epoch migration

general issues — important

Wire record IDs still disclose kinds and, for host keys, hostnames and ports.
The record-key model also has no explicit, rotatable epoch, so a future vault
key rotation or ID migration lacks a downgrade-safe transition and rollback
contract across Séance, Poltergeist and Klabautermann.

Suggested fix: derive wire IDs with a domain-separated keyed HMAC, carry a
versioned key epoch in the authenticated envelope, and ship dual-read
migration, interrupted-upgrade and rollback fixtures before changing writers.
Include old/new-client interoperability and an external protocol review.

### SYNC-03: Typed deletion policy, complete acknowledgements and batched apply

general issues — important

**IDs:** SOL-001, SOL-005, SOL-006, SOL-010, SOL-037, SOL-059,
SEA26-SEC-11, STATUS 14, S1-10, #54 residual.

Account-scoped persistence, stable origin tuples, exact sent-tuple settlement,
cursor recovery and network-free mutation phases are implemented in #636 and
#638. Remaining gaps are acknowledgement validation for missing, duplicate or
foreign IDs; an honest pending/incomplete result when round limits are
exhausted; typed deletion policy for host keys, credentials, assistant settings
and bookmarks; batched domain persistence; and explicit orphan state for live
sessions whose remote server configuration was deleted.

Suggested fix: extend the shared settlement contract once for all consumers,
validate the complete acknowledgement set, and retain unsettled operations
durably. Define authenticated deletion semantics without turning absence into
delete authority, persist each domain batch once, and reconcile affected live
sessions explicitly. Test malformed acknowledgements, exhausted rounds,
restart after deletion, and local edits racing blocked apply or push.

### SYNC-05: Account epochs and rollback tripwires

bugs — important

A numeric cursor reset can recover from a server watermark moving backwards,
but it cannot distinguish normal re-enrolment from a restored or rolled-back
database. Reusing the same account name after deletion can therefore make old
and new sequence histories look like one stream, and a compromised or damaged
server can silently serve a previously valid older history.

Suggested fix: add a random per-account epoch to pull responses, persist it
with the client ledger, and rotate it on account recreation or deliberate
restore. Remember the highest watermark and a rolling digest of pulled tuples;
require an explicit full-resync decision and warn when the epoch or history
moves backwards. Cover delete/re-register and backup-restore integration over
real HTTP and SQLite. Export the account-epoch and cursor-reset model to
Poltergeist as the same shared contract (this folds part of the former
XAPP-03).

The account-scoped envelope floor in #639 rejects a return from observed floor
2 to 1. It does not detect a complete, internally consistent rollback to an
older floor-2 snapshot on a brand-new device without an external checkpoint.

### CRED-01: One-shot passphrases for referenced keys

usability — important

A referenced private key can now keep, replace or clear its stored passphrase,
but connecting with an encrypted file still requires either persisting the
passphrase or editing the saved server. Users cannot supply a passphrase for
one Test/Connect attempt without adding it to the vault.

Suggested fix: when a referenced key needs a passphrase, offer a cancellable
one-shot prompt whose value belongs only to that connection attempt. Keep
storage an explicit separate choice and preserve the editor's
keep/replace/clear state on cancellation or authentication failure.

### CRED-05: Missing credentials, recovery material and onboarding

missing features — important

**IDs:** SOL-035, workflow backlog · **Status:** Partial (the
credential-required state landed: `CredentialMissingException`; so did recovery codes
with encrypted export and restore, the inline credential prompt and the
recovery offer after the first saved credential; the final app-lock slice is
implemented locally, awaiting integration and review)

**Problem.** A synced local-only `secretRef` used to become an empty
credential on a new device with misleading auth errors. Since 2026-10-08
`resolveCredentials` throws `CredentialMissingException` for a named entry
the vault lacks, and the failed tab reads "Credential required on this
device" with the server's (or jump host's) editor one tap away. Also since
2026-10-08, Settings > Sync > Recovery sets up a recovery code (a
`RecoveryKey`, shown once and never stored; the vault keeps only the derived
wrap key and key check, as the reserved entry `recovery:wrap-key`, which every
re-key re-seals), exports the vault encrypted (`SecretsExport`) and restores
an export on any device, keeping or replacing credentials already there
([design](../docs/design/cred-05-recovery.md)). Mitigation
since: keyless servers default to agent (#131), which has its own problems
(SSH-06).

The failed tab asks for the missing password or key in place (or switches the
server to the SSH agent), and saving a credential on a device without a
recovery code offers one once; "Not now" is remembered and Settings still
offers it.

**App lock (approved 2026-10-08).** Optional, off by default, device-local.
Android/iOS/macOS/Windows only; hide the setting where device auth is
unavailable, including Linux. Device biometrics or device passcode/PIN
fallback authenticate before the first saved-credential read each launch
and after at least 5 minutes hidden/paused. Inactive events do not start or
reset the timeout. Concurrent readers share one prompt and one lazy keystore
unlock; background time during a prompt cannot be erased by its lifecycle
events. Stale auth and read completions fail explicitly and later attempts
can retry. Both setting transitions require successful device auth.

`AppLock` owns the policy; `NativeDeviceAuthenticator` adapts `local_auth`.
Vault plaintext/blob reads, stored API keys, referenced identity files,
recovery exports/restores/code replacement and rekey admission use the same
gate. Sync/inbox timers defer while locked; manual credential reads may
authenticate. Auth refusal is distinct from missing credentials, damaged
entries and OS-keystore failures. Locked launches defer keystore probing and
rekey-journal settlement until authentication. Existing SSH and assistant
sessions may retain credentials already read; the gate does not erase them,
encrypt identity files, or protect local SFTP copies. The route and separate
Settings window use SettingsBackend and the existing settings-link engine.

**Gate.** Two devices with and without credential opt-in; locked and missing
keys; export round-trip and tamper rejection; cancelled recovery; interrupted
import. Explain local SFTP plaintext retention separately from vault
guarantees. App-lock policy/native-adapter, launch/concurrency, cancellation,
retry, timeout, rejected setting transitions, mutation-queue, journal and
settings-link tests cover the automated paths. Native authentication and
passcode fallback on real Android/iOS/macOS/Windows devices, desktop window
switching and OS sleep/resume remain manual validation.

### SYNC-06: Recent re-authentication for destructive account deletion

general issues — important

A valid device session is sufficient to delete the whole sync account. Token
hashing, expiry and per-device revocation reduce the blast radius of a stolen
database or token, but they do not prove recent user intent for this
irreversible operation.

Suggested fix: require a recent password/verifier challenge, or an equivalent
short-lived re-authentication grant, before account deletion and other
account-wide destructive actions. Test expiry, replay, concurrent revoke/login
and delete so a revoked or stale session cannot complete the operation.

### SYNC-07: Assistant-settings sync trust boundary

general issues — important

**IDs:** #76 follow-up (S5 new gap), #139 follow-up · **Status:** Open

**Problem.** Since #76 an opted-in peer can silently repoint the provider or
endpoint, so terminal context can go to a new endpoint without notice; STATUS
names "surfacing an adopted change of provider or endpoint" as a follow-up.
Rotated keys leave stale keystore entries (removals never travel); "stop
sharing the keys" needs a sealed tombstone (SYNC-01). From #139:
`includeTerminalContext` is device-local; decide whether to sync it next to
the redaction setting.

**Next.** On apply, when provider, base URL or model changes, hold the change
pending and show a one-time confirmation ("Assistant endpoint changed on
<device>"); until confirmed, keep the previous endpoint or disable sending.
Garbage-collect replaced keystore entries locally.

**Gate.** A pulled endpoint change sends no request to the new endpoint before
confirmation; a declined change is not re-prompted every round.

### PROTO-01: Strict wire parsing and deterministic revisions

bugs — important

**IDs:** SOL-008, SOL-009, SOL-013, S1-13 · **Status:** Open

**Problem.** Missing fields still default into acceptance, and numeric
truncation and weak range checks remain outside the KDF parser and the
sync/record parser work already in review. `record.dart:155-163` remains
lenient for fields
such as `deleted ?? false` and `blob ?? ''`; DTOs default a missing
`protocolVersion` to current (`sync/dtos.dart:34-35, 83-84`). Exact LWW ties
still lack an authenticated operation counter or other deterministic total
order. The engine does not check one acknowledgement per id
(`sync_engine.dart:119-129`), and `SyncOutcome` has no pending state.
Unknown-kind preservation (#58) is done; do not reintroduce kind guessing.
HTTP boundary parsing is also inconsistent:
session authorization requires the exact spelling `Bearer`
(`server.dart:318-330`) even though auth schemes are case-insensitive;
non-numeric or negative inbox cursors silently behave like zero
(`inbox_handlers.dart:104-107`); and the served producer client accepts
string-typed but malformed URLs, app IDs and tokens until a later opaque
failure (`inbox_docs.dart:301-318`).

**Next.** Make remaining `EncryptedRecord.fromJson` fields required and typed,
with length bounds and canonical envelope combinations; define a version
policy with typed parse errors and visible quarantine for unknown future data;
and add an authenticated operation ID/counter/HLC for total order with
SYNC-01. One acknowledgement per submitted ID, rejecting duplicates and
unknown IDs, is SYNC-03 slice 3. Opaque wire IDs (SOL-012) ride the SYNC-01
migration. Share one case-insensitive authorization parser across session and
producer routes, reject invalid inbox cursors with a typed 400, and validate
HTTP(S) URL structure plus exact base64url app/token lengths while decoding
producer pairing data.

**Gate.** Parser fuzz/property tests; LWW commutative, associative and
idempotent; exact ties, same-millisecond edits, clock rollback; missing
acknowledgements; unknown kinds across old and new clients; migration
interoperability. Cover lowercase authorization schemes, invalid inbox
cursors, malformed pairing URLs and wrong-length pairing fields.

### PROTO-02: Remaining KDF, identity and crypto assurance

general issues — important

**IDs:** SOL-014, SOL-016, SOL-017, SOL-018, S1-11 (client half), S2-20,
#136 username follow-ups · **Status:** Partial

**Done:** AST-001 bounds KDF resources, requires integer JSON and a 32-byte
output, and validates direct derivation; defaults are unchanged. The app
strength floor is separate from resource validity. #136 added server-side salt
(16 B) and verifier (32 B) shape checks and username validation including
invisible characters.

**Problem.** The client still runs `base64.decode(pre.argonSalt)` with no
length check (`app_services.dart:474-480`), so a malicious server can hand
every user one fixed or empty salt and amortize a dictionary attack. Only a
recovery-code KAT exists (`seance_protocol/test/crypto_test.dart:108`); there
are no Argon2id, HKDF-domain, verifier-hash or XChaCha20-Poly1305 vectors. No
NFC/NFD policy for passphrases; case-variant usernames (`Alice`/`alice`) remain
distinct accounts and need a versioned normalization policy.
`SecretVault.getSecret(id)` does not check the decrypted secret's id (S2-20,
table row only: re-trace). Identity-form `seance://connect` links also accept
an empty username that the normal server editor cannot save or match
(`suite_links.dart:242-245,364-389,439-456`).

**Next.** The client refuses a prelogin salt that is not exactly 16 bytes. Add
independent vectors including production factors. Define Unicode and case
policy only in a versioned format with migration fixtures (registration-time
case fold; existing accounts are not renamed). Verify decrypted secret
identity, defensively copy key/blob storage, minimize root-key retention.
Profile the KDF on a midrange phone (the 64 MiB/10-iteration/4-lane ceilings
are safety limits, not a latency promise). Unsupported old factors are
rejected, never clamped or hand-edited into a different key. Apply the same
nonempty username and trim policy to connect-link parsing and builders.

**Gate.** A malicious prelogin fails before allocation; vectors match; NFC/NFD
is documented and tested without breaking existing accounts; external crypto
and protocol review before sync GA. Unsupported factors alone cannot prove
whether the endpoint is malicious or an account is legacy. Connect links reject
empty usernames, and valid trimmed identities round-trip through parse/build.

### STORE-01: Persistence failure paths and transactional client storage

bugs — important

**IDs:** SOL-034, SEA26-SEC-09, SEA26-SEC-10, BOTH-REV-003, S3-08, S3-13 ·
**Status:** Partial

**Done (#91, #100):** per-path in-process write queue
(`services/atomic_file.dart:31-52`); a POSIX rename failure keeps the
destination; owner-only option; the journal read separates I/O from damage.

**Problem.**
- The Windows fallback (`atomic_file.dart:66-75`) deletes the destination and
  then renames. If the destination is held with `FILE_SHARE_DELETE`
  (antivirus, indexer), only `*.tmp` survives and nothing reads `.tmp`. Next
  launch: an empty vault (empty-password connects), default settings with a
  new `deviceId` and no recovery notice, a missing managed index. The next
  write truncates the `.tmp`.
- `quarantineCorruptFile` (`:81-89`) deletes an existing `.corrupt` first.
- Loaders quarantine on any exception, including read I/O
  (`file_stores.dart:22-38, 297-315`; `app_settings.dart:513-547`). A vault
  reset shows no notice. `SettingsStore.load` salvages defaults when the read
  (not the parse) fails and then overwrites the original.
- The fixed `<file>.tmp` name is unsafe across processes; no directory fsync.
  Multiple processes and symlink aliases of one path are not coordinated
  (STORE-02 covers the process lock, acquired before cache load).
- S3-13: four JSON stores set `_loaded` after awaits (a first-load race that
  `FileVaultStore` already fixed at `:277-295`), and `putServer`,
  `deleteServer`, `putSnippet`, `add` and `put` mutate `_cache` before
  `_flush` with no restore, so a failed save is later committed or pushed.

**Next.** Windows: retry the rename with backoff (about 5 tries, 20 to
200 ms), then `file -> file.bak`, `tmp -> file`, delete `.bak`; never delete
the only copy. `recoverInterruptedWrite(File)` restores from `.bak`/`.tmp` in
each `_load`. Timestamped quarantine names; keep the newest 5. Read outside the
`try`; quarantine only decode/shape errors; let `FileSystemException` propagate
so the store retries later. An `AppServices.vaultWasRecovered` notice. A shared
`_JsonMapStore<T>` with memoized `_loading` and snapshot/restore on a failed
flush. Unique temp names. Prefer transactional client storage for cross-file
invariants later. Keep the write queue and the settings device-ID salvage.

**Gate.** `atomic_file_test.dart` with `IOOverrides`: rename throws once then
succeeds (no destination deleted); a missing file plus `.tmp` recovers; two
corrupt events keep both copies; a read `FileSystemException` does not
quarantine; a failed write leaves `getServer` returning the old value. Injected
read/stat/rename/write failures, permissions, same-path and cross-process
races, crash at each replacement stage, disk full, malformed UTF-8/JSON and
partial-valid documents. Good state is never quarantined for a temporary
failure; the original or a recoverable replacement survives. Port the fixes to
Poltergeist (its atomic-file helper has already diverged, BOTH-REV-012).

### STORE-02: Single-instance guard on Linux and Windows

bugs — important

**IDs:** S3-09, X-09, SOL-034 (multi-process) · **Status:** Open

**Problem.** `linux/runner/my_application.cc:131` uses
`G_APPLICATION_NON_UNIQUE`; the Windows runner has no mutex. Every store
caches and writes whole snapshots, so two instances drop each other's changes
(servers, known hosts, tombstones, managed index, `vault.json`). A re-key in
one instance while the other holds the old key can leave an unopenable vault.

**Next.** Linux: `G_APPLICATION_DEFAULT_FLAGS` so a relaunch activates the
first instance. Windows: a named mutex plus `FindWindow`/`SetForegroundWindow`.
Dart backstop early in `main()` (before `restoreAndTrack`): an exclusive
`RandomAccessFile.lock` on `<appSupport>/.instance.lock`, showing "already
running" otherwise; the settings-window engine returns before this code.

**Gate.** Unit test of `InstanceLock.acquire(dir)` where a second acquire in a
spawned process fails (fcntl locks are per process). Manual relaunch on Linux
and Windows focuses the existing window.

### SRV-01: Remaining pre-authentication and request-body abuse controls

general issues — important

Unknown accounts still have a distinguishable prelogin response, making
username enumeration possible. Rate limiting is process-local when the service
is replicated, oversized chunked bodies can be reset without an actionable
413, and capped body reads have neither idle nor total deadlines, allowing a
slow client to retain connections indefinitely.

Suggested fix: return a deterministic fake salt and default work factors for
unknown users with indistinguishable status and shape; define persistent or
shared limiter state before supporting replicas; return a structured 413 for
oversized chunks; and enforce both idle and total body-read deadlines. Test
known/unknown timing shape, proxy spoofing, slow bodies, restart and
multi-replica limits.

### SRV-02: Versioned schema registry and crash/restore assurance

missing features — important

**IDs:** SOL-051, SOL-054, S1-07 residuals.

Account-generation authorization and mutations are transactional in #594;
legacy envelope changes are transactional in #639. These upgrades add
generation constraints and foreign-key enforcement, but there is no explicit
versioned migration registry. Contention has no bounded asynchronous retry
contract, durability settings need documentation, and standalone operator
backup/restore procedures need a WAL-safe contract. The updater's candidate
backup and rollback are implemented in #619.

Suggested fix: use transactional PRAGMA user_version migrations, preserve
reviewed constraints and cascades, define bounded asynchronous contention
retry/backoff and Retry-After, and document synchronous/durability settings.
Document online backup and restore without copying a live database separately
from its WAL. Test migration interruption, cross-process kill/lock recovery,
disk-full failures, corruption and restore during writes. Existing
two-connection and trigger-rollback tests do not prove power-loss durability.

### SRV-03: Graceful drain and sanitized server diagnostics

general issues — important

**IDs:** SOL-052, SOL-053, SOL-055, S1-09 residuals.

Storage-aware readiness and deployment health checks are implemented in #610.
SIGTERM still closes the listener and exits without a documented bounded drain,
database close or checkpoint policy. Unexpected handler failures return an
anonymous 500 without the server-side exception, stack, route or request ID
needed to diagnose the cause. The macOS audit found this at
packages/seance_sync_server/lib/src/server.dart:398-414. Operators are affected
even when the public error correctly hides sensitive details.

Suggested fix: stop accepting requests, drain to a deadline, finish or roll
back writes, checkpoint and close SQLite, and handle repeated signals. Log a
sanitized request ID, method/route, exception type and stack; preserve causal
stacks when wrapping failures. Exclude authorization, bodies, verifiers,
ciphertext and raw commands. Add request/status/duration/size and
auth/throttle/push/database counters. Logging is roughly one to two hours;
drain and real-container readiness/persistence/restart tests are a separate
slice. Exercise SIGTERM during reads and writes and forced storage failure.

### SSH-01: Explicit connection-attempt cancellation and recovery UI

bugs — important

**IDs:** SOL-020, SOL-032, SOL-033, SEA26-SEC-12, S2-07 residuals.

Bounded shell, exec, forwarding and subsystem opens with owner-close races and
late-result cleanup are implemented in #621. Users still lack a single
ConnectAttempt handle that cancels every phase, including pre-socket work,
jump parents, TOFU and keyboard-interactive dialogs. The connecting surface
offers a spinner without precise phase, Cancel, Retry or Copy log actions;
Test Connection has no complete cancellation surface.

Suggested fix: carry one attempt-scoped cancellation handle through
openAuthenticatedClient and its owned resources, keeping interactive-auth and
channel-open deadlines distinct. Expose accurate phase/reason and
Cancel/Retry/Copy log. Verify cancellation with open trust/auth dialogs,
immediate remote close, retry, stream errors, and deleted/replaced tabs; no
late session commit, leaked ownership or unhandled completion error.

### SSH-06: Agent default, agent reachability and the macOS sandbox

bugs — important

**IDs:** X-06, L-02, S2-16, X-04 (Séance side) ·
**Status:** Open (important on macOS)

**Problem.** New servers default to ssh-agent (`server_editor.dart:287`) and
keyless imported hosts become agent (`ssh_config_import.dart:35`), even with no
agent (live run, L-02); mobile has no agent at all. Séance's macOS build is
App-Sandboxed (`macos/Runner/Release.entitlements`; the only exception is
read-only `~/.ssh`), and the sandbox very likely blocks connecting to
`$SSH_AUTH_SOCK` (launchd's `/private/tmp/com.apple.launchd.*/Listeners`,
1Password and Secretive group containers) (X-06, LIKELY: verify on a Mac).
There is no key selection, so agents holding many keys hit `MaxAuthTries`
(S2-16, table row only). The macOS sandbox migration PR #45 never landed. Once
tagged, the agent default also breaks Poltergeist on its v0.9.1 pin (X-04; see
XAPP-02).

**Next.** Verify on macOS. Decide: drop App Sandbox for the direct-distribution
build (Poltergeist ships unsandboxed; the sandbox already costs the `~/.ssh`
exception, bookmarks and the `$HOME` rewrite) or add and test exceptions. Map
EPERM to "The macOS sandbox blocks the ssh-agent socket". Default to agent only
when one is reachable (`SSH_AUTH_SOCK` set and the socket exists, or the
Windows pipe exists); otherwise Password; never on mobile. Add per-server
identity selection (like `IdentitiesOnly`) for agents.

**Gate.** The editor default under each condition (fake reachability probe); a
signed macOS build connects through the launchd agent and 1Password; a many-key
agent connects with the chosen key.

### TERM-01: Backend-neutral terminal engine and conformance gate

general issues — important

Application menus and panes still reach through the terminal abstraction to
xterm-specific paste, selection and scrollback APIs. That makes a future
backend swap, including libghostty, impossible to evaluate behind one stable
contract even though parser bounds now protect the current fork.

Suggested fix: extend TerminalEngine with domain-level output, input, paste,
selection, search and scrollback operations, then run one backend-neutral
conformance suite covering vim, htop, readline, alternate screen, Unicode,
mouse reporting, resize and malformed output. Keep backend mechanics private.

### TERM-02: Bound remaining completed control-sequence work

performance problems, stuttering, and jank — important

REP is bounded by the writable viewport, but IL, DL, ICH, DCH, ECH, SU, SD and
resize still accept large completed numeric counts. A short hostile sequence
can therefore request work far beyond the visible screen even though
unfinished sequences and REP no longer wedge the UI.

Suggested fix: define numeric and work budgets for every completed control,
bound insert/delete/erase/scroll operations by the active screen or scroll
region, handle numeric overflow, and use bulk operations where semantics allow.
Preserve wrap, cursor and alternate-screen behavior and record the fork changes
in PATCHES.md. Add adversarial time bounds plus normal conformance tests.

### TERM-06: Preserve platform text-editing new-tab shortcuts

usability — important

Tab close/select/next/previous commands, Clear Scrollback and shortcut help
are implemented. AppMenus still binds plain Ctrl-T on every platform, which
can steal the macOS Emacs transpose binding from text fields.

Suggested fix: expose Cmd-T on Apple platforms and Ctrl-Shift-T elsewhere
through the same platform-aware action table used by terminal shortcuts.
Preserve native text editing and application key modes; test new-tab routing
with terminal, text-field and server-list focus. Destructive-close policy is
tracked only in APP-02.

### TERM-07: Command blocks, Draft Dock and safe injection

missing features — important

**IDs:** SEA-028, SOL-047, S2-03, multiline paste policy · **Status:** Open

**Problem.** `paste_to_prompt` and the command generator inject raw keystrokes
into whatever runs in the foreground (`chat_controller.dart:80-83, 227-234`;
`paste_sanitizer.dart:79-105`; sinks in `chat_sidebar.dart:77-85` and
`command_generator.dart:105` @9322f6e). "Paste but never run" holds only at a
shell prompt: in vim normal mode `ggdGZZ` wipes and saves a file without Enter
(S2-03; that entry was cut short, so re-trace the app sinks). Several
`paste_to_prompt` calls per turn are all staged. Clipboard paste is unguarded
(`app_menus.dart:96-102`).

**Next.** Gate injection on OSC 133 prompt state (`atPrompt`): outside a proven
empty prompt, stage into a local Draft Dock instead of the PTY. The Dock (one
backend-independent surface for AI, snippets and history) shows the exact
target and source, editable text, danger findings, final control/newline
validation and explicit handling of a nonempty prompt; it never silently
concatenates or submits. Then OSC 133 command blocks with Copy command/output,
Save snippet, reviewed Rerun and Explain. Multiline clipboard paste gets its
own preview policy that preserves bracketed paste and editor workflows.

**Gate.** Injection while an alternate-screen program runs goes to the Dock;
nonempty prompt; stale session; bracketed paste unchanged in vim and nano.

### AI-01: Streaming assistant presentation and recovery

missing features — important

Assistant conversations are session-local and bounded, and providers expose a
stream, but ChatSession and the UI still present a completed plain-text block.
Long responses provide no progressive feedback, Markdown and code are not
shown as structured selectable content, and the user lacks explicit Stop and
Retry actions tied to the originating session.

Suggested fix: carry the existing provider stream through ChatController and
ChatSession, render safe selectable Markdown and code with staging rather than
execution, and expose Stop/Retry with the same visible target and privacy
receipt. Remember the include-terminal-context choice durably per session
so a reopened or resumed session keeps the user's decision (SYNC-07 covers
the cross-device question). Stop must use the existing abort path; retry must
not duplicate a tool effect or silently change sessions.
Keep tool-bearing turns buffered until their structure is complete while
streaming text-only final turns. The Sol evidence is
app/seance_app/lib/ui/chat_sidebar.dart:57-113 and
packages/seance_core/lib/src/llm/chat_controller.dart:181-191,332-343;
rough effort is one to two days.

### AI-02: Native tools, exact outbound receipts and redaction grammar

general issues — important

**IDs:** SOL-042, SOL-044, SOL-045, SEA26-SEC-14, S2-11 · **Status:** Open
(the quoted/static-word redaction slice landed in #132)

**Problem.** Native tool-call IDs are discarded; results become user strings
(`chat_controller.dart:240`). `ChatResult.sent` omits history and search
snippets and is never rendered. Brave is read from `settings.braveApiKeyRef`
(`app_services.dart:902` @9322f6e) with no settings UI. Search results are
untrusted content. Redaction grammar residuals: YAML tagged values and block
scalars; shell command substitutions and backticks; source-language
comparisons and Go `:=`; YAML plain scalars with shell-like quote prefixes
after `:`. For `password == "example words"`, `password := "example words"` and
`password: $'example words'` the current filter can leave the quoted text
visible, sometimes after masking only an operator or prefix. Static shell words
and adjacent recognized fields are covered by #132 and must not be implemented
again.
S2-11 (table row, written before #132 merged; re-check which still leak): URL
credentials, `-pPASS`, HTTP Basic auth and partial PEM blocks (JSON keys and
`*_SECRET_KEY` are probably covered by #132). An ad hoc operator exclusion is
unsafe: `password==secret` can be a valid shell assignment.

**Next.** Provider-neutral typed calls and results preserving IDs (Anthropic
`tool_use`/`tool_result`; OpenAI `tool_calls` and tool-role messages); keep the
bounded tool loop. Capture the complete serialized provider payload after
redaction, including history and searches, and show expandable receipts
(target, provider/endpoint/model, command blocks, redactions, queries and
results, token estimate, exact outbound text). Redact final outbound history,
tool results and model echoes, not only user input. Format-aware parsing for
the residual grammars, with serialized provider-request regressions, never
executing expressions while redacting; a conservative fallback for terminal
text that is not valid structured input; user-defined
patterns; label the filter best-effort. Add Brave to Settings or remove it. Add
provider connectivity and latency diagnostics. Native provider web search stays
a separate path.

Sol re-anchored the native-tool gap at llm/provider.dart:5-15,89-103,
chat_controller.dart:228-262, anthropic_provider.dart:35-66 and
openai_provider.dart:35-57. Keeping call IDs and native tool-role messages also
prevents search snippets from being promoted to ordinary user-role authority;
label returned material untrusted. This slice is roughly one to two days.

**Gate.** Second-request wire fixtures for both providers; search-injection
fixtures; payload-to-receipt equality; credential URL, cookie, kubeconfig,
Basic auth and PEM examples through actual provider bodies.

### APP-01: Recover dirty editor drafts after mobile process death

missing features — important

Desktop exit requests can be guarded, but mobile swipe-away and operating
system process death provide no reliable exit callback. A dirty built-in editor
buffer can therefore disappear even though no explicit close action was
accepted.

Suggested fix: autosave dirty mobile buffers on pause and after a short edit
debounce to an owner-only draft sidecar, without overwriting the remote or
managed checkout. On restart, show a recover/discard comparison and remove the
sidecar only after a successful save or explicit discard.

### APP-02: Put destructive tab-close policy behind the service boundary

general issues — important

Tab teardown is exception-safe, but managed-edit and dirty-editor confirmation
still originates in UI handlers. A native shortcut, command palette or future
caller can invoke AppState.closeTab directly and bypass the same destructive
close policy the visible tab button enforces.

Suggested fix: make closeTab require a domain-level confirmation callback and
return a structured close report. Centralize dirty buffers, retained local
copies and connected-session policy there, then route UI buttons, native menus,
shortcuts and the action palette through it. Cover bypass attempts and
cancelled confirmation.

### WF-01: Planchette action palette

missing features — important

**IDs:** workflow backlog, Planchette idea · **Status:** Open

**Problem.** No action palette exists; only the Cmd-K command generator.

**Next.** A fuzzy palette over service commands: hosts, snippets, settings,
reconnect, sync, assistant; keyboard-first with shortcut help; a restrained
selection motif and no theatrical delay.

**Gate.** Filtering, focus return and final target confirmation; it uses
service commands, never raw UI-to-network calls.

### WF-02: Quick connect, recents and transient session identity

missing features — important

One-off user@host[:port] connections still require a saved server, and the
empty main surface offers no recent targets. Repeated unsaved sessions would
also be hard to distinguish because they have no lightweight identity that can
later become the saved server's mark.

Reproduction: entering user@host:port in the server filter gives no result;
the empty terminal surface at app/seance_app/lib/ui/terminal_pane.dart:1810-1827
offers only saved servers. Ephemeral-host users must persist a full record for
each one-off connection. Rough effort for the first slice: one to two days.

Suggested fix: show an italic Connect to result in the server filter, open it
through the same editor, authentication and TOFU path without persistence, and
offer Save from the session row with duplicate detection and MRU recents. Let a
transient session choose an ephemeral symbol or hue and offer that mark when it
is saved. Never persist an unsaved config implicitly.

### WF-03: Device and account management UI

missing features — important

The sync service can issue, expire and revoke device sessions, but the app has
no complete surface to sign out, list sessions, revoke another device or show
expiry/last-use metadata. Account deletion, passphrase rotation and a
conflict/deletion audit are also absent, so users cannot manage the account
lifecycle without lower-level calls.

Suggested fix: build Settings UI over the session endpoints with current-device
labelling, confirmed revoke-current/revoke-other/revoke-all and sign-out.
Require SYNC-06 recent re-authentication for account deletion; add safe
passphrase rotation and an acknowledgement-aware deletion/conflict audit.
Offer an opt-in synced pinned-servers set (device-local by default) so a
user's pinned servers can follow the account. Never imply a remote
credential was revoked until the operation is confirmed.

### REL-01: Harden the release workflow and pin toolchains

general issues — important

**IDs:** SOL-040, SOL-056, X-07, X-11, X-23, X-24, X-26 (Séance side),
BOTH-REV-007 · **Status:** Partial (Dependabot for actions/gradle,
action bumps #109-#113; releases require app tests and the fork suite)

**Problem.** `.github/workflows/release.yml`: workflow-level `contents: write,
packages: write` inherited by every job; mutable action tags
(`softprops/action-gh-release@v2`, `docker/*`, `subosito/flutter-action@v2`,
`dart-lang/setup-dart@v1`); releases public immediately per matrix leg; no
tag-vs-pubspec check on dispatch (the comment at lines 20-24 only asks for
one); no refuse-overwrite; no SHA256SUMS; Docker `type=raw,value=latest` on
every tag including prereleases (`:315`). CI and release use unpinned `stable`
Flutter/Dart while the app pubspec says `flutter: ">=3.24.0"` (X-11);
Poltergeist pins 3.47.2 and relies on Séance's macOS accessibility gate "on the
same Flutter line" (X-26). The Dockerfile uses floating `dart:stable` and
`debian:stable-slim` without `--enforce-lockfile` (X-23). No
`persist-credentials: false`; no secret scan (fixtures contain PEM headers and
need a scoped allowlist); Dart tests are Ubuntu-only despite Windows named-pipe
and Unix-socket agent code; the review workflow makes a single attempt (X-24).
No multi-arch images.

**Next.** Port Poltergeist's release structure: resolve the checkout ref,
refuse to overwrite, a shell loop checking that all four pubspecs equal
`${tag#v}`, draft legs with `fail_on_unmatched_files`, and a sums job that
verifies a bijection and then publishes. SHA-pin third-party actions; job-level
permissions (read for test/native/flutter); `persist-credentials: false`;
`latest` only when the tag contains no `-`; `FLUTTER_VERSION: '3.47.2'` in CI
and release, the app floor `>=3.47.2`, AGENTS §1 pinned, bumped together with
Poltergeist. Pin base images by version and digest sharing one Debian codename;
`dart pub get --enforce-lockfile`. Add a secret scan, multi-OS `dart test` and
one bounded review retry. Make Docker Hub and Gradle pulls resilient (caches,
authenticated pulls, bounded retries) and distinguish infrastructure failures
from code failures. Back up before schema updates, wait for readiness and roll
back failed deploys (`update.sh`). Pin an SDK/golden-update policy; never
regenerate goldens just to turn CI green. Correct stale scratch/static-image
and every-request version claims (DOC-01).

**Gate.** A dispatch with a mismatched tag fails; a prerelease does not move
`latest`; a re-run refuses to overwrite; SHA256SUMS verify; packaged install
and upgrade; failed rollout recovery.

Sol's current build-input evidence is .github/workflows/ci.yml:209-217,2374-2380,
.github/workflows/release.yml:451-456 and
seance/packages/seance_sync_server/Dockerfile:7,19,25,39: floating Dart/image
inputs and non-enforced locks can change artifacts from the same commit.
Pin the bundled Dart version, image digest/codename and enforce-lockfile,
with a lock-drift check. Rough effort: half a day plus pin maintenance.
The updater backup/candidate/rollback slice is implemented in #619 and must
not be repeated.

### REL-02: Verify downloaded Linux packaging tools

general issues — important

**IDs:** X-08, SOL-040 appimagetool note · **Status:** Open

**Problem.** `scripts/package-linux.sh:380-401` downloads appimagetool 1.9.1,
runs `chmod 755` and executes it without a checksum, caching by basename.
Without `--runtime-file` (`:436-445`) appimagetool embeds a runtime fetched
from the mutable `type2-runtime` "continuous" release, and the job holds
`contents: write`.

**Next.** Pin `APPIMAGETOOL_SHA256_x86_64`/`_aarch64` and verify with
`sha256sum -c` before `chmod`, for downloaded and cached copies; pin a
`type2-runtime` asset with its SHA-256 and pass `--runtime-file`; source-aware
cache keys; keep explicit local-tool overrides. Make the same change in
Poltergeist.

**Gate.** A hash mismatch, a URL collision and an interrupted download fail the
build.

### XAPP-01: Preserve unknown `ServerConfig`, `Snippet` and `Bookmark` keys

bugs — important

**IDs:** X-03, "protocol hygiene" idea · **Status:** Open

**Problem.** `seance_protocol/lib/src/models/server_config.dart:327-400`:
`toJson` writes and `fromJson` reads only known fields; unknown enum names
degrade to null. Poltergeist round-trips Séance's catalog through a lagging
pin, so any field Séance adds is stripped fleet-wide when Poltergeist (or an
older Séance) edits a label, and the stripped record wins LWW. Poltergeist's
editor already dropped `jumpHostId` this way (X-02, being fixed on its side).

**Next.** A private `Map<String, Object?> _unknown` captured in `fromJson` and
merged back in `toJson`, carried by `copyWith`; keep the raw values of
known-but-rejected enum names. The same for `Bookmark` and `Snippet`. Add
"every model round-trips unknown keys" to POLTERGEIST.md's never-touch list,
with a golden test per model that both repos run. Poltergeist re-pins
afterwards.

**Gate.** Decode JSON with extra keys, `copyWith(label:)`, `toJson`: the extras
survive byte-identical; an unknown icon name round-trips.

### XAPP-02: Tag and re-pin coordination for #131 (agent default, API break)

general issues — important

**IDs:** X-04, X-25, X-05 (Séance side), PR-S4 ·
**Status:** Open (blocks the next tag)

**Problem.** Once tagged, Séance's agent default makes every new or keyless
imported server fail in Poltergeist on v0.9.1 (`AgentAuthUnsupportedError`).
The re-pin is breaking: `KeyboardInteractiveResponder` now takes a
`KeyboardInteractiveChallenge`; `AgentAuthUnsupportedError` was removed;
`openAuthenticatedClient` gained `resolveJumpHost`, `forward` and
`loadAgentIdentities`; `seance_core` added `ffi: ^2.1.0` (license gate).
Without a resolver, `jumpHostId` configs now fail honestly
(`ssh_session.dart:855-861`), while the old pin dials the destination directly
(X-05). The wire format and record kinds are unchanged since `035b0d8`.

**Next (Séance side).** Do not tag the agent default until Poltergeist has a
fallback or is ready to re-pin in the same window; resolve SSH-06 first.
Record the API changes in CHANGELOG. Consider the downstream canary job (idea).

**Gate.** Poltergeist builds and connects to an agent server on the new tag.

---

## Nice-to-have

### CRED-03: Diagnose and recover mixed-key legacy accounts

bugs — nice-to-have

**IDs:** S1-05 and SEA26-SEC-08 residuals.

The empty-account key-check and safe enrolled-device bridge are implemented in
#594 and #639, including tombstone-only accounts. An account already containing
ciphertext from incompatible vault keys can still be reported as a wrong
passphrase rather than as mixed-key data, leaving users without a clear
recovery path.

Suggested fix: after key verification, classify unreadable records separately
from an incorrect account passphrase and offer explicit, previewable recovery.
Preserve incompatible ciphertext until the user chooses what to restore or
discard. Test correct-key, wrong-key and mixed-key accounts distinctly.


### SYNC-04: Oversize save guards and durable refusal state

general issues — nice-to-have

A snippet or image mark can still be saved above the server's advertised blob
limit and will then be retried on every later sync run unless its content
changes.

Suggested fix: reject oversize content at save time using the active account's
advertised limits, persist a refusal fingerprint so unchanged content is not
re-uploaded across runs, and surface the offending record and current limit.
Use SYNC-03's incomplete-outcome contract when the round limit is reached.

### SYNC-08: Exclude-from-sync residuals

bugs — nice-to-have

**IDs:** #72 follow-ups (S5 new gap) · **Status:** Open

**Problem.** No "has ever synced" bit, so re-linking can retract unprompted
(`server_editor.dart:24-30`); a peer's later exclusion deletes a config this
device re-included (`sync_coordinator.dart:555-563`); pins pushed before
exclusion are withheld, never retracted (`:203-220`; needs SYNC-01).

**Next.** Persist a per-server `everSynced` flag; treat a peer exclusion as a
retraction only when it is newer than this device's re-inclusion revision.

**Gate.** Coordinator tests for re-link, peer exclusion after local
re-inclusion, and pin withholding.

### SYNC-09: Monotonic snippet (and re-pin) stamps

bugs — nice-to-have

**IDs:** S1-08 · **Status:** Open

**Problem.** `ui/snippets_pane.dart:377-387` stamps edits with raw `now`;
`AppState.saveSnippet` (`app_state.dart:1465` @9322f6e) does not clamp. After
adopting a snippet from a peer whose clock runs ahead, a local edit loses LWW
and `putSnippet(remote)` (`sync_coordinator.dart:671`) silently reverts it.
Contrast `nextUpdatedAt` (`server_editor.dart:158-159`), `putLocalSecret` and
`_deletionStamp`. Re-pin at `ssh_session.dart:125`
(`pinnedAt: DateTime.now()`) has the same shape: fail-safe but confusing, as
the old pin returns and blocks.

**Next.** Clamp centrally in `saveSnippet`:
`updatedAt = max(snippet.updatedAt, existing.updatedAt + 1)`; consider the
same for re-pin.

**Gate.** Saving an edit to a snippet whose stored `updatedAt` is
`now + 60000` stores a larger stamp.

### SYNC-10: Idle sync reports own echoes and spends two rounds

bugs — nice-to-have

**IDs:** S1-12 · **Status:** Open

**Problem.** `sync_engine.dart:78,87` counts `applied++` when the remote copy
of this device's own record wins the seq tie; idle runs report "pulled 5" in
Settings (`settings_screen.dart:1352`) and always take two rounds (reproduced).

**Next.** In `_pullOnce`, when `updatedAt` and `deviceId` match, still
`putRemote` (clear dirty, adopt seq) but do not count it as applied; update the
loop's break-condition test. Pairs with the "echo-free cursor advance" idea.

**Gate.** Probe: idle runs 1 and 2 report `pulled=0 rounds=1`.

### SRV-04: Validated, overridable server configuration

general issues — nice-to-have

**IDs:** S1-14 · **Status:** Open

**Problem.** `packages/seance_sync_server/docker-compose.yml:27` hard-codes
`SEANCE_OPEN_REGISTRATION: "false"` (and the limiter and cap variables); `.env`
only feeds `${}` interpolation, so enrolling requires a local diff that
collides with `./update.sh`'s `git pull --ff-only`. An invalid port
(`bin/seance_sync_server.dart:40-47`) also silently falls back to its default,
so an operator can deploy on an unintended port without a diagnostic.

**Next.** `"${SEANCE_OPEN_REGISTRATION:-false}"` and the same pattern for the
other variables; document them in `.env.example`. Parse the port strictly,
enforce its documented range at startup and print a concise CLI usage error
instead of silently substituting a default.

**Gate.** `docker compose config` with an `.env` override shows the value.
Invalid, negative, zero and out-of-range ports fail startup with the offending
setting named.

### SSH-02: Keepalive cannot detect a dead peer

bugs — nice-to-have

**IDs:** S2-08 · **Status:** Open (table row only: re-trace)

**Problem.** One unanswered keepalive ping stops keepalives for good, so a dead
peer is never detected. Core keepalive controls came in #77.

**Next.** Re-trace the keepalive code under `seance_core/lib/src/ssh/`. Count
consecutive unanswered pings, keep sending on the interval, and close the
session with a clear "connection lost" reason after N misses (OpenSSH
`ServerAliveCountMax` semantics).

**Gate.** A fake transport that stops answering: the session reports lost
after N intervals; an answering transport keeps pinging.

### SSH-03: Cancellation wrapper leaks a listener per chunk

bugs — nice-to-have

**IDs:** S2-06 · **Status:** Open (table row only: re-trace)

**Problem.** `_cancelWhenRequested` adds a listener per 16 KiB chunk to a
never-completing future: about 500 MB per million chunks in JIT (benchmarked).
The code is shared by Poltergeist's bulk transfers.

**Next.** Register one listener per transfer, or remove the subscription on
completion.

**Gate.** A 100k-chunk transfer keeps the listener count constant (counting
fake) and memory flat in a benchmark; cancellation still works mid-transfer.

### SSH-04: Keyboard-interactive echo, cancel and keyboard flow

usability — nice-to-have

**IDs:** SOL-021, AST-002 residual, S4-21 · **Status:** Partial

**Done (#131):** typed `KeyboardInteractiveChallenge {server, prompts, name,
instruction}`; trusted endpoint separated from server text; private answers,
per-field reveal, keyboard privacy, IME scrolling.

**Problem.** The echo flag is dropped (`ssh_session.dart:661` maps only
`promptText`); cancel is still "empty list"
(`ui/keyboard_interactive_dialog.dart:5`); Enter neither submits nor advances,
and the reveal button is in the Tab order (`:106-127`).

**Next.** `List<bool> echo` and an explicit `KeyboardInteractiveCancelled`
result (keep callback compatibility); `textInputAction: last ? done : next`;
`onSubmitted` advancing or submitting; the reveal button with `skipTraversal`.
Verify Next/Done traversal and intentional password/OTP autofill without
guessing from remote text.

**Gate.** Enter submits a single prompt; with two prompts the first Enter moves
focus; cancel is distinct from an empty valid challenge; echo and no-echo;
multiple rounds; prompt count and order; small screens; native composition,
reveal, selection and focus; hardware and software keyboards. A server echo
flag is not proof an answer is non-sensitive.

### SSH-05: ssh_config import parity

missing features — nice-to-have

**IDs:** SOL-022, SEA-007, SEA-027, S2-10, S4-26, ProxyJump import (S5 gap),
`importSshConfig` outside `_mutate` · **Status:** Partial (lines split as
ssh splits them, every name on a `Host` line imports, and a host with a
refused `Port` is skipped and counted)

**Problem.** Paste-only dialog without preview or dedupe
(`ui/server_list_pane.dart:788-823`); a fresh UUID per import; the last value
wins (`ssh_config_import.dart:69`; OpenSSH is first-wins); wildcard defaults are
dropped (`:74-79`); no Include; `ProxyJump` is parsed (`:87`) but not mapped to
`jumpHostId`; an empty username is kept. S2-10 (table row only): `%h` is not
expanded. S4-26: the dialog's `TextEditingController` is never disposed.
`importSshConfig` (`app_state.dart:1155` @9322f6e) writes the store outside
`_mutate` (harmless today, but it breaks the queue's invariant). Keyless hosts import as agent (#131; see SSH-06).

`SshConfigLine` now splits each line as ssh's `argv_split()` does: quotes and
backslash escapes are removed, `#` starts a comment only where an argument
would start, and one `=` may follow the keyword, so `Key = value` reads
`value` (S2-10). Every name on a `Host` line imports with the block's
settings, and a host whose `Port` the importer refuses is skipped and counted
in the toast.

**Next.** First value wins; evaluate each imported alias against matching
`Host *` defaults; handle multiple identities; Include with a loop guard;
`%h` expansion; ProxyJump mapped to a saved host; unresolved auth marked
setup-required. An `_ImportSshConfigDialog` StatefulWidget owning its
controller, with file Browse and "Read ~/.ssh/config" on desktop, a preview
with unsupported-directive warnings and host/port/user dedupe; run under
`_mutate`. Consider `ssh -G` behind an evaluator interface on desktop.

**Gate.** Idempotent repeated imports; wildcard and repeated blocks; Include
loops; ProxyJump mapping; sandbox file grants. No directive executes local
commands during preview.

### SSH-07: Agents, jump hosts, forwards and key management

missing features — nice-to-have

**IDs:** SOL-028, S2-22, X-14 (Séance), ProxyJump editor gap (S5) ·
**Status:** Partial

**Done (#131):** Unix and Windows agent clients (`ssh/ssh_agent.dart`);
saved-host jump chains with per-hop TOFU, auth, keepalive and cleanup.

**Problem.** No editor UI for `jumpHostId` (`server_editor.dart:919-920` "not
exposed yet"; the route is preserved on save). Automatic server-local URL
forwarding is transient; there is no configurable, durable local, remote or
dynamic forwarding. When the requested local port is occupied, automatic
forwarding silently chooses another port even though absolute redirects and
cookies can retain the original port. Active automatic tunnels have no
discoverable status or revoke surface. Malformed IPv4 such as
`127.999.999.999` is classified as local because octets are parsed without
range checks (`server_links.dart:19-23`). If listener cancellation or close
throws during loopback-forward shutdown (`loopback_forward.dart:65-81`), later
relay sockets are not destroyed even though `done` completes.
No known_hosts import/export (`HostKey.fromPublicKey` is unused), no key
generation or public-key deployment. The Windows agent was never exercised at
runtime, and real agents including password-manager integrations were not
validated. Poltergeist's older pin still needs an audited adoption (XAPP-02).
dartssh2 3.0.2 defaults included dh-group1-sha1, hmac-md5,
ssh-rsa/SHA-1 and CBC, with no strict-KEX (Terrapin) support (S2-22). Since
2026-10-10 the 4.1.0 pin negotiates strict KEX and drops dh-group1-sha1 and
hmac-md5; both apps keep SHA-1 key exchange and CBC as a last resort and
ssh-rsa in its 3.0.2 slot before ECDSA (owner decisions). Dependabot covers
github-actions and
gradle only (not pub), and its gradle entry points at `/`, where no Gradle files
exist (X-14).

**Next.** A "Connect via" saved-host picker (cycle-checked) and alias/import
parity (SSH-05); explicit capability errors; then known_hosts import/export and
fingerprint aids; then forwarding UI for local, remote and dynamic tunnels with
explicit bind addresses; per-device key generation and public-key deployment
as a separate slice. Validate real agents, including password-manager
integrations and Windows named pipes. Restrict default
algorithms to modern sets with an explicit per-host legacy opt-in (an owner
decision; the global fallback stays until then). Dependabot: add `pub` for the
workspace and the app; point gradle at `/app/seance_app/android`. Forwarding
needs persisted bind/target configuration, safe loopback defaults, explicit
exposure warnings and lifecycle/status UI. Surface automatic tunnels with the
server target, local URL, Copy/Open, health and Revoke; any traffic indication
must honour reduced motion. Warn, retry, offer Copy, or refuse when a fallback
port would break exact-port semantics. Range-check every IPv4 octet. Teardown
must attempt listener and every relay cleanup independently, complete `done`
only after those attempts, and retain an actionable aggregate failure.

**Gate.** A real sshd matrix (agent cancellation and unavailability, every-hop
TOFU, jump failure cleanup, explicit forwarding bind addresses and lifecycle,
malformed local-target hosts, occupied same-port behavior, and teardown where
listener cleanup throws while relays remain active; legacy-algorithm refusal).
Verify strict-KEX/Terrapin behaviour and dependency advisories against primary
evidence. Preserve SFTP cancellation conformance (dartssh2 3.0.2, #59) on
upgrades.

### SSH-08: Honest reachability probes

bugs — nice-to-have

**IDs:** SOL-024, S2-18, "polite probing" idea · **Status:** Open

**Problem.** `TcpBannerProber`
(`seance_core/lib/src/probe/probe_service.dart:22-56` @9322f6e) documents that
"a banner starting with `SSH-` confirms online" but never checks it: any
completed connect is online (including a banner timeout), and every
`SocketException` (refusal, DNS, routing) is offline. Servers with a
`jumpHostId` are probed directly (`updateServers`, `:182`), leaking a direct
connection attempt and showing a wrong status (S2-18). Done: bounded
concurrency, connected-host skipping, disposal guards (#36), sweep
serialization (`4a50782`).

**Next.** Read up to 255 bytes for an `SSH-` line; ECONNREFUSED is offline,
DNS/unreachable/timeout is unknown; jump-routed servers report unknown (or are
probed through the route later); per-host opt-out. Preserve background pause,
staggering and the active-session bypass. Optional: per-host
exponential backoff for offline hosts with "last checked" in the tooltip.

**Gate.** Loopback services returning SSH, HTTP, silence, split banners,
pre-banner lines and malformed or oversized data; a jump-routed host is never
dialed; disposal and background transitions neither publish late state nor
restart timers.

### SSH-09: Remote git probe hardening and porcelain parsing

bugs — nice-to-have

**IDs:** S2-05, S2-04, #137 follow-up · **Status:** Open

**Done (#137):** dialect-neutral `quoteShellWord` for the git probe and the
staged `cd` (fish-safe); control-character guard on OSC 7 directories.

**Problem.**
- The probe is still parsed by the login shell (`remote_git.dart:214`
  @9322f6e); fish before 4 cannot parse `{ }` groups and csh differs.
- S2-05 (table row only): the background probe honours the repository's
  `core.fsmonitor` (a repo-configured command runs) and takes optional index
  locks.
- S2-04 (table row only, VERIFIED with git 2.43): porcelain v2 `-z` headers
  are NUL-terminated, so branch, upstream, ahead/behind and stash are dropped
  on every git >= 2.17; the test fixtures use LF-terminated headers.
- OSC 7 handling decodes `Uri.path` a second time
  (`xterm_engine.dart:188-197`), so a literal `%20` path component becomes a
  space and Files/Git can follow the wrong directory.

**Next.** `client.execute('sh -s')` with the script written to stdin; pass
`-c core.fsmonitor= -c core.untrackedCache=false` and `GIT_OPTIONAL_LOCKS=0`;
split `-z` header records on NUL; replace fixtures with captured real output.
Use `uri.path` directly for OSC 7 paths; Dart has already decoded it once.

**Gate.** A fixture from real `git status --porcelain=v2 -z --branch
--show-stash` yields branch, upstream, ahead/behind and stash; a repo with a
hostile `core.fsmonitor` does not run it (side-effect file absent); the probe
works with fish 3 and csh as the login shell (skip when absent). An OSC 7 URI
containing `%2520` resolves to a path with a literal `%20` component.

### SSH-10: Upload replace residuals

general issues — nice-to-have

**IDs:** S2-09, #138 follow-ups · **Status:** Partial

**Done (#138):** replace refused over symlinks, FIFOs, devices and folders (up
front); permission bits masked (`& 0xFFF`); staging owner-only when the final
mode withholds read or write.

**Problem.** The temp file is readable before `fsetstat` lands (dartssh2's open
takes no attrs); uid/gid are not preserved on replace; a kept setuid/setgid bit
moves to the uploader's identity; a symlink planted between the second
preflight and the rename is not detected (SFTP has no compare-and-rename).
Poltergeist re-pin note: #138 adds one `fsetstat` per upload for non-0666
modes, and Poltergeist's fakes may need `setStat`.

**Next.** Open the temp file with restrictive attrs where the server honours
them, otherwise create and chmod before writing any bytes; drop setuid/setgid
when the owner would differ (like `cp -p`); attempt `fchown` to the original
uid/gid and report when refused; document the remaining TOCTOU honestly
(hash-before-rename is not a lock).

**Gate.** Upload CAS tests: no data written before the mode is set; setuid
dropped on owner change; ownership preserved when permitted.

### SSH-11: SFTP robustness, progress coalescing and throughput

performance problems, stuttering, and jank — nice-to-have

Uploads are limited to one local chunk per round trip, while each progress
chunk can notify the Files pane and cause thousands of rebuilds during a large
transfer. Listings also accept server-supplied names containing slash, dot-dot
or NUL, and a dead cached SFTP subsystem cannot be reopened cleanly.

Suggested fix: pipeline a measured, bounded number of outstanding writes;
coalesce progress notifications to a frame- or time-based cadence while always
emitting start, completion, cancellation and failure; reject invalid names at
the listing boundary; and evict a closed subsystem so reopening returns a
normal Future. Benchmark typing latency and throughput at 50 ms RTT and cover
hostile names and reconnect.

### Resume interrupted SFTP transfers from verified checkpoints

missing features — nice-to-have

Interrupting a Files upload or download restarts it from byte zero. The
transfer API exposes progress and cancellation but no offset negotiation or
retained partial-transfer state, wasting bandwidth and time on mobile or
unreliable networks.

Suggested fix: offer opt-in Resume/Restart using verified local/remote sizes
and fingerprints, retain clearly named partial files, and reject a resume if
the endpoint or source has changed. Test interruption and source changes in
both directions. Rough effort: two to four days.

### SSH-12: Host-key algorithm preference ignores the pinned type

bugs — nice-to-have

**IDs:** S2-17 · **Status:** Open (table row only: re-trace)

**Problem.** The negotiated host-key algorithm does not prefer the pinned
key's type, so a server offering several key types can present a different
one and raise a false "HOST KEY CHANGED".

**Next.** When a pin exists, put its algorithm first in the host-key
preference list.

**Gate.** A server with ed25519 and ecdsa keys and an ecdsa pin: no
changed-key prompt.

### TERM-03: Fork reflow pushes a half-filled screen into scrollback

bugs — nice-to-have

**IDs:** S4-05 · **Status:** Open

**Problem.** `third_party/xterm/lib/src/core/buffer/buffer.dart:531-571`
(`resize`): seven lines at 80x24 resized to 44 columns give `scrollBack=5`
with 35 blank rows visible; with a long line below the prompt, narrowing
leaves the cursor one row below its prompt because `_cursorY` is not adjusted
for reflowed lines (both reproduced). It shows when dragging dividers, snapping
windows or rotating phones, and breaks `fzf --height` and zsh menus.

**Next.** Record the cursor line before reflow (an anchor or wrapped-row
count); after reflow, drop trailing blank rows below the cursor down to the new
height before anything becomes scrollback; set
`_cursorY = newCursorAbs - scrollBack`; keep the maxLines trim patch.

**Gate.** The two probes as expectations (`scrollBack == 0` with the first row
intact; the cursor row reads `prompt$`); a narrow-then-widen round trip; an
alternate-buffer no-op.

### TERM-04: Bounded, Unicode-safe pending-input hints

bugs — nice-to-have

**IDs:** AST-010, SEA-006 · **Status:** Open

**Problem.** `services/xterm_engine.dart:278` `_trackPending` appends per rune
without a bound, ignores cursor and history edits, and removes one UTF-16 code
unit on backspace (quadratic on large pastes; malformed non-BMP text).
`_snippetTitle` (`app_state.dart:1924` @9322f6e) and `_shortError` (`:1856`)
truncate with `substring`.

**Next.** Cap at about 4 KiB, then mark unknown; delete by grapheme
(`characters`); invalidate on arrow and history keys; reuse the grapheme-safe
middle-ellipsis truncation for labels and errors. Pending text stays a hint,
never authoritative shell state or safe LLM context; do not guess a remote
cursor position from screen columns.

**Gate.** Emoji, combining and ZWJ edits; large pastes; cursor, history and
control keys; no-echo input; no malformed UTF-16, unbounded growth or
automatic cloud prefill.

### TERM-08: Disconnect recovery ("Last words")

missing features — nice-to-have

**IDs:** SEA-026 · **Status:** Open

**Problem.** Disconnected sessions render `_Disconnected`
(`terminal_pane.dart:1081` @9322f6e) instead of the retained scrollback;
reconnect is manual; the connection-failed view has no "Edit server" action.
Persisted edit placeholders are not session restoration.

**Next.** Render the retained `TerminalView` read-only with a reason, duration
and cwd banner plus Copy, Save, Reconnect and Edit server. Then opt-in
reconnect with bounded backoff and cancel after network changes, and opt-in
tab restoration with a target preview. tmux/Mosh persistence is a separate
feature, not a promise of TCP reconnect. Simultaneous terminal splits are also
a separate post-v1 design for multi-host work; preserve the existing
session/engine seams for both splits and Mosh rather than coupling them to
reconnect. Local-shell and process-restoration policies remain separate.

**Gate.** Network flaps, background/resume, auth expiry, normal and error exit,
manual cancel, stale attempts; never replay a command or login script silently.

### TERM-09: Terminal display preferences and link affordance

usability — nice-to-have

**IDs:** S4-15, S4-24, SOL-064 (preferences), OSC 8 residual ·
**Status:** Open

**Problem.** The terminal passes no `textScaler`
(`terminal_pane.dart:1096-1114`), so the grid follows the OS text scale (about
22 columns on a 360 dp phone at 2x, while Settings still says 13 pt). The fork
shows a hand cursor over any link
(`third_party/xterm/lib/src/terminal_view.dart:356-363, 391`) although opening
needs Cmd/Ctrl or touch (`:423-429`). OSC 8 links (#103) have no keyboard
discovery or mobile gesture. There are no cursor shape/blink, scrollback length
(fixed `maxLines` 10000), bell, ligature, OSC 52 or remote-title settings.

**Next.** `textScaler: TextScaler.noScaling`; seed `terminalFontSize` from the
OS scale on first run (clamped), or add "Scale terminal with system text"
(default off); show the effective size. Click cursor and underline only while
the modifier is held, with a "Cmd-click to open" tooltip. Add cursor and
scrollback settings first; bell, ligature, OSC 52 and remote-title policies are
distinct features (titles must not impersonate trusted chrome).

**Gate.** `RenderTerminal.cellSize` at text scale 2 equals the 1.0 size; hover
without the modifier shows the text cursor.

### TERM-10: Mobile terminal interaction gate

usability — nice-to-have

**IDs:** SEA-023/025/028 mobile gate, STATUS 10 · **Status:** Open
(validation)

Test on devices: touch handles, the copy toolbar, magnification, edge drag,
selection under output, external keyboards, iPad shortcuts, CJK and dead-key
IME, and floating or overlay keyboards covering the last row. Preserve the
implemented multi-click, shift, drag, trim and Option behaviour.

### PERF-01: Reproducible latency harness, then measured changes

performance problems, stuttering, and jank — nice-to-have

**IDs:** SOL-026, SOL-057, SOL-059, SEA-012, AST-012 · **Status:** Open

Risks, not measured regressions: packet-by-packet synchronous parsing and
rapid PTY resize compete with input; all servers' sessions stay mounted in an
`IndexedStack` (`terminal_pane.dart:287` @9322f6e), where hidden views retain
render and paragraph caches and take part in layout and resize; broad `AppState`
notifications rebuild chrome (the MaterialApp now rebuilds only on
`appearance`, #128; the old trace-line storm was fixed in #35); KDF, crypto,
whole-collection JSON writes, recursive SFTP scans and editor work share the UI
isolate (preserve the existing syntax memoization and highlight caps); SFTP and
keystrokes share one transport, and transfer throughput is not typing latency.
Only
`test/connect_perf_test.dart` exists.

**Next.** Record p50/p95 frame and keystroke latency, parser throughput and
peak RSS on a laptop and a midrange phone: captured ASCII/colour/Unicode,
`yes`, large files, full scrollback, unterminated controls, resize spam,
selection during output, 1/10/50 tabs, tab switches, concurrent upload and
cancel. Separate parser, layout, raster, transport and GC time; target 60 Hz
(16.7 ms frames), not an unmeasured claim. Then, one at a time and each
measured: bounded output queues and backpressure, coalesced and
duplicate-suppressed PTY resize, active-server plus LRU rendered views without discarding
session state, focused listenables, batched domain writes, off-isolate work,
glyph-run painting (idea). The initial PTY stays 80x24 until widget layout
(STATUS 8); negotiate the measured grid earlier only if the harness shows
visible redraw. Remote resize must never recurse into itself. The optional
connection flight recorder (AST-012, see Ideas) can expose
DNS/TCP/handshake/auth/shell versus parse/layout timings; keep its retention
bounded and its export previewable and redacted, with no keys, commands or raw
traces by default.

**Gate.** Harness numbers recorded in the PR for each change; no regression in
interactive interrupt latency or quick tab switches.

### PERF-03: Built-in editor gutter relayout per keystroke

performance problems, stuttering, and jank — nice-to-have

**IDs:** S4-06, UI-10 (sibling review) · **Status:** Open

**Problem.** `built_in_text_editor.dart:472-503` `_ensureGutterLayout` keys its
cache on text identity, so each keystroke lays out a second `TextPainter` over
the whole span (up to 200k chars) and calls `getOffsetForCaret` per line: about
260 to 335 ms per keystroke for a 150 KB file in debug JIT. Byte/line recounts
and TextField layout remain after the syntax cutoff.

**Next.** A monospace fast path: if `maxLineChars * advanceWidth <=
textWidth`, tops are `i * lineHeight`; otherwise use the field's
`RenderEditable` for visible lines, or debounce precise layout to idle.
Benchmark giant lines too. Preserve BOM and line-ending fidelity and save
safety.

**Gate.** A `@visibleForTesting` counter: 20 keystrokes in a no-wrap 150 KB file
do 0 precise layouts; wrapped documents keep correct tops; the existing gutter
tests pass.

### PERF-05: Verify transport cancellation at the real socket

performance problems, stuttering, and jank — nice-to-have

The in-review providers and search use `http.AbortableRequest`, propagate
cancellation through headers, bodies and SSE, and close owned clients. Their
unit coverage does not prove that each platform HTTP adapter actually closes a
live socket after Stop, timeout, settings replacement or disposal.

Suggested fix: add platform-backed integration fixtures that observe the
server connection close after Stop, timeout, settings replacement and
disposal, not merely a rejected late result. Fix only adapters that fail this
gate; do not add another cancellation abstraction around the existing abort
path.

### AI-03: Untrusted-context delimiters are static and spoofable

general issues — nice-to-have

**IDs:** S2-12 · **Status:** Open (table row only: re-trace)

**Problem.** Terminal and search context is wrapped in fixed markers
(`<<<CONTEXT` / `CONTEXT>>>`, e.g. `command_generator.dart` near `:80`
@9322f6e) that terminal output can close and follow with instructions.

**Next.** Per-request random nonce delimiters, escaping any occurrence in the
content, plus a system instruction naming the nonce; prefer provider-native
structured content blocks where available.

**Gate.** Context containing the closing marker cannot end the block (unit test
on the built prompt).

### AI-04: Danger-linter bypasses

bugs — nice-to-have

**IDs:** S2-13 · **Status:** Open (table row only: re-trace)

**Problem.** The independent danger linter misses `bash <(curl ...)`,
`sh -c "$(curl ...)"`, `| sudo -E bash`, quoted targets, `/dev/xvda` and
similar forms (verified by running the linter).

**Next.** Add rules with a table of positive and negative cases; normalize
quoting before matching. The review-before-run gate stays the real safety.

**Gate.** Table tests for each bypass and for safe look-alikes.

### AI-05: Bounded, recoverable command-history learning

bugs — nice-to-have

**IDs:** SOL-046, AST-007 residual, SEA-034, S3-10, STATUS 9.

Capture is restricted to proven OSC 133 prompt transitions in #597. The
remaining history issues are unbounded command length, no whisper/clear
controls, and frozen learning once all 400 stored commands have count >= 2:
a new count-1 command is evicted immediately, with unstable tie ordering.
The delayed save callback drops its Future and can lose up to three seconds
of statistics on quit.

Suggested fix: bound command length and loaded/dismissal data, use stable
recency-aware eviction that retains the just-recorded command, and await/log
saves. Add Clear history and an explicit whisper choice for capture and
outgoing context. Preserve the independently applied recognizable-secret
filter, proven prompt boundary, nested-shell and alternate-screen rules.
Historical backups, damaged files and arbitrary plaintext secrets cannot be
promised scrubbed. Test the 400-command saturation case, save failures and
quit-time flush.

### AI-06: Safe context enrichment and search error typing

missing features — nice-to-have

**IDs:** workflow backlog "Safe context enrichment", STATUS 15 ·
**Status:** Open

**Problem.** OSC 7 cwd, OSC 133 D exit code and OSC 1337 shell kind exist
(`xterm_engine.dart:166-260`), but chat sends only `recentText(maxLines: 200)`
(`chat_sidebar.dart:69` @9322f6e). Search failures have no domain exception
type (STATUS 15).

**Next.** A labelled context header with cwd, shell and last exit ("unknown"
when not reported); prefer command blocks (TERM-07) over a blind last-N-lines
window. Add a typed search failure when a retry UI exists.

**Gate.** Header content with and without shell integration.

### APP-03: Lifecycle mapping treats `inactive` as background

bugs — nice-to-have

**IDs:** S3-05 · **Status:** Open

**Problem.** `main.dart:105-109` calls `setForeground(lifecycle == resumed)`.
On desktop `inactive` means "not focused but visible" (on Android it also
covers the notification shade and split screen). Every refocus runs an
immediate probe sweep of every server (`probe_service.dart:223-228, 241-243`)
and re-hashes all managed checkouts twice on the UI isolate
(`remote_files_controller.dart:1300-1312`, plus per-tab
`reconcileLocalCopies`); open editors re-stat. Switching windows every 10 s
multiplies sshd preauth log noise about 4.5x, and status dots go stale on a
visible second monitor.

**Next.** Ignore `inactive`; `hidden`/`paused`/`detached` pause; `resumed`
resumes; idempotent `setForeground` (`app_state.dart:1997` @9322f6e); one
`reconcileAll` per resume fanned out to tabs and controllers (skip where
directory watchers run); optionally `ProbeService.resume()` sweeps immediately
only if the last sweep is older than the interval.

**Gate.** Bootstrap widget test: `inactive` leaves `probe.isPaused == false`;
`hidden` pauses; `resumed` resumes once; a counting fake store sees one
`reconcileAll` per resume.

### APP-04: Managed checkout recovery residuals

bugs — nice-to-have

**IDs:** S3-12, S3-11, S3-08 (index part), #141 follow-ups, "expose retained
plaintext edits", "recovered edits drawer" idea · **Status:** Partial

**Done (#141):** checkouts preserved across index loss or quarantine (sweep
inhibited); startup survives unreadable checkouts. Earlier: per-file "Discard
local copy"; the editor keeps 0600 and refuses symlinks. Still owed from the
Files backlog: expose retained plaintext edits, their storage and discard.

**Problem.** Preserved checkouts are not visible anywhere. Checkouts whose
server is gone are skipped at restore (`app_state.dart:2204-2205` at
`dd7e105`), keeping hidden plaintext and edits forever. A newer-version index
is still quarantined instead of opened read-only. A Windows `*.tmp` index left
by the delete-then-rename fallback is never read back (STORE-01). S3-11:
renaming onto a path with a retained local copy overwrites
`localCopies[target]`, and `ManagedRemoteFileStore.update` (`:148-162`) lacks
`put`'s duplicate check, so the old edits become invisible, leak on close and
block future checkouts of that path.

**Next.** A "Recovered edits" list (Settings > Files) of all checkouts not
attached to a live session, with sizes, Open, Reveal, Export, Upload to and
Discard, plus bulk discard; minimal slice: `AppState.orphanedManagedFiles`
feeding a one-time notice. Open a newer index read-only and disable
managed-edit writes with a clear error. `renameEntry` refuses when a local copy
holds the target ("upload or discard the local copy of b.txt first"); `update`
gets the duplicate check.

**Gate.** A seeded orphan for server `gone` is listed after `load()`; index v2
untouched and read-only; the rename is refused with remote and index unchanged.

### APP-05: Vault lock reason and platform-correct messages

bugs — nice-to-have

**IDs:** S3-14 · **Status:** Open

**Problem.** A settle failure sets `vaultKey = null` but `keystoreStatus` stays
`available` (`app_services.dart:199-214`), so no notice appears
(`main.dart:153-155`), and every connect then advises installing gnome-keyring
(`secure_master_key.dart:22-25`), on every platform.

**Next.** An `AppServices.vaultLockReason` enum (`keystoreUnavailable`,
`rekeyPending`, `keyMissing` for CRED-04); a notice on any reason; reason- and
platform-specific `VaultLockedException` messages.

**Gate.** `keystore_resilience_test.dart` with an unreadable journal via
`IOOverrides`: locked with reason `rekeyPending` and a matching message.

### APP-06: Schedule sync after a new host-key pin

bugs — nice-to-have

A host key written by the core trust path does not schedule automatic sync.
Other local edits trigger a debounced round, but a newly trusted key can remain
device-local for up to the periodic interval or until another edit occurs.

Suggested fix: have the application host-key service report a newly created or
changed pin and queue the same coalesced auto-sync used by server/snippet
mutations. Do not schedule for a no-op verification. Test that a pin during an
active round produces exactly one bounded follow-up.

### APP-07: Settings-window lifecycle, key-window routing and draft safety

usability — nice-to-have

Closing Settings before its hello handshake can leave the host believing the
runner is visible, so the next open targets a stale page. Cmd-T and Cmd-K can
also act on the main window while Settings is the key window, opening terminal
UI invisibly behind it. Geometry is not restored and closing discards unsaved
fields, including API keys.

Suggested fix: track runner visibility independently of hello, validate
Terminal/Assistant menu actions against the current key window, persist
clamped geometry, and warn before closing a dirty settings draft. Cover
closed-before-hello, key-window changes and focus restoration; run the native
macOS and Windows settings runners manually.

### APP-08: App data location and file permissions

general issues — nice-to-have

**IDs:** S3-18 · **Status:** Open

**Problem.** `app_services.dart:157` uses `getApplicationSupportDirectory()`,
which is Roaming AppData on Windows, so plaintext `sftp-checkouts/`,
`command_stats.json` and `identity_reads.jsonl` roam with domain profiles. On
Linux, `servers.json` and `managed_remote_files.json` are written with the
umask mode. `remote_files_controller.dart:1319-1327` shells out to `chmod`.

**Next.** Caches and checkouts under `getApplicationCacheDirectory()` (Local
AppData) with a migration shim; `chmod 700` the app-support directory on Linux
or write all stores owner-only; use the `posix` package's `chmod`.

**Gate.** A migration test moves existing checkouts; created files are 0600 on
Linux.

### APP-09: Files pane follow-ups and device validation

missing features — nice-to-have

**IDs:** Files backlog (docs/SFTP.md), STATUS 2, 11, 12, 13, UI-09 (sibling
review), Android keep-alive (#51) · **Status:** Open

Implemented, not to be re-added: SFTP, recursive transfers, durable local
edits, conflict-checked upload-back, POSIX metadata, chmod and symlinks,
sorting/filtering/bookmarks, Android export and the syntax/find/save-and-upload
editor. Remaining scope is in [docs/SFTP.md](docs/SFTP.md), not "add an SFTP
browser". Centralize destructive-close guards (APP-02) before adding shortcuts
or swipe-close.

- Widget tests for `files_pane` with picker and opener fakes (none today).
- Keyboard and accessibility pass: arrow, Enter and Delete in the list
  (`docs/SFTP.md:196`).
- Copy/move, drop onto folder rows, persisted sort/filter per server (the
  smallest slice) (`docs/SFTP.md:185-194`).
- Make case-insensitive sorting deterministic: after the folded-name compare,
  compare the exact name and then path
  (`remote_files_controller.dart:1402-1420`) so repeated refreshes cannot
  reorder case-only peers according to arbitrary server listing order.
- Resumable/queued background transfers, an optional dedicated transfer
  connection (feasible via `openAuthenticatedClient`), server-side hash where
  available, promised-file drag-out: separate proposals
  (`docs/SFTP.md:181-184`).
- IME personalized-learning suppression on editor and search fields in both
  siblings (UI-09, sibling review): the remote editor sets
  `enableSuggestions: false` but not `enableIMEPersonalizedLearning: false`
  (verified at `f5570dd`, `built_in_text_editor.dart:1112, 1294`; only the k-i
  dialog sets it). Preserve composition, undo and smart-quote settings; verify
  on Android; not a guarantee against a malicious keyboard.
- Real-device validation: OpenSSH, BBEdit/macOS, Android SAF/provider grants,
  iOS editing (iOS opener copy/share is not proof of upload-back), the macOS
  native Edit menu (STATUS 11), and the app end-to-end (STATUS 2).
- Android foreground keep-alive (#51) is implemented, not device-validated:
  measure battery and OEM behaviour, notification permission, the Android 15
  six-hour `dataSync` timeout; revisit Play `specialUse` if distributing there.

**Gate.** Never erase unsaved edits implicitly. Preserve cancellation ownership
from dartssh2 3.0.2/#59 and the VFS metadata and hash controls (#61, #62).
Concurrent save/upload, reconnect/restart, chroots, symlinks, providers without
stable paths. Repeatedly shuffle a listing containing case-only name pairs and
verify that every refresh produces the same order.
Hash-before-rename still has a remote-write race; do not call it a lock.

### UI-01: Three-stage adaptive layout and navigation

visual issues and layout problems — nice-to-have

**IDs:** SOL-039, SOL-060, SOL-062, SOL-065, SEA-015, SEA-018, UI-12
(sibling review), L-04, S4-K layout · **Status:** Partial

**Done:** window geometry persisted and clamped (#47); pane widths persisted;
1280x800 defaults; Android Back drawer-first with predictive back (#123); Files
Back climbs folders; iOS edge swipe on Files; scrollable host-key and k-i
dialogs; the Settings window (#126); keyboard and assistive pane dividers
(#134).

**Problem.** Still two-stage at the computed 960 px breakpoint
(`ui/adaptive_shell.dart:27-31`): a 959 px desktop window gets the phone home
with a FAB, and live sessions are hidden unless `_viewingTerminal` was set.
Narrow mode is a state flag, not routes (no iOS swipe-back from the terminal).
At 1000 to 1024 px the utility pane (about 280 px) plus the rail leaves the
terminal about 480 px, under 80 columns, and the utility tab label truncates to
"Snipp..." (L-04, observed live). The utility drawer is a fixed
`Drawer(width: 380)` (`terminal_pane.dart:77-78` @9322f6e). The utility tab and
active host are not persisted. No explicit pane collapse. On Android 12L and
older, Back on the server list still finishes the activity and ends sessions
(`docs/STATUS.md:547-549`).

**Next.** Wide: list, terminal, utility. Medium: list and terminal plus a
utility drawer. Phone: routes. A persisted collapse toggle for the utility
pane, auto-collapsing below about 1100 px, distinct from automatic
constraints. Clamp drawers and dialogs to 90% of the actual width. Persist the
utility tab, selection and active server where useful. Verify geometry after
monitor changes. Handle Android 12L Back (move the task to the back instead of
finishing). Keyboard splitters are done (#134); do not reimplement them.

**Gate.** 320/700/960/1440 px, 1x/2x text, IME, RTL, monitor removal, Android
predictive Back and iOS swipe, breakpoint changes; no lost session or editor
state, duplicate SSH work, keyboard disappearance, unexpected exit or focus
theft; list and utilities reachable by keyboard.

### UI-03: Chrome that grows with text scale

visual issues and layout problems — nice-to-have

**IDs:** S4-03, UI-08 (sibling review) · **Status:** Open

**Problem.** Fixed heights: tab strip 38 px (`terminal_pane.dart:355, 635`
@9322f6e), utility tabs 52 px (`sidebar_panel.dart:168, 191`). At text scale 2
the tab labels spill over terminal rows and the panel logs `RenderFlex
overflowed by 1.00 pixels` four times.

**Next.** `minHeight` constraints sized from the text scaler, or
`MediaQuery.withClampedTextScaling(maxScaleFactor: 1.6)` on chrome rows (as
native tab bars do); the same for `_PanelTabLabel`. Do not clamp the user's
scale globally. Test fixed-height utility and session tabs with the keyboard
open too.

**Gate.** Pump `TerminalTabStrip` and `SidebarPanel` at `TextScaler.linear(2.0)`:
no FlutterError; chip height at least the label paragraph height.

### UI-04: Accessible controls, touch targets and reduced motion

usability — nice-to-have

**IDs:** SOL-061, SOL-064, SEA-019, SEA-020, SEA-021, SEA-039, UI-03
(sibling review, touch), S4-17, "quiet motion" idea · **Status:** Partial

**Done:** a one-value status dot with shape and spoken description; state text
leads the second line; a hidden live header announcement; row verbs via
Shift+F10/Menu; a High-contrast preset and contrast tests (#128); the
installed-font picker (#89); keyboard dividers (#134).

**Problem.** Tab close is 28 px (`terminal_pane.dart:670-679`); the key bar's
`minWidth` is 40 (`terminal_keyboard_bar.dart:187`, about 34 dp tall); strip
buttons are 40x38 on phones; compact mobile rows are 40 dp (#129): all under 44
to 48 dp. Tab selected/connection semantics are implemented in #623, and
persistent settings-recovery notices in #627. Pane transitions at
app/seance_app/lib/ui/adaptive_shell.dart:101-131 and chat scrolling at
ui/chat_sidebar.dart:104-113 still ignore reduced-motion preferences. The
terminal screen-reader fallback is minimal.
Pane divider keyboard resizing (#134) still needs native assistive-technology
verification. Device themes, persisted terminal font/palette/zoom, mobile
cursor modes, grapheme-safe middle labels and the composed status badge exist;
what remains is interaction and semantics validation plus missing preferences
(TERM-09). The Assistant send action (`chat_sidebar.dart:234-243`), snippet
filter clear (`snippets_pane.dart:93-99`) and narrow Back action
(`terminal_pane.dart:156-158`) lack explicit tooltips or semantic labels.

**Next.** Touch-only 48 dp targets without bloating desktop. One shared
reduced-motion policy honouring `MediaQuery.disableAnimationsOf` for routes,
drawers and notices: remove spatial slides and tweens while progress, focus,
navigation and cancellation still complete. Preserve #627's bounded notices,
pause/expiry and recovery actions while adding modal/native validation
(UI-05), plus a useful terminal screen-reader fallback. Localization is a
separate app-wide task: introduce ARB localization incrementally, starting
with dialogs, errors, actions and semantic labels (#134's current semantics
are English, matching the untranslated UI). Add stable tooltips and labels to
the named icon-only actions.

**Gate.** Tap-target tests; preserve tab selected/connection semantics;
native assistive technology; colour-vision simulation; large
text; selection during output; with `disableAnimations`, progress, focus,
navigation and cancellation still complete. Remote titles cannot impersonate
trusted chrome. Widget semantics expose Send, Clear filter and Back without
inferring their glyphs; localized dialog/action fixtures load from ARB. Do not
replace the existing status palette or create another theme picker.

### UI-05: Scope notices to modal surfaces and verify native announcements

usability — nice-to-have

**IDs:** UI-04 (sibling review), S4-18, L-03 residuals.

Visible limits, coalescing, overflow history, live semantics, timer pause,
contrast and persistent recovery notices are implemented in #627. Modal
placement remains: an error notice observed in the live run covered the Add
server dialog title. Widget semantics also do not establish that each native
screen reader announces the notice and keeps its action discoverable.

Suggested fix: place dialog-owned errors inline or below the active modal
title, preserving the shell prompt and keyboard focus. Verify VoiceOver and
TalkBack announcements, persistent recovery actions, focused/hovered expiry,
one-shot actions and short/large-text viewports without duplicating the
bounded shared queue.

### UI-06: Recoverable theme editing and complete palette integration

aesthetics and theming — nice-to-have

Custom accent foregrounds can be resolved for contrast, but theme editing can
still leave extreme or failed previews hard to recover from. Git change glyphs
bypass the family hue vocabulary; editor syntax, search and badge roles follow
brightness rather than the chosen palette; the bootstrap surface is unthemed;
and cross-app theme JSON has no complete corruption/unknown-field contract.
The accent-adjustment footnote also promises raw fills too broadly: Material
controls using the adjusted primary do not all preserve the raw accent.

Suggested fix: make preview and persistence transactional with an always
legible keyboard reset; route Git through FamilyPalette; derive or validate
syntax, search and badge roles against the active surfaces; theme bootstrap;
and test copy/paste interchange with Poltergeist, unknown fields, corrupt
individual values, large fonts and every preset. Preserve device-local scope
and explicit server colours. Make the adjustment copy describe the actual
palette roles and which fills retain the chosen colour.

### UI-07: Use one legible monospace fallback stack

visual issues and layout problems — nice-to-have

Fingerprints are gated behind explicit review, but roughly twenty widgets still
use a bare fontFamily of monospace. That generic family is not reliably
resolved on macOS or iOS, weakening character distinction in fingerprints,
PEM fields, logs, status text, Git, snippets, chat, files, import and the key
bar.

Suggested fix: expose SeanceTheme.mono with the existing monoFallback stack and
replace every bare monospace declaration. Add a source scan and platform style
tests proving the fingerprint stack includes legible native fallbacks such as
Menlo and Consolas.

### UI-08: Server editor and Add-server ergonomics

usability — nice-to-have

**IDs:** S4-22, L-01, STATUS 20 · **Status:** Open

**Problem.** No `autofocus` in `ui/server_editor.dart`; Save/Test and the test
result sit at the end of the scroll view (no Save visible at 1024x700); the
phone editor is a roughly 280 px inset dialog. The label is required even when
host, user and password are filled (L-01, live). Test connection validates the
whole form, so the label validator blocks a pre-save test (STATUS 20).

Sol re-anchored the Test-only validation issue at
app/seance_app/lib/ui/server_editor.dart:335-365,853-859. A valid host, port,
username and credential should be testable before choosing a local display
label. Rough effort: two to four hours.

**Next.** Autofocus Label (new) or Host; pin the actions and result row outside
the scroll view; `Dialog.fullscreen` below 600 px; default a blank label to the
host (hint "Defaults to the host"); Test validates only connection fields.

**Gate.** Label focused on open; Save hit-testable at 1024x700 without
scrolling; saving with a blank label stores the host; Test runs with a blank
label.

### UI-09: Narrow-width and repeated-chrome polish

visual issues and layout problems — nice-to-have

At narrow widths the assistant provider dropdown overflows, the update banner
can wrap per character, utility labels and the phone title truncate, and Import
competes for title space. Terminal backgrounds no longer match the slate
chrome and resize bands lack hover feedback. Chat, Snippets, Context and Git
repeat the already selected tab name as a page heading, the density switch is
two ambiguous tiny glyphs, and the empty main area offers no clickable next
step.

Suggested fix: expand and ellipsize the provider dropdown; stack the banner and
move narrow actions into overflow; collapse utility labels to labelled
tooltips; retune terminal neutrals while preserving ANSI contrast; make resize
handles transparent until hover/drag; remove the four redundant headings while
keeping page actions; replace the density glyph pair with one labelled control;
and leave the empty state's next step to WF-02's recents and
quick connect rather than duplicating them. Verify a
200/260/320/360 capture matrix at large text.

### UI-10: Current visual captures, identity and launcher artwork

aesthetics and theming — nice-to-have

The checked-in screenshot and capture set predate the five-tab inspector,
current Files/Context/Git surfaces, themes and unified macOS chrome. There is
no full-app matrix at 320/700/960/1440 and 1x/2x, the small launcher icon is
photographic, ServerAvatar remains an undecided unused component, and the
phone FAB needs verification against long lists and scaled text.

Suggested fix: recapture deterministic native light/dark desktop and narrow
screens with a live terminal, every current inspector surface and representative
presets; add useful context-sensitive empty states; verify FAB clearance and
platform metadata; run a spacing, radii and density consistency pass; add a
quiet identity edge for session surfaces; and audit the Linux packaging
artwork and metadata; create a terminal/sigil small icon while retaining the
photographic art for onboarding; and decide whether ServerAvatar is part of the
product. Preserve user-controlled terminal palettes and explicit host colours.

### REL-03: Linux package metadata port-backs

general issues — nice-to-have

**IDs:** X-12, X-13, SOL-063 AppStream · **Status:** Open

**Problem.** The `.deb` libstdc++6 floor compares a GLIBCXX ABI tag with
package versions (`package-linux.sh:204-219`), so it never rejects.
`copyright` says "as published in the source repository" (`:330`).
`scripts/build.sh:264` ignores `package_linux` failure (exit 0 after "packages:
FAILED"). The GTK view background `#000000` flashes black on resize
(`linux/runner/my_application.cc:48`). No AppStream metainfo
(`package-linux.sh:441`).

**Next.** Copy Poltergeist's GLIBCXX-to-GCC mapping and tests;
`$APPLICATION_ID.desktop`; embed the license text; `package_linux || FAILED=1`;
a transparent GTK background (main and settings views); add metainfo.

**Gate.** `dpkg-deb -I` shows a real libstdc++ floor; `desktop-file-validate`
and `appstreamcli validate` pass; build.sh exits non-zero on packaging failure.

### REL-04: Release identity, notarization and Apple/mobile metadata

general issues — nice-to-have

macOS releases are ad-hoc signed and unnotarized, forcing Gatekeeper
workarounds and repeated keychain ACL prompts. Apple plists lack a local-network
usage description, so LAN SSH gets a generic prompt and denial lacks recovery
guidance. The APK versionCode remains 1, the iOS display name is Seance App,
cleartext transport policy is unreviewed, and the committed Android sideload
key provides continuity rather than publisher authenticity.

Suggested fix: when protected credentials are configured, sign macOS artifacts
with Developer ID, submit for notarization, staple the ticket and verify with
spctl/Gatekeeper before publishing. Add local-network usage strings and
actionable denial mapping to iOS and macOS; derive a monotonic Android
versionCode; set the visible iOS name to Séance; document/test transport policy,
reverse-proxy examples and public-distribution signing. Verify signed relaunch
preserves keychain data. Document that `localhost` on mobile means the
phone itself: a mobile user pointing a server at `localhost` reaches the
device, not a desktop.

### REL-05: Review-service latency and configuration drift

general issues — nice-to-have

**IDs:** earlier P2 entry, X-24 (retry) · **Status:** Open

**Problem.** Both siblings' `.github/workflows/zai-code-review.yml` set
`MAX_CHUNK_CHARS: 25000` (Séance: `:82`, verified at `f5570dd`) while the
adjacent comment says that size exhausted the reasoning/output budget and that
the action default should be used. #132's first assessment needed two
output-limit retries before returning useful feedback, and its sixth completed
only after three output-limit failures and smaller-chunk retries. Séance permits one 170-minute attempt; Poltergeist two,
with a retry and a backstop. These are ceilings, not evidence that every run
times out.

**Next.** Verify the pinned action's defaults; measure small and large patches
with candidate chunk sizes; reconcile the comments; choose an explicit
wall-clock and retry budget from coverage, latency and failure data;
coordinate with Poltergeist's current-PR scope fix so inherited main changes do
not inflate the workload. Do not change the workflow during an active
assessment to manufacture approval.

**Gate.** Coverage, elapsed time, retries and output-limit failures recorded;
timeout and partial-review notices distinguishable from clean reviews;
superseded heads cancelled and no stale result approves a new head.

### REL-06: Small Séance code port-backs

bugs — nice-to-have

**IDs:** X-16 · **Status:** Open

**Problem.** `lib/services/badge_image.dart:251` catches only `Exception` in
the encode phase; `toImage`/`toByteData` can fail with an `Error`, which
crashes the import instead of showing "couldn't encode". Poltergeist fixed
this (`catch (_)`, `cee70be`).

**Next.** Port the catch; ask Poltergeist to update its PORTS "verbatim" entry.

**Gate.** A fake encoder throwing an `Error` returns the failure result.

### DOC-01: Agent-facing docs that mislead

general issues — nice-to-have

**IDs:** SEA-030, X-20, X-21, S5 stale items, astra outdated statements ·
**Status:** Open

Fix each; generate counts in CI or drop them.
- `docs/POLTERGEIST.md:348-350` and its closing bullet say Poltergeist reads
  `serverConfig` read-only and writes only `bookmark:`/`hostkey:` records.
  Since 2026-09-24 it writes `serverConfig` and opted-in `secret:` records.
  Rewrite the section, state the `secret:` publication rules, and add a
  field-preservation invariant (XAPP-01). Its table still lists PR-S4 (agent +
  ProxyJump) as an ask; #131 delivered it.
- AGENTS.md `:114` and `:317` test counts (746/700/245) are stale (baseline
  above: 778 package tests, 1,083 app tests); STATUS points readers at them.
- `CHANGELOG.md` has only "Unreleased" although v0.9.2 shipped; items merged
  before the bump sit under Unreleased.
- `docs/STATUS.md`: items 3 (redaction toggle) and 5 (UTF-8 across packets) are
  implemented (`chat_sidebar.dart`; `xterm_engine.dart:146-148` chunked
  decoder): delete them. The #54 housekeeping text is half stale: servers and
  snippets write tombstones since #84; full per-round pulls are fixed in #636. The
  "Should do next" numbering starts at 2.
- Code comments cite wrong STATUS numbers: `server_editor.dart:60, 109` say 17
  (actual 18/19), `app_services.dart:635` says 16 (actual 17). Renumber or fix.
- `packages/seance_sync_server/README.md:95` says every request carries a
  `protocolVersion`; GET `/v1/sync`, prelogin and DELETE do not.
- `PROPOSAL.md:86, 190` describe a scratch image; the Dockerfile uses
  `debian:stable-slim`.
- `astra.md`: "Window sizing belongs to PR #47" and "#49 ... rebase/review it"
  are outdated (both merged); the PR #44 local-shell note no longer describes
  the implementation now in main.
- The archive's relative links were written for the repository root; current
  targets: [astra.md](astra.md), [July archive](docs/reviews/analysis-2026-07-25.md),
  [PROPOSAL.md](PROPOSAL.md), [status](docs/STATUS.md), [SFTP](docs/SFTP.md).

**Gate.** A reviewer reading only AGENTS, STATUS and POLTERGEIST reaches
correct conclusions about X-02/X-03 and current counts.

Sol confirmed the redaction/UTF-8 drift at docs/STATUS.md:2034-2036,2047-2049.
Reconcile each advertised defect with current tests and link completed work;
rough effort for that focused cleanup is one hour.

### XAPP-04: Shared files, packaging and platform parity

general issues — nice-to-have

**IDs:** X-08, X-09, X-10, X-11, X-26, BOTH-REV-011,
BOTH-REV-012, shared-file guard idea · **Status:** Open

The Séance halves are tracked in REL-02, STORE-02, CRED-04 and REL-01. Keep
`family_hues.dart`, `sidebar_kit.dart`, the theme
palette/presets/contrast files and the settings-window runners in step (a
manifest plus a CI hash check is an idea below; `SelectedTabView` moved into
`ghost_ui` on 2026-10-04 and needs no check). Pin both siblings to the same
Flutter version so Poltergeist's reliance on Séance's macOS accessibility gate
holds. BOTH-REV-012: keep an authoritative port ledger. Shared package fixes
belong upstream; copied UI and storage files need behavioural parity checks and
dated divergence entries (the two atomic-file helpers have already diverged in
serialization and fallback behaviour); test cross-repo security contracts
rather than keeping only a historical copy timestamp. BOTH-REV-011 (theme
interchange) is in UI-06. Poltergeist-only items from the X slice (X-01, X-02, X-05 on its side,
X-15, X-17) live in its ANALYSIS.md.

### Bound served Python producer input reads

general issues — nice-to-have

The generated producer client in
`packages/seance_sync_server/lib/src/inbox_docs.dart:337-347,419-432` reads
reason files, scripts and stdin completely before enforcing the 64/96 KiB
limits. A large file can exhaust memory and an endless pipe can hang
automation.

Stream at most the applicable limit plus one byte and reject an oversized
source immediately. Rough effort: two to four hours.

### Resolve or refuse a missing local-shell home

general issues — nice-to-have

`packages/seance_core/lib/src/terminal/local_shell.dart:143-153` leaves the
working directory unspecified when `HOME` or `USERPROFILE` is absent, so the
shell can start in a launcher or app-bundle directory on managed desktops.

Resolve the platform account's home through a host service, or refuse startup
with an actionable message when no safe home is available. Rough effort: two
to four hours.

### Scan Context incrementally and only while useful

performance problems, stuttering, and jank — nice-to-have

app/seance_app/lib/app_state.dart:246-255 starts Context detection for every
open terminal. terminal_context.dart:729-754,805-866 rebuilds and regex-scans up
to the last 300 rows every 300 ms on the UI isolate, even when Context is never
opened. This spends frame time and battery during high-volume logs, while
faster output can disappear before inspection and lose actionable paths/links.

Suggested fix: activate scanning while Context is visible or after first use,
consume completed logical lines incrementally into a bounded queue, and track
generations/ranges rather than rescanning the tail. Profile before moving work
to an isolate. Keep detection passive. Rough effort: one to two days.

### Keep a local command trail and pinned Context working set

novel, delightful, or quirky ideas worth trying — nice-to-have

Context items from app/seance_app/lib/services/terminal_context.dart:747-765
and ui/context_pane.dart:110-168 disappear as output advances. Existing OSC 133
events already expose command completion, cwd and exit status, but the panel
does not connect those events to discovered paths and links.

Suggested fix: render bounded, collapsible local command cards containing
command, cwd, exit status and detected evidence; let users pin useful items
into a session working set or explicitly include a card in assistant context.
Reuse the TERM-07 command-block model. Do not execute detected content or
persist raw terminal output by default. Rough effort: two to four days.

### Export a sanitized session postcard

novel, delightful, or quirky ideas worth trying — nice-to-have

Diagnostics, host-key details, command status and selected terminal output are
available separately. Users helping a teammate must assemble them manually and
can accidentally include secrets.

Suggested fix: build a preview-first local Postcard that redacts host, user,
path and token patterns, lets the user inspect and edit the exact material,
and exports a compact Markdown or image summary only after confirmation.
Explain that redaction is best-effort and export no credential material.
Reuse the transcript and flight-recorder evidence models. Rough effort: two
to three days.

### Show an informative connection séance pulse

novel, delightful, or quirky ideas worth trying — nice-to-have

Connection status is centralized around
app/seance_app/lib/ui/terminal_pane.dart:646-713, but a generic spinner does
not explain which connection phase is waiting.

Suggested fix: map real DNS, transport and authentication diagnostics to an
optional restrained three-beat indicator, with accessible stage text and a
static reduced-motion equivalent. Add no delay or invented progress. Keep
the separate presence/RTT idea based on actual measurements. Rough effort:
one day.

## Ideas

Each is local and explicit by default, reduced-motion aware and subordinate to
shell predictability. Ideas with a backlog entry point there. These
consolidate earlier ideas without removing their useful variants.

| Idea / IDs | First useful slice and acceptance |
|---|---|
| Fingerprint spirit sigils / SEA-033, randomart and SSHFP | Deterministic randomart and an optional host hue on rows, tabs and TOFU; the same key gives the same identity across devices and a changed key visibly changes it; optional SSHFP check. Never replaces fingerprint verification or overrides explicit labels. |
| Safe Draft Dock / SOL-047 | See TERM-07. Local, editable, target-labelled staging with source and danger cues; only an explicit action sends to the PTY, never Enter. Test nonempty prompts and stale sessions. |
| Planchette | See WF-01. One fast action palette with a restrained selection motif; no theatrical delay or focus ambiguity. |
| Production wards and tint | A synced production/staging/lab tag with symbol and colour; a 3 to 4% server-hue wash on prod terminals; extra confirmation for reviewed destructive/sudo actions and multi-line pastes. No promise of intercepting every command. |
| OSC 133 command cards / SEA-028 | See TERM-07 and the local command trail/pinned Context working set: Copy, Explain, Snippet, reviewed Rerun, Compare, Include in chat, from real boundaries. |
| Last words | See TERM-08. Preserve final output, duration, cwd and disconnect reason with copy/save/reconnect; never hide diagnostic scrollback behind a blank placeholder. |
| Completion notices / SEA-031 | For background completed commands, an optional tab badge or OS notice with exit and duration; correct session attribution; command text hidden by default. |
| Ghost tabs / SEA-032 | A short-lived Undo close restoring host and label with reviewed cwd staging; not remote process restoration; never bypasses managed-edit guards (after APP-02). |
| Whisper mode / SEA-034 | See AI-05. Auto-arm only from a trustworthy signal. |
| Séance transcript / SEA-035 | See the sanitized session postcard finding: preserve command/output blocks, timestamps, host and duration in the preview, with file, clipboard or snippet destinations and best-effort redaction. |
| Presence pulse / SEA-036 | A real keepalive RTT tooltip, sparkline or quiet pulse (expose RTT from core first); no invented measurement; never animate terminal text; reduced motion. |
| Custom/two-hand mobile decks / SEA-037 | Per-host saved keys, modifiers left and navigation right, punctuation drawer, repeat/haptics, clipboard actions; keep application cursor modes and 48 dp targets. |
| Context ledger / SOL-044 | See AI-02. An expandable exact outbound receipt for every assistant request, including history, search and redaction; no hidden resend. |
| Idle divination / SEA-038 | Per-host opt-in cheap uptime/disk/reboot facts over `SshSession.runCommand`, outside the PTY; no autonomous assistant execution or undisclosed periodic commands. |
| Reading anchor / "Jump to live" pill / AST-011 | An unread-output counter ("37 new lines") and Jump to live while scrolled up or selecting, using `RenderTerminal.stickToBottom`; stable absolute anchors and bounded counts after trims; no selection theft or unsolicited snap-to-bottom; test alternate screens. |
| Connection flight recorder / AST-012 | Bounded opt-in phase timings (DNS/TCP/handshake/auth/shell vs parse/layout) in `SshConnectionLog`; a redacted export preview; no commands, keys or raw traces by default. |
| Portable workspace recipe / AST-013 | Save hosts, tab labels, pane layout and intended cwd; preview targets, then explicitly reconnect; stage a quoted cd only at a verified empty prompt; never silently replay commands or login scripts. |
| Quiet connection rehearsal / AST-014 | Test connection exists (#74); add an optional, cancellable staged DNS/port/key-readability check before saving that explains the next trust/auth step, with real cancellation (SSH-01) and field-only validation (UI-08). No password guessing, background remote commands or silent pinning. |
| Files breadcrumb return trail | Surface the existing endpoint-scoped folder history, distinct from host favourites; test chroot and disconnected identity, keyboard access and exact return paths; never an implicit shell `cd`. |
| Quiet motion | See UI-04's reduced-motion policy (routes, drawers, notices; no spatial slides or tweens under `disableAnimations`). |
| Search with scrollbar ticks | Add match ticks to the terminal overview strip after the in-review search implementation, with stable anchors through trim. |
| Tab switcher ("séance table") | Reuse the tab-overflow control as a Ctrl-Tab popup with live dot, cwd, running command and type-to-filter. |
| Tab drag-reorder, move to new window | Reorder within a server's strip first, persisted in tab order. |
| Draft ectoplasm | See APP-01 (mobile draft autosave). |
| Recovered edits drawer | See APP-04. |
| Account sigil | Four words from a 256-word list derived from `syncKeyCheck` (CRED-02) in Settings > Sync, so two devices can be compared at a glance. |
| Polite probing | See SSH-08. |
| Linux terminal conventions | Opt-in copy on select and middle-click paste of the last in-app selection (Flutter lacks PRIMARY). |
| Glyph-run painting | Benchmark `paintLine` at 200x60, then batch same-style cell runs into one paragraph behind a flag, with golden comparisons (PERF-01). |
| "Who changed this?" sync receipts | A sealed `device:<id>` name record; an "edited on MacBook, 3 min ago" tooltip; feeds WF-03's device list. |
| Echo-free cursor advance | When the accepted seqs are exactly `previousLatest+1..latestSeq`, advance the cursor without re-downloading own pushes (after SYNC-03 slice 1); test the non-contiguous case. |
| Rollback tripwire | Remember the highest `latestSeq` and a rolling hash of pulled tuples; warn "server state went backwards" (first slice: SYNC-05's check, logged). |
| Non-enumerating prelogin | A deterministic fake salt `HMAC(serverSecret, username)` and default params for unknown users; test that known and unknown users are indistinguishable by status and shape. |
| Account doctor endpoint | `GET /v1/account/stats` (records, bytes, largest record, tombstones) plus a Settings line; helps SYNC-04 and S1-10 victims. |
| Second-launch hand-off | After STORE-02, a second process asks the first to focus via a loopback port recorded in the lock file. |
| Handoff URLs (both apps) | `poltergeist://open?server=<id>&path=` from Séance's cwd and `seance://connect?server=<id>&cd=`; register on macOS and Linux for one verb; an `sftp://` clipboard fallback. |
| Drag from Poltergeist onto a Séance terminal | Accept `text/uri-list` `sftp://` drops and paste the shell-quoted path when host and user match the session. |
| One theme for the family | "Use Séance's theme" in Poltergeist; later an opt-in synced `appearance` record (device-local by default). |
| Downstream canary | A Séance CI job building Poltergeist core against the PR's `seance_core` (analyze-only, non-blocking first); would have caught X-25. |
| Shared-file guard | A manifest of byte-identical files with normalization rules and a CI hash check against the sibling's recorded revision. |
| Session tray (both apps) | A local socket announcing `{serverConfigId, state}`: Séance shows Poltergeist's transfer count, Poltergeist shows an open-shell dot. No secrets shared. |
| Poltergeist-side ideas using Séance code | Port Séance's Android `KeepAliveService` to Poltergeist transfers; server-side operations over `runCommand` (reflink copy, `sha256sum`, git chip). Tracked in Poltergeist's ANALYSIS.md. |

Later, separate proposals: terminal splits, tmux/Mosh persistence,
provider-native web search (STATUS 7), sync OIDC and libghostty (proposal M10).
Historical proposals and their ownership links remain in the archive; verify
current code before planning them.

---

## Completion ledger

One line per completed backlog item; details are in the PRs and the archive.
Residuals live in the entries named.

| PR | Item(s) | Residuals now tracked in |
|---|---|---|
| [#132](https://github.com/L-K-M/Seance/pull/132) (sibling reviewer, head `8bfd0eb`) | SEA26-SEC-01: redaction masks complete quoted JSON/YAML values and static shell assignment words, including escaped and truncated inputs, adjacent fields, common `secret_key` spellings and AWS secret-access-key fields; actual provider-body coverage. General redaction remains best-effort. | AI-02 (YAML tags/block scalars, dynamic shell, `==`/`:=`, colon-prefixed scalars, S2-11 forms) |
| [#133](https://github.com/L-K-M/Seance/pull/133) (sibling reviewer, head `659e034`) | SEA26-SEC-06 / SOL-051 slice: atomic SQLite account deletion with rollback under injected failures | SRV-02 (schema migrations, contention, durability and WAL-safe backup/restore) |
| [#134](https://github.com/L-K-M/Seance/pull/134) (sibling reviewer, head `1322090`) | UI-02 (sibling review) / SOL-061 slice: focusable, labelled pane dividers with arrow and assistive adjustment, visible focus, clamped values, RTL geometry; modified arrows pass through | UI-01, UI-04 (native AT QA, localization) |
| [#135](https://github.com/L-K-M/Seance/pull/135) | New devices and Reset start in the Terminal theme (`10b49f8`, `06204c8`); partial and extension-less host themes keep the Séance fallback | UI-06, UI-10 (captures predate the change) |
| [#136](https://github.com/L-K-M/Seance/pull/136) | S1-01 auth-route body cap and `BytesBuilder`; S1-06 username validation including invisible characters, before the limiter; S1-15 typed 400; S1-11 server-side salt/verifier shape | SRV-01 (non-enumerating prelogin, shared limiter, chunked 413/body deadlines), PROTO-02 (client salt check, case/Unicode policy), PROTO-01 (remaining wire parsing) |
| [#137](https://github.com/L-K-M/Seance/pull/137) | S2-01 fish-safe `quoteShellWord` for the git probe and staged cd; OSC 7 control-character guard | SSH-09 (`sh -s`, fsmonitor, porcelain `-z`) |
| [#138](https://github.com/L-K-M/Seance/pull/138) | S2-02 refuse replace over symlink/FIFO/device/folder; permission-bit mask; part of S2-09 (owner-only staging when the final mode withholds read or write) | SSH-10 |
| [#139](https://github.com/L-K-M/Seance/pull/139) | S4-04 persisted "Include terminal output" opt-out, shared by the chat drawer and the command generator (also closes the sibling review's drawer `_includeContext` reset) | SYNC-07 (sync it?) |
| [#140](https://github.com/L-K-M/Seance/pull/140) | S1-04: a record the server refuses as too large no longer stops pulled records from being applied; the sync status names it | SYNC-04 (save-time size guard and persisted refusal state) |
| [#141](https://github.com/L-K-M/Seance/pull/141) | S3-01 managed checkouts preserved across index loss; S3-03 startup survives unreadable checkouts | APP-04, STORE-01 |
| [#142](https://github.com/L-K-M/Seance/pull/142) | S4-07 new tab uses the current saved config | None |
| [#145](https://github.com/L-K-M/Seance/pull/145) (imported merge `5339c3d51`) | TERM-06 navigation: guarded close, select 1 to 9, next/previous tab shortcuts | TERM-06 (platform new-tab binding), APP-02 (service close policy) |
| [#146](https://github.com/L-K-M/Seance/pull/146) (imported merge `a3db541e1`) | TERM-05: terminal scrollback search | Search-overview ticks remain an idea |

Earlier landed work that closed or reshaped backlog items (verified by the S5
audit at `dd7e105`; details in the archive and STATUS):

| PR(s) | Item |
|---|---|
| #64 to #71 | Earlier consolidation ledger: KDF ceilings (AST-001), auth field privacy, footer layout, status contrast, client release tests, HTTP cleanup, capture filtering, transactional push/pull (#71) |
| #47, #49 | Window-state persistence; 64 KiB unfinished-sequence cap (part of AST-009) |
| #58, #59, #61, #62 | Unknown-kind preservation; SFTP cancellation (dartssh2 3.0.2); VFS metadata and hash controls |
| #72, #73, #74 | Exclude from sync; duplicate server and the `_mutate` queue; Test connection and referenced-key passphrase |
| #84 | Server and snippet delete tombstones (#54 for those kinds) |
| #90, #92 | Push batching to server limits; advertised blob cap |
| #91 | Current-state bugfixes including the per-path write queue, turn-only chat context, snippet id checks |
| #95, #98, #99, #100, `6f3d7f3` | Serialized vault ops, credential versioning, healing an unreadable credential, crash-safe re-key journal |
| #103 | OSC 8 hyperlinks (keyboard discovery and mobile gestures remain: TERM-09) |
| #123 to #131 | Sidebar kit, Android Back, densities, Settings window, family colours, themes, mobile rows, agent and ProxyJump (#131) |
| Various (sibling review's completed-scope list) | KDF ceilings, auth field privacy, footer layout, default status contrast, client release tests, HTTP cleanup, recognizable-secret capture filtering, transactional record push/pull, unknown-kind preservation, SFTP/editor features, terminal selection, current vault re-key journal, deletion intents, independent secret timestamps, app mutation queue, agent/jump transport, device themes, narrow Back handling. Completed changes are not instructions to implement again; residuals above stay independent of them. |
| #80, #81 | SOL-036 macOS key-file access: audit log hardening (native validation only) |

---

## Invariants and release gates

Preserve: shared protocol code; domain-separated Argon2id/HKDF and XChaCha
AEAD; strict changed-host-key blocking; explicit review-before-run; default-on
redaction (best-effort, never a secrecy guarantee); terminal scrollback and
search content treated as untrusted; no assistant execution or file tools;
stable terminal identities and selection; top notices that never cover the
shell prompt; every model round-trips unknown keys (once XAPP-01 lands). The
always-available assistant is deliberate, not a missing toggle. JSON stores and
pure-Dart crypto are intentional, swappable v1 choices.

Before sync and credential handling are called production-ready:

| Gate | Status at `9322f6e` | Entries |
|---|---|---|
| Restart-level two-device typed deletion and exact ack/apply races | Partial: server/snippet deletion convergence tests exist; hostKey/secret deletes and persistent exact settlement remain | SYNC-03 |
| Opaque-ID, key-epoch, interrupted migration and rollback fixtures | Open | SYNC-01 |
| Real HTTP-over-SQLite concurrent snapshot/upsert and crash tests | Partial: #71 concurrency tests; no cross-process kill or crash tests | SRV-02 |
| Independent crypto vectors, device KDF profiling, external protocol review | Open | PROTO-02 |
| Real sshd auth/changed-key/resize/output/strict-KEX matrix | Partial: a real Unix-socket agent test; one manual local sshd check; no CI matrix | SSH-01, SSH-07, TRUST-01 |
| Signed Apple keystore relaunch and migration; Android upgrade and backup | Open | CRED-04, REL-04 |
| Adaptive golden/semantics tests plus native keyboard/clipboard/IME | Partial: server-list captures, narrow Back tests, Xvfb drives; no devices | UI-01, UI-04, TERM-10 |
| Running-container readiness/persistence/backup/restart/SIGTERM smoke tests | Open: CI builds the image only | SRV-03, REL-01 |
| Account-epoch rollback detection and enrolment key check | Open | SYNC-05, CRED-02, CRED-03 |

The original gate audit was at `9322f6e`. The rows above have been narrowed to
the residual work after later main changes and the open 2026-11-04 review PRs;
they do not claim those open PRs are merged.

---

## Appendix: review records for #132 to #134

Carried over from the sibling reviewer's ANALYSIS.md so that no review decision
is lost. All three PRs have merged since (`8bf33b8`, `3ee800f`, `c185049`); at
publication they were open on separate branches from the reviewed main. The
check/review snapshot below does not certify later commits or native behaviour.
Deferred suggestions recorded here are not backlog entries unless an entry
above names them.

| PR | Final reviewed head | Remote checks and review |
|---|---|---|
| #132 | `8bfd0eb` | Eight build/test checks passed, including all five client builds, package/app tests and Docker; both final full-review checks passed. Six assessments completed; the final two were full reviews of this same revision with no agreed important finding in the implemented forms. One superseded hybrid refresh was cancelled and is excluded. |
| #133 | `659e034` | All nine checks passed, including five client builds, package/app tests, Docker and review. Two completed distinct-revision assessments, no agreed important findings. |
| #134 | `1322090` | All nine checks passed, including five client builds, package/app tests, Docker and review. Two completed full assessments on distinct revisions, no agreed important findings. |

| PR | Branch | Local evidence |
|---|---|---|
| #132 | `codex/redact-quoted-secrets` | Seven initial failures reproduced quoted-value leaks. Later fail-first regressions cover punctuation boundaries, custom-filter ordering, `secret_key` and AWS secret-access-key labels, adjacent assignments and complete static shell words; 551 core tests and analysis pass on `8bfd0eb`. Unit tests and actual OpenAI/Anthropic request bodies reproduced the AWS, overlap and shell-word leaks before repair. Redaction still cannot promise arbitrary secret detection. |
| #133 | `codex/atomic-account-deletion` | Four failures reproduced partial deletion. All 72 server tests and analysis pass, including API-level 500/rollback, contention and full unaffected-account assertions. Cross-process crash and power-loss tests remain separate. |
| #134 | `codex/accessible-pane-resizing` | Six accessibility/RTL regressions failed before repair, followed by rapid opposite-arrow and modified-arrow regressions. All 34 focused resize/narrow-Back tests and full Flutter analysis pass on `1322090`. Native assistive technology remains unverified. |

Review decisions to retain: #133's optional unknown-account store no-op test
was deferred; deleted-token retry already returns 401 at the HTTP boundary and
contention tests verify no partial commit. A repeated suggestion for an explicit
autocommit assertion after HTTP 500 was also deferred: the tested subsequent
successful DELETE must begin a fresh transaction and would fail if one remained
open. Two completed assessments on distinct revisions found no agreed important
issues. This does not close the separately listed delayed-login/account-deletion
race.

#134's first assessment prompted the modifier-arrow guard so Alt/Ctrl/Meta
shortcuts pass through a focused divider. Optional settings-write coalescing
needs measurement first: writes are atomic and serialized, width bounds limit
repeats, and `setPaneWidths` does not notify the whole app. English semantics
match the current untranslated UI; localization is a separate app-wide task.
Speculative layout-invariant and disabled-adjustment-value polish was deferred.
The second full assessment at `1322090` found only optional polish, completing
two distinct-revision assessments without agreed important findings. Repeated
bound-announcement/write-coalescing suggestions, Shift-arrow behavior and SDK
drift notes were deferred; the existing semantics APIs had already compiled on
the CI-pinned SDK, and latest-head CI is recorded separately.

#132's first completed assessment succeeded after two output-limit retries; it
did not time out. Its verified `SECRET_KEY` bypass prompted a narrow fix and
reset the clean-review count. A purported blocker referred to a deliberately
synthetic test fixture and was rejected with test evidence. Short unquoted
values remain masked deliberately: benign short configuration values can be
false positives, but reinstating the old length floor would expose short
passwords. The filter remains best-effort rather than a guarantee of secrecy.
The second assessment exposed standard `AWS_SECRET_ACCESS_KEY` fields. A
unit test and both provider-body tests confirmed the leak before its fix; this
also reset the clean-review count. The claimed `client_secret_key` bypass was
refuted and its already-working masking is now explicitly tested. A queued
same-head reassessment was cancelled before the genuine AWS fix and does not
count as a completed assessment.

The third assessment at `1822c40` had no important findings. Its subsequent full
reassessment exposed an overlapping-label bypass: an earlier unquoted value
could consume the next label and leave its secret visible. This reset the clean
count again. Local independent checks also found static shell-word fragments;
`8bfd0eb` repairs both, including the equality-at-quote boundary, newline and
three-field chains, ANSI-C/localized quotes, concatenated fragments and escaped
spaces. The reviewer's proposed `<=` cursor guard was too broad; a verified
quoted-value regression requires `<` instead. Ambiguous single-quote backslash
handling remains conservative to avoid leaking valid Python-style strings.
YAML tags/block scalars and dynamic shell expressions remain explicit grammar
residuals above. The repeated synthetic-fixture blocker and claimed absence of
tests were rejected using the fixture content and actual provider tests.

The fifth completed assessment, a full review at `8bfd0eb`, found no agreed
important defect in the implemented forms. Its comparison/Go-operator and
colon-prefixed plain-scalar suggestions are acknowledged as concrete grammar
gaps above, rather than denied or treated as universal redaction approval.
An ad hoc operator exclusion is unsafe: `password==secret` can itself be a
valid shell assignment whose value begins with `=`. These expansions need
format context and their own tests. The superseded hybrid refresh had included
inherited main changes; it was cancelled and replaced with a full-current-PR
assessment, not counted as a completed round. The shared reviewer-scope task
is recorded in Poltergeist's ANALYSIS.md.

The sixth assessment completed successfully at `8bfd0eb` after three output-limit
failures and smaller-chunk retries; it did not time out. Its proposed
`RangeError` is prevented by the existing guard: an emitted value starts at or
after `match.end`, and that end cannot precede `copiedThrough`. Its generic
`env`/`FOO` examples are not recognized secret labels. The escaped-space claim
overlooks the later `=` branch's `_shellWordEnd` result; the whitespace claim
overlooks the assignment regex's trailing whitespace consumption. Built-in
masking and scanner/provider tests are present. These claims and the repeated
synthetic-fixture warning were rejected with source/test evidence; seven direct
probes of cited inputs and equivalent recognized labels passed. The stated
YAML/dynamic-shell gaps remain tracked work, not a secrecy guarantee.

Optional mock-client teardown, request-count diagnostics, label-list linking,
phase-order documentation, assertion wording and tighter benchmark timing were
deferred. Reinstating a value-length floor or guessing that ordinary-looking
words are public would expose valid short/word-based secrets. The final two
full assessments establish the requested feedback steady state on one revision;
they are not two distinct-revision rounds under the repository's default metric.
The PR has since merged (see the completion ledger).
