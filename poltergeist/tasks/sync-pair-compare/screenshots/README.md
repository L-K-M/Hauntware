# Sync-pair compare captures

Captured on Linux with Flutter 3.47.2 from widget tests at 1200×720 logical
pixels and 2× output. The light production theme uses DejaVu Sans and DejaVu
Sans Mono from the host plus Flutter's Material Icons.

- `before-sync-pair-compare.png`: the existing two-file sync-plan row before
  double-click.
- `after-sync-pair-compare.png`: the resulting locked, independent editors,
  metadata headers, and BOM/line-ending notices.

The fixtures use temporary local files with deterministic contents. Recreate
the captures from `app/poltergeist_app`:

```bash
POLTERGEIST_CAPTURE=1 \
POLTERGEIST_CAPTURE_DIR="$PWD/../../tasks/sync-pair-compare/screenshots" \
FLUTTER_ROOT=/home/paseo/opt/flutter \
flutter test test/ui/sync/sync_plan_view_test.dart \
  --plain-name 'double-clicking a two-file row opens compare'

POLTERGEIST_CAPTURE=1 \
POLTERGEIST_CAPTURE_DIR="$PWD/../../tasks/sync-pair-compare/screenshots" \
FLUTTER_ROOT=/home/paseo/opt/flutter \
flutter test test/ui/compare_view_test.dart \
  --plain-name 'shows two locked editors with independent find bars'
```
