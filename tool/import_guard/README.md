# Dependency guard

Run `dart pub get` at the repository root and `dart pub get` in each
configured product, then `dart run tool/import_guard/bin/check.dart` from
the root. The check covers every product in `tool/guards.yaml`; pass
`--product <name>` to check just one. `poltergeist/scripts/check-imports.sh`
forwards to this entrypoint for the `poltergeist` product and also accepts
invocation by absolute path. CI analyzes and tests the guard with explicit
`tool/import_guard` paths.

Run `dart test tool/import_guard/test` from the checkout root after
`dart pub get`. The CI target is
Linux; the shell fixtures require Bash and permission to create symlinks.

Per product, the guard parses import/export directives, including
conditional branches and escaped literals, in the configured scan areas
(Séance, Planchette and Poltergeist: `packages/` and `app/`). Only the
configured import areas may reference `package:dartssh2` — for example
Poltergeist's core connection module and its M0 bench package, plus the
files named in `import_exemptions`. Configured pure-Dart packages cannot
reference `dart:ui`, `dart:ui_web`, Flutter packages, or plugins.

Beyond imports, the guard enforces the product's `no_dart_io` directories
(no `dart:io`, conditional imports included), the
`seance_core_implementation_imports` allowlist (`package:seance_core/src/...`
is a violation everywhere else in the product), and
`forbidden_dependencies` (a package-name or glob map, checked against each
scanned package's pubspec dependencies and Dart imports, and walked
transitively through resolved packages). Every matching key's forbidden
list applies, so `ghost_ui` inherits both a `ghost_*` entry and its own.

Plugin classification uses the product's resolved package configuration
(`<product>/.dart_tool/package_config.json`) and each dependency's pubspec:
`flutter.plugin`, `environment.flutter`, or a Flutter SDK dependency.
Standalone resolutions named in `tool/guards.yaml` (Poltergeist's
`poltergeist_bench`) resolve through their own package config. Runtime
dependencies propagate that classification;
external development dependencies do not. Local dependencies, development
dependencies, and overrides are checked even when unused. No app dependency
resolution or network access is needed.

Known Flutter SDK package names are diagnosed directly when absent from
pure-Dart resolution. Other package names require resolved metadata.

Missing, malformed, or linked scan inputs fail closed. Project-root generated
directories (`.dart_tool`, `build`, `.symlinks`, `ephemeral`, `.git`) and
known native build, Flutter cache, and Apple `Pods` locations are excluded.
Directories with those names inside source trees remain covered, as does a
package named `build`. Directories outside the configured scan areas
(Poltergeist's `tool/`, which holds its tooling) are not scanned. The
sanctioned M0 harness is a configured standalone resolution. This checks
package directives
and dependency metadata; normal Dart analysis still validates library access
and types.
