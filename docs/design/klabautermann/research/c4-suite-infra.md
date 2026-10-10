# C4: Suite infrastructure a fourth Hauntware product must touch

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Read-only investigation of the Hauntware repository at `bf1da58` (main,
"Merge pull request #109"), 2026-10-10. No repo files were modified.
Every claim cites `path:line` in that tree. Placeholders below:
`<prod>` = the new product's lowercase ASCII directory/package stem
(e.g. `wraith`), `<Prod>` = its display name.

Verified live (2026-10-10): repo visibility is `public`
(`gh api repos/L-K-M/Hauntware`); latest main CI run 37918443169
(2026-10-09) used 124.0 job-minutes over ~15 min wall; release run
37205118744 (v1.9.0, 2026-10-04) used 93.1 job-minutes across 21 jobs.
GitHub's limits page (fetched today) gives 20 concurrent jobs / 5
concurrent macOS jobs on Free and Pro, 60/5 on Team. Not verified here:
which GitHub plan owns `L-K-M`, and the billing rule that public repos
pay nothing for standard runners.

---

## 0. Executive summary

- The suite hard-codes its three products in about 15 places. They fall
  into four groups: the root orchestrators (`scripts/build.sh`,
  `scripts/test.sh`, `scripts/release.sh`, `scripts/release-manifest.txt`),
  the root release tool (`tool/release_version`: `_projectNames` and
  `_defaultProducts`, plus 6 test files with fixtures),
  `.github/workflows/{ci,release}.yml` (separate dart, flutter and
  client jobs per product, and the release `needs:` lists), and
  `scripts/check-workflows.sh` check 11. Nothing discovers products
  automatically.
- **The release tool ignores an unregistered product without any error.**
  A directory that is not in `_projectNames` is "unmanaged"
  (`tool/release_version/lib/release_version.dart:785-794`). Its pubspecs
  are not version-checked, not bumped and not lock-rewritten. The product
  must therefore be registered in the same PR as its first versioned
  pubspec. Registering it in `_defaultProducts` before the app exists
  makes `check` fail (`:231-242`).
- **The history checker needs nothing.** `scripts/check-history.py:33`
  iterates only `source-refs.json` `sources`. A greenfield product needs
  no entry, and adding one would fail the `preservation:<project>` tree
  check (`:35-36`).
- The three guards most relevant here are Poltergeist-local: the import
  guard, the license/local-dependency gate and the private-key scope
  check. They scan only `poltergeist/` (`poltergeist/scripts/check-imports.sh:5-13`,
  `poltergeist/tool/license_gate/bin/check.dart:24-27`,
  `poltergeist/test/integration/assert-private-keys-scoped.sh:4`). A
  fourth product gets no dependency-boundary enforcement unless these
  guards are generalized or copied.
- Adding the product grows the release from 13 to 18 clients and from 25
  to 33 manifest assets. CI cost grows by about +30-35 job-minutes per
  run, and the macOS jobs per run go from 7 to 9 against a 5-concurrent
  macOS cap.

---

## 1. Exhaustive change checklist (grouped by area)

### 1.1 Root scripts

| # | File:line | Change |
|---|---|---|
| S1 | `scripts/build.sh:31` | `PRODUCTS="planchette seance poltergeist"`: append `<prod>`. |
| S2 | `scripts/build.sh:46` | Argument `case` lists products explicitly. Add `<prod>`, or an explicit `scripts/build.sh <prod>` exits 2 ("Unknown argument", `:47-50`). |
| S3 | `scripts/build.sh:2-26` | Header/usage comment ("planchette/scripts/build.sh and siblings"). Update the prose. |
| S4 | `scripts/test.sh:2-12` | Header says "all three subtrees". Update it. |
| S5 | `scripts/test.sh:46-133` | Add a `( cd <prod>; dart pub get; dart analyze <explicit pkgs>; dart test <explicit pkgs> )` block for the pure-Dart workspace (pattern: Séance `:66-75`, Poltergeist discovery loop `:88-101`). |
| S6 | `scripts/test.sh:135-168` | Add a Flutter block: `(cd <prod>/app/<prod>_app && flutter pub get && flutter analyze && flutter test)` (pattern `:163-167`). Add any new shared Flutter package to the Planchette loop and the `dart format` line (`:141-152`) if it lives in `planchette/packages/`. |
| S7 | `scripts/release.sh:78` | `RELEASE_CI_NOTE` enumerates the products and APK/IPA targets. Add `<Prod>`. |
| S8 | `scripts/release-manifest.txt:123-155` | Add a `# --- <Prod> clients (5 targets, 8 assets)` block: `<prod>-android.apk`, `<prod>-linux-x64.tar.gz`, `<prod>_*.deb`, `<prod>-linux-x64.AppImage`, `<prod>-linux-x64.flatpak`, `<prod>-macos-universal.zip`, `<prod>-ios-unsigned.ipa`, `<prod>-windows-x64.zip` (mirrors `:147-155`). Header prose at `:112-116` names the products. |
| S9 | `scripts/check-workflows.sh:244` | Check 11 loops `for leg in client_seance client_poltergeist`. Add `client_<prod>` so its APK version-code verification is enforced. Header item 11 (`:29`) says "both Android client legs". |
| S10 | `scripts/refresh-seance-release-audit.sh:10,20` | Poltergeist-specific (`poltergeist/docs/PORTS.md`). **No change** unless the new product also adopts a Séance provenance record. Decide explicitly (see 2.9). |
| S11 | `scripts/verify-android-version.sh:8-9` | Generic, run from the app dir. Only the comment names Séance/Poltergeist. Call it from the new android legs. |
| S12 | `scripts/verify-macos-app.sh:62-64` | Generic, run from the app dir. Call it from the new macOS legs. |
| S13 | `scripts/test-desktop-launch.py:20-30` | Generic launcher. Call it from the new macOS/Linux/Windows legs with the product's bundle/binary path (and `--home user` if it uses the keychain). |
| S14 | `scripts/flatpak-repack.sh:3-6`, `scripts/package-linux-gcc-floors.sh:1-3` | Shared helpers, sourced by each product's `build-flatpak.sh`/`package-linux.sh`. Only the comments enumerate products. |
| S15 | `scripts/macos-keyboard-fixture.mm` | Shared fixture included by each product's `scripts/test-macos-keyboard.mm:16` (`#include "../../scripts/macos-keyboard-fixture.mm"`). The new product adds its own 16-line `.mm` stub with a `<PROD>_USE_CONTROLLER` macro (pattern `poltergeist/scripts/test-macos-keyboard.mm:8`) and a `test-macos-keyboard.sh`. |
| S16 | `scripts/resolve-package-root.py`, `scripts/check-windows-shells.py` | Generic. No change. `check-windows-shells.py` will enforce `shell: bash` on multi-line steps in new Windows-capable jobs (`scripts/check-windows-shells.py:6-12`). |

### 1.2 Root release tool (`tool/release_version`)

| # | File:line | Change |
|---|---|---|
| R1 | `tool/release_version/lib/release_version.dart:38-39` | `_projectNames = ['planchette','seance','poltergeist']`: add `<prod>`. **Without this, every pubspec/lock under `<prod>/` is treated as unmanaged** (`:785-794`). Nothing would version-check it, `RELEASE_PUBSPECS` would not bump it (`:335-347`), and post-bump would not re-pin its locks (`:410-428`). |
| R2 | `tool/release_version/lib/release_version.dart:123-150` | Add a `SuiteProduct(name: '<prod>', appPubspecPath: '<prod>/app/<prod>_app/pubspec.yaml', readmePath: '<prod>/README.md', flutterVariablePlistPaths: ['<prod>/app/<prod>_app/ios/Runner/Info.plist', '<prod>/app/<prod>_app/macos/Runner/Info.plist'])`. Recommended: `flutterVariablePlistPaths` (Planchette/Séance style, `CFBundleVersion = $(FLUTTER_BUILD_NUMBER)`, e.g. `seance/app/seance_app/macos/Runner/Info.plist:25-26`) over Poltergeist's literal style (`poltergeist/app/poltergeist_app/macos/Runner/Info.plist:32-33` = `2.9.0`), because the literal style must be rewritten at every release (`:305-328`). |
| R3 | `tool/release_version/lib/release_version.dart:231-242` | `check` *requires* each registered product's app pubspec, README marker (`:540-557`, exactly one `<!-- version -->X<!-- /version -->`) and plist (`:576-604`). R2 must land together with the scaffold, never before. |
| R4 | `tool/release_version/lib/release_version.dart:15-27` | The suite tool imports `ReleaseVersion` from `poltergeist/tool/release_version`. This is a cross-product coupling to know about, not to change. |
| R5 | `tool/release_version/test/release_script_test.dart:95-123` | `unorderedEquals([...])` lists every owned pubspec ("a package added to or dropped from the suite has to change this list on purpose", `:94-95`). Add `<prod>/app/<prod>_app/pubspec.yaml` and every `<prod>/packages/*/pubspec.yaml`. Add `isNot(contains('<prod>/pubspec.yaml'))` beside `:121-123`. |
| R6 | `tool/release_version/test/release_script_test.dart:382-400` | The child `release.sh` forwarder loop `for (final product in ['planchette','seance','poltergeist'])`. Add `<prod>`, which requires `<prod>/scripts/release.sh` (pattern `poltergeist/scripts/release.sh:1-8`). |
| R7 | `tool/release_version/test/release_workspace_test.dart:750-905` | `_writeFixture` builds a synthetic suite per product (`// --- Planchette ---` `:791`, Séance `:816`, Poltergeist `:853`). After R2 the default-products `check` fails on this fixture until a `// --- <Prod> ---` block (workspace root, packages, app pubspec `1.1.0+1010099`, lock, plists, README) is added. Also add the product app pubspec to `_syncTargets` (`:919-925`). |
| R8 | `tool/release_version/test/release_version_cli_test.dart:216-275` | Fixture loop `for (final project in ['planchette','seance','poltergeist'])` (`:234`) and explicit plist writes (`:258-275`). Add `<prod>` and its plists. |
| R9 | `tool/release_version/test/windows_version_test.dart:7-11` | `_apps` list. Add `<prod>/app/<prod>_app`. The new `windows/runner/Runner.rc` must define `VERSION_AS_NUMBER FLUTTER_VERSION_MAJOR,FLUTTER_VERSION_MINOR,FLUTTER_VERSION_PATCH,0` with no `FLUTTER_VERSION_BUILD` (`:14-31`; reference `poltergeist/app/poltergeist_app/windows/runner/Runner.rc:65`), because build code 1090099 overflows the 16-bit field. |
| R10 | `tool/release_version/test/build_script_test.dart:28-33` | `--check` output expectations. Add `contains('<prod>')`. |
| R11 | `tool/release_version/test/build_script_test.dart:206-211` | "a macOS build starts without the previous app bundle": add `('<prod>', '<prod>_app', '<Prod>.app')`. The product `build.sh` must delete the previous bundle before `flutter build macos`. |
| R12 | `tool/release_version/test/build_script_test.dart:262-266` | "a product build fails when a later step fails": add `('<prod>', '<prod>_app')`. The product `build.sh` must emit `app: FAILED (copy to dist/)`, `apk: FAILED (copy to dist/)` and `packages: FAILED` in the shared format. |
| R13 | `tool/release_version/test/flatpak_repack_test.dart` | Generic (sources `scripts/flatpak-repack.sh`). No change. |

### 1.3 CI (`.github/workflows/ci.yml`)

Current per-product jobs and what the fourth product needs:

| Job (line) | Scope | Fourth-product action |
|---|---|---|
| `contracts` (`:50-67`) | Generic: actionlint, check-workflows, check-history | None. Picks up new jobs automatically (timeouts, pins, manifest coverage). |
| `suite_tool` (`:75-92`) | Root release tool | None. Runs R5-R12 tests. |
| `planchette_core` (`:95-119`, 3-OS matrix) | Planchette | Template for a multi-OS pure-Dart job. |
| `seance_dart` (`:122-150`, Ubuntu) | Séance | Template for a single-OS pure-Dart job. |
| `poltergeist_dart` (`:153-203`, 3-OS matrix, `packages/*` discovery) | Poltergeist | Best template: discovery loop, so new packages need no workflow edit. |
| `dart_tools` (`:206-284`) | Poltergeist guards (import/protocol/license/pin audit/bench/fixture) | Add a `<prod>_tools` job if the new product gets its own import/boundary guard (see 1.5). |
| `seance_pin_audit` (`:286-337`) | Paths filter `seance/**` (`:304-314`) | Any `seance_core` change made for the new product triggers this audit. Expect to run `audit-seance-pin.sh --write-record` only when provenance changes (`:327-331`). |
| `detect_integration` / `integration` / `sync_integration` (`:339-479`) | Poltergeist sshd fixture plus sync server | Template if the new product adds a Docker-based sshd/dockerd fixture. Its paths filter must include the shared packages it consumes (pattern `:362-369`). |
| `detect_bench` / `bench` / `m0_bench` / `m0_evidence` (`:481-880`) | Poltergeist only | None. |
| `planchette_flutter` (`:884-936`) | Shared Flutter packages plus app plus `dart format` | If a new shared package (e.g. a server-list package) lands in `planchette/packages/`, add its resolve/analyze/test/format lines (`:897-936`). |
| `seance_flutter` (`:938-963`), `poltergeist_flutter` (`:965-983`) | Per-app analyze plus test | Add `<prod>_flutter` (copy `:965-983`). |
| Comment (`:985-990`) | "3 Planchette desktop + 5 Séance + 5 Poltergeist targets" | Update the count. |
| `planchette_client` (`:992-1076`), `seance_client` (`:1078-1214`), `poltergeist_client` (`:1216-1339`) | 3/5/5-leg matrices | Add `<prod>_client` with 5 legs: android `apk --release`, linux `linux --release` flavor x64, macos, ios `ipa --release --no-codesign` (lockstep comment `:1241-1243`), windows. Steps: setup-java 17 (`:1251-1255`); Linux toolchain incl. `libsecret-1-dev libjsoncpp-dev` (`:1259-1264`); ad-hoc signing sed on `<prod>/app/<prod>_app/macos/Runner.xcodeproj/project.pbxproj` (`:1273-1280`); `verify-macos-app.sh` (`:1289-1292`); keyboard fixture (`:1293-1296`); 3 release-launch steps (`:1302-1314`); `verify-android-version.sh` (`:1316-1320`); `package-linux.sh --output-dir dist-packages` (`:1324-1327`); Flatpak build check (`:1330-1339`). |
| `docker` (`:1342-1351`) | Sync-server image | Only if the new product ships a server-side component/image (see 4.6). |
| Header (`:3-9`) | "the three module workflows ... planchette/, seance/ and poltergeist/" | Update the prose. |

No client job has an `if:`/paths filter, so every PR builds every client.

### 1.4 Release (`.github/workflows/release.yml`)

| # | Line | Change |
|---|---|---|
| W1 | `:3-9` | Header: "13 client targets (3 Planchette desktop, 5 Séance, 5 Poltergeist)" becomes 18 targets. "three products' files". |
| W2 | `test` gate `:69-285` | Add a step that resolves, analyzes and tests the new pure-Dart packages (pattern `:230-237`), plus any new guard (pattern `:259-285`). Timeout is 30 min (`:72`); the v1.9.0 run used 10.1 min. |
| W3 | `flutter` gate `:289-347` | Add `<prod>` analyze plus test (pattern `:342-347`). Timeout 45 (`:292`, "three apps plus shared packages"); the v1.9.0 run used 14.5 min. Expect about 18-22 min with a fourth app. The timeout still fits, but the comment needs updating. |
| W4 | new `client_<prod>` | Copy `client_poltergeist` (`:925-1160`): checkout-ref provenance step (`:975-998`, copied verbatim into every job), SHA-pinned actions only (enforced by `scripts/check-workflows.sh:69-73`), matrix `files:` per leg (`:941-973`), lock-drift guard after build (`:1054-1062`), launch/verify steps, Package `case` (`:1096-1151`), `softprops/action-gh-release` draft upload with `fail_on_unmatched_files: true` (`:1152-1160`). Planchette uses a separate `flatpak_planchette` leg (`:615-688`); follow the Séance/Poltergeist pattern of building the Flatpak inside the Linux leg (`:1114-1121`) instead. |
| W5 | `docker.needs` `:1168-1174` | Add `client_<prod>` so the GHCR image never publishes when the new client floor fails. |
| W6 | `sums.needs` `:1247-1253` | Add `client_<prod>`. |
| W7 | `:1303-1306` | Comment "25 product assets across the three apps" becomes 33. |
| W8 | Notes heredoc `:1323-1339` | Add a `**<Prod>**` line (and app-ID note). |
| W9 | `:18-23` | Signing inventory: "No signing secrets exist ... Do not add signing inputs without a decision". The new product must follow it: committed public debug-grade keystore, unsigned IPA, ad-hoc macOS. |
| W10 | `:1041-1043` | The license gate step is Poltergeist-only (`SEANCE_LICENSE_GATE_V1` marker, `poltergeist/tool/license_gate/lib/license_gate.dart:9-12`). Do not copy it unless the gate is generalized. |

### 1.5 Guards and where they enumerate products/packages

| Guard | Location | Scope today | Fourth-product implication |
|---|---|---|---|
| Workflow contracts | `scripts/check-workflows.sh` | Root workflows. Generic except check 11 (`:244`) | S9. Check 3 (`:90-158`) automatically demands manifest/leg coverage both ways, so new assets must be in the manifest. |
| Windows shells | `scripts/check-windows-shells.py` | Generic | New Windows legs need `shell: bash` for multi-line `run:`. |
| History | `scripts/check-history.py` | `sources` in manifest only (`:33`) | None (see section 3). |
| Release version lockstep | `tool/release_version` | `_projectNames`, `_defaultProducts` | R1-R12. |
| Import/dependency guard | `poltergeist/tool/import_guard/lib/import_guard.dart:10-20`, wrapper `poltergeist/scripts/check-imports.sh:5-13` | Scans `poltergeist/packages` and `poltergeist/app` (`_Area` `:13`, `:33-46`). Confines `dartssh2` to `packages/poltergeist_core/lib/src/connection` (`:10-11`, `:147`). Pure-Dart packages may not import Flutter/plugins (`poltergeist/tool/import_guard/README.md:11-14`) | **Not applied to the new product.** Either generalize it into a root `tool/` guard parameterized per product (core dir, connection dir), or add `<prod>/tool/import_guard` and a CI step. The root AGENTS rule "UI uses host services" (`AGENTS.md:42-45`) and "Poltergeist consumes the shared SSH/protocol implementation through its core barrel" (`:43-44`) are only machine-enforced for Poltergeist. |
| Local-dependency / license gate | `poltergeist/tool/license_gate/lib/license_gate.dart:33-34, 243-246, 331, 350`, runs from `poltergeist/` (`bin/check.dart:24-27`) | Requires `seance_core`/`seance_protocol` to be local path deps inside `seance/`, never git/hosted. Marker-only in PR CI (`ci.yml:283-284`), full in the Poltergeist release leg | Not applied to `<prod>/`. Path deps are the suite convention (`AGENTS.md:20-21`, "Shared packages use relative paths"), so either extend the gate's root or add an equivalent check. |
| Protocol guard | `poltergeist/tool/protocol_guard` (README `:10-12`) | Poltergeist engine isolate protocol (08 §3.3) | Product-specific. Only relevant if the new product adopts an engine-isolate request/event protocol. |
| Séance pin audit | `poltergeist/tool/seance_pin_audit`, `poltergeist/scripts/audit-seance-pin.sh`, `scripts/refresh-seance-release-audit.sh` | Records Séance lineage consumed by Poltergeist in `poltergeist/docs/PORTS.md` | Not needed for a same-repo product. Decide explicitly in the new plan's decision log. |
| Private-key scope | `poltergeist/test/integration/assert-private-keys-scoped.sh:4,9-11,27` (run by `secret-scan.yml:26-27`) | Scans `poltergeist/` only, with exactly 3 allowed fixture keys | New fixture host keys under `<prod>/test/...` are not covered. Extend it or add a sibling script plus a step. |
| Gitleaks | `.gitleaks.toml:9-17`, `.gitleaksignore` | Root. The allowlist has Poltergeist's `ci-release.jks`, `key.properties` and fixture keys | Add `^<prod>/app/<prod>_app/android/(app/ci-release\.jks\|key\.properties)$` and any fixture keys. |
| GLM review identity | `scripts/check-workflows.sh:198-200` | `zai-code-review.yml` byte-identical to `poltergeist/.github/workflows/zai-code-review.yml` | None. Do not add a `<prod>/.github`. |

### 1.6 Other repo-level config

| # | File:line | Change |
|---|---|---|
| C1 | `.github/dependabot.yml:13-22` | Add `gradle` for `/<prod>/app/<prod>_app/android`. Optionally `pub` entries (only Planchette has them, `:24-38`). |
| C2 | `.github/workflows/fixture-images.yml:28-30` | Single hard-coded `IMAGE`/`CONTEXT` (Poltergeist sshd base). A new frozen fixture base image (e.g. sshd+dockerd) needs a matrix or a second workflow, with the same "publish on main by dispatch, pin digest" flow (`:10-12`, `:51-118`). |
| C3 | `.github/workflows/secret-scan.yml:24-27` | Add a fixture-key scope step for the new product if it commits fixture keys. |
| C4 | `.gitignore:15-17` | `/dist/` and `build/` already cover the root. Each product keeps its own `.gitignore` (`.gitignore:1-4`). Add `<prod>/.gitignore`. |

### 1.7 Root docs

| # | File:line | Change |
|---|---|---|
| D1 | `README.md:10-16` | Product table: add a `<Prod>` row (purpose, Android/iOS/Linux/macOS/Windows). |
| D2 | `README.md:18-19` | "Product names, application IDs, storage locations and keystore namespaces stay distinct". The new IDs must be distinct. |
| D3 | `README.md:32`, `:55` | "Build all three apps", "all 13 client targets". |
| D4 | `AGENTS.md:3-5`, `:9-14`, `:42-45`, `:60`, `:64-66` | Product list, layout bullets, boundaries (add "<Prod> consumes the shared SSH/protocol implementation through its core barrel"), "all 13 clients", CI-preserved gates. |
| D5 | `CHANGELOG.md:1-33` | Suite-level entry for the new product (root changelog lists suite changes; product changelogs carry product detail, `CHANGELOG.md:76-78`). |
| D6 | `docs/design/` | Home for cross-product design docs (format: scope, status/approval, inventory with `path:line`, e.g. `docs/design/server-appearance-package.md:1-12`). Use it for a "shared server list" extraction design. |
| D7 | `docs/history/README.md` | No change (it documents imported products only, `:3-10`). |

### 1.8 Packaging (per-product, new files)

| # | New file | Pattern / constraint |
|---|---|---|
| P1 | `<prod>/scripts/build.sh` | Copy Poltergeist's client-only build (`poltergeist/scripts/build.sh:1-35`): targets `app\|apk\|flatpak` (`:60`), `--debug`, `--install` (macOS `/Applications/<Prod>.app`, Linux `~/.local/opt/<prod>`), artifacts into `<prod>/dist/` with product-prefixed names, honors `HAUNTWARE_BUILD_ORCHESTRATED` (root `scripts/build.sh:23-26`). |
| P2 | `<prod>/scripts/package-linux.sh` | About 500 lines, copied per product (Polt 522, Séance 494, Planchette 526 lines; only ~171 diff lines between Polt and Séance after renaming). Identity constants at `poltergeist/scripts/package-linux.sh:50-53`: `BUNDLE_EXECUTABLE`, `LINUX_APPLICATION_ID=ch.lkmc.<prod>`, `LINUX_STARTUP_WM_CLASS="${LINUX_APPLICATION_ID^}"`. Desktop entry `StartupWMClass` at `:316-317`, `Maintainer`/`Homepage` at `:413-414`. Consider extracting the common body into `scripts/` (as was done for `flatpak-repack.sh`) rather than making a fourth copy. |
| P3 | `<prod>/scripts/build-flatpak.sh` | Copy `poltergeist/scripts/build-flatpak.sh:1-60`. `APP_ID=ch.lkmc.<prod>` (`:14`), sources `../scripts/flatpak-repack.sh` (`:48-52`), bundle `dist/<prod>-linux-x64.flatpak` (`:54`). |
| P4 | `<prod>/flatpak/ch.lkmc.<prod>.yml` | Copy `poltergeist/flatpak/ch.lkmc.poltergeist.yml:1-31`. Runtime `org.gnome.Platform` `'50'`, `command: <prod>`. Choose `finish-args` deliberately: `--share=network`, `--socket=ssh-auth`, `--talk-name=org.freedesktop.secrets` are needed for an SSH tool. `--filesystem=home` (`:20`) is justified for Poltergeist file transfer and probably *not* for a monitoring tool (use portals for log export). Do **not** copy Séance's legacy `com.lkm.seance_app` id (`seance/flatpak/com.lkm.seance_app.yml:4`, `seance/scripts/build-flatpak.sh:14`). |
| P5 | `<prod>/scripts/release.sh` | 8-line forwarder (`poltergeist/scripts/release.sh:1-8`). Required by R6. |
| P6 | `<prod>/scripts/test-macos-keyboard.{sh,mm}` | See S15. Gated in macOS CI legs (pattern `ci.yml:1293-1296`). |
| P7 | `<prod>/media-sources/<prod>-icon.png` | 1024x1024 master. Launcher icons via `flutter_launcher_icons` config in the app; Linux icons generated by `package-linux.sh` (`poltergeist/docs/plan/07-MILESTONES.md:279-288`). |

### 1.9 Signing and platform identities (per-product, new files)

| # | Item | Convention / evidence |
|---|---|---|
| G1 | Android | Committed **public** debug-grade keystore `android/app/ci-release.jks` + `android/key.properties` (`poltergeist/app/poltergeist_app/android/key.properties:1-5`). `build.gradle.kts` pins the certificate SHA-256 so accidental rotation fails builds (`poltergeist/app/poltergeist_app/android/app/build.gradle.kts:11-52`) and signs release with it (`:80-93`). `applicationId = "ch.lkmc.<prod>"` is frozen after first release (`:65-67`). JDK 17 (`:59-62`). Generate a new keystore for the product (distinct cert), pin its digest, and allowlist it in gitleaks (1.5). |
| G2 | Android AGP/Kotlin | If using `file_picker` 11+, copy the Kotlin re-apply workaround (`poltergeist/AGENTS.md:187-189`). |
| G3 | iOS | Unsigned IPA (`release.yml:962-969`). Bundle id `ch.lkmc.<prod>App` (pattern `poltergeist/app/poltergeist_app/ios/Runner.xcodeproj/project.pbxproj:386`). `CFBundleVersion = $(FLUTTER_BUILD_NUMBER)` (R2). |
| G4 | macOS | `PRODUCT_NAME` must be ASCII (codesign rejects accented file names: `seance/AGENTS.md:250-254`; `poltergeist/AGENTS.md:161-163`; `planchette/AGENTS.md:89-91`). `PRODUCT_BUNDLE_IDENTIFIER = ch.lkmc.<prod>App` in `macos/Runner/Configs/AppInfo.xcconfig` (pattern `poltergeist/.../AppInfo.xcconfig:8,11`). Ad-hoc signed. **All three apps ship unsandboxed with empty `Release.entitlements`** (Planchette/Poltergeist empty `<dict/>`; Séance explains at length in `seance/app/seance_app/macos/Runner/Release.entitlements` and `seance/AGENTS.md:136-145`). No `keychain-access-groups` (restricted, blocks ad-hoc launch); use the legacy login keychain via `MacOsOptions(usesDataProtectionKeychain: false)` (`poltergeist/AGENTS.md:190-192`). macOS floor 12.0 (`seance/AGENTS.md:266`). |
| G5 | Linux | `linux/CMakeLists.txt` `BINARY_NAME "<prod>"`, `APPLICATION_ID "ch.lkmc.<prod>"` (Planchette/Poltergeist pattern `poltergeist/app/poltergeist_app/linux/CMakeLists.txt:7,10`; Séance's `seance_app` binary is the odd one out). WM_CLASS class `Ch.lkmc.<prod>` must equal `StartupWMClass` (`poltergeist/AGENTS.md:164-172`). |
| G6 | Windows | `Runner.rc` `VERSION_AS_NUMBER` semantic-only (R9). The products are inconsistent today: `CompanyName` is `ch.lkmc` (Planchette/Séance) vs `L-K-M` (Poltergeist), exe names `planchette.exe` / `seance_app.exe` / `poltergeist_app.exe` (`*/windows/runner/Runner.rc:93-99`, `*/windows/CMakeLists.txt:7`). Pick one (recommend `<prod>.exe`, `CompanyName L-K-M`, `LegalCopyright Unlicense`) and reference it in the CI/release launch step. |
| G7 | Android label | `android:label="<Prod>"` (pattern `poltergeist/.../AndroidManifest.xml:10`). Display names may be non-ASCII; file/bundle names may not. |

---

## 2. Conventions the new product must follow

1. **One version, lockstep.** Every owned package pubspec declares the
   suite semantic version (`1.9.0` today, `pubspec.yaml:121`); the app
   declares `X.Y.Z+code` (e.g. `poltergeist/app/poltergeist_app/pubspec.yaml:4`
   `1.9.0+1090099`). Android code = bounded monotonic mapping
   (`poltergeist/tool/release_version/lib/release_version.dart:74-81`),
   Apple literal form = `major+1.minor.patch` (`:83-86`). The workspace
   root pubspec is unversioned and named `_<prod>_workspace`
   (pattern `poltergeist/pubspec.yaml:7`; the release tool test asserts
   `_workspace` never appears, `release_script_test.dart:119-120`).
2. **Owned package names must be globally unique against every
   dependency name.** Post-bump re-pins *any* lock entry whose name
   matches an owned package, regardless of source
   (`release_version.dart:85-104`, `:624-627` "a stale pin is stale
   whether path- or git-sourced"). Naming a package after a pub.dev
   dependency in use would corrupt locks.
3. **Per-product pure-Dart workspace; app outside it.** `pubspec.yaml`
   with `workspace:` of `packages/*` only; the Flutter app is NOT a
   member and path-depends on them (`poltergeist/pubspec.yaml:1-15`,
   `poltergeist/AGENTS.md:182-184`). Resolve sequentially; never
   `--directory`; never bare `dart test` at a product root
   (`AGENTS.md:20-22, 36-38`).
4. **Shared code by relative path, never copied.** `AGENTS.md:5`
   ("shared library implementations are never copied") and `:20-21`.
   Examples: `poltergeist/packages/poltergeist_core/pubspec.yaml:17-24`
   (`planchette_core`, `seance_core` by path; `dartssh2: 3.0.2` pinned
   exactly like seance_core), `poltergeist/app/poltergeist_app/pubspec.yaml:13-55`
   (`ghost_ui`, `planchette_editor`, `ghost_desktop`, `ghost_marks`).
   **Server-list implication:** the server list/editor UI is *currently
   duplicated* app-side: `seance/app/seance_app/lib/ui/server_editor.dart`
   (1297 lines) vs `poltergeist/app/poltergeist_app/lib/ui/server_editor.dart`
   (1490), plus `seance/.../server_list_pane.dart` (1123),
   `server_grouping.dart` (301) and Poltergeist's `lib/ui/sidebar/sidebar_servers_section.dart`.
   Only the appearance cluster was extracted (`planchette/packages/ghost_marks/lib/src/`,
   design `docs/design/server-appearance-package.md`). A fourth app
   "showing the same server list" should come with a design doc plus an
   extraction into a shared package, not a third copy.
5. **Shared data model.** Server list = `ServerConfig`
   (`seance/packages/seance_protocol/lib/src/models/server_config.dart:54`)
   synced as `RecordKind.serverConfig` inside E2E-encrypted records
   (`seance/packages/seance_protocol/lib/src/records/record.dart:13-33`).
   New record kinds can roll out safely: unknown kinds decode to
   `unknown` and every apply path skips them (`record.dart:16-21, 35-46`),
   and kinds match by name, never ordinal. App code imports only the
   `seance_core` barrel, which re-exports `seance_protocol`
   (`seance/packages/seance_core/lib/seance_core.dart:3-7`). Update
   checks go to the shared repo `L-K-M/Hauntware`
   (`seance/packages/seance_core/lib/src/update/update_checker.dart:7-8`).
6. **Identities.** `ch.lkmc.<prod>` (Android/Linux/Flatpak),
   `ch.lkmc.<prod>App` (Apple), ASCII file/bundle names, distinct
   storage locations and keystore namespaces (`README.md:18-19`,
   `AGENTS.md:44-45` "Preserve application IDs, keychain names ...").
   Release asset names are product-prefixed and unversioned except the
   Debian `.deb` (`scripts/release-manifest.txt:108-116`,
   `release.yml:1091-1093`).
7. **Distribution stance.** No signing secrets; unsigned/ad-hoc desktop,
   unsigned IPA, committed public APK key (`release.yml:18-23`,
   `README.md:55-58`). No linux-arm64 (`ci.yml:1231-1235`).
8. **Platform folders committed** with reviewed identities and fixes
   (`AGENTS.md:45`; `seance/AGENTS.md` "The platform folders ... ARE
   committed").
9. **Per-product docs layout** (all three have it): `AGENTS.md`,
   `CLAUDE.md` (points at AGENTS.md plus the PR babysitting block,
   `poltergeist/CLAUDE.md`), `README.md` with exactly one version marker
   (`poltergeist/README.md:12`), `CHANGELOG.md` with `## Unreleased`
   (`poltergeist/CHANGELOG.md:1-3`), `LICENSE` (Unlicense, same as root
   `LICENSE:1-5`), `analysis_options.yaml`, `.gitignore`,
   `docs/STATUS.md`. Poltergeist adds `docs/plan/`, `docs/INSTALL.md`,
   `docs/RELEASE.md`, `docs/PORTS.md`.
10. **Shared-rules block.** Each product `AGENTS.md` embeds the
    `<!-- shared-rules:start --> ... <!-- shared-rules:end -->` block
    byte-identical to the root's (`AGENTS.md:78`; verified identical for
    Planchette and Poltergeist with `diff` during this research). No
    automated check enforces this.
11. **Testing conventions.** Pure-Dart `test()`s for engine logic,
    widget tests with injected fakes, real temp dirs where filesystem
    behaviour is the subject (`seance/AGENTS.md` sec. 4), host-bound
    gates in CI only (`scripts/test.sh:24-27`): release-build launch
    test on macOS/Linux/Windows (`scripts/test-desktop-launch.py:1-31`),
    `verify-macos-app.sh`, APK version-code check, Linux packaging plus
    Flatpak smoke check (`scripts/flatpak-repack.sh:116-137`), macOS
    keyboard fixture. A "required" native test uses an env flag so a
    missing native library fails instead of skipping (pattern
    `SEANCE_NATIVE_PTY_REQUIRED`, `ci.yml:1152-1161`). Docker sshd
    fixtures with frozen, digest-pinned base images
    (`fixture-images.yml:3-12`).
12. **Workflow conventions.** Every job has `timeout-minutes`
    (`check-workflows.sh:37-62`); actions pinned to tags in CI and to
    SHAs in release (`:64-80`); main CI never cancelled (`ci.yml:35-42`,
    `AGENTS.md:66`); Windows multi-line steps name `shell: bash`; only
    the docker job gets `packages: write` (`check-workflows.sh:208-228`).
13. **Commits/PRs.** Imperative subject <= 72 (target 50), body wrapped
    at 72, no model identifiers in code/docs (`poltergeist/AGENTS.md:156-158`).
    Later PRs use the GLM review workflow with the shared stopping rules
    (`AGENTS.md:68-71`).

### Plan-document model (Poltergeist `docs/plan/`)

- **00-OVERVIEW.md**: status/date line (`:3`), purpose paragraph with
  precedence rule ("when a chapter conflicts with this overview's
  decision log, the decision log wins; when code reality conflicts with
  the plan, stop and update the plan first", `:13-17`), reading-order
  table (`:19-36`), requirements table `R#` -> chapter (`:39-52`),
  **decision log** (`:54-1165`): a one-line quick index (`:61-71`), then
  themed `###` groups, each entry a bullet (bold `Dn`, a dash, the
  title, then the rationale) with dated amendments inline ("amended 2026-09-24 by owner directive",
  `:129-130`; "D35 ... (2026-09-25, owner-directed; amends D1, D23, and
  D29 for Android only)", `:1128-1129`). A parking-lot decision (D25,
  `:1148`) records what not to build. Ends with "The one-sentence
  product" (`:1167-1171`). Changing a decision = edit 00 in the same PR
  (`:56-59`).
- **07-MILESTONES.md**: posture rules (milestone = mergeable demoable
  main; checkable exit criteria; relative sizes S/M/L; fixed order with
  named parallelism; budgets gate from introduction, `:9-35`), milestone
  table with gates (`:37-55`), per-milestone Goal/Scope/Exit criteria
  checklists (e.g. M1 scaffold `:257-300`, which spells out the
  `flutter create --org ch.lkmc` identity fix-ups), milestone-close chores
  (`:781`), fast-follows (`:809`), distribution workstream (`:843`),
  risk register with "pre-authorized fallback / cut line" column
  (`:956-969`), Definition of done (`:971`), explicitly out of scope
  table (`:1005-1024`).
- **09-PLAYBOOK.md**: work loop with gate table (`:12-40`), repo
  conventions operationalized (`:56`), required code idioms (`:103-459`),
  ported-code rules (`:460`), per-PR definition of done checklist
  (`:502-533`), hard "never" rules (`:535`), GLM review policy (`:580`),
  "when stuck" (`:627-664`).

Recommended structure for the new product's plan: the same 00 (decision
log), 01 product, 02 UX, 03 architecture, a "04 suite integration"
chapter (shared server list package, record kinds, seance_core changes
and their sequencing), feature chapters (observability, Docker), 07
milestones (M1 = scaffold *and* full suite registration), 08 testing
(fixtures), 09 playbook (link to Poltergeist's rather than copy
idioms that apply verbatim).

---

## 3. History checker constraints for a new product directory

- `scripts/check-history.py:28-29` requires `preservationCommit`
  (`39ec91564927b63b7ff3bc349c932749d9887661`, `docs/history/source-refs.json:452`)
  to be an ancestor of HEAD. That stays true.
- `:33-52` iterates only `snapshot["sources"]` (`planchette`, `seance`,
  `poltergeist`; 173 + 54 + 180 refs, 0 + 13 + 4 annotated tags).
  **A brand-new product needs no `source-refs.json` entry, and must not
  get one:** `:35-36` would compare `rev-parse <preservation>:<prod>`
  (a path that does not exist at the preservation commit) with a
  recorded tree and fail.
- If the product were first prototyped in a **separate repository**
  and later imported with history, format 1 cannot express it. There is
  one global `preservationCommit`, and every source's tree must match it
  (`:35`). The other three trees have since diverged, so a second import
  would need a format-2 manifest (per-source preservation commit) and
  matching edits to `check-history.py:12, 25-36`, `docs/history/README.md`,
  and the `.gitleaks.toml` dual-path convention (`.gitleaks.toml:1-5`).
  **Recommendation: build greenfield inside `<prod>/` from day one.**
- Import-era rules that do not apply to a greenfield product: "Do not
  squash the initial migration PR" and old-root-path commits
  (`AGENTS.md:52-55`). `.gitleaksignore` pins commit:path pairs; do not
  rewrite history.
- CI runs the checker in `contracts` with `fetch-depth: 0`
  (`ci.yml:55-67`) and in the release gate (`release.yml:194-198`), and
  `check-workflows.sh:171-180` enforces both. A new product changes none
  of this.

---

## 4. Recommended directory layout

```
<prod>/
  AGENTS.md                 product guide + byte-identical shared-rules block
  CLAUDE.md                 "start with AGENTS.md" + PR babysitting block
  README.md                 exactly one <!-- version -->1.9.0<!-- /version --> marker
  CHANGELOG.md              "## Unreleased" first
  LICENSE                   Unlicense (copy of root)
  analysis_options.yaml
  dart_test.yaml            (optional; Planchette/Poltergeist have one)
  .gitignore
  pubspec.yaml              name: _<prod>_workspace, publish_to: none, NO version,
                            workspace: [packages/<prod>_core, ...]
  pubspec.lock              committed (lock pins re-written by release tool)
  packages/
    <prod>_core/            pure Dart, resolution: workspace, version: 1.9.0
                            (host/metric collectors, parsers, docker-over-SSH client,
                            consumes seance_core by ../../../seance/packages/seance_core)
    <prod>_<feature>/       further pure-Dart packages as the plan decides
  app/
    <prod>_app/             Flutter app, NOT a workspace member, version 1.9.0+1090099
      android/ ios/ linux/ macos/ windows/   committed, identities per section 1.9
  docs/
    plan/                   00-OVERVIEW (decision log) ... 09-PLAYBOOK
    STATUS.md
    INSTALL.md              first-launch steps (Gatekeeper/SmartScreen/IPA re-sign)
  scripts/
    build.sh                app | apk | flatpak, --debug, --install
    release.sh              8-line forwarder to ../../scripts/release.sh
    package-linux.sh        (or a thin wrapper over a new shared scripts/ helper)
    build-flatpak.sh        sources ../scripts/flatpak-repack.sh
    test-macos-keyboard.sh  + test-macos-keyboard.mm (#include root fixture)
    check-imports.sh        if a per-product import guard is adopted
  flatpak/
    ch.lkmc.<prod>.yml
  media-sources/
    <prod>-icon.png         1024x1024 master
  test/integration/         (optional) docker-compose fixture: sshd + dockerd,
                            frozen base images, key-scope assertion
  tool/                     (optional) product guards; prefer generalizing
                            poltergeist/tool/import_guard to root tool/ instead
```

Shared, cross-product additions belong outside `<prod>/`. Put the
server-list/editor UI package next to `ghost_marks` in
`planchette/packages/` (that is where all shared Flutter packages live
today, `scripts/test.sh:141-147`), put a design doc in `docs/design/`,
and land any SSH/exec/docker helpers that Séance and Poltergeist could
use in `seance/packages/seance_core`.

---

## 5. Risks

### 5.1 CI time and cost
- Measured per main run (2026-10-09): 124.0 job-minutes. Client legs
  sum to Planchette 16.2, Séance 22.7 and Poltergeist 27.3 minutes; app
  flutter jobs take 3.2-9.2 minutes. A five-platform fourth product adds
  roughly **+25-30 client minutes, +3-9 flutter minutes and +1-10 Dart
  minutes, about +30-45 job-minutes (+25-35%)**. Every PR pays this,
  because client jobs have no path filters (section 1.3).
- **macOS concurrency:** each CI run today has 7 macOS jobs
  (`planchette_core` macOS, `poltergeist_dart` macOS, Planchette macOS,
  Séance macOS and iOS, Poltergeist macOS and iOS). The new product adds
  2 (macOS, iOS), or 3 with a macOS core matrix, giving 9-10. GitHub's
  cap is 5 concurrent macOS jobs on Free/Pro/Team (docs fetched today),
  shared across concurrent PRs, so wall-clock time grows even though
  minutes on a public repo are (per GitHub billing, not re-verified)
  free.
- Mitigation options to evaluate (each needs a decision, because CI
  currently compiles everything on every PR on purpose, `ci.yml:985-990`):
  a `detect_<prod>` paths filter for the new client matrix (pattern
  `ci.yml:339-395`) that still runs on main/dispatch; a single-OS pure-Dart
  job unless the core has platform-dependent logic.

### 5.2 Release matrix
- Clients go from 13 to 18, manifest assets from 25 to 33, release macOS
  legs from 6 to 8. The v1.9.0 release took about 23 min wall and 93.1
  job-minutes; expect about 115-120. The `flutter` gate (14.5 of 45
  allowed minutes) and `test` gate (10.1 of 30) stay within their
  timeouts.
- More legs mean a higher chance that one flaky leg fails the whole
  atomic publish. Recovery is "delete the release, never the tag"
  (`release.yml:16`, `:117-128`). Three v1.9.0 attempts were needed
  (runs 37185141913, 37199904467 failed; 37205118744 succeeded).
- Forgetting W5/W6 (`needs:`) would let the GHCR image and the public
  release publish without the new client's assets. Check 3 catches only a
  missing *manifest* entry, and check 11 must be extended manually (S9).
- A server-side companion (agent binary or container) would add a
  `server`-style matrix and manifest entries (pattern `release.yml:352-425`,
  manifest `:141-145`), and possibly a second GHCR image. That requires
  extending `check-workflows.sh:208-228`, which allows `packages: write`
  in exactly one job. An agentless (SSH-only) v1 avoids all of it.

### 5.3 Release tool and history
- Silent unmanaged state if `_projectNames` is not updated (R1); hard
  `check` failure if `_defaultProducts` is updated before the scaffold
  (R3). Land both with the M1 scaffold PR together with fixture updates
  R5-R12, or `suite_tool` goes red.
- History checker: no risk for greenfield; a format change is needed only
  for an external-history import (section 3).

### 5.4 Guard coverage gap
- Import boundaries ("only the connection module touches dartssh2",
  "pure-Dart packages never import Flutter"), the local-dependency rule
  and fixture-key scoping are enforced only under `poltergeist/`
  (section 1.5). A new product would merge without them unless the plan
  schedules generalization early (ideally M1).

### 5.5 Duplication pressure
- `package-linux.sh` (~500 lines) and the server editor/list UI (~1300-1500
  lines per app) would become third/fourth copies if cloned, which
  contradicts `AGENTS.md:5`. Extract first, or record the copy
  explicitly with a follow-up.
- Existing identity inconsistencies (Windows `CompanyName`, exe names,
  Séance's legacy Flatpak id) make "copy the closest sibling" ambiguous.
  The plan should fix the new product's identity table up front (section 1.9).

### 5.6 Shared-package churn
- Changes to `seance_core`/`seance_protocol`/`planchette_core` made for the
  new product trigger Poltergeist's integration and bench detectors
  (`ci.yml:362-369`, `:513-520`) and the Séance pin audit (`:304-314`).
  Expect extra CI work and occasional `audit-seance-pin.sh --write-record`
  commits. New `RecordKind`s are safe for older clients (`record.dart:16-21`),
  but adding a kind changes the shared protocol package that every app and
  the server compile.

### 5.7 Platform-sandbox decisions
- Remaining unsandboxed on macOS is the suite norm, but its cost is
  "real and permanent" (`seance/AGENTS.md:136-145`). The Flatpak
  `finish-args` (`--filesystem=home` etc.) should be chosen per product,
  not copied from Poltergeist. iOS/Android background limits matter for
  monitoring (alerts) and must be named in the plan, as Poltergeist did
  with D35.
