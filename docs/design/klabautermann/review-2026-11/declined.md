
## 23:45 sweep
- #712 r1: noLink for failed root probe (kept, planner-wide meaning); busyboxTools idempotency (refuted, fresh shims per setUp); trim() (declined). Fixed: xattr test skip on applet-first BusyBox (54a41b33).
- #715 r1: limit learning (refuted, monotone + zero-open guard); hostKeyLocator (refuted, == '$host:$port').
- #717 r1 minor: fixed Uint8List copy; declined .env proxy line, extra boundary tests.
- #706 r2: threshold doc (refuted, "satisfies clear" = thresholdHolds); others nits.
- #708 r2: unreadable as moved (refuted, changed excludes unreadable); caps forget (refuted, refreshFleet forgets).
- #705 r2: backoff skip (refuted, due already filters; payload reads cache).
- #710 r2 minor: StackTrace.current (declined, minor-only).
- #713 r2 minor: done.
- #718 r1 minor: staleSourceItems leftover (declined, never read); reconnect doc (declined).
- #719 r1: empty keystore entry FIXED d8f22424 (+ seance copy); vaultHoldsSecrets catch (declined). New round requested.
- #720 r1: APK profile FIXED 9a4ce237, rm guard, LC_ALL=C; compile error (refuted); bash 3.2 "$@" (refuted). New round requested.
- #721 r1: LicenseRegistry (refuted, setUp reset); platform override (refuted); setState (refuted).
- #722 r1: OSC7 (refuted, identical semantics); test nits declined.
- #723 r1 minor: p.delimiter (declined, POSIX-only utilities).
## #724 GLM r1
- Critical MainActivity scheme: refuted; uri from documents map, registered via Uri.fromFile (scheme file).
- _recoveries gating: by design; recovery copies only reach Dart via recoveries().
- defaultTargetPlatform: declined; Theme platform honours overrides, consistent with editor.
## #725 GLM r1 (d49cf1c)
- Major root_targets duplicates: refuted; self-test passes, bases is a set so equal climb+rest cannot normalize to one path from two bases.
- Minor hoist box.dart write: declined nit.
## #726 GLM r1 (9949384)
- Major pinnedKeyType serialization: refuted; no codec/==/copyWith on HostKeyPromptData (isolate object passing), protocol_test + engine_host_test pass (84).
- Minor progress test chunk coupling: declined; fixed chunk size, deterministic, already guards progressEvents > 4.
## Flake noted (report to user)
- klabautermann_core inventory_session_test: after sshd kill + redial LinkReady, next plan refused noLink (seen once on #721 run 43129685837, passed on re-run). Likely race between LinkReady and plan readiness. Follow-up candidate.
## #734 GLM r1 (7d55840), 0 actionable
- Major ReceivePort GC in _failWhileStarting: refuted; an open ReceivePort is held by the VM's port map and is not closed by GC; the isolate dies on the thrown error anyway.
- Minor _LogTail doc vs streaming: applied (doc corrected to streaming behaviour, plus orphaned _Section doc restored).
- Minor mounted guard in _changed: declined; listener removed in dispose, LogRead never notifies synchronously in addListener.
- Minor both metric streams get the same failure: declined; intended and documented (shared derive diff).
## #735 GLM r1 (e5f8db0), 0 actionable
- Minor 1s clock margin: declined; runner VM is the CI machine itself (same clock), a >1s backward step mid-test is not a realistic CI event, and no other case starts the job unit within that second.
- Info window overflow: declined; oneshot writes ~5 records, 50 is ample; comment already states the count.
- Info since timezone: refuted; commands.dart sends --since=@<epoch seconds> (_journalTime), timezone-free.

## #736 GLM round 1 (7b1c639)
- Refuted: fleet_density missing foundation import (dart:core; analyze clean).
- Refuted x4: lifecycle masking dropped (TimedReveals owns AppLifecycleListener).
- Declined x2: read throws leaves reading stuck (identical to pre-PR code on main; queryHost returns failures in result) - out of scope for behavior-preserving refactor.
- Declined: test nits (queries().single twice, 10 s pump, redundant ensureInitialized) - minor-only.

## #738 GLM round 1 (c0ca7d0)
- Refuted (Major): associative array needs bash 4. package-linux-common.sh already uses `declare -gA` on main (SONAME_TO_DEP, line 58); Linux-only packager.
- Declined (Minor): diagnostic link not closed in _diagnoseEditRefusal. Real but only on an already failing test path, closed at process exit; no push for a minor-only round. Carry into a later edit of that test.
- Declined (Minor): old cache names orphaned. Cosmetic.

## #739 GLM round 1 (0e9c7d7)
- Declined (Minor): `.first` finder for sync filter field in test; fails loudly, matches existing usage; minor-only round, no push.
- Refuted (Info): "flag acts on iOS/macOS only". Flutter docs: enableIMEPersonalizedLearning maps to Android's IME_FLAG_NO_PERSONALIZED_LEARNING (incognito); it is the mobile keyboard case the change targets.

## PR #741 (klab/argv-masking), GLM review comment 6838091079 at d8416e0

Fix commit: `a0d5d96c7` "Mask split header credentials and -c newlines"
(worktree /tmp/mask-glm, not pushed). Red run of the new tests against the
old code: /tmp/claude-0/-home-user/31cd7d87-a2c2-516b-8a2c-4ca4cf147894/scratchpad/review/mask-glm-red.txt (5 failing tests).

| Finding | Verdict | Evidence |
| --- | --- | --- |
| ps fallback `-H Authorization: Bearer abc` leaves `abc` visible | Apply | Red: `curl -H Authorization: ******** abc`. After a secret header value that is an auth scheme alone, the next token is masked too (`_authSchemes`). Test "a ps fallback header masks the token after the name, and the credential after an auth scheme". Reviewer's expected output (collapse to one mask) not adopted; tokens stay separate. |
| mongo/mongosh `--password` not masked | Refute | Key-pattern rule already masks `--password <v>` and `--password=v` (`_isSecretOption`, `_keptBeforeValue`); new assertion in the redis-cli/mongosh test passed before the fix. |
| Header name with whitespace before the colon | Apply (different fix) | Leak was real (`-H 'Authorization : Bearer abc'` shown whole) but the suggested `.trim()` was a no-op: header text comes from `\S+` tokens. A secret header name without a colon now masks the rest of its argument or shell word. Test "a secret header name with a blank before its colon". |
| Closing quote dropped (3 test lines) | Apply | Easy and correct when the kept prefix opened the quote: `_closesQuote` keeps it (`-u 'me:********'`); a value whose opening quote is masked (`--password='a b'`) shows no stray quote (existing test). |
| Newline not a command separator | Apply (scoped) | Real leak: `sh -c 'docker pull x\ndocker login -p hunter2 reg'` left `hunter2` visible (second docker read as operand). Applied only in the argument after a `-c` option cluster and outside quotes (`_ShellLine`), since a newline in `curl -d` data or a quoted JSON body must not end the curl command (guard tests). |
| htpasswd `-C`/`-r` are not value options | Refute | httpd `support/htpasswd.c`: `apr_getopt(state, "cnmspdBbDi25C:r:v", ...)`; manual: `[ -r rounds ] [ -C cost ]`. |
| Attached option leaves a dangling pending value | Decline | Deliberate over-mask: `-passin` under `docker login` reads as `-p`+`assin` yet may be a single-dash long option whose value is next; existing test "the argument after a secret-named option" pins it and failed when the suggestion was tried. Reveal undoes over-masking. |
| Redundant `api-key` check | Refute | Catches names where Api-Key is not the ending, e.g. `X-Goog-Api-Key-Id` (existing test). |
| §8.9 paragraph readability | Decline | Style nit; §8.9 updated for the new behavior instead. |

## #742 GLM round 1 (8802dc1): minor-only
- Second-pass fake test coverage, duplicated quota fakes across two test files, others: minor test-structure suggestions, no defect. The real server's second pass is covered by storage_batch_test and the end-to-end integration test. Declined (reviews waived; minor only).

## #745 GLM round 1
- clean assembleDebug falls back to FAIL: applied (filter clean / :clean). Abbreviations (aD) stay strict: declined, safe direction.

## #743 (planchette/text-formats) GLM round at 5048f93, triage commit 0808ae16c

- (1) Major, managed open offers Reopen with Encoding that drops the
  publication and loosens SymlinkPolicy.reject: REAL. Fixed by carrying
  the publication in the banner offer and reopening through the managed
  open. Test `managed_document_test.dart` "Reopen with Encoding keeps the
  checkout managed" (red: publication null; green after).
- (2) Major-labelled, encoding tooltip "BOM adds 3 bytes": NOT A BUG (the
  menu always offers UTF-8 BOM, so the note is accurate). Reworded to
  "a UTF-8 BOM adds 3 bytes" for clarity; literal, no ARB entry.
- (3) Major, setMetadata resets encoding from a fresh metadata object:
  NO LIVE BUG. Only production caller (Planchette status bar line ending
  menu) already threaded encoding; Seance/Poltergeist/Klabautermann have
  no setMetadata callers. Replace-all is the existing contract (a fresh
  object reset the BOM before this PR too). Hardened: added
  TextDocumentMetadata.copyWith, status bar uses it, setMetadata doc
  states the contract. Coverage tests green from the start.
- Coordinator nits: invisible U+FEFF literals in text_encoding.dart and
  text_encoding_test.dart written as escapes (applied).
- Not triaged here (minor/info, outside assigned scope): link-chain
  message wording, reopenWithEncoding interactionLocked early return,
  test comments, BOM invariant centralization, Poltergeist invalidUtf8
  classification wording, failsWith matcher tightening, ARCHITECTURE.md
  leading space, _firstInvalidUtf8 -1 fallback, dominant line-ending
  extra tests.

## #744 planchette/undo-budget, GLM round 1 (f67ff46), fixes in fb95a2143

Applied:
- identical() text checks in `_trackHistory`/`_syncUndoState` (Major):
  partly valid. Composing-only IME updates go through
  `EditableText._formatAndSetValue` with the platform's decoded string
  (editable_text.dart:3684-3713), so pending was misreported: canUndo
  true with an empty history, canRedo false, and
  `UndoHistoryController.redo()` is gated on canRedo
  (undo_history.dart:380-385). Fixed with identity then `==`, adopting
  the equal copy. Wrong parts: no empty step is recorded
  (`EditHistory.record` returns on equal texts, edit_history.dart:96)
  and undo with nothing pending correctly takes back the newest step.
  Selection-only platform updates keep identity
  (`_handleSelectionChanged` sets `controller.selection`). Test: "an
  input method marking a word keeps undo state" (red: canUndo true).
- Stale remount timer after install (Major): valid. Install branch of
  `_changed` now cancels `_fieldRemount`. Test: "a reload cancels a
  pending remount" (red: new UndoHistoryState).
- `reset()` charging the base text (Minor): valid for text over 8M
  UTF-16 units (reachable by growing a document past the 4 MiB load
  cap). `_open = 0` in reset. Test: "a document larger than the budget
  alone is not remounted" (red: remounted on caret moves).

Declined:
- Duplicate undo/redo listeners (Major): wrong. Registration is in the
  constructor only; `text` is `late final` (editor_controller.dart:193).
- Undo mid-composition leaves IME composing (Major): wrong. The
  history write has an empty composing range and
  `_didChangeTextEditingValue` -> `_updateRemoteEditingValueIfNeeded`
  sends `setEditingState` (editable_text.dart:4016-4025, 4918-4929);
  existing test "undo during a composition takes back the composition".
- Lock/load not republishing canUndo (Minor): undo()/redo() guard via
  `_canStepHistory`; no host displays the flag (only the tool notice
  button, which calls the guarded `c.undo`).
- Static budget knob leak (Minor): the only test that sets it restores
  it with addTearDown.
- fieldHistoryDepth unbounded loop, missing undoController comment
  (editor_view.dart KeyedSubtree comment already explains),
  type() code units, undoAll readability, random-test selections
  (Info): nits, no behavior change.
- Outside diff: no UndoHistory onUndo/onRedo wiring remains;
  EditHistory has a 16 MiB budget with eviction tests.

## #746 GLM round 1
- xml hold not enforced in dependabot ignore: applied.
- Poltergeist fss/url_launcher sibling pins diverged from Klab: applied (bumped Poltergeist to 10.3.4/6.3.3).
- unorm_dart normalization stability: declined (patch bump, tests pass).
- group/loginScript null-aware form: declined; they are instance fields (not promotable), so use_null_aware_elements does not apply and the analyzer is clean.

## #747 GLM round 1 (d5e302b, 3 minor)
- Cancel autofocus: valid, low-risk. Minor-only round with reviews waived; not starting a push for it. Carry into the next push to this branch if one happens, else follow-up.
- fontFamilyFallback for monospace URL: valid cosmetic; same disposition.
- Visible-link-opens-directly test: valid coverage gap; same disposition.

## #748 GLM round 1 (86fa9fd, 1 major + ~20 minor) -> fixes in 1eca8dde8
Applied: fixed-sleep poll in open_recent_test; _offerSaveSiblings error reporting/retry; Directory.exists permission error = folder unavailable; already-gone sibling counts as deleted; .edit covered by missing-document guard.
Refuted: save_elsewhere real disk (saveSiblings null); synthetic-package (no-op in 3.47.2); pubspec l10n deps (present).
Declined: _recordedPaths order (in-memory first); FakeDialogs list ref (fresh list); committed l10n (suite convention); "Sign In" casing (unchanged from main, follow-up); hardcoded English (staged ARB migration); Isolate.run captures (speculative); cosmetic items (unmodifiable, same shadowing, comments, table test, MaterialApp setup, dialog layout assertion); python3 in xattr test; xattr loss deliberate.

## #749 GLM round 1 (416d9ce, 0 actionable)
- Info: add Tab-reaches-Open assertion. Declined: info only, default Material focus traversal; not worth a push.
- Outside-diff: hidden-link comparison strictness. Refuted: xterm PATCHES.md #52 / terminal_view.dart _followableLinkAt + buffer.isLinkTargetHiddenAt: exact compare of joined cell text across adjacent rows vs target after trim only; no case folding.

## #751 GLM round 1 (37939b2) + CI fixes -> dd92382fb
CI: release tool test fake lacked `dart build cli` (fixed f2baad1f8); pin audit record refreshed for SQLite blessing (dd92382fb).
Applied: go-dart-notices wording (dart build cli ships libdartaot*.so) f4574d1fd.
Refuted: ci.yml shell (defaults.run.shell bash; Windows leg passed); `blessing` SPDX (valid id, oci-licenses.py accepts, image notice job passed); double close (sqlite3 3.9.1 close() idempotent); overrides // comments (stripped by load_overrides); overrides file missing; stage dir handling (cp -R); dispose rename (remaining are non-sqlite).
Declined: build.sh bundle sanity check (CI runs --help on 3 OSes).
Docker entrypoint via symlink: earlier local image run used the entrypoint path and was healthy.

## #752 GLM round 1 (b82e087, 0 actionable, 2 minor + 1 info)
- `||` vs `&&` on stdout/stderr done: declined. SSH EOF is channel-level (RFC 4254 5.3); stdout and extended-data stderr end together in dartssh2, so equivalent.
- Uncancellable Timer.run: declined. Zero-duration timer fires on the next event turn, before any timeout abort; closing an already-closed sink returns its done future (no sync throw) and the async result is ignored.
- Info: commands closing outputs while reading stdin lose EOF: known trade-off, stated in the PR body.

## #757 (Planchette deferred-4), GLM round 1 (head c5fbe2e)
- DocumentIo.kt:68 require admits 0; document_store.dart:202 no Dart range check on maximumBytes (inline suggestion 4575298947). Declined: programmer-error guards, every caller passes the fixed export constant; reviews waived. Carry into a later push only if one touches these files.
- Remaining 6 GLM minors: nits, no action.

## #759 (Planchette F7 phase 2), GLM round 1 (head 62dd87e)
- Major "missing dart:io import" in localization_contract_test.dart: REFUTED, import exists at line 2. PR comment posted.
- Title-case button labels (Keep Mine, Convert to Spaces/Tabs, Open Folder, Save All, Save Anyway): declined, moved verbatim from existing strings; a catalog-wide casing pass is a separate copy decision.
- ICU plural for bulkCloseTitle: declined, dialog only shown for 2+ documents (single document uses its own title).
- Semicolon in encoding tooltip, quoted folder path, platform-locale fallback in _l10n: minor copy/English-only app; declined.

## #762 (Poltergeist follow-ups), GLM round 1 (head b00e05a)
- Major: vacuous `textContaining('ssh-ed25519')` assertion. APPLIED (41c86311d): asserts each fingerprint block's own type.
- Minor: Home/End from an unfocused table land on the wrong end. Verified real, APPLIED with failing-then-passing regression tests (41c86311d).
- Remaining minors (truncated in notification): not acted on; nits.
- #762 round 1 also: reveal on collapse change (sync_plan_table.dart:195) declined, minor polish.

## #761 (vault re-key gate), GLM round 1 (head c3a79a9)
- Major "unreleased owned re-key wedges store": REFUTED. All four stageRekey call sites (klab sync_credentials.dart:123, planchette workspace_catalog.dart:297, poltergeist sync_credentials.dart:130, seance app_services.dart:645) release in an outer finally.
- Major "atomic_write_blocker.delete() not idempotent": declined, test-only helper used once per test with create/delete paired; no data outside the temp sandbox.
- Inline 4575436558 (Poltergeist sync_credentials.dart:144, guard read-back so the write error survives): declined. Read-back failure leaves the journal staged either way and surfaces as KeystoreException, which the "commits and then cannot testify" test asserts; only the message would differ.

## #763 (Klab settings dedup), GLM round 1 (head 5354f6a), minor only
- engine_reads.dart onError: declined, pre-existing in the six replaced controllers (reviewer agrees not a regression); follow-up candidate.
- requestId/request duplication: declined, every caller derives both from one local.
- Leftover Docker tab references: checked, none (git grep SettingsTab.docker/settingsTabDocker empty).

## #765 (Poltergeist F6/F8 dedup), GLM round 1 (head 450f583)
- Major "persist-first base changes failure semantics": REFUTED. PersistedValueController.write is apply-first (assign, notify, then await save; equality short-circuit kept), identical to the old EditorTextSizeController. Only appearance_controller.dart:14-16's "[PersistedValueController]" reference to persist-first is a misleading doc link; doc-only, carry into a later push if one touches the file.
- Major "overlapping writes persist out of order": declined, pre-existing in every replaced controller (same unawaited save); not introduced by the dedup. Follow-up candidate: serialize saves in the base class.
- Inline 4575486943 (file_reveal.dart:213 errors.ignore() on timeout): declined, minor; after kill the stderr stream ends normally and the decoder error path is theoretical. Carry if the file is touched again.

## #760 (Klab engine follow-ups), GLM round 1 (head ca53e5e)
- Major "refusal detail bypasses refusalDetail sanitization": REFUTED. The only ActionRefused send with a detail (engine_isolate.dart:1579, PlanAction refuse()) wraps it in refusalDetail(); the other send (line 2399) carries no detail.
- Minor "blank detail renders 'Details:'": refuted by the same path; refusalDetail returns null for blank text (operation_plan_test.dart:61).
- 03-ARCHITECTURE "while it is null" dangling referent and remaining minors: doc nits, declined.
- #760 inline: disk_usage_tree_test.dart:266 pumpEventQueue ordering and disk_usage.dart:115 catchError on cancelled: declined as minor (test passes; cancelled futures complete normally). Will revisit only if CI shows the test flaky.

## #764 (desktop dedup C5 + IPv6), GLM round 1 (head 7f42a70)
- Major "load tolerance lost": REFUTED. GhostWindowStateFile.load (ghost_desktop window_state_file.dart:36) catches `on Object` and returns null; tests at window_state_file_test.dart:33/76/83/100 cover missing, non-snapshot, unusable frame, malformed overwrite.
- Major "serialized saves vanished": REFUTED. save() chains on _saveTail (line 53); tests :118 (one at a time, in order), :150 (last wins), :156 (failed save does not block next).
- Inline: titlebar reset order (macos_titlebar.dart:92), byte-exact pin comments, macos_window_utils pin comment: declined, minor/doc; no macOS build to verify an order change.

## #766 (GLM r1)
- REFUTED major: settle outside exclusive races writes. FileVaultStore.settleRekey is _serialize-d; writes refuse while journal pending (_requireNoRekey); concurrent settle returns none. Reply on thread 4576460808.
- REFUTED minor: test "journal old key cannot open is left alone": old key opens its own snapshot; adopt+clear is correct; covered by seance_core vault_rekey_journal_test.dart:48.

## #767 (GLM r1, reviews waived; triage only)
- REFUTED "majors" that ask whether moved behavior survived: GhostRecoverySection refreshes on configured==null in initState/didUpdateWidget (ghost_recovery.dart:206-220), detaches listener on dispose; code dialog barrierDismissible:false (433) + PopScope(canPop:false) (509); IME flags off on both fields (536-538, 650-652) tested (ghost_recovery_test.dart:353,364); liveRegion (402, 550); restore trims and refuses empty (628-629, 687), so Séance call site needs no guard; first-group check trimmed and case-insensitive (472).
- DECLINED pre-existing (dedup keeps behavior): app lock catches Exception only (same on main in both apps), switch tappable during auth, clipboard not cleared, restore dialog barrier-dismissible, _run model-identity guard, enum name in not-changed toast.
- DECLINED nits/design: ghost_keystore exporting a Flutter section (import guard allows; recorded design), dead-wrapper suspicion, Return-key receiveAction assert, restore failure test, scrollable restore dialog.

## #768 (GLM r1, merged)
- DECLINED major "pool spans a Séance store delta": ea74a726f..af3f165dc is #761 (vault re-key: seance_core FileVaultStore + app vault wiring); P1/P2/P4/P7 measure Poltergeist entries/tab paths, not the secret vault. cpuModel pin and wording nits declined.

## #770 (GLM r1): 0 actionable. DECLINED minor ops literal in test cleanup (kRootOpsDir is a full path constant; rmdir of a renamed dir would fail the root:root 755 assertions loudly, not vacuously); info backup-side repair (wrapper repairs on first root op, documented in commit); outside-diff wrapper repair test (nit).

## #771 (GLM r1, minors): DECLINED lift-condition comment (the stated reason already names the condition); pubspec cap (all window_manager constraints are caret ^0.5.x, which excludes 0.7); per-block ignore (only one pub block).

## #772 (GLM r1, minors only): DECLINED wording nits (cap margin phrasing, "Both" antecedent, entrypoint clause, parenthetical); reviews waived and none changes a fact.

## #774 GLM round 1 (32e7ab3)
- rebootPending excludes notBack (major): DECLINED behavior change. User decision Q1: card stays "until the server is back or the wait times out"; existing test encodes hide at notBack. Doc comment fixed to match.
- Timeout armed at request time (major): APPLIED. Timer now armed when the host takes the run; regression test (red before, green after).
- _tick in build (major): REFUTED. A Timer callback runs from the event loop, never synchronously inside build, so a 'setState during build' crash cannot happen; _tick only starts/cancels the timer idempotently. Style only.

## #775 GLM round 1 (fb48da1)
- listFolders splits the mirror-probe doc comment: APPLIED (moved above the comment).
- _copy() leaves the sheet open with no feedback when enqueue returns false: UNREACHABLE. enqueueOtherPaneCopy refuses only when !plan.allows(folder), and Copy (button and semantics tap) is disabled exactly then; plan is immutable. Added an assert plus comment instead of a dead message.
- _hostLabel shows "This device" for a remote target with null bookmark: APPLIED. Reachable transiently: _openLocal clears _pendingRemote before the rebind commits, while location is still remote. Now falls back to the server id (same as the shell's delete-dialog label). No regression test: the fake lanes cannot hold a local open mid-rebind.
- Rename allows(folder) to destinationFolder: APPLIED (trivial).
- Scope test ListTile finder to the folder picker: APPLIED (trivial).
- Add debugPrint logging: DECLINED (no diagnostic value; queue failures surface in Transfers).
Fix commit e242646; glm-review label added for round 2.

## #775 GLM round 2 (e242646)
- Copy double-tap double-pop (minor): REFUTED. Flutter routes.dart _ModalScopeState wraps the route in IgnorePointer(ignoring: animation.status == reverse) (lines 1155, 1222), so the popped sheet takes no second tap during its exit animation. Second minor-free round -> steady state.

## #783 GLM round 1 (409bfa0): 0 actionable
- Badge controller on non-badge platforms (minor): DECLINED. One listener and no-op calls; a platform check in main duplicates the capability decision the notifications sink already makes.

## #779 GLM round 1 (9395848)
- Lost update in _SettingsEditorRegistry._mutate (major): APPLIED, serialized; regression test red->green.
- notifyListeners after dispose (major): APPLIED (disposed guard).
- late final field reassignment (minor): REFUTED, only initState assigns it.
- Lost tests (info): REFUTED, moved to ghost_editors editor_registry_test.dart:80,100.
- Long lines / savedRegistry across tests (info): DECLINED, fresh backend per test via setUp; style.

## #778 GLM round 1 (comment 6902553372)
- BLOCKER put() validators not imported: REFUTED (defined in editor_definition.dart, imported line 5; analyze clean). PR comment posted.
- Reserved selectors in id alphabet: REFUTED (in-memory selectors are <system>/<builtin>; persisted ids rejected by isReservedEditorId in fromJson and put).
- setDefaultForExtension throws on malformed ext: DECLINED (documented FormatException contract; the only UI caller validates first).
- _resolvedSelectorFor infinite recursion: REFUTED (schemes are const, so the constructor assert runs at compile time; defaultSelector is always a selector).
- normalized.single StateError: REFUTED (normalizeEditorExtensions takes one value and never splits).
- Dropdown stale default: REFUTED (constructor _repairDefault + remove() reset; setDefault validates).
- Poltergeist scheme selectors: REFUTED (scheme composes '$namespace.system').
- onError toast unmounted: REFUTED (editors_settings.dart:172 checks context.mounted before onError).
- Minor: extension error under the name field: APPLIED c8bfd87. Binding dialog Return-to-submit: APPLIED c8bfd87.
- Minor: copyWith un-normalized: REFUTED (put normalizes). Dangling bindings on remove: REFUTED (remove strips them). Other test/style minors: DECLINED (reviews waived; no defect).

## #780 GLM round 1 (comment 6902586027)
- Major: deleteToken failure after wipe: REFUTED (ChannelSyncKeystore.deleteApiKey completes on any answer and never throws; documented contract).
- Sign-out dialog omits saved credentials: APPLIED 964623e.
- "Still signed in" toast: DECLINED (the only throwing step after the wipe is enrollment.clear(); on its failure the file keeps the account, so the device is still enrolled).
- SyncEnrollmentFile.clear() memory-before-file: DECLINED (store convention: a failed write keeps the change in memory and the next write retries; sync_state_files_test:151).
- Fleet not refreshed after sign-out: REFUTED (isolate test asserts a CatalogReplaced in the sign-out window).
- SyncAccountInfo equality, empty diagnostic, test-hardening, en-only keys (only en locale exists): DECLINED (no defect; reviews waived).

## #781 GLM round 1 (comment 6902647648)
- Move-undo silently skips refused enqueue: REFUTED (PaneDropDelegate.enqueue returns null only for empty rootPaths; byFolder entries are never empty).
- Cut dimming not reactive: REFUTED (FileClipboardScope is an InheritedNotifier and maybeOf uses dependOnInheritedWidgetOfExactType).
- First trash path records Put Back without local check: REFUTED (it is inside `if (local && !permanent)`).
- Focused-text-field chord test: DECLINED (test naming; reviews waived).
- Minors: DECLINED (reviews waived; no defect).

## #782 GLM round 1 (comment 6902801494)
- BLOCKER detach races queued write: APPLIED (regression test failed before).
- Android _quit freeze without thaw on flush failure: APPLIED (no automated test; settings flush failure not reachable from the Android test harness without new seams).
- Active index shift on skipped tabs: APPLIED (regression test).
- Clean file tabs lose metadata: DECLINED (metadata is line ending/BOM, which a clean tab reads fresh from disk; restoring a stale copy would be wrong).
- Overlay onto an already-open dirty tab: DECLINED (a file is open in one window only; restore runs on fresh workspaces).
- python3 dependency in lock test: REFUTED (Python 3 is a required toolchain per AGENTS.md; CI has it).
- Windows CI: android_app_test temp-folder deletion fixed in b024e06 (settle fake-zone IO before teardown).

## #777 GLM round 1 at 11d6ed5 (comment 6902867996)
- Server-copy save records folder without chosen gate: REFUTED (branch requires saveAs, which sets chooseTarget, so chosen is always true).
- Hard-link in-place skipped without digest: REFUTED (every caller passes a digest for an existing file: planchette _saveTarget, poltergeist/seance wrappers fall back to textDocumentSha256; null only for a missing file, which has no links).
- Directory.existsSync accepts a regular file: REFUTED (Directory.existsSync is false for a non-directory).
- saveAsFolders per-field fallback, search_fold range invariant, non-FileSystemException restore: DECLINED (no reachable defect; reviews waived).

## #784 GLM round 1 (comment 6903235687)
- "1 units" fallback, trailing-trim preview arm, extractMatches unchanged count = scope: DEFERRED as pre-existing (main's planchette_editor editor_strings.dart:546, :705, :583 have identical behavior; #784 is a faithful extraction). Follow-up candidates.
- ANALYSIS.md approximate counts: DECLINED (approximate figures, hedged).

## #785 (docs)
- GLM r1 minor x2 applied (verified): reboot wait 15-min timeout still ends on later boot (power_waits.dart:15); hot-exit setting off restores prompt.
- Own fix: ghost_editors test count 44 -> 46.

## #786 (dependabot hold)
- GLM r1 minor: add note that screen_retriever needs Flutter upgrade AND nativeapi review. Declined: the comment block already states both conditions; screen_retriever is a direct dep of ghost_desktop (pubspec line 17). Optional finding, no push.

## Wave 6 GLM triage (reviews waived; real bugs only)
- #787 minors (merged as is): _keyLength at mint site; damaged-key hint names macOS keychain only (Seance runs on Linux/Windows); --refresh GC KeyError when COMPONENTS gains a pin. All real but minor -> wave-6 review follow-up PR.
- #788 4 "blockers" (won't compile): REFUTED, CI analyze+test passed on b6313a1; comment 6913081940. mounted guard already present. Copy edits ("Open its server", "unuploaded" descriptions): declined, English kept identical by design (parity test).
- #789 minors: restoreChangedOnDisk period (English unchanged by design; parity), remote file error dropped with no window -> follow-up (check pre-existing).
- #790 minors: batch kept-name toasts may replace each other; refused-record kind lost on lookup throw; test reason -> follow-up.
- #791 major: Kotlin workaround removal "unproven" -> verify against CI Android jobs on #791 (APK builds); MB message derive from constant (minor).
- #792 major: fake 413 parity: REFUTED, real code uses 'payload_too_large' (seance_core sync_engine.dart:144, record_coordinator.dart:159). minor holdsRecords + awaitingSpace -> follow-up.
- #793 retry budget never resets without success: declined (bounded by design; next edit or quit flush still writes). _plural reuse, 81-col line (CI format check decides), test reasons -> follow-up if CI passes.

## Follow-ups after wave 6 (not done)
- Move LocalDeviceAuthenticator into a shared package (needs catalog-library.md section 9 revised).
- FLAG_SECURE / window titles while locked: product decision.
- Seance link review: no activation count.
- App files are not format-checked in CI; several have pre-existing drift.

## #796 GLM triage
- BLOCKER platformMenusEnabled: REFUTED (getter absent in Flutter 3.47.2; local analyze+test clean). PR comment posted.
- Gate model test deleted: REFUTED (moved to ghost_keystore/test/app_lock_gate_model_test.dart).
- Locked credential reads treated as absent: REFUTED (protectCredentialReads wraps the keystore op via AppLockController.read, the shared mechanism Poltergeist uses; no null/absent result).
- saveAppLock stale _error: REFUTED (_persist clears _error on success). Concurrent-newer-write-fails race: declined, far-fetched (needs another window's write to fail right after this one succeeded).
- Quit disabled while locked: REFUTED in effect. The doc comment concerns the macOS native menu, where Quit is a separate item outside _commandSpec. Off macOS the in-window menu sits behind the gate anyway.
- Minor PlatformException catch: declined for parity (identical authenticator in Poltergeist/Klabautermann); revisit with the shared LocalDeviceAuthenticator follow-up.
- Minor kIsWeb in supported: declined (no web target).
- Minor refreshAvailability test: suggestion only, existing regression test already asserts it.

## #795 GLM triage (one round; no actionable findings -> steady state)
- openDirect returns committed after failure dialog: REFUTED. LinkOpenResult.committed means "step done, do not requeue" (link_queue.dart:42-45, _run); no success bookkeeping. Same as _committedUnlessMoved for display-only steps.
- localization allowlist removal: REFUTED by green CI localization contract test.
- StreamBuilder snapshot.data!: REFUTED. Broadcast controller (link_queue.dart:525), stream == stable per controller, initialData given, no error events.
- Unmounted prompt context drops failure: REFUTED. notCommitted keeps the link at the head for the next activate.
- CHANGELOG "work as before", _waitFor polling, deleted Poltergeist wiring pins, import order, test-helper asserts, parser assert: minor/nits, declined.

## #800 GLM round 1 (9e014fd)
- device_authenticator.dart:76 product-specific "saved secrets" wording / enum name: declined. These are Séance's existing on-screen strings, kept verbatim on purpose; other apps never display them; rewording changes Séance UI (out of scope).
- seance/docs/STATUS.md:11 "messages unchanged" ambiguous: refuted. The shared class throws Séance's exact former strings; the strings GLM cites came from the other apps' copies.
- ghost_keystore pubspec version bump to 1.10.0: refuted. Owned package versions follow the suite version in lockstep (AGENTS.md); only the release script changes them.

## #805 GLM round 1 (271a7b3)
- docker_router.dart:1045 keep stack trace of unexpected read errors: declined as minor. Phase 1's engine error boundary is the diagnostics channel for unexpected errors; revisit there, not in this PR.
- image_updates.dart:180 _forgetChanged assumes full list: declined as minor; all call sites pass the full image list. A doc sentence may ride a later push.

## #806 GLM round 1 (b7b842c)
- http_client.dart:885 / :1013 "major": a body or hijacked duplex nobody listens to or cancels holds its pooled connection. Declined: this is the deliberate other side of DKR-3 (reading with no listener buffered without bound). Every caller in the repo listens at once; a caller that drops a stream is a bug the old behaviour hid by buffering. A timeout drain would reintroduce unbounded reads. No change.
- byte_read_buffer.dart:103 deterministic boundary test; http_pool_test.dart:693 chunk size comment; remaining minors: declined as minor (randomized test covers the branch).

## #808 GLM round 1 (67a3b09)
- integration_workflow_test.dart:213 "major" cast crashes on a job without steps: declined. No job in ci.yml or release.yml lacks steps; if one is added the test fails loudly, which is a guard doing its job, not a masked check.
- :230 fragile test.sh parsing, :212 working-directory filter: declined as minor.
- "FLUTTER_VERSION may be undefined" (outside diff): refuted, ci.yml defines env.FLUTTER_VERSION at the top and every Flutter job uses it.

## #810 GLM round 1 (0d32812), merged at 0d32812
- Critical engine_client.dart:185 "fatal stack always dropped": refuted. Isolate.addErrorListener sends `[String error, String? stack]` (both Strings, per the dart:isolate docs), and engine_client_test.dart:40 asserts `exit.stack` is not empty on a real isolate death; it passes in CI.
- Major main.dart:422 shutdown unbounded: refuted. IsolateEngineClient.shutdown waits at most `_shutdownTimeout` (2 s) and then kills the isolate (engine_client.dart:259-276). A regression test with an engine that ignores Shutdown is added with the restart follow-up.
- Major server_editor_controller.dart:140 rejection trusts any id: refuted. Ids are `server-edit-N` from this controller's own counter, and `_fail` only removes ids from its own maps, so a foreign id settles nothing.
- Major request_rejections_test.dart:180 unawaitedThen: declined, test diagnostics only; the assertion still fails if the bug returns.
- Major AuditQuery catch reports no fault: real but minor; the follow-up reports it through `fault` as the other last-resort catches do.
- Minor monitoring_controller.dart:829 garbled doc sentence: fixed in the follow-up.
- Minor engine_health.dart:59 fault after dispose: refuted; a cancelled subscription receives no further events.
- Minor request_ids.dart `_ => null`: deferred to ENG-11, which removes catch-alls so the compiler checks exhaustiveness.
- Minor container_terminals id-less OpenTerminal rejection, RunRefused without detail, refused forward ends as closed, app_undo_test RangeError, admin CR/LF as wrongPassword, EngineFault unredacted (shown only in a local debug print and dialog, never exported), PlanAction double answer (latent only), sampling test matching only the type: declined as minor or latent.
- Follow-up: the AuditQuery fault report is declined after all. `AuditLog.query` already turns file errors into `unreadable` (audit_log.dart:118-124); the engine's catch is a last resort with no reachable throw to test.

## #812 GLM round 1 (4836f38), merged at 4836f38
- Minor threshold.dart:116 inverted band enforced only in fromJson, "one legacy record could take down the store": the store half is refuted. `KlabautermannRecords.rules()` decodes each record through `_tryDecode` and skips one that throws (klabautermann_records.dart:316-322). A constructor guard is declined: the editor and fromJson are the only entry points, and the constructor is used by tests with fixed values.
- run_as_shell_test library-load `id` call, unchecked chmod, su applet note, boots_test flavour table, robustness_test stride: declined as test nits (minor-only round).

## #807 GLM round 1 (0118867) and the implementer's triage (36efcfa)
- procs.dart `_parseCmdline` "headers inside a skipped region are still processed": confirmed by reading, and by design. A header inside skipped text is judged by the same rules as anywhere else; a forger can only mark a bounded set of entries unavailable, never attribute its bytes to another pid, except for a pid that exited between the rows and the cmdline read, which is the same anywhere in the block (03 §7.2). Tests pin the jump-ahead, repeated-pid and mid-list forger cases (36efcfa).
- Withdrawn pids keep stale `bytes`: declined, `bytes` is read only for entries that are non-null, and withdrawn entries are nulled.
- edit_shell_test top-level `id`, shell_sampler relaxation by collector name, cron fixture comment, golden coverage: declined as test nits.

## #814 GLM round 1 (f21c8a6)
- log_search.dart:309 unsafe `as LogLine` cast: refuted. `_find(seq) >= 0` means the seq is in `_lines`, which `_takeCounts` fills only from `LogLine` entries; seqs are stable row identities.
- log_search.dart:413 stale matches on a regex restart: refuted. `_searchAll` clears `_lines`, `_total` and `_current` before `_forgetPattern` and the first question.
- log_pattern_worker.dart:101 release-mode `assert(_pending == null)`: declined. The only caller asks one question at a time (`_askWorker` returns while `_asked != null`).
- log_tokens.dart:83 empty-range guard, duplicated test helper, line_reading_test assertion on non-matches: declined as minor.

## #811 (secret masking), checks before merge
- Gitleaks: the implementer's f0e2b2c added the two synthetic `curl -u` samples to `.gitleaksignore`; Secret scan passed at f0e2b2c.
- `_maskedProcsText` under-masking: none found. Lines up to `== cmdline ==` pass unmasked, but the sampler (program.dart:967-990) always writes that header before any `== ps ==` or `== ps_w ==` block, and only `== meta ==` and stat rows (no arguments) come before it. A host that reorders its own output only exposes its own data.

## #815 GLM round 1 (49c6d82), fixes in 936cffd
- Fixed: a run that throws while built over a restarted engine (now shut down and reported as stopped, with a red/green test); the old run is disposed in a `finally`; the held-event replay skips a closed stream; the CHANGELOG restart count; `EngineStopped.recovery` documented.
- Refuted, major: cadence and cadence-cap listeners leak (removed by the run's disposers in main.dart); KlabautermannApp updated in place (it is a StatelessWidget whose `_RemountOnChange` remounts on a new `(fleet, monitoring, prompts)` identity).
- Refuted, minor: previous quit guard not disposed and per-run controllers not disposed (both in the run's disposers); settings window inputs rebuilt per run (the new host rebinds the window through `replacing`).
- Declined: `takeFaultNotice` consumes faults inside the quiet window (same behaviour as the notice before #815, by design: a repeating error is told once per minute); EngineHealth dispose guard and EngineRestarter.dispose not shutting the engine down (both live for the launch and are never disposed in the app); unguarded `readPinConflicts` (unchanged code from before the PR).

## #816 GLM round 1 (e5f0f5a): 0 actionable.

## #817 GLM round 1 (590a43b), minor only, no push
- endpoint_confirmation.dart:143 hops matched by label can over-select on a label collision: declined. Every row it selects is a shown row with its own host, port and user, checked visibly before the user presses Confirm; nothing is pinned that the list did not show.
- :133 deselecting a server leaves its hops checked, and re-selecting re-checks a hop the user unchecked: declined as a minor UX choice; the checks are visible and the user confirms what is checked.

## Helper notes (2026-11-24)
- ENG-7 follow-up, deferred: `SaveServer`'s write path (`runWrite` -> `pinsFor([confirmed])`) still pins a saved server's never-confirmed hops with their current addresses. Same class as ENG-7; changing the save flow is a product decision.
- UIA-11 (Overview rebuilds every card on each clock tick): deferred from the UI batch for size; goes with UIA-08's split of overview_panel in the app refactor chain.
- ARC-02 remainder (unused barrel names, DockerContainersQuery/DockerImagesQuery, TerminalEndInput, v1.x alert types): deferred to the dead-code step of the app chain.
- ENG-8 follow-up fixed in #819 (2a11fc7): the linear matcher compared `*` literally before treating it as a wildcard.

## #819 GLM round 1 (2a11fc7): 0 actionable, no push
- Outside diff, "putRule and saveServer discard the seal result": refuted. `putRule` (engine_sync.dart:847) and `setServerPrefs` (:822) refuse on a non-null `_sealKlabautermann` result; `saveServer` does not use that seal but `CatalogWriter.saveServer`, whose only outcomes are `written` and `refusedPullOnly`, and it checks the latter.
- Staged writes before a mid-flight refusal in `saveServer`: declined. After the config is saved only `_retractPrefs` can refuse, with a removal payload far under any cap or pull-only, which `_write` and `writer.saveServer` refuse earlier.
- sampling_scheduler.dart:300 a stale run's lost-readings timer stays armed, engine_sync_test.dart:365 unclosed injected store: declined as minor (a run stopped during the lending await can get one timer, which fires once and `_lose` returns on the stale run at sampling_scheduler.dart:921; the test store dies with the test's temp directory).

## #818 GLM round 1 (588aa93): 0 actionable
- Fixed in 1383dec: action_preview.dart:79, a plan answered after the whole app was remounted (an engine restart) read the disposed root overlay's context and threw. Red/green test in actions_test.dart.
- Declined as minor or informational: the redundant `.cast` and missing `orElse` in stacks_panel_test, the Column in detached_operations (the reviewer itself says no change is needed), the hard-coded 10080 in `alertRuleMinutesTooLong` (English only, the limit is a fixed product rule), the thresholds_tab_test view setup order, the captured `host` in run_output_sheet_test. `TableRowOrder` exists (CI compiles it).

## #820 GLM round 1 (b6e9f95): 1 actionable, refuted
- jobs_panel.dart:205 "raw enum name shown to users": refuted. `jobsAnacronFailed` is an ICU `select` on the `JobHistoryFailure` name with prose for each case and an `other` fallback; nothing shows the identifier.
- Fixed in 8146421: a 0-minute anacron delay read "starting 0 minutes late"; it now reads "starting right away" (red/green in jobs_view_test).
- services_view.dart:208 socket `rowKey` collision on `|`: refuted. systemd unit names allow only ASCII letters, digits, `:-_.\` and `@`, so the unit part cannot contain `|`, and the unit part fixes where the split falls within one unit's rows.
- Declined as minor: redundant `.cast` in the socket tests, `cronRuns` computed twice per anacron row, two `setState`s in `_openFromPalette`, the retry test's total query count.

## #821 GLM round 1 (68715c9): 1 actionable, all refuted, no push
- safety_controller.dart:289 (major) "a transiently empty fleet wipes every local safety entry": refuted. `listed` reads `fleet.servers` when called (main.dart:605), not a snapshot. The engine sends `CatalogReplaced` before the prefs diff at startup and after every round (engine_isolate.dart:1273, 1155, 1213), so the first prefs notification sees no pref records, and the fleet controller subscribes before the prefs controller (main.dart:452 vs 590), so it holds each new catalog before `_keepLeaving` runs.
- safety_controller.dart:290 (major) "an empty ServerSafety is stored per departed server": refuted. `_withLocal` removes an entry equal to the default (safety_controller.dart:221); the test asserts `saved.last.servers` is empty.
- engine_vault.dart:60 injected store bypassed elsewhere: refuted, `FileVaultStore` is built only at engine_vault.dart:73.
- safety_test null-`listed` case: declined as minor.
