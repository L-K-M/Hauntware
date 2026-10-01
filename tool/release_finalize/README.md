# Release finalizer

This maintainer-only tool closes D23's local trust step. CI creates one draft
with seven payloads and `SHA256SUMS`; this tool independently verifies the
signed tag and the source commit recorded in the draft, rebuilds the current
desktop target from that commit, checks the CI
archive is within 10% of the local archive, and runs the downloaded client.
It then signs the checksum list, re-downloads and verifies every asset, makes
the release public, and immediately verifies it again.

Prerequisites:

- an authenticated `gh` CLI allowed to edit releases;
- a clean checkout whose `HEAD` is the fetched signed tag's commit;
- the maintainer OpenPGP secret key available to `gpg`;
- the independently published 40-hex primary-key fingerprint;
- Flutter 3.47.2 and the native build tools for Linux, macOS, or Windows;
- no running Poltergeist instance during the five-second launch smoke.

Run from any directory:

```sh
scripts/finalize-release.sh \
  --repository L-K-M/Poltergeist \
  --tag v0.1.0 \
  --fingerprint 0123456789ABCDEF0123456789ABCDEF01234567
```

The fingerprint has no environment-variable fallback. Supply the value from
the independent publication channel, not from GitHub or the release draft.
The tool never replaces an asset. It pins the first draft's GitHub release ID.
A confirmed pre-publication mismatch leaves the draft intact. Any
post-publication failure leaves the release in place and prints an alert for
manual review; GitHub cannot condition deletion on the verified snapshot.
