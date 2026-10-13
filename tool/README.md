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

- `import_guard` confines `dartssh2` and Flutter/plugin imports per the
  product's entry (`tool/import_guard/README.md`).
- `protocol_guard` keeps function-typed fields out of the engine protocol
  types (`tool/protocol_guard/README.md`).
- `license_gate` verifies the `SEANCE_LICENSE_GATE_V1` release wiring and
  that every `seance_*` dependency resolves as a licensed local path pin.
  `--marker-only` checks the wiring without resolving the SPDX texts.
  `poltergeist/scripts/check-imports.sh` forwards to the import guard for
  the `poltergeist` product.

Without `--product`, the import and protocol guards check every configured
product; today only `poltergeist` is configured. Reported paths are
repository-root-relative, so they carry the product directory as a prefix.
