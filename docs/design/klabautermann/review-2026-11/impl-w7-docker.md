# Wave 7 DOCKER (plan rows 1.4, 2.9, Docker lows)

PRs: #805 `klab/docker-fixes` head 271a7b3e4; #806 `klab/docker-fixes-2`
head b7b842c05. Both cut from origin/main 4137174ab, ready, not
subscribed, not merged. They touch different files and do not depend on
each other.

## Findings

| Finding | Status | Where | Test (red, then green) |
|---|---|---|---|
| DKR-1 router catch | FIXED 271a7b3e4 | `docker_router.dart` `_read` gains `on Object` -> `DockerQueryFailed(connectionFailed, detail: type only)`; `_run` gives `inFlight` back in `finally` | `docker_router_test` "a read that throws something other than a Docker error...": red = unhandled `Bad state: not a Docker error` plus 5 s timeout waiting for the result; green |
| DKR-1 window clamp | FIXED 271a7b3e4 | `RegistryRateLimit.maxWindow` (24 h), clamped as seconds in `_parse` | `registry_reference_test` "a window is a day at most", `image_updates_test` "a 429 that names an absurd window": red = compile failure (constant missing; the RangeError itself is the report's confirmed scenario); green |
| DKR-1 ascii.decode | FIXED 271a7b3e4 | `stack_sources.dart` `_readElevated`, `allowInvalid: true` | `test/admin/elevated_reads_test` "a first line that is not ASCII": red = `FormatException: Invalid value in input: 195`; green |
| DKR-4 | FIXED 271a7b3e4 | `image_updates.dart` `_forgetChanged`: rows whose tag is gone or names another image are dropped before the check | `image_updates_test` "a row is for the image its tag named": red = 1 host command where 2 expected; green |
| DKR-5 | FIXED 271a7b3e4 | `exec_sessions.dart` sends one resize after the start when `!gates.hasExecConsoleSize`; new gate and `apiVersionExecConsoleSize` in `api_version.dart` replace the private constant in `endpoints.dart` | `exec_sessions_test` "below API 1.42...": red = resizes `[]`, expected `['e1 120x40']`; green. Plus a 1.44 case that expects no resize |
| DKR-8 | FIXED 271a7b3e4 | `container_logs.dart`: three protocol errors running without a line end a follow as `failed`, detail = the error plus the framing warning when set | `container_logs_test` "a follow whose stream breaks the wire format three times": red = a fifth `/logs` request and no end; green |
| DKR-2 | FIXED b7b842c05 | `http_client.dart` `_open` closes the duplex and throws when the client closed meanwhile; `docker_watch.dart` cancels the body on an epoch mismatch | `http_pool_test` two "close while ... duplex opens" tests: red = timeout (request hung on a closed client); green |
| DKR-3 | FIXED b7b842c05 | `_BodyCtl` and the hijack controller hold the duplex paused until a listener comes; a hijacked duplex closed unheard calls `onDead` | `http_pool_test` "a body nobody listens to yet..." and "a hijacked duplex nobody listens to yet...": red = `clientReadPaused` false; green |
| DKR-7 | FIXED b7b842c05 | `_Connection.hasStrayBytes`, checked in `usable` and `_release` | `http_pool_test` group "stray bytes": red = 1 open where 2 expected (the stale response answered the next request); green |
| DKR-10 | DONE b7b842c05 (refactor) | new internal `lib/src/byte_read_buffer.dart`, used by the HTTP parser, `demuxStdcopy`, `byteStreamToLines` | new `byte_read_buffer_test`; existing parser suites unchanged and green |
| DKR-12 | DONE | every test it names for the items above exists now | |
| DKR-6, DKR-9, DKR-11 | NOT DONE | out of scope per brief | |

All findings were confirmed real on origin/main before the fix (each red
run above is on unmodified main code).

## Checks (local)

- `dart analyze --fatal-infos packages/klabautermann_docker packages/klabautermann_core`: no issues on both branches.
- #805: `dart test packages/klabautermann_docker` +425; `packages/klabautermann_core` +2041 ~30. All passed.
- #806: `dart test packages/klabautermann_docker` +435; `packages/klabautermann_core` +2034 ~30. All passed.
- `dart format` on every changed file: no change.
- Not run: app `flutter analyze`/`flutter test` (app unchanged), klabautermann_host suite (unchanged), import guard (needs every product resolved; failed on missing poltergeist package_config), protocol guard (no protocol shape changed: `RegistryRateLimit` only clamps a value), CI.

## Notes

- `test/admin/elevated_reads_test.dart` got one test (the harness for the elevated stack read lives there). It is outside `test/docker/`; another agent editing that group may conflict.
- CHANGELOG: four lines in #805. None in #806: nothing user-visible, and a line at the end would conflict with #805.
- DKR-3 is a behaviour change for callers: a streamed body's connection returns to the pool only once the body is listened to and read. All callers in the repository listen at once (checked: watcher, log reader, exec sessions, one-off exec, pull plan).
- The watcher's body cancel (DKR-2) has no test of its own: after the client fix a closed client fails the request or aborts the body, so the branch should be unreachable.
- DKR-8: a clean stream end between two protocol errors does not reset the count; only a line does.
- DKR-1 detail string names the error type only, on purpose (the message could carry unmasked host output).
- Not fixed, noticed: `_readElevated`'s `await for (process.stdout)` still rethrows a stream error; the router's catch now answers it as a failed query instead of a typed stack file failure.

## STATUS sentences

- A Docker query that fails with an unexpected error is answered as a failed query and no longer ends the engine; a registry's rate-limit window is believed for 24 hours at most.
- Image update rows are kept per tag only while the tag names the same image.
- Container shells on API 1.41 are sized by one resize after the start.
- A container log follow ends as failed after three consecutive wire-format errors without a line.
- The Docker HTTP client closes a duplex that opens after `close()`, holds a body or hijacked duplex back until it has a listener, and retires a pooled connection that holds unread bytes.
