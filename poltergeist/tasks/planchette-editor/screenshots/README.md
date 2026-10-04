# Shared editor adoption captures

The before and after PNGs use the same dummy `.env.local` document, search query,
1100 × 760 logical viewport, and light/dark themes. PNGs are rendered at 2×.

- Before: Poltergeist commit `7003e37a`, with the capture test temporarily copied
  into the otherwise unchanged checkout. The source test was restored afterward.
- After: the shared Planchette editor integration, including the line-number
  gutter and localized replacement controls. The replacement is entered but
  not applied, so document text is identical to the baseline.

The baseline has a find bar but no replace controls. The same capture test uses
`POLTERGEIST_CAPTURE_BASELINE=1` for that run to skip opening controls which did
not exist yet.

These are real-font Flutter widget-test renders of editor content and the
fallback menu, not native macOS window screenshots. They do not include native
window chrome. Flutter 3.47.3 loads the installed Arial, Arial Bold, and Courier
New faces through the capture harness's DejaVu aliases; icons come from the SDK.

Run from `app/poltergeist_app` with `POLTERGEIST_CAPTURE=1`, an absolute
`POLTERGEIST_CAPTURE_DIR`, the font directory in `POLTERGEIST_CAPTURE_FONT_DIR`,
and `FLUTTER_ROOT` pointing to the SDK:

```sh
flutter test test/ui/built_in_editor_capture_test.dart \
  --plain-name 'captures shared editor search and replace in both themes'
```
