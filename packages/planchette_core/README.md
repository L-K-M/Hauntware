# Planchette core

Pure Dart document I/O, language detection, syntax tokens, search ranges,
and text metrics shared by Planchette, Poltergeist, and Séance.

`loadTextDocument` reads strict UTF-8 with a 4 MiB default cap. Its snapshot
records the resolved file, text, UTF-8 BOM, dominant line ending, and digest.
The default editing buffer uses LF. `TextNormalization.preserve` retains
raw line endings for host compatibility. Only the first leading BOM is
metadata; additional U+FEFF characters remain document content.

Managed files use `SymlinkPolicy.reject`. User-selected local files may use
`resolveOnce`; retain the returned `file` when saving so later changes to a
link do not redirect the document.

`saveTextDocument` requires the expected on-disk SHA-256 and replaces an
existing regular file. `createTextDocument` exclusively publishes a new
file after all bytes are written and flushed. Neither follows a destination
symlink. A failed save never authorizes advancing the caller's document
identity, saved text, or baseline. Both return the digest of committed bytes.
Hosts supply `.poltergeist` or `.seance` as `temporaryPrefix` so their recovery
and cleanup rules continue recognizing temporary and backup siblings.

POSIX temporary content is owner-only before writing. Replacements retain
the original permission bits. The replacement protocol has a brief missing
path interval and provides best-effort conflict detection, not a lock against
other writers. Native no-replace publication prevents overwriting a newly
created destination during publication or rollback. If another writer blocks
rollback, the error identifies the backup retained for recovery.

Android uses hard-link publication because older supported releases do not
export the desktop Linux no-replace rename API. This requires a filesystem
that supports hard links. If source cleanup fails after publication, neither
destination nor original is removed by the native helper; the error reports
both paths so the host can recover without deleting a concurrent writer's
replacement. A create can therefore report this exceptional cleanup failure
after the complete destination has appeared.

Syntax tokens and `TextMatch` use half-open UTF-16 offsets. They contain no
Flutter styles or ranges; presentation belongs to `planchette_editor`.

Run `dart pub get`, `dart analyze`, and `dart test` here. The native save tests
run on each desktop platform; tests that create symlinks skip Windows because
creating links there can require privileges.
