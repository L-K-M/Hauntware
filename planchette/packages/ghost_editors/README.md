# ghost_editors

The external editor registry shared by Poltergeist and Séance: which
applications can open a remote file's checkout, which one a default open
uses (globally and per extension), how that choice persists, and the
Settings section that edits it.

## What it owns

- `ExternalEditorDefinition`, `EditorHostPlatform`,
  `currentEditorHostPlatform` and the id/target validators, and the
  extension and display-name rules the registry and its edit dialog share.
- `EditorRegistry`: configured editors (at most 64), the global default,
  per-extension defaults (longest match wins, validated at read, stripped
  when an edit or removal orphans them) and `effectiveDefaultFor`.
- `EditorRegistryScheme`: what makes each app's registry its own. Selectors
  are app-neutral in memory (`EditorRegistry.systemDefaultId`,
  `EditorRegistry.builtInId`) and persist as `<namespace>.system` and
  `<namespace>.builtin`; the scheme also sets the written format version,
  the default selector, whether the whole namespace is reserved, and the
  migrations every stored document passes through before it is decoded.
- `GhostEditorLauncher`: `openWith` and `pickEditor` over the app's own
  runner channel (`openWithApplication`, `pickApplication`) on macOS and a
  detached process on Linux and Windows, never a shell.
- `GhostEditorsSettingsSection` over an `EditorRegistryModel`, with the
  app's strings in `GhostEditorsStrings`.

## What hosts keep

- Persistence (where the document lives, rollback on a failed write) and
  their scheme and migrations.
- The runner channel name and the System default launch, including the
  refusal to hand the OS a file it would run as a program.
- Built-in editor routing beyond the selectors (size limits, content
  checks) and every user-facing string.

| App | Namespace | Version | Default | Reserved | Migrations |
| --- | --- | --- | --- | --- | --- |
| Poltergeist | `poltergeist` | 1 | System default | whole namespace | none |
| Séance | `seance` | 2 | built-in editor | selectors only | version 1 System default to built-in; legacy `remoteFileEditor: bbedit` |
