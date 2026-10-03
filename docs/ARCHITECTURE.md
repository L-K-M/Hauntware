# Shared editor architecture

Planchette is both a standalone text editor and the source of the editor
packages embedded by [Poltergeist](https://github.com/L-K-M/Poltergeist) and
[Séance](https://github.com/L-K-M/Seance). This extraction was requested by
the owner on 2026-09-27 so improvements reach all three applications through
versioned dependency updates.

## Ownership

| Layer | Owns |
|---|---|
| `planchette_core` | Language detection, tokenization, search ranges, document encoding metadata, bounded loading, guarded local-file writes |
| `planchette_editor` | Editing state, highlighting, search and replace, gutter, status, focus, editing surface, and shared save/close contracts |
| `ghost_ui` | Shared leaf UI primitives: family hues, WCAG contrast math, middle-ellipsis text, top toasts, the sidebar kit, ghost menus, and the file-list presentation helpers |
| `ghost_desktop` | Desktop window lifecycle shared by all three apps: remembered frame, missing-monitor policy, maximized/full-screen restore, and the intercepted close path behind host-owned adapters |
| Planchette app | Local document tabs, native menus, Open/New/Save/Save As, file-open events, and application close/quit |
| Host applications | Their own windows/tabs, localized chrome, remote sessions, managed working copies, uploads, conflict resolution, and notifications |

The editor depends on `planchette_core` and `ghost_ui`; apps also consume
`ghost_ui` directly. Core and UI have no SSH or application dependencies.
Shared UI publishes widgets and plain presentation models; the editor has
no native window manager.
`ghost_desktop` keeps the same leaf rule: it depends on Flutter plus the
window_manager/screen_retriever plugins and declares the adapter interfaces
each host satisfies — persistence, close policy, monitor fallback and show
trigger stay host choices.
A remote document remains a managed local working copy owned by its
host; no second virtual filesystem is introduced.

`ghost_ui` owns the generic ghost menus that used to live in
`planchette_editor`; the editor re-exports them from their old location so
existing imports keep working. The sidebar kit reads its chrome through the
`SidebarThemeTokens` `ThemeExtension` instead of a host chrome class: each
host installs one on its `ThemeData`, copying its existing resolved tokens
field-for-field (`sidebarBackground`, `separator`, `hoverFill`,
`capsuleFill`, `inactiveSelectionFill`, `secondaryText`,
`sidebarRowExtent`, `cornerScale`; `corner(base)` multiplies a radius by
`cornerScale`). With no extension installed the kit falls back to the same
slate/Finder neutrals the hosts' own `Chrome.of` defaults resolved to.

File lists use `GhostFileRow` on desktop and `GhostFileCompactRow` on touch,
with shared columns, kind glyphs and formatting. Hosts project filesystem
entries into `GhostFileItem`, provide `GhostFileTheme` tokens and localized
strings, and retain selection, gestures, drag payloads and file operations.

## Compatibility

The extraction starts from Poltergeist `c43b5411` and Séance `6a1a3301`.
Poltergeist contributes dotenv support and localized/window-host integration.
Séance contributes the line-number gutter, caret/document status, and the
remote-change adapter. Host wrappers retain their public entry points while
the reusable implementation moves here.

Application themes and strings are injected. Both applications retain their
existing save/upload and dirty-close behavior. Native menus and session-owned
remote state stay in their applications.

## File handling

The editor remains a bounded UTF-8 text editor: a 4 MiB file limit and a
200,000-character highlighting limit. BOM and dominant line-ending metadata
survive saves; mixed line endings are normalized according to the existing
document policy, rather than claimed to be preserved individually.

User-selected local symlinks may be resolved once at open. Managed copies
must be regular files and reject symlinks. Saves use the resolved identity,
guard the expected on-disk digest, and preserve original permission bits.
Temporary plaintext is owner-only before writing on POSIX. Each host retains
its temporary-file prefix so its recovery and cleanup rules still recognize
editor leftovers.

The desktop app checks open files when its window regains focus. A file's
size and modification time decide whether it is worth hashing; the digest
decides whether it changed. A document without edits takes the new version
through the same install as Revert to Saved, a document with edits keeps
its text until the user reloads or keeps it, and keeping it adopts the
digest found on disk as the next save's guard. A missing file is recreated
with exclusive creation, so a file that reappeared is never overwritten.

These filesystem checks are best-effort conflict guards, not a cross-process
lock. The current two-rename replacement has a brief missing-path interval.
The migration must not describe it as a transaction with other applications.

Android uses exclusive hard-link publication for compatibility with older
system libraries. Its filesystem must support hard links. If publication
succeeds but removal of the source fails, both names are retained and the
error identifies them for recovery; a complete destination can exist even
though that exceptional cleanup failure is reported.

New files and Save As have explicit create/replace contracts. A canceled or
failed save does not change a document's identity or erase its dirty state.
The save baseline advances only for the text revision actually written;
later edits remain unsaved.

The controller owns pending `TextDocumentMetadata` independently of a file
path, so untitled buffers can choose an ending and BOM. Dirty state compares
both text and metadata with the load/last-save baseline. File-format choices
do not rewrite the buffer or join text undo; indentation is a view/editing
preference and is not dirty state.

Save cleanup is opt-in through `TextSaveOptions`. It uses core span edits,
maps the selection and changes the live buffer before the guarded write, so
the cleanup is undoable and cannot leave hidden disk-only changes. A failed
write keeps the cleanup visible and unsaved. Hosts preserving raw EOLs pass
`TextNormalization.preserve` to the controller as well as their file APIs;
this determines Normalize Line Endings and final-newline insertion.

## Distribution and development

Planchette keeps all three packages and its app in one repository. Local
app development uses relative package paths. Consumers pin the shared
packages to the same reviewed Git revision and commit their lockfiles. A
package update is validated in both host apps before merging the adoption
PRs.

The first standalone app targets macOS, Windows, and Linux with one tabbed
document window. Its files are local; it has no network service, account,
telemetry, or updater. The shared Flutter surface stays usable in the host
apps' existing mobile flows.
