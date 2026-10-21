# Theme paste fixtures (X-01)

Each file is the exact text Copy theme puts on the clipboard in a sibling
app: `JsonEncoder.withIndent('  ')` over the palette's `toJson`, which
Séance writes through `ghost_theme`'s Appearance section and Poltergeist
through its own `ThemePalette`. `theme_paste_fixtures_test.dart` pastes
each into Klabautermann's codec and Appearance tab.

| File | App | Palette |
|---|---|---|
| `seance-terminal.json` | Séance | `ThemePresets.terminal`, with its terminal colours |
| `seance-custom.json` | Séance | `ThemePresets.solarized` with the font `JetBrains Mono`, relabelled Custom |
| `poltergeist-vapor.json` | Poltergeist | `ThemePresets.vapor` |
| `poltergeist-custom.json` | Poltergeist | `ThemePresets.midnight` with the font `Fira Code` and corners at 1.5, relabelled Custom |

To regenerate one, run a test in that app that writes
`const JsonEncoder.withIndent('  ').convert(palette.toJson())` to the
file, with the palette built as the table says, and review the diff.
