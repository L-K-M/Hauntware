# D22 bookmark-import evidence

These Flutter widget captures show the shared import preview with existing
`ssh_config` data and a FileZilla `sitemanager.xml` export. They use the dark
production theme, DejaVu Sans, a 1400 x 900 logical-pixel viewport, and DPR 1.

Regenerate them with:

```bash
cd app/poltergeist_app
POLTERGEIST_CAPTURE=1 flutter test test/ui/quick_open_capture_test.dart
```

The captures prove layout and displayed import verdicts. Parser, security,
dedupe, cancellation, and persistence behavior are covered by automated tests.
