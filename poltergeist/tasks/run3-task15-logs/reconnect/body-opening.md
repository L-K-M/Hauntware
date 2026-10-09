## Scope

Task15 post-merge repair, companion to merged #84 (`6e8b686`). Not another credited task or M3 closure. Preserve #84's route guards, toolbar repair, review history and explicit gaps.

02 UX §2.7 requires cached rows to stay disabled until a listing arrives over the healed connection. Independent supervisor tests proved #84 left verbs enabled on status-only loss and cleared the banner on `connected` alone.

## Repair

- Latch loss, invalidate old generations, preserve cache, disable pane commands/Refresh.
- Re-list the retained channel after connected. Production `reconnect.dart` rebinds healthy `PaneChannel`s before publishing that status; a failed binding can still expose a permanent error. Only an accepted healed listing removes the banner.
- Failed healing exposes localized Retry. Reopen awaits the old channel's release, retains cached rows, and respects attempt/channel ownership. Cancel/detach invalidate healing and cannot disconnect a newer same-id bind or a healthy sibling.
- Loss owns one dim layer, not loading/error overlays. Reserve banner space so the cached first rows remain visible. `canRetryRecovery` exposes only Retry availability to its view; recovery/binding modes stay private.

No core/backend/protocol, dependency/pin, port, or unrelated layout/font change. Stable STATUS IDs14/18/19 retained. PORTS unchanged: no source port.

## Evidence

Persistent artifacts: `tasks/run3-task15-logs/reconnect/`.
- `baseline-red.log`: both portable supervisor regressions fail at runtime on unchanged main; `supervisor-after.log`: the unchanged external supervisor file passes (2 tests).
- `pane_reconnect_test.dart`:13 cases cover status-only/failed/delayed healing, old answers, retry/release waits, cancellation, same-id replacement, sibling isolation, cancelled-first-listing recovery.
- Widget tests cover real session/toolbar enablement, single loss dim and first-row visibility. `overlay-red.log` and `cached-row-red.log` are runtime failures; final widget proof passes.
- Full app565 tests, focused89 tests, analyze clean. Commands, full bounded output and explicit exits retained; `verify.sh` reproduces final checks. Core remains unchanged; exact-head CI validates its gates.
- Seven fresh readable widget captures inspected under `captures/`. Installed Roboto/MaterialIcons and a monospace substitute load only in the isolated harness. Native/install QA remains unverified. No real-SFTP/native or release claim.

Earlier harness corrections (frame settlement and an explicit replacement landing path) are not product red evidence. Full-suite localization failure was a missing reviewed technical-string allowlist, now repaired.

## Review policy

Stabilization carries from #84 (>10 rounds): fix confirmed defects, not optional nits. No claim from green job/count alone; inspect complete edited summaries and paginated feedback, disposition each thread. Exact-head CI/review pending at opening. Hourly check-in armed; PR subscription API unavailable. Supervisor independently accepts task15 after this companion; no next task starts here.
