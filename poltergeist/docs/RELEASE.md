# Release runbook

How a Hauntware suite release ships: one `vX.Y.Z` tag builds and publishes
Planchette, Séance (apps, sync-server binaries and image) and Poltergeist
together. Releases publish straight from CI with **no human step**
(00 D23, decision change 2026-09-03): no signatures, no
maintainer key. The checksums are an integrity channel — they catch
corrupted downloads, not a compromised pipeline.

## 1. Cut the tag

From the repository root (`poltergeist/scripts/release.sh` forwards there):

    scripts/release.sh X.Y.Z --push

The version grammar is stable `X.Y.Z` only; the tag is a plain annotated
tag. Pushing it triggers [`release.yml`](../../.github/workflows/release.yml):
the release-existence guard, the test gate, every product's client builds,
the sync-server binaries and image, and the sums job. `v0.*` tags publish
as pre-releases automatically.

## 2. What CI does, in order

1. Creates the release **hidden** and attaches each leg's assets as its
   build finishes (Android APKs, Linux `.deb` + AppImage + Flatpak +
   bundle, macOS zips, Windows zips, unsigned iOS IPAs — each IPA is
   zipped out of the `--no-codesign` `.xcarchive` — and the sync-server
   tarballs). Asset names carry the product prefix.
2. Once every leg is green, the sums job downloads the full asset set,
   enforces the manifest floor (every entry in the repository root's
   `scripts/release-manifest.txt` must be present; a missing asset is a
   pipeline bug), attaches `SHA256SUMS`, writes
   the same sums plus the platform labels (the Android APK's sideload
   note, D35; the iOS IPA's unsigned, unsupported label, D29) into the
   notes.
3. Re-downloads every asset and re-checks each digest against
   `SHA256SUMS`, then **publishes** the release — corruption introduced
   after the sums were computed never goes public. (An asset corrupted
   at upload time is not caught; the sums certify whatever the release
   serves.)

The public never sees a partial or sum-less release. A failed run leaves
an invisible draft.

## 3. Verify (recommended, not gating)

When the workflow is green, the release is already public. Worth a minute:

- `gh release download vX.Y.Z --clobber && sha256sum -c SHA256SUMS`
  (`shasum -a 256 -c` on macOS) — catches a corrupted upload early, while
  few people have downloaded it. On a mismatch, re-fetch to confirm,
  then delete the release and the tag and dispatch again on the same
  commit — never edit assets on a published release.
- For `v0.*` releases, confirm the pre-release flag is set (not
  "Latest"); if the flag is wrong, `gh release edit vX.Y.Z
  --prerelease` fixes it. Latest follows the newest non-prerelease
  release, so stable releases take Latest automatically.

## Invariants and rules

- A release is created once and never updated: any run whose tag already
  has a release — draft or published — fails instead of overwriting
  same-named assets, and runs serialize behind a concurrency group keyed
  on the tag.
- Transient failure (flaky runner, network): just re-run the failed
  jobs. The guard already passed, the draft keeps its assets, and a
  re-run re-attaches anything missing. Never use "Re-run all jobs":
  the guard job will then (correctly) fail because the release
  exists — that is the created-once invariant, not the broken-commit
  case, so don't start the delete-and-retag recovery.
- Broken commit: fix on `main`, delete the release **and the tag**, then
  dispatch the workflow on the fixed commit (the dispatch path recreates
  the tag there) — re-running against the old tag only rebuilds the
  broken commit. Deleting a published release never recalls assets that
  were already downloaded.
- Never rotate, move, or delete the committed Android keystore — in-place
  APK upgrades depend on it (07 §4's signing policy covers the public-key
  risk posture).
- Keep `ci.yml` and `release.yml` client matrices in lockstep.
