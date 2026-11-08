# Reviewed branch retirement (2026-11-08)

This retires the 20 alternative task branches left after #653 and the two
local CI merge-preview refs. The content review used main
`307e9463ab0be53ff941cd6b4d135f82304f67af`, merge-base diffs, current
implementations and regression tests, not ancestry alone.

Useful failure-path and security tests are retained as separate changes:

- Authentication settings, trusted-proxy parsing and login retry headers.
- HTTP account-generation races during login, pull and account deletion.
- A validly sealed, wrong-kind tombstone must trip the catalog guard without
  deleting its server.
- Safe custom accents and a different already-visible active terminal tab.
- Failed credential-config writes must preserve the committed reference.
  That regression exposed a real `FileConfigStore` bug: rejected changes
  remained in its cache and could ride a later successful save. Config
  operations now serialize and publish a candidate only after its durable
  write succeeds. Failed deletion and queued-read cases are also covered.

The remaining implementations are already present, superseded by stronger
current code, or deliberately rejected below. History-only merge parents
retain every exact tip without adopting the old trees. Each preservation
merge was checked for an identical before/after tree. Thus retiring a branch
name loses neither its historical commits nor the useful rescued changes.
Ancestry does not mean that an alternative implementation ships.

## Decisions

| Branch | Exact reviewed tip | Content decision |
| --- | --- | --- |
| `ci/sudo-free-packages` | `ddda6d0de6523dc26c35809abc5c2736cd228005` | Reject the abandoned self-hosted Flatpak route. #454 uses hosted VMs without lifting container confinement. Its sudo-free installer and alternative smoke sandbox are not needed by the supported pipeline. |
| `codex/merge-sessions` | `c64a38a35e0360095008172ade3c36684ff3062a` | Already ported in #651: device-scoped sessions, selective revocation, expiry, digest storage, rotation and all app composition roots. Client/server session regression files are identical. |
| `klab/f1b` | `01408474d948bdd81a483a6aa9d52bae007ec82a` | Superseded by the reviewed shared localization scanner and its stricter unreadable-file, normalized-path and empty-scan checks. The unused app analyzer pin is already removed. |
| `klab/seance-search-test-budget` | `c91ec67589f221b05e89949c61168e897e0567d8` | Superseded by #391: both search-session constructors receive a whole-buffer test budget, including the disposal case this branch missed. |
| `probe/queue-max` | `3d3d062f843dbc3aaa568b251fdba4f05f767d9f` | Discard the sleep-only CI concurrency experiment as product code. Do not enable its workflow. |
| `sol/account-crypto-state` | `cfd41ea713913af9e844bef46fd5c8bf21070f47` | Already incorporated: independent vault-key checks, account generations and bounded bearer sessions. Current legacy-account and readiness tests are stronger. |
| `sol/authenticated-record-envelope` | `e5f45ef490e71ef08d17d4c290be12623267b2a0` | Already incorporated, then strengthened with purpose-bound envelopes, authenticated metadata and migration-only legacy decoding. |
| `sol/bounded-auth-rate-limits` | `deb1d879924b777aa0f60389ffcad5fc790f1eb3` | Current bounded overflow buckets and source/global admission retain the behavior. Rescue the missing settings, proxy parsing and retry-header tests. |
| `sol/bounded-sync-pagination` | `12a7d5564cacd93129ed0ad309a8a45e067acb3d` | Current protocol-4 stable-watermark pages, quotas and per-page checkpoints supersede this stack. Retain stricter rejection of overflowing legacy listings. |
| `sol/durable-sync-mirror` | `21bbd933fc59a8a69ecaa199de49894f17d25e39` | Account-scoped durable mirrors, cursor recovery and envelope floors are already incorporated and extended. |
| `sol/envelope-cutover` | `3d90f57e7552b0df328546f16cceb926e15027da` | Authenticated-envelope cutover and current-protocol pulls are already incorporated. Retain the later server-driven floor-CAS migration. |
| `sol/nonblocking-sync-queue` | `d76e94a5297f3f2818a7383a3decbcc61197b579` | Already incorporated: staged local phases and network work outside mutation queues, with slow-network regression coverage. |
| `sol2-atomic-registration` | `756fb074b5a43d82b02b63a95f0df0a3b8fbc520` | Current registration is atomic and principals bind both account generation and token digest. Rescue gated HTTP login/pull/deletion race tests. |
| `sol2-inbox-pagination-quota` | `fb2a31a8ace1582e24c9bb5d8a6a59882743fbea` | Account-wide count/byte quotas and streamed stable pages are already present. Do not restore the older wire shape or four-page truncation. |
| `sol2-record-store-transactions` | `ab5a225cf79e2fb3cc5db5e182d05bcd8fd63ca4` | Current candidate-state transactions and failure-injection tests retain the work and also cover recovery/envelope-floor state. |
| `sol3/accent-contrast` | `e8caa4b6eb93aa1d2a71d87edf79c2e392d723e0` | Current per-region contrast and explicit adjustment action supersede the implementation. Rescue the safe non-seed custom-accent test. |
| `sol3/bounded-rate-limits` | `0544ee404f38bc61e9250b73fdb51cbc0e97c577` | Proxy normalization and session controls are incorporated. Retain overflow sharing instead of active-key eviction, and invalidation instead of migrating plaintext sessions. |
| `sol3/explicit-credentials` | `ce54494761668e3e23d30ab9ae2a556303a1c485` | Current explicit credential/passphrase actions, identity-path binding and reference-aware retirement are stronger. Rescue failed-save coverage and fix the exposed config-cache leak. |
| `sol3/sync-envelope-v2` | `da14720537012ba415d529de05a7760e7ec67cf3` | Retain current purpose binding, fail-closed migration and staged mutation APIs. Rescue the positive wrong-kind tombstone tripwire test; do not substitute the alternative retry/error policies. |
| `sol3/tab-overflow` | `6434d8c2791ae5a505bdd432e0c63789cef7fd09` | Current strip also handles RTL, reduced motion, wheel fallthrough and checked menus. Rescue the different-already-visible-tab no-scroll regression. |
| `refs/remotes/ci/pr-merge` | `21d37cb74c3c7991705db0a1af7c187a30b1fb1f` | Synthetic preview only: both parents are already on main and recomputing their automatic merge reproduces its exact tree. |
| `refs/remotes/pr-598-merge` | `15131dd7e646bee2d9f46d5c1b5682cc48b0cac1` | Synthetic preview only: both parents are already on main and recomputing their automatic merge reproduces its exact tree. |

## Deliberate differences

`sol3/sync-envelope-v2` also proposes bounded multi-record push bisection,
quota retries and an immediate snapshot retry. Those are not equivalent to
current behavior: `sync_test.dart` explicitly requires a whole-batch refusal
to end the run, and the current engine re-reads local versions between
requests. Do not replace that contract with the alternative's static retry
batches as part of branch retirement. Likewise, do not restore legacy
winners after an envelope-floor downgrade: current migration fails closed.
The historical implementation remains reachable for a separately designed
change if those policies are reconsidered.

The current inbox processes and checkpoints one bounded page at a time,
stops at an unresolved page, and enforces account-wide count/byte caps. The
old four-page refresh ceiling is not a missing storage bound.

## Boundaries

Only delete a reviewed branch name after these history parents and rescued
changes reach main, and only if its remote tip still equals the reviewed
hash. New active work, including `klab/followups-3` and
`fix/file-list-keyboard`, is outside this retirement. Preserve the original
import-history refs, archived tag metadata, release tags, application
identities, wire formats and user data. No release or image publication is
part of this change.
