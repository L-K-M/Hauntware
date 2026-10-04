Unicode 17.0.0 simple case folding uses `CaseFolding.txt` statuses C and S.
Full folding uses C and F. T tailoring is excluded, and unlisted code points
stay unchanged.

Sources:

- [CaseFolding.txt](https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt),
  retrieved 2026-09-12
- [DerivedCoreProperties.txt](https://www.unicode.org/Public/17.0.0/ucd/DerivedCoreProperties.txt),
  retrieved 2026-09-28
- [Unicode license](https://www.unicode.org/license.txt), retained in `LICENSE.txt`

The package-level `LICENSE` includes the Unicode notice for bundled clients.

`CaseFolding-17.0.0.txt` is verbatim. Its SHA-256 is
`ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`.
`DefaultIgnorable-17.0.0.txt` retains the source's 27
`Default_Ignorable_Code_Point` rows verbatim. The full source SHA-256 is
`24c7fed1195c482faaefd5c1e7eb821c5ee1fb6de07ecdbaa64b56a99da22c08`;
the extract SHA-256 is
`fdfaaeddf73e63079c237c9e5f8c1a4be88391de0d8b3974093fad6f694c8a1f`.

Regenerate offline from the repository root:

```sh
dart run packages/poltergeist_core/tool/unicode/generate.dart
dart test packages/poltergeist_core/test/browse/unicode_simple_fold_test.dart
```

The generator verifies both fixture hashes, combines adjacent simple mappings
with equal offsets at stride 1 or 2, and emits full-fold and default-ignorable
tables. Tests compare every Unicode scalar against the fixtures, including
unmapped gaps.
