# Klabautermann review r8: UI docker, logs, charts, actions (prefix UIB)

Scope: `klabautermann/app/klabautermann_app/lib/ui/{docker,logs,charts,actions}` (about 26,000
lines). Paths below are relative to `klabautermann/app/klabautermann_app/lib/ui/` unless they
start with another root. Read-only review; two timings were taken with a standalone Dart script
outside the repository (`/opt/flutter/bin/dart`, JIT), using the exact patterns from the source.

Counts: 2 high, 4 medium, 7 low (13 findings).

---

## UIB-1 (bug, high): a regular-expression search runs unbounded on the UI isolate; an ordinary pattern freezes the app for many seconds

- File: `logs/log_search.dart:186-194` (`_searchAll`), `:219-236` (`_searchNew`), `:262-278`
  (`_search`); caller `logs/logs_panel.dart:811-822` (300 ms debounce, then `setQuery`).
- Code:
  ```dart
  void _searchAll() {
    _pattern = _compile();
    ...
    _searchNew();          // every held line, synchronously
  ...
  return [
    for (final match in pattern.allMatches(text)) ...
  ```
  The class comment itself says "a search field should debounce its input or search in slices
  across frames"; only the debounce was done. The buffer holds up to 50,000 lines of up to
  16 KiB each, and Dart's `RegExp` backtracks with no time limit.
- Measured: 50,000 lines of about 150 characters (an access-log shape), pattern
  `.*items.*upstream.*zzz` (no match, nothing exotic): 15.7 s in one synchronous call. Patterns
  such as `(\w+\s?)+$` did not finish inside the script's 110 s budget on 200 lines.
- Scenario: Logs panel or a container's logs with a full buffer, Regex toggle on, the user types
  a pattern with two or three `.*`. 300 ms after the last key the whole app stops painting and
  taking input for seconds to minutes; there is no cancel, and each later keystroke queues
  another full search. A following view also runs the pattern over every new batch
  (`_onLines` -> `_searchNew`) on the UI isolate. The same path serves the stack logs and
  container logs (`LogSearchField` is shared).
- Fix: search in slices (for example 2,000 lines or 8 ms per frame, newest first, with a
  generation counter that a new query cancels) or in a helper isolate over `rowText` snapshots;
  cap the text a regex sees per line (the first N KiB) and give up on a line after a step budget
  by wrapping `allMatches` iteration with a stopwatch; show "searching" in the suffix. Add a
  test that a pathological pattern over a full buffer returns control within a frame budget.
- Size M. Confidence high (measured).

## UIB-2 (bug, high): `_urlTail` is quadratic, so one log line with a URL followed by a long run of dots stalls every frame that shows it

- File: `logs/log_tokens.dart:33` (`_urlTail`), used at `:74`; called from
  `logs/log_text.dart:430` (`logTokens(body.text)` inside `logLineSpan`, uncached, on every
  build and every wrap measurement of the row).
- Code:
  ```dart
  final _urlTail = RegExp(r'[.,;:!?)\]}]+$');
  ...
  final tail = _urlTail.firstMatch(match[0]!)?.group(0)?.length ?? 0;
  ```
  `firstMatch` tries every start position; in a run of punctuation that does not reach the end
  of the URL each start scans the rest of the run, which is O(n^2).
- Measured with the two patterns as written: `http://` + 4,000 dots + `a` takes 165 ms,
  `http://` + 16,000 dots + `a` takes 2,474 ms, per call. 16 KiB is the buffer's line cap, so
  the cap does not help.
- Scenario: a container prints progress dots after a URL without a newline
  (`Fetching https://registry/v2/........`), or a hostile container prints such a line on
  purpose. While that row is on screen, every rebuild of it (each new batch while following,
  each search step, each scroll that rebuilds it) blocks the UI isolate for up to 2.5 s. This is
  the app-side twin of SMP-01 (`linePriority`), in a different pattern.
- Fix: strip the tail with a backwards loop over code units (O(n)), or anchor the scan
  (`lastIndexOf` a non-tail character). Also cache a row's tokens by seq as
  `ContainerLineReader` caches levels, so a visible row is tokenised once. Add a timing test
  with a 16 KiB line for each token pattern.
- Size S. Confidence high (measured).

## UIB-3 (bug, medium): a stack's merged logs rebuild the whole view on every out-of-order batch; a paused view is thrown to the oldest line

- Files: `docker/stack_logs.dart:130-162` (`_take`), `:170-187` (`_rebuild`);
  `logs/log_view_controller.dart:151-170` (`replaceContainer`); `logs/log_view.dart:268-285`
  (`_onLines`).
- Code path:
  ```dart
  // stack_logs.dart
  final inOrder = newest == null ||
      added.every((entry) => entry.at == null || !entry.at!.isBefore(newest));
  ...
  mergeSort(_merged, compare: _Entry.byTime);
  _trim();
  _rebuild();                      // -> logs.replaceContainer(all records)
  // log_view_controller.dart
  _buffer.clear();                 // "numbering continues where it stood"
  _slots.clear();
  addContainer(records);
  // log_view.dart
  if (removed.entries > 0 && !widget.controller.following.value) {
    ...
    final extent = removed.rows * _text!.lineHeight;
    position.shiftBy(-math.min(extent, position.pixels), path: -extent);
  ```
  `LogBuffer.clear` keeps numbering, so after a replace every old entry counts as evicted
  (`_RowCounts.sync` pops them all). `extent` is then the whole old content, which is at least
  `position.pixels`, so the offset becomes 0.
- Scenario: a stack with two or more chatty services. Batches arrive per container, so
  container B's batch for the same interval arrives after A's and its first line is older than
  A's last: `inOrder` is false on most batches. Effects, each traced in the code: (1) a user who
  paused to read is moved to the oldest line on each such batch, so pause is unusable; (2) the
  seqs change, so open JSON fields collapse (`_expanded.removeWhere`) and the search loses its
  current match (`LogSearch._onLines` sets `_current = null`); (3) each rebuild relabels and
  re-adds up to 10,000 lines, re-searches all of them and resets both row-count trees, up to the
  engine's batch rate, on the UI isolate. The class comment claims the rebuild is "keeping its
  scroll state"; only `following` is kept. `test/stack_logs_test.dart:73` checks the order only.
- Fix: stop rebuilding for ordinary interleaving. Hold each stream's lines in a small reorder
  window and release them in time order up to the minimum "newest time" over the running
  streams (a k-way merge watermark, or a 200 to 300 ms hold), so appends stay in order and
  `replaceContainer` is left for the chip toggle. For the remaining replaces, carry the anchor:
  let `replaceContainer` report the mapping (or the index of the first kept record) so the view
  can restore offset, expanded rows and the current match. Add a widget test: paused, an older
  batch arrives, the first visible line is unchanged.
- Size M. Confidence high for the jump and the reset (code trace), medium for how often it
  happens in practice.

## UIB-4 (bug, medium): the quit guard answers "quit" when the app locks while its question is open, discarding unsaved edits nobody agreed to discard

- File: `actions/quit_guard.dart:42-64` (`_ask`), `:34-40` (`confirm`).
- Code:
  ```dart
  void onLock() {
    if (_lock?.locked == true && !locked.isCompleted) locked.complete(true);
  }
  ...
  _accepted = await Future.any([confirmQuitWhileRunning(...), locked.future]);
  ```
- Scenario: app lock on, a remote editor holds unsaved text. The user presses Cmd+Q, the app
  asks "Quit and discard unsaved changes?", and the user switches away to check something. After
  `appLockBackgroundTimeout` (5 minutes hidden) the lock engages, `locked.future` completes
  with true, `_requestExit` answers `AppExitResponse.exit`, and the edits are gone, with detached
  operations orphaned and shells ended, although the question was never answered.
  `test/app_undo_test.dart:363` ("locking during a quit question cannot trap the request") pins
  the `exit` answer, so this is deliberate, but the stated goal (do not trap the request) is met
  just as well by answering cancel: the request resolves, and a later quit from the locked app
  already passes (`confirm` returns true while locked).
- Fix: complete `locked` with false (cancel) and dismiss the open dialog (keep the dialog's
  navigator route and pop it), so nothing is discarded without an answer; update the test.
  Separately decide whether a quit from an already locked app should really discard unsaved
  editor text silently (`confirm`, line 37): at least keep that case to "no unsaved edits", or
  ask after unlock.
- Size S. Confidence high on behaviour (test pins it), medium that the owner wants it changed.

## UIB-5 (bug, medium): a detached operation's output and a timer's run output show an empty box when the read is refused, fails or is still opening

- Files: `actions/detached_operations.dart:296-348` (`_OperationOutput`),
  `actions/run_output_sheet.dart:113-149` (`RunOutputLog`).
- Both build a `LogsPanelController` and show only `LogView(controller: _reading.logs)`. The
  controller's `opening`, `rejected` and `status` (ended with a reason and the host's error
  text) are never rendered; `LogStatusNotice` is used only by the Logs panel and
  `container_logs.dart:356`.
- Scenario: "Show output" for an operation whose log file was cleaned up, on a server whose link
  is down, or a timer's journal the login user may not read. The sheet (or the dock tab) stays
  blank with no reason and no Retry, which contradicts the repository rule "never report a
  skipped or failed operation as successful" in spirit: an empty output reads as "it printed
  nothing".
- Fix: wrap both in `ListenableBuilder(listenable: _reading)` and put
  `LogStatusNotice(panel: _reading)` above the `LogView`, as `ContainerLogsView` does. See
  UIB-11 for the shared sheet.
- Size S. Confidence high.

## UIB-6 (refactor, medium): the Docker list panels repeat one scaffold five to six times

- Files: `docker/containers_panel.dart`, `images_panel.dart`, `volumes_panel.dart`,
  `networks_panel.dart`, `stacks_panel.dart`, `events_panel.dart` (and `apps_panel.dart` for the
  watch holder).
- Evidence: after renaming `volume` to `network`, `volumes_panel.dart` (573 lines) and
  `networks_panel.dart` (603 lines) differ in 206 lines in total, so about four fifths of each is
  the same text. Repeated in each panel: (a) `String? _held` with `_sync()` and `_release()`
  around `watchX`/`unwatchX` (7 files); (b) "another server" reset in `didUpdateWidget`;
  (c) the header notices (low session, failed with Retry, kept, reading) built from
  `DockerNotice`; (d) `_headerShare` with `ConstrainedBox(maxHeight: constraints.maxHeight *
  _headerShare)` over a `SingleChildScrollView` (8 files in this slice, 3 more outside);
  (e) the search field with clear button and `_searchFocus`; (f) the wide table versus phone
  list switch on a scaled width.
- Concrete extraction:
  1. `DockerWatch` (a small class or State mixin): `sync(visible, serverId)` and `release()`
     over a pair of `void Function(String)`; removes (a) and the risk of one panel forgetting
     the release on a server switch.
  2. `DockerListScaffold({notices, toolbar, body, wide})`: owns (c), (d) and the padding.
  3. `DockerListNotices.of(list.failure, hasData, endpoint, retry)` returning the notice list.
  4. `DockerSearchField(controller, focusNode, hint, clearTooltip)` for (e).
  5. Then `VolumesPanel` and `NetworksPanel` become one `DockerResourcePanel<E>` with columns,
     filter chips and row actions as parameters; images can follow.
  6. `ImageActionsButton`, `VolumeActionsButton` and `NetworkActionsButton`
     (`actions/docker_actions.dart:265-297`, `593-628`, `831-868`) are one
     `RowActionsButton(serverId, point, items)`.
- The `*_view.dart` files are already the pure halves (entries, filters, columns) and are fine;
  the duplication is between the panels, not between a panel and its view.
- Size L. Confidence high.

## UIB-7 (refactor, medium): concrete splits for the largest files

- `docker/containers_panel.dart` (1777): move `DockerNotice` (lines 1755-1777, imported by at
  least ten other files) to `docker/docker_notice.dart`; `_columns`, `_shownColumns` and
  `_ColumnsDialog` (952-1272, 1397-1492) to `container_columns.dart`; `ContainerHealthBadge`,
  `ContainerStateBadge`, `_StatusCell`, `_Figure` (1351-1396, 1523-1715) to
  `container_badges.dart`; the bulk selection (`_selectionBar`, `_selectColumn`, `_Selectable`,
  `_GroupHeading`, 657-753, 1273-1350, 1493-1522) to `container_selection.dart`; the phone list
  with `_BuiltRow`/`_BuiltRows` (816-951, 1716-1754) to `containers_list.dart`. The panel state
  then holds filters, the watch and the layout switch (about 500 lines).
- `logs/log_view.dart` (1552): `_RowCounts` (942-1196) to `log_row_counts.dart`, public and
  unit-tested on its own (a Fenwick tree with eviction is the riskiest logic in the file and is
  only tested through widget tests today); `_LogRows`/`_RenderLogRows` (1201-1340) to
  `log_rows_sliver.dart`; `_TailScrollController`, `_TailScrollPosition`,
  `_ShiftableScrollAnimation` (1367-1552) to `log_tail_scroll.dart`; `_TextLayout` (844-940) to
  `log_text_layout.dart`.
- `docker/container_details.dart` (1402): `ContainerInspectionScope`, `openContainerDetails`,
  `ContainerInspectorBody`, `ContainerDetailsPage`, `_RemovedBuilder` (40-408) to
  `container_inspector.dart`; `_LogTail` (1021-1141) to `container_log_tail.dart`; `_Facts`,
  `_Mount`, `_ManagedByBadge`, `_RawJson` (1179-1402) to `container_details_parts.dart`.
- `charts/time_series_chart.dart` (1311): `TimeSeriesPainter` and the crosshair painter (from
  about line 800) to `time_series_painter.dart`; `_Readout` and `_ReadoutLayout` to
  `time_series_readout.dart`.
- `logs/logs_panel.dart` (1253): `LogSearchField`, `LogLiveChip`, `LogStatusNotice`,
  `LogNotice`, `LogBootPicker`, `LogFilePicker` (690-1253) are imported by `docker/` files from
  the panel file; move them to `log_search_field.dart`, `log_notices.dart`, `log_pickers.dart`.
- `docker/stacks_panel.dart` (1110): `StackOverviewPage`, `StackOverview`, `_Profiles`,
  `_ServiceCard`, `_ContainerRow` (628-1110) to `stack_overview.dart`.
- Size L (mechanical). Confidence high.

## UIB-8 (bug, low): a stack's profiles are read once per element and survive a server switch

- File: `docker/stacks_panel.dart:901-903` (`_ProfilesState`), keyed only by the stack's name at
  `:289` (`key: ValueKey(selected)`).
- Code: `late final Future<DockerPayload> _read = widget.monitoring.docker.readStackProfiles(
  widget.serverId, project: widget.project);` with no `didUpdateWidget`.
- Scenario: the desktop workspace reuses its panels across servers (`server_workspace.dart:224`
  handles `serverId` changes in place). Server A and server B both run a stack named `traefik`.
  Select A, open Stacks, switch to B: `StackOverview` keeps its element (same key), `_Profiles`
  keeps A's future, and B's overview lists A's profiles.
- Fix: key `StackOverview` with `ValueKey((widget.serverId, selected))`, or re-read in
  `didUpdateWidget` as `ContainerProcessesSection` does with its `_reads` counter.
- Size S. Confidence high (code trace; not run).

## UIB-9 (drift, low): a stack's merged logs follow a fixed set of container ids and go dead after a redeploy

- File: `docker/stack_logs.dart:302-323` (`openStackLogs`), `:56-65` (containers fixed in the
  constructor), `:281-290` (`LogStreamEnded` -> `StackLogState.ended`).
- Scenario: open a stack's logs, then pull and redeploy it (STK-06) to watch it come up. The
  recreated containers have new ids; every stream ends, each chip reads "ended", and no new
  line arrives until the page is closed and opened again. The page does not listen to
  `stacksFor(serverId)`.
- Fix: have `StackLogsPage` listen to the stack list and reconcile the controller's containers
  by service and name (open streams for new ids, keep the merged lines), or at least show a
  notice with a "Read again" action when every stream ended.
- Size M. Confidence medium (behaviour of a recreated container's stream not run).

## UIB-10 (refactor, low): the inspector's in-place shell is unreachable in the shipped app

- File: `docker/container_details.dart:130`, `:146`, `:160-162`, `:230-241`, `:255-261`.
- Code:
  ```dart
  if (!shell) {
    if (WorkspaceDockScope.maybeOf(context) case final dock?) {
      dock.show(DockedShell(serverId, container));
      return;
    }
  }
  setState(() => _shell = !shell);
  ```
  `ContainerInspectorBody` is built only by `inspector_pane.dart:51`, which sits under
  `WorkspaceDockScope` (`desktop_shell.dart:252`). So `_shell` never becomes true in
  production, and the `ContainerShellPane` branch, the `dockerShellHide` tooltip and the
  class comment ("one that swaps its details for a ContainerShellPane") describe a path only
  tests reach (`test/container_terminal_test.dart:1023` builds the body without a dock). That
  path also closes a running shell without `confirmEndRunningShell` when another container is
  selected, unlike the dock.
- Fix: remove the in-place shell (state, branch, string) and point the tests at the dock, or
  keep it and add the same close guard. Decide once.
- Size S. Confidence medium (no other production caller found by grep).

## UIB-11 (refactor, low): small duplicated pieces inside the slice

- Three output sheets with the same shell (drag handle, `DraggableScrollableSheet` 0.6/0.3/1,
  header row with title and close, body): `actions/detached_operations.dart:254-348`,
  `actions/run_output_sheet.dart:33-110`, `actions/cron_run_output.dart`. Extract
  `showOutputSheet(context, title:, closeTooltip:, builder:)`; with UIB-5 the two log sheets
  become one `LogOutputSheet(reading:)`.
- "Latest read wins" (`int _reads`, `final read = ++_reads; ... if (!mounted || read !=
  _reads) return;`) is written out in `docker/container_processes.dart`,
  `docker/image_history.dart`, `docker/review_panel.dart`, `docker/stack_file_view.dart` (and
  two files outside the slice). A `LatestRead<T>` holder with `run(Future<T>)` and `discard()`
  removes four copies.
- The monospace `TextStyle` (`fontFamily: monoFontFamilies.first, fontFamilyFallback: ...`) is
  built by hand in 7 files of the slice (`action_preview.dart:167`, `cron_run_output.dart`,
  `container_command.dart:124`, `image_history.dart`, `image_pull.dart`,
  `container_details.dart`, `container_processes.dart`), and `container_command.dart:126`
  passes the whole family list as fallback where the others skip the first. One
  `monoTextStyle(TextStyle? base)` in `theme/app_theme.dart`.
- The three header-plus-`LogView` screens (`LogsPanel`, `ContainerLogsView`, `StackLogsPage`)
  each rebuild the header-share column; a `LogScreenScaffold(header:, view:)` covers them.
- Size M. Confidence high.

## UIB-12 (bug, low): an action tapped while another preview is being planned is dropped without a word

- File: `actions/action_preview.dart:28-29` and `:62`.
- Code: `if (operations == null || operations.planning) return;` and, after the plan,
  `if (!context.mounted) return;`.
- Scenario: planning reads the host and can take seconds on a slow link. The user taps Restart
  on container A, then Stop on container B before A's preview appears: B's tap does nothing and
  nothing says so. Likewise a plan whose opener left the tree (a phone row's button after the
  page popped) is dropped after the engine already planned it.
- Fix: show a top toast ("Another action is being prepared") in `startAction`, and in
  `previewAndRun` fall back to the root navigator's context (the overlay is already captured)
  instead of returning.
- Size S. Confidence high.

## UIB-13 (test, low): gaps around the findings above

- No timing test for `logTokens` on a 16 KiB line (UIB-2), and none for `LogSearch` with a
  slow pattern (UIB-1); `log_search.dart`'s comment quotes a plain-text timing only.
- `test/stack_logs_test.dart` checks merge order but not a paused view, expanded fields or the
  current match across a rebuild (UIB-3).
- No test switches the server under a mounted `StackOverview` (UIB-8).
- `_RowCounts` has no direct unit test (see UIB-7); its eviction, compaction and `_keepShare`
  paths are exercised only through pumped widgets.
- Size M. Confidence high.

---

## Checked and found sound (no finding)

- Action targets: every Docker intent carries a stable id or name taken when the control was
  built (`container.id`, `image.id`, volume name, network id, project name), the preview's
  `targetName` comes from the engine's plan, and `operations.run` sends the plan id, so a list
  refresh between menu and confirmation cannot retarget an action. Row menus capture the panel
  state's context, not a row's.
- `ActionConfirm`: the typed tier compares exactly, Run and Enter are gated by `_ready`, Escape
  and barrier dismissal return null, and key repeat cannot activate the autofocused Run.
- Read-only and observe-only: every control in the slice sits behind `ActionEntry` or
  `actionsAllowedAt`; the phone shell page is gated again inside its route.
- Terminal: the session, engine and shell are closed on dispose, reopen and back; paste goes
  through the policy on every path (keys, toolbar, menu, soft keyboard); only http and https
  links without userinfo open; default xterm shortcuts are off.
- Log text: `parseSgr` drops C0, C1 and non-SGR sequences before anything is measured or drawn;
  each line starts from a plain style; contrast is floored per span; caches are bounded.
- Export: redaction failure never falls back to raw text; staged files are owner-only and
  removed; the file name comes from Docker-validated names.
- Charts: non-finite samples become unknown in the ring; scales have guards for null, zero and
  non-finite maxima; plot rectangles of zero size return early; gaps are clipped to the window;
  callers that pass `max` guard it (`overview_panel.dart:1226`).
- Async gaps in `container_processes`, `image_history`, `review_panel`, `stack_file_view`,
  `image_pull`, `container_command`, `log_export`: all check `mounted` and a read counter.
- Strings: no hard-coded user-facing text found in the slice (grep for literal `Text`, labels,
  tooltips and hints).

## Overall assessment

The slice is carefully built: targets are id-based, confirmations come from the engine's plan,
lifecycle handling is consistent, and the log view and charts handle hostile text and odd
numbers well. The real risks are synchronous work on the UI isolate driven by user or remote
input (regex search, one token pattern, the stack logs' rebuild-per-batch). The quit guard has
one deliberate choice that loses data. The main maintenance cost is the repeated panel scaffold
and five files over 1,100 lines; both have mechanical fixes. Overflow at narrow width or 2x
text was not exercised by running the app; the code uses `Wrap`, `OverflowBar` and scaled
breakpoints throughout.

## Coverage

- Read fully: `actions/confirm.dart`, `quit_guard.dart`, `action_preview.dart`,
  `action_entry.dart`, `docker_actions.dart`, `run_output_sheet.dart`;
  `docker/container_terminal.dart`, `stack_logs.dart` (controller and page);
  `logs/log_view.dart`, `log_text.dart`, `log_search.dart`, `log_tokens.dart`,
  `log_export.dart`, `log_view_controller.dart`, `logs_panel_controller.dart`,
  `container_lines.dart`, `log_level.dart`; `charts/time_series.dart`, `chart_values.dart`,
  `time_series_crosshair.dart` (hit and step logic); also `controllers/container_terminals.dart`
  and the plan/run half of `controllers/operations_controller.dart` for context.
- Read in part: `docker/containers_panel.dart` (state, body, key actions, bulk bar; lines
  84-730), `container_details.dart` (60-480), `stacks_panel.dart` (76-335, 625-925),
  `container_command.dart`, `image_pull.dart`, `container_logs.dart`, `container_processes.dart`,
  `image_history.dart`, `review_panel.dart`, `stack_file_view.dart` (state only),
  `actions/detached_operations.dart` (150-348), `cron_run_output.dart`,
  `logs/logs_panel.dart` (panel state, search field, status notice),
  `charts/time_series_chart.dart` (state and build, 150-380).
- Skimmed by grep only: `images_panel.dart`, `volumes_panel.dart`, `networks_panel.dart`
  (structure and diff), `sparkline.dart`, `gauge.dart`, `bars.dart`, `core_heatmap.dart`,
  `chart_marks.dart` (division and guard sites), `actions/host_actions.dart`,
  `activity_page.dart`.
- Not reached: `apps_panel.dart`, `events_panel.dart`, `docker_panel.dart`,
  `docker_endpoint_picker.dart`, `docker_endpoint.dart`, `unlisted_stacks.dart`,
  `container_diagnosis.dart`, `container_links.dart`, `container_log_range.dart`,
  `container_usage_charts.dart`, `docker_cells.dart`, `logs/log_query.dart`, the painter half
  of `time_series_chart.dart`, `series_ring.dart`, `chart_style.dart`, and the tests beyond the
  ones named above.
