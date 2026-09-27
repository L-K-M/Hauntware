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
| Planchette app | Local document tabs, native menus, Open/New/Save/Save As, file-open events, and application close/quit |
| Host applications | Their own windows/tabs, localized chrome, remote sessions, managed working copies, uploads, conflict resolution, and notifications |

The dependency direction is app → Flutter editor → pure Dart core. The core
has no SSH or application dependency, and the editor has no native window
manager. A remote document remains a managed local working copy owned by its
host; no second virtual filesystem is introduced.

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

## Distribution and development

Planchette keeps both packages and its app in one repository. Local app
development uses relative package paths. Consumers pin both shared packages
to the same reviewed Git revision and commit their lockfiles. A package
update is validated in both host apps before merging the adoption PRs.

The first standalone app targets macOS, Windows, and Linux with one tabbed
document window. Its files are local; it has no network service, account,
telemetry, or updater. The shared Flutter surface stays usable in the host
apps' existing mobile flows.
