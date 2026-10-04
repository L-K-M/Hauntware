#!/usr/bin/env bash
# Contract checks for the root CI/release infrastructure. Run in CI
# (the `contracts` job) and locally; exits non-zero on any violation.
#
# Checks:
#   1. every job in every root workflow carries a job-level
#      `timeout-minutes` (a stuck runner must cost red, not forever),
#   2. every `uses:` is pinned — immutable SHAs on the publish path
#      (release.yml), version tags elsewhere, matching the subtree
#      workflows' pinning convention,
#   3. every asset the release legs attach is covered by
#      scripts/release-manifest.txt (the publish floor),
#   4. all tracked helper scripts pass `bash -n`,
#   5. scripts/test.sh and this script are executable,
#   6. the preserved-history gate and the root release_version contract
#      are wired into the workflows (full-history checkouts where the
#      gate runs; check-tag/check-order at the release gate),
#   7. the shared GLM workflow stays byte-identical to the fleet
#      canonical (the poltergeist copy — the evolved variant carrying
#      the bounded retry and unfinished-review report),
#   8. multi-line run scripts in jobs that can run on Windows name
#      their shell (Windows otherwise runs them under PowerShell).

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
err() { echo "!! $*" >&2; fail=1; }

# --- 1. Job-level timeouts ------------------------------------------------
# A job header is a 2-space-indented key under `jobs:`; a job-level
# timeout sits at 4 spaces. Step-level timeouts (8+ spaces) do not
# count — they bound one step, not the runner.
for wf in .github/workflows/*.yml; do
  awk -v file="$wf" '
    /^jobs:/ { injobs = 1; next }
    injobs && /^[^ ]/ { injobs = 0 }
    injobs && /^  [A-Za-z0-9_-]+:/ {
      if (job != "" && !seen) {
        printf "!! %s: job %s has no timeout-minutes\n", file, job > "/dev/stderr"
        bad = 1
      }
      job = $1; sub(/:.*/, "", job); seen = 0
      next
    }
    injobs && /^    timeout-minutes:/ { seen = 1 }
    END {
      if (job != "" && !seen) {
        printf "!! %s: job %s has no timeout-minutes\n", file, job > "/dev/stderr"
        bad = 1
      }
      exit bad
    }
  ' "$wf" || fail=1
done

# --- 2. Pinned actions ----------------------------------------------------
for wf in .github/workflows/*.yml; do
  while IFS= read -r line; do
    ref="${line##*@}"
    case "$(basename "$wf")" in
      release.yml)
        # The publish path must not follow a mutable tag.
        [[ "$ref" =~ ^[0-9a-f]{40}$ ]] ||
          err "$wf: unpinned action ref on the publish path: $line"
        ;;
      *)
        [[ "$ref" =~ ^(v[0-9]+(\.[0-9]+)*|[0-9a-f]{40})$ ]] ||
          err "$wf: unpinned action ref: $line"
        ;;
    esac
  done < <(grep -oE 'uses: [^ #]+@[^ #]+' "$wf" | sed 's/^uses: //')
done

# --- 3. Manifest covers every attached asset ------------------------------
# Collect every asset-looking name or template the workflow produces —
# literal `files:` lines and matrix `files: |` lists — then match each
# manifest entry against them. `${{ matrix.X }}` templates behave like
# `*` for the match (their expansion set is the leg's declared files).
# `${{…}}` expressions normalize to `*` first, so templated entries
# like `seance-sync-${{ matrix.platform }}.tar.gz` cover their
# expansion set rather than breaking the literal match.
mapfile -t candidates < <(
  sed -E 's/\$\{\{[^}]*\}\}/*/g' .github/workflows/release.yml |
    grep -oE '[A-Za-z0-9_.*+-]+\.(apk|tar\.gz|zip|ipa|deb|AppImage|flatpak)' |
    sort -u
)
missing=0
while IFS= read -r pattern; do
  [[ -z "$pattern" || "$pattern" =~ ^# ]] && continue
  covered=0
  for candidate in "${candidates[@]}"; do
    # shellcheck disable=SC2053
    [[ "$pattern" == $candidate ]] && { covered=1; break; }
  done
  [[ "$covered" -eq 1 ]] ||
    { err "release-manifest entry not attached by any leg: $pattern"; missing=1; }
done < scripts/release-manifest.txt
[[ "${#candidates[@]}" -gt 0 ]] || err "no asset candidates found in release.yml"

# --- 4. Shell syntax on helper scripts ------------------------------------
while IFS= read -r script; do
  bash -n "$script" || err "bash -n failed: $script"
done < <(find scripts -name '*.sh' -type f)

# --- 5. Executable bits ----------------------------------------------------
for script in scripts/test.sh scripts/check-workflows.sh; do
  [[ -x "$script" ]] || err "not executable: $script (chmod +x)"
done

# --- 6. History gate + root version contract -------------------------------
for wf in ci release; do
  grep -q 'python3 scripts/check-history.py' ".github/workflows/$wf.yml" ||
    err "$wf.yml must run scripts/check-history.py (preserved-history gate)"
done
# The gate walks the whole imported graph; the checkouts that run it must
# fetch every M0-era object, not a shallow tip.
grep -q 'fetch-depth: 0' .github/workflows/ci.yml ||
  err "ci.yml must fetch full history for the preserved-history gate"
grep -q 'fetch-depth: 0' .github/workflows/release.yml ||
  err "release.yml must fetch full history for the preserved-history gate"
# The release gate defers version semantics to the root tool (the root
# `hauntware` manifest is the first RELEASE_PUBSPEC); a re-implemented
# shell scan must not creep back in.
grep -q 'tool/release_version/bin/release_version.dart' \
  .github/workflows/release.yml ||
  err "release.yml must verify versions via the root release_version tool"
# The sync fixture resolves seance_core's rootUri against the
# package_config file, not the shell's working directory — the self-test
# pins relative/absolute/encoded URI handling and the missing-anchor
# fail-closed path, so a regression cannot silently build the wrong
# Docker context again.
grep -q 'resolve-package-root.py' .github/workflows/ci.yml ||
  err "ci.yml sync fixture must resolve seance_core via scripts/resolve-package-root.py"
python3 scripts/resolve-package-root.py --self-test ||
  err "resolve-package-root self-test failed"

# --- 7. GLM canonical identity ---------------------------------------------
cmp -s .github/workflows/zai-code-review.yml \
       poltergeist/.github/workflows/zai-code-review.yml ||
  err "zai-code-review.yml differs from the fleet canonical (poltergeist/)"

# --- 8. Windows legs run bash scripts under bash ----------------------------
python3 scripts/check-windows-shells.py --self-test ||
  err "check-windows-shells self-test failed"
python3 scripts/check-windows-shells.py .github/workflows/*.yml ||
  err "a Windows-capable job runs a multi-line script without shell:"

if [[ "$fail" -ne 0 || "$missing" -ne 0 ]]; then
  echo "workflow contract checks FAILED" >&2
  exit 1
fi
echo "workflow contract checks passed"
