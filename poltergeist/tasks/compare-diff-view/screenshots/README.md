# Minimal diff view captures

Captured on Linux with Flutter 3.47.2 from widget tests at 2× output, in
the light production theme with DejaVu Sans and DejaVu Sans Mono from the
host plus Flutter's Material Icons.

- `compare-diff-side-by-side.png`: 1200×720. One changed line, with the
  line-ending and BOM chips, the change bar and both side headers.
- `compare-diff-unified.png`: 1200×720. Unified, with a region's two
  removed lines above its added line.
- `compare-diff-compact.png`: 390×844, Android posture. Unified by
  default, with the change bar on two lines and icon-only layout buttons.

The fixtures use temporary local files with deterministic contents.
Recreate the captures from `app/poltergeist_app`:

```bash
for name in 'shows aligned rows' 'unified lists left-only' \
    'compact posture defaults'; do
  POLTERGEIST_CAPTURE=1 \
  POLTERGEIST_CAPTURE_DIR="$PWD/../../tasks/compare-diff-view/screenshots" \
  POLTERGEIST_CAPTURE_FONT_DIR=/usr/share/fonts/truetype/dejavu \
  FLUTTER_ROOT=/opt/flutter \
  flutter test test/ui/compare_view_test.dart --plain-name "$name"
done
```

The first test also writes `after-sync-pair-compare.png`, the Separate
layout; that capture belongs to `../../sync-pair-compare/screenshots/`.
