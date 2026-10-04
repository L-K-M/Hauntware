# Dotenv highlighting

The editor now recognizes `.env`, `.env.*` and `*.env` on POSIX and Windows
paths. Assignment-aware scanning colors keys, `export`, comments and quoted
values, including multiline values. Bare values retain their text style.
The scanner follows the supported subset of
[Node's dotenv convention](https://nodejs.org/api/environment_variables.html#dotenv)
documented in 06 §7.1; it does not expand or execute values.

## Verification

- Before the fix, 17 of the 18 dotenv regression cases failed. They cover
  detection, exact key ranges, `export` collisions, literal bare values,
  hashes, quoting, incomplete multiline input, BOM, CRLF and Unicode offsets.
- Visual inspection found dark comments below the text contrast threshold.
  The new regression measured 3.41:1 before the palette correction and now
  requires at least 4.5:1 against both default editor backgrounds.
- All 69 tests across `dotenv_syntax_test`, `editor_syntax_test`,
  `built_in_text_editor_test` and `built_in_editor_capture_test` pass locally
  on Flutter 3.47.3. Full app analysis is clean; CI uses the 3.47.2 pin.
- Independent review exercised 20,000 randomized incomplete inputs without
  exceptions or invalid token ranges and checked linear scaling with large
  malformed inputs. It found no correctness blocker.
- The first full CI run passed 2,880 tests and found two localization-audit
  failures: the literal inventory needed the new scanner's technical strings
  and still contained the removed POSIX-only separator literal. The follow-up
  updates only those exact inventory entries, preserving both audit rules.
  All 79 combined editor/localization tests and full app analysis then pass.

## Visual evidence

The [capture provenance](screenshots/README.md) records the baseline revision,
fonts and reproduction command. These are widget renders of actual editor
code. No native window behavior is changed or claimed by these captures.

| Theme | Before | After |
|---|---|---|
| Light | [before](screenshots/before/editor-dotenv-light.png) | [after](screenshots/after/editor-dotenv-light.png) |
| Dark | [before](screenshots/before/editor-dotenv-dark.png) | [after](screenshots/after/editor-dotenv-dark.png) |

To check interactively, open `.env.local` in the built-in editor, type a
key/value pair, then add a multiline quoted value with a hash inside it.
Confirm that the hash remains string content and the next assignment is
highlighted normally. Repeat with an unquoted apostrophe, an empty value,
an inline comment and both themes.
