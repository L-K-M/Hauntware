/// The external editor registry shared by Poltergeist and Séance:
/// [ExternalEditorDefinition]s, the [EditorRegistry] with its global and
/// per-extension defaults, persisted through each app's
/// [EditorRegistryScheme] (id namespace, format version, migrations), the
/// [GhostEditorLauncher] behind an app's own runner channel, and the
/// Settings section that edits the registry over an [EditorRegistryModel].
/// Apps keep their System default launch, their persistence and their
/// strings.
library;

export 'src/editor_definition.dart';
export 'src/editor_launcher.dart';
export 'src/editor_registry.dart';
export 'src/editors_settings.dart';
