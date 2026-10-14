# Suite tooling

Tools that enforce suite-wide contracts from the repository root.
`tool/release_version` keeps every owned pubspec/app version in lockstep
with the root manifest; the guards below run per product from one shared
configuration file.

## `tool/guards.yaml`

One `products` entry per product, keyed by its top-level directory name.
Paths inside an entry are relative to that product directory. The schema
(`tool/import_guard/lib/guards_config.dart`) fails closed on unknown keys,
missing required keys, and unknown product names. Per product it declares:

- `scan`: top-level directories the guards scan for packages and sources
- `pure_packages`: package paths the pure-Dart boundary rules apply to
  (`dir/*` covers `dir`'s immediate children)
- `dartssh2_imports`: directories allowed to import/export `package:dartssh2`
- `dartssh2_dependents`: package directories allowed to declare a `dartssh2`
  dependency
- `dartssh2_dev_dependents`: package directories allowed to declare
  `dartssh2` only under `dev_dependencies`
- `import_exemptions`: single files exempt from the dartssh2 import rule
- `no_dart_io`: directories whose Dart sources must not import `dart:io`,
  including conditional imports
- `forbidden_dependencies`: a map from a package name or glob (`ghost_*`) to
  the package names or globs it must not depend on directly or transitively;
  the lists of every matching key apply
- `seance_core_implementation_imports`: directories allowed to import
  `package:seance_core/src/...`; every other file in the product that does is
  a violation
- `standalone_resolutions`: packages resolving through their own
  `.dart_tool/package_config.json` outside the product workspace lock
- `engine_protocol`: the engine protocol directory (`null` when the product
  has none)
- `engine_protocol_callback_owners`: engine files allowed to hold
  function-typed fields, mapped to the internal classes that may hold them

## Guards

All commands run from the repository root after `dart pub get` here and
`dart pub get` in the product being checked. Each guard resolves a product
through `<product>/.dart_tool/package_config.json`; a missing resolution
fails closed with a `dart pub get` hint.

```sh
dart run tool/import_guard/bin/check.dart [--product <name>]
dart run tool/protocol_guard/bin/check.dart [--product <name>]
dart run tool/license_gate/bin/check.dart [--marker-only]
```

- `import_guard` confines `dartssh2`, `seance_core` implementation imports and
  Flutter/plugin imports per the product's entry, and enforces the product's
  `no_dart_io` and `forbidden_dependencies` rules
  (`tool/import_guard/README.md`).
- `protocol_guard` keeps function-typed fields out of the engine protocol
  types (`tool/protocol_guard/README.md`).
- `license_gate` verifies the `SEANCE_LICENSE_GATE_V1` release wiring and
  that every `seance_*` dependency resolves as a licensed local path pin.
  `--marker-only` checks the wiring without resolving the SPDX texts.
  `poltergeist/scripts/check-imports.sh` forwards to the import guard for
  the `poltergeist` product.

Without `--product`, the import and protocol guards check every configured
product: `seance`, `planchette`, `poltergeist` and `klabautermann`. Reported
paths are repository-root-relative, so they carry the product directory as a
prefix.

## `tool/l10n_contract`

The shared localization contract scanner (03 §3.5 F1b), extracted from
Poltergeist's app-local `localization_contract_test.dart` so a second app
reuses it instead of copying it. It is a standalone pure-Dart package
(its own `pubspec.yaml`, `publish_to: none`, no Flutter), so it resolves
and runs in place, independently of the root `dart pub get`:

```sh
cd tool/l10n_contract && dart pub get && dart analyze && dart test
```

`LocalizationContract` takes an app root, an `L10nContractConfig`
(generated localization prefix, generated Dart suffixes, scanned
directories) and a per-file technical-literal allowlist, and returns
typed `L10nFinding`s: disallowed literals, unparseable sources and dead
allowlist entries. An empty scan is the contract's success verdict.
Apps consume it as a path `dev_dependency` and keep their own allowlist
as data; the scanner itself never depends on `package:test`.
