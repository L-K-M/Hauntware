# Planchette Review — Analysis

Thorough review of the desktop text editor (Planchette). No code changes made yet; observations only.

## Bugs / Issues

1. Tab bar title shows untitled number (`Untitled 1`) even when a named file is open; dirty-dot (`●`) logic is present but easy to miss.
2. Empty state (`Start with a blank page`) does not show the file path when a document is open but empty; displays only the default subtitle.
3. Status bar line/column is 1-based; some editors use 0-based internally; no user preference exposed.
4. No session restoration: closing and reopening the app loses open documents.
5. No split pane / multi-cursor support.
6. `file_picker` dependency (≥11) breaks APK builds on AGP 9+ unless Kotlin workaround applied; build scripts do not enforce version pins.

## Performance

- Large files (>200K chars) skip syntax highlighting; no progressive/tokenized rendering for very large files.
- Scroll-to-match uses `TextPainter.getOffsetForCaret` which may be slow for long prefixes.
- No virtualized line rendering; entire document is one `TextField` widget.

## Missing Features

- No find/replace history.
- No word wrap toggle.
- No zoom / font size shortcut.
- No drag-and-drop file open (native).
- No printing / export to PDF.
- No dark/light theme toggle per document.
- No bookmark / jump-to-line.
- No auto-save / recovery after crash.

## Visual / Layout

- Theme is a single teal seed (`0xff245b5c`); could use more variety and better contrast in dark mode.
- Gutter width recalculates on every scroll notification via `CustomPaint`; could cause jank on fast scroll.
- Error banner (`Material` with `errorContainer`) pushes content downward abruptly; no animation.
- Menu bar (`MenuBar`) is only shown on non-macOS; macOS uses `PlatformMenuBar` which is correct but no customization of macOS-specific about/services submenus.

## Aesthetics / Theming Ideas

- Dark mode syntax colors are fine but could be more vibrant (editor-like themes: Monokai, Dracula, Solarized).
- Gutter number alignment and divider could be thinner / subtler.
- Active tab indicator (rounded top) is subtle; could add a colored underline.
- Status bar joins items with `·`; could use vertical separators (`|`) or more spacing.
- Add a subtle background texture / gradient to the empty state.

## Novel / Quirky / Delightful Ideas

- Show the SHA-256 digest briefly on save (as a subtle tooltip) — "document fingerprint" aesthetic.
- Animated dirty dot: pulse gently when unsaved (like a heartbeat).
- Typewriter sound feedback option (optional, quirky).
- "Ghost" previous version overlay when external file changed (conflict preview).
- Tab names could show file extension as a tiny colored badge (language indicator).
- A small clock or timestamp in the status bar showing when the file was last saved.
- Quirky splash / empty state message rotation (e.g., quotes about text editing).
Session restore: add workspace persistence using File-backed document registry; restore tabs on startup; retain undo stacks via IndexedStack with persistent controllers.
