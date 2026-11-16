Unicode 17.0.0 full case folding for case-insensitive plain-text search:
`CaseFolding.txt` statuses C (`unicodeCaseFold`) and F (the expansions the
search applies before it, mapping offsets back). S and Turkic T mappings
are not part of full folding. Regular-expression search keeps Dart's own
simple folding.

Sources:

- [CaseFolding.txt](https://www.unicode.org/Public/17.0.0/ucd/CaseFolding.txt),
  verbatim in `CaseFolding-17.0.0.txt`, SHA-256
  `ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183`
- [Unicode license](https://www.unicode.org/license.txt), retained in
  `LICENSE.txt`

The package-level `LICENSE` carries the Unicode notice as a license chunk,
so every app that bundles `planchette_core` lists it on its licenses page.

Regenerate offline from `planchette/`:

```sh
dart run packages/planchette_core/tool/unicode/generate.dart
dart test packages/planchette_core/test/search_full_fold_test.dart
```

The generator verifies the fixture hash and refuses a C mapping that would
change a string's UTF-16 length or an F mapping keyed outside the BMP. The
test compares every C and F row of the fixture with the search.
