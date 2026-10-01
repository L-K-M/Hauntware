# Releasing Poltergeist

Releases use a maintainer-signed source tag and a locally signed checksum
manifest. CI never receives the maintainer key.

## Prerequisites

- A clean, green `main` checkout with full tag history.
- Dart 3.12+, Flutter 3.47.2, and the native desktop toolchain.
- `gh`, authenticated with release write access.
- `gpg`, with the maintainer OpenPGP secret key unlocked.
- `lkm-release` 1.1.0 or newer.
- A Git tagger email verified by GitHub, with the public key uploaded to the
  same GitHub account so the remote tag is marked verified.
- The key's 40-hex primary fingerprint from an independent publication
  channel. Do not learn it from GitHub or the draft being verified.
- An offline, pre-signed successor-key transition statement created with
  the maintainer key, per D23.

The same key signs the Git tag and `SHA256SUMS.asc`. Never put its secret key
or passphrase in GitHub Actions.

## Cut the tag

Versions are `X.Y.Z`, `X.Y.Z-betaN`, or `X.Y.Z-rcN`. Beta numbers are 1–49;
RC numbers are 1–49. The release script synchronizes every pubspec, the app
lockfile, README, and Android `versionCode`.

```sh
export POLTERGEIST_RELEASE_FINGERPRINT=0123456789ABCDEF0123456789ABCDEF01234567
scripts/release.sh 0.2.0
git show --show-signature v0.2.0
git push --atomic origin HEAD v0.2.0
```

The script signs a throwaway tag before mutation and requires its OpenPGP
primary fingerprint to match `POLTERGEIST_RELEASE_FINGERPRINT`. It also
requires signed-tag mode from the shared release engine. Any failed preflight
halts before the release commit or tag exists.

## CI draft

The tag workflow tests the tagged commit, builds all clients, and creates one
hidden draft. It must contain exactly these seven payloads plus
`SHA256SUMS`:

```text
poltergeist-android.apk
poltergeist-linux-x64.tar.gz
poltergeist_<Debian version>_amd64.deb
poltergeist-linux-x64.AppImage
poltergeist-macos-universal.zip
poltergeist-ios-unsigned.ipa
poltergeist-windows-x64.zip
```

Debian prereleases use its ordering marker: `0.2.0-beta1` is packaged as
`0.2.0~beta1-1`, and `0.2.0-rc1` as `0.2.0~rc1-1`. Pub versions and tags keep
the hyphen form. The tilde makes each prerelease sort before `0.2.0-1`.

The notes bind the tag, source commit, canonical checksum list, and these
disclosures:

- Android is a rehearsal artifact, not a supported v1 target.
- The iOS IPA is unsigned and must be re-signed before installation.

Do not edit the draft or replace an asset. Fix the source or workflow and cut
a new version instead.

## Verify and publish

From the tagged checkout, run:

```sh
scripts/finalize-release.sh \
  --repository L-K-M/Poltergeist \
  --tag v0.2.0 \
  --fingerprint 0123456789ABCDEF0123456789ABCDEF01234567
```

The finalizer:

1. verifies the signed tag and exact source commit;
2. downloads and hashes every draft asset;
3. rebuilds this host's desktop archive and enforces the 10% size bound;
4. launches the downloaded client for a five-second smoke test;
5. signs `SHA256SUMS` locally and uploads `SHA256SUMS.asc`;
6. re-downloads and verifies the closed asset set;
7. publishes once, then verifies the public release again.

A live mismatch or inconclusive API result leaves the release standing and
prints an alert for manual review. GitHub does not support a conditional
release `DELETE`, so automatic removal could delete a release repaired after
the final verification.

## Post-publication check

Download one payload from the public release, recompute its SHA-256, and match
it against the release notes. Verify the detached signature with the
independently obtained fingerprint:

```sh
gpg --verify SHA256SUMS.asc SHA256SUMS
sha256sum <downloaded-payload>
```

For `v0.1.0`, confirm the release is a pre-release and not Latest. From
`v0.2.0` onward, install the APK over the previous rehearsal APK to verify
the monotonically increasing Android version code.

The Android key is deliberately public. Its signature supports in-place
upgrades but does not prove origin. The signed tag attests source, while the
signed checksum manifest binds the published bytes. Neither makes CI builds
reproducible.
