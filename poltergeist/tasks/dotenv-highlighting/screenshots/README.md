# Dotenv highlighting captures

These PNGs show the same `.env.local` sample in light and dark themes.
All assignments contain dummy values. The sample covers bare and empty values,
`export`, single and double quotes, quoted hashes, multiline values, and comments.

- `before/`: baseline commit `594fbc13a3defa7d3a5f80d208ac6555c0c924ca`,
  rendered in an isolated managed worktree with only the capture test copied in.
- `after/`: the dotenv-highlighting changes in this task.

Both runs use the identical `captures dotenv highlighting in light and dark
themes` test in `app/poltergeist_app/test/ui/built_in_editor_capture_test.dart`.
The logical viewport is 1100 × 760, rasterized at 2× to 2200 × 1520 PNGs.
Flutter is 3.47.3 on macOS. The actual fonts are the installed Arial, Arial Bold,
and Courier New faces, supplied under the existing harness's DejaVu font aliases.
Material icons come from the Flutter SDK.

These are real-font Flutter widget-test renders of editor content and its
fallback menu, not native macOS window screenshots. Native title bars and OS
menus are outside the captures.

Run from `app/poltergeist_app` with `POLTERGEIST_CAPTURE=1`, an absolute output
directory in `POLTERGEIST_CAPTURE_DIR`, the font directory in
`POLTERGEIST_CAPTURE_FONT_DIR`, and `FLUTTER_ROOT` set to the installed SDK:

```sh
flutter test test/ui/built_in_editor_capture_test.dart \
  --plain-name 'captures dotenv highlighting in light and dark themes'
```

The font directory needs `DejaVuSans.ttf`, `DejaVuSans-Bold.ttf`, and
`DejaVuSansMono.ttf`; this run used symlinks to the installed faces listed above.
