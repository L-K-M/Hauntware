# File-list keyboard controls

## Inventory and defects

| Surface | Implementation | Findings before this change |
| --- | --- | --- |
| Poltergeist desktop, local and SFTP, either pane | `poltergeist/app/poltergeist_app/lib/ui/panes/pane_view.dart`, `pane_commands.dart`, `../workspace_shell.dart` | Arrows, anchored Shift selection, Home/End, outline Left/Right, type-ahead and platform file commands already existed. Opening a sidebar favorite activated the destination pane but left focus on the sidebar. Arrow keys then navigated sidebar rows instead of files. Page navigation was missing. Cmd-Up/Down depended on the surrounding command registry rather than the listing's own handler. Keypad Enter was missing from normal activation. |
| Poltergeist compact browser | `poltergeist/app/poltergeist_app/lib/ui/compact/compact_listing.dart` | Touch gestures existed, but the listing had no hardware-keyboard handler. |
| Séance session Files, including the pushed Files screen | `seance/app/seance_app/lib/ui/files_pane.dart` | Desktop arrows, Shift selection, Enter, Space, select-all and context menus existed. Modified arrows incorrectly moved selection, so Cmd-Up/Down did not navigate. Home/End, page navigation and parent-folder commands were missing. Empty folders unmounted the listing's focus node. Compact rows had no keyboard handling. |
| Planchette local and remote folder workspace | `planchette/app/planchette_app/lib/widgets/folder_browser.dart` | Only Up/Down and Enter were bound. An initial Up selected the first row instead of the last. Movement ignored the disabled/loading state and did not reveal offscreen selections. Parent-folder and boundary/page commands were missing. |
| Klabautermann disk-space explorer | `klabautermann/app/klabautermann_app/lib/ui/disk_explorer.dart` | Folder activation was pointer-only, without a keyboard cursor. This is a read-only directory drill-down, not a file editor or transfer browser. |

The common navigation vocabulary and bounded cursor/scroll calculations live in
`planchette/packages/ghost_ui/lib/src/ghost_file_list_keyboard.dart`. Hosts keep
ownership of file operations, selection models, loading state and root boundaries.

### Other file-related surfaces

- Poltergeist's Quick Open palette is a command/location search, not a directory
  listing. It already owns its result navigation and Enter modifier actions.
- Poltergeist's sync-plan table has its own row navigation and inclusion/action
  commands in `ui/sync/sync_plan_view.dart`. Comparison views, batch-rename
  previews, transfer/activity rows and open-document tabs are not folder browsers;
  their existing view-specific controls remain unchanged.
- Séance's Local edits and transfer sections expose individual buttons and menus,
  not a second selectable directory listing. Terminal arrows continue to belong
  to the shell when the terminal has focus.
- Planchette's remote-folder dialog accepts a path; it does not render a file
  list. Open/Save and upload pickers supplied by `file_picker` or the operating
  system retain their native keyboard behavior.
- Klabautermann's Docker stack-file and remote-editor views display documents,
  not navigable directory lists. Fleet/server tables are not file lists.

## Common navigation

These keys act only while the file listing itself has focus, including when it
is empty. A click in the listing or normal focus traversal arms it. Opening a
Poltergeist sidebar location also hands focus to its destination listing.
Text fields, buttons, menus, other panes and terminal/editor surfaces keep their
own keys.

| Action | macOS | Windows/Linux |
| --- | --- | --- |
| Previous / next item | Up / Down | Up / Down |
| First / last item | Home / End | Home / End |
| Move by a visible page | Page Up / Page Down | Page Up / Page Down |
| Open current item | Cmd-Down or Cmd-O | Enter or keypad Enter |
| Parent folder | Cmd-Up | Alt-Up or Backspace |
| Rename, when offered | Return or keypad Enter | F2 |
| Item menu, when offered | Menu or Shift-F10 | Menu or Shift-F10 |
| Select all, in multiselect browsers | Cmd-A | Ctrl-A |

Planchette and Klabautermann have no rename operation in their file lists, so
Return/Enter opens there too. Klabautermann opens folders only and cannot climb
above the mount point. Planchette stays inside its workspace root. The other
browsers stop at the filesystem root.

Arrow, boundary and page movement auto-repeat and clamp at the list ends. With
no cursor, forward movement starts at the first item and backward movement at
the last. Every move reveals the target row. Open, parent and other action-key
repeats are consumed without acting again, preventing a held key from racing
through folders. Extra modifiers do not silently turn a chord into plain
selection movement.

In Poltergeist and Séance, Shift plus a movement key extends or shrinks the
anchored range. Plain movement selects only the target. Planchette and
Klabautermann remain single-selection browsers: adding selection gestures that
have no corresponding bulk operation would imply capabilities they do not have.
Loading, stale, disconnected and failed listings do not permit actions on old
rows. A parent-folder command can still leave a failed/empty folder where the
host supports it.

## Deliberate product-specific controls

- Poltergeist retains outline Left/Right expansion/collapse, plain Tab pane
  switching, type-ahead, Quick Select, selection undo/redo, clipboard/transfer
  and delete commands. Space previews. Escape follows its existing ordered
  cancellation rules. Open retains the configured double-click action and the
  existing guarded local/remote open pipeline.
- Séance keeps Space to toggle the cursor item's selection and Escape to clear
  selection. Rename now follows the same macOS Return / other-platform F2
  convention as Poltergeist. Its Keyboard shortcuts dialog includes file-list
  commands.
- No new destructive shortcuts or file-opening capability are introduced into
  the read-only disk explorer or the editor's folder sidebar.

## Regression coverage

App widget tests cover the sidebar-to-list focus handoff on all three desktop
platforms, ordinary arrows and Shift ranges, page/boundary movement and scrolling,
empty-folder parent navigation, exact modifier matching, disabled-state guards,
and macOS open/parent commands. Shared tests pin cursor bounds and key resolution.

`scripts/macos-keyboard-fixture.mm`, used by all four native runner fixtures,
also checks real engine delivery of Up/Down, Home/End and Page Up/Down, including
AppKit function/keypad flags, Command, Shift and repeat events. It starts no app
window, posts no system input and reads no saved user data. These native and
widget checks are not a real-device or full desktop end-to-end smoke test.
