// What the app shows about itself beside its fixed identities (04 §12.3).

/// The preview label of decision 16 (04 §12.1 and §12.3; 03 §11.7), shown
/// after the display name until v1: in the app title (the `appTitle` ARB
/// value, so the About dialog and Settings > General's about row) and in
/// the Linux package description (`scripts/package-linux.sh`). Tests tie
/// each of them to this constant, which is never displayed by itself.
///
/// The label is not an identity: the display name, the bundle and
/// application ids, `CFBundleName`, the keystore names and every other
/// value of 04 §12.3 stay as they are. That is why the app's own About
/// dialog replaces AppKit's About panel, which shows `CFBundleName`. M7
/// drops the label in one change: this constant, the ARB value and the
/// package description.
const String kPreviewLabel = '(preview)';
