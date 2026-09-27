/// Platform-agnostic core for Planchette, the cross-platform text editor.
///
/// Scaffold only — the document model, editing operations, and file handling
/// land here so the Flutter app in `app/planchette_app` stays a thin shell.
/// Nothing in this package may import `dart:io`'s UI-adjacent surfaces or
/// `package:flutter/*`: it must stay JVM-free, testable with plain
/// `dart test` on any host.
library planchette_core;
