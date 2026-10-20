# Shared library design: `suite_links` and Séance link intake

Scope: Klabautermann foundations row F5d (03-ARCHITECTURE.md D12, the
section 3.5 table at :1834, section 7.22 and 11.2 item 6; 02-FEATURES.md
X-03, X-04, X-06 and X-10; 04-IMPLEMENTATION.md section 15 decision 18).
New library `suite_links` in `seance/packages/seance_core/lib/src/links/`:
the strict parsers and builders for `seance://connect`,
`poltergeist://browse` and the reserved `klabautermann://server`, plus the
display-safety helpers, moved from Poltergeist's app. Séance gains link
intake (a known server and a starting folder only, asked before
connecting) and scheme registration on five platforms. Poltergeist gains
Android and iOS registration. Dependencies: `seance_protocol` and `meta`
only, both already `seance_core` dependencies
(`seance/packages/seance_core/pubspec.yaml`). No Flutter, no `dartssh2`,
no `poltergeist_core` edge.

Status: proposed for the Klabautermann foundations (F5d); approval under the owner's instruction of 2026-10-13 to implement the plan (`docs/design/klabautermann/06-EXECUTION.md:13-14`).

Main commit read: `11ee9db7`.

Path prefixes: PA = `poltergeist/app/poltergeist_app`, PC =
`poltergeist/packages/poltergeist_core`, SA = `seance/app/seance_app`,
SC = `seance/packages/seance_core`, SP = `seance/packages/seance_protocol`,
KA = `klabautermann/app/klabautermann_app`, KC =
`klabautermann/packages/klabautermann_core`.

## 1. Inventory

### 1.1 Production files

| File | Lines | Contents |
|---|---|---|
| `PA/lib/services/deep_links.dart` | 925 | Constants (:17-21), UUID pattern (:23-26), `DeepLinkFailureKind`/`DeepLinkFailure` (:28-42), `DeepLinkRequest`/`ServerDeepLink`/`HostDeepLink` (:44-89), `_endpointHostKey` (:91-98), `DeepLinkParse` (:100-112), `parsePoltergeistDeepLink` (:114-200), port/host/username/path validators (:202-244), display safety (:246-415), review and handler interfaces (:417-467), `DeepLinkCoordinator` (:469-840), private queue helpers (:842-925) |
| `PA/lib/services/seance_links.dart` | 105 | `seanceDeepLinkScheme`/`seanceConnectRoute` (:7-8), `seanceConnectUriForBookmark` (:10-27), `seanceConnectUriForServer` (:29-30), `_seanceConnectUri` (:32-36); `SeanceLauncher`/`SeanceLinkLauncher` over `url_launcher` with a handler probe (:38-105) |
| `PA/lib/ui/deep_link_dialogs.dart` | 375 | `showDeepLinkReviewDialog` (:16), `showDeepLinkFailureDialog` (:36); calls `safeDeepLinkHostDisplay`/`safeDeepLinkDisplay` at :151-153 and :364-365. App-side, ARB strings |
| `PA/lib/services/quick_connect_address.dart` | 493 | `quickConnectMinPort`/`MaxPort` = 1/65535 (:31-32), `QuickConnectTarget` (:76). App-side; the parser imports it (`deep_links.dart:15`) |
| `PC/lib/src/fs/local_fs_safety.dart` | | `validatePathComponent` (:75-101), `_maxFileNameBytes = 255` (:40), `_utf8ByteLength` (:509); the parser's path rule (`deep_links.dart:12-13, 238`) |
| `SC/lib/src/terminal/shell_command.dart` | 72 | `buildChangeDirectoryCommand` (:10-47): absolute path, no C0/C1 controls, quoted with `quoteShellWord`, never a line terminator. Exported (`SC/lib/seance_core.dart:17`) |
| `SA/lib/services/xterm_engine.dart` | | `TerminalStageResult` (:22-28), `shellIntegration` (:85-86), `injectInput` (:324-329), `stageChangeDirectory` (:351-371): stages the quoted `cd` at a verified empty OSC 133 prompt and never presses Enter |

Call sites. Poltergeist: `main.dart:92-106` creates the coordinator and
feeds it from `AppLinks().uriLinkStream`; `_acceptDeepLink`
(`main.dart:781-794`) adds the URI first and raises a workspace window
second; `main.dart:623-625` probes the Séance handler;
`workspace_shell.dart:542` implements `DeepLinkHandler`, binds it at
:623-635, and handles `reviewHost` (:3837-3846), `openHost`
(:3849-3863), `openServer` (:3865-3880) and `showFailure` (:3882-3899);
`ui/sidebar/seance_commands.dart:23,35,40` call the launcher. Séance: no
link handling exists. A search for `app_links`, `uni_links`, `seance://`,
`uriLinkStream` and `onGenerateRoute` under `seance/` finds nothing
outside docs. `SA/lib/services/web_links.dart` opens only `http`/`https`
links from terminal output.

### 1.2 Poltergeist's parser

`parsePoltergeistDeepLink` (:114-200) is strict:

- Scheme and route compare case-insensitively; a path other than empty
  or `/`, a fragment, an authority port or userinfo refuse the link as
  `unsupportedLink` (:115-124).
- A malformed query (`FormatException`) or any repeated key refuses as
  `invalidParameters` (:126-138).
- Key sets are exact (`setEquals`, :142, :170). `{serverId, path}`
  requires a UUID (any case, lowercased on output, :149, :160).
  `{host, port, username, path}` requires a decimal port 1 to 65535
  without sign or spaces (:175-183, :202-212), a host of at most 1,024
  units with no space, control, `/ \ @ ? # &` (:214-223), and a username
  with no display control (:225-228). A host form missing only `port`
  reads `invalidPort` (:164-169).
- The path is absolute, at most 4,096 UTF-8 bytes, and every component
  passes `validatePathComponent`: non-empty, not `.` or `..`, no `/`,
  `\` or NUL, at most 255 bytes (:230-244; `PC/.../local_fs_safety.dart:83-101`).
  A trailing slash or `//` therefore refuses.

Coupling that blocks a verbatim move:

- `package:flutter/foundation.dart` (:11) for `setEquals`, `@immutable`
  and, in the coordinator, `ValueListenable`, `ValueNotifier` and
  `FlutterError` (:464, :864, :835-839).
- `validatePathComponent` from `poltergeist_core` (:12-13), which
  `seance_core` cannot import (Poltergeist depends on Séance,
  `PC/pubspec.yaml:20-21`).
- `quick_connect_address.dart` (:15) for the port bounds and for
  `HostDeepLink.target` (:75-80).
- `_validHost` and `_validUsername` call `_isUnsafeDisplayControl`
  (:217, :227), which belongs to the display block.

### 1.3 Display safety

`safeDeepLinkDisplay` (:272-283) strips C0, DEL, C1, U+2028/2029 and the
default-ignorable format characters (bidi overrides, zero-width marks,
variation selectors, tags; :344-368) and reports whether it removed any.
`safeDeepLinkHostDisplay` (:285-312) adds per-label flags for
non-ASCII, mixed scripts (Han with kana or Hangul is not mixed,
:314-330) and unclassified scripts. All of it is pure Dart apart from
`@immutable`.

Séance's review needs `safeDeepLinkDisplay`: the starting folder comes
from the link, and `buildChangeDirectoryCommand` rejects only C0/C1
(`shell_command.dart:30-38`), so a bidi override or zero-width mark would
reach the dialog. The parser needs the predicate itself (1.2). The plan's
"[guess: needs them]" holds: the whole block (:246-415) moves.

### 1.4 Intake queue

`DeepLinkCoordinator` (:469-840) serializes requests to the active
workspace's handler. Host forms coalesce by endpoint key
(`_endpointHostKey`: host lowercased except an IPv6 zone id, :91-98) and
count activations (:82-88, :525-543); the review shows the current link,
at most two waiting (`deepLinkVisibleQueueLimit = 3`, :19, :750-771) and
an overflow iterable; "discard all" removes only the endpoints the
snapshot showed (:465-466, :800-818). A handler failure pauses the queue
and requeues the link (:651-659); a handler change cancels the running
operation and requeues (:491-507, :732-739).

Two facts matter for Séance:

- The pending queue has no count limit. `_pending` is an unbounded
  `ListQueue` (:476); only the review's visible list is bounded. Server
  links and failures do not coalesce.
- Only host forms are reviewed. A catalog-id link opens the server
  directly (:667-705; `workspace_shell.dart:3865-3880`), as `PORTS.md`
  states ("Catalog misses stop; host forms always show the endpoint
  review", `poltergeist/docs/PORTS.md:458-460`).

The coordinator is Flutter code with Poltergeist's host-coalescing shape.
It stays in Poltergeist (§6 gives Séance its own).

### 1.5 Outbound Séance links

`seanceConnectUriForBookmark` sends `serverId` when the bookmark's
`BookmarkServerRef` has a `serverConfigId`, else `host`, `port` and
`username` from its `EmbeddedHostIdentity` (`seance_links.dart:10-27`).
`Bookmark`, `BookmarkServerRef` (`SP/lib/src/models/bookmark.dart:15-17`)
and `ServerConfig` (`SP/lib/src/models/server_config.dart:54`) are
`seance_protocol` types, so lines 7-36 can move whole. The builders do not
validate the id. No `poltergeist://browse` builder exists: tests build
those URIs with `Uri(...)` (`PA/test/services/deep_links_test.dart:705-706`).

### 1.6 Séance today

- Servers: ids come from `uuidV4()` (`SA/lib/ui/server_editor.dart:256`),
  which prints lowercase hex (`SP/lib/src/crypto/random.dart:16-28`). The
  local shell row uses `kLocalShellServerId = 'local-shell'`
  (`SA/lib/app_state.dart:98`), which a UUID check refuses.
- Opening: `openTerminal` focuses the server's last tab or opens one
  (`app_state.dart:1288-1301`); `newTab` always opens and connects a new
  tab (:1354-1371). `configFor` falls back to open tabs' snapshots when
  the stored list lacks the id (:1655-1666), so it is not a "known
  server" test.
- Prompts: host-key and keyboard-interactive prompts go to the root
  navigator (`SA/lib/main.dart:148-157`); the settings window's engine
  runs the same `main` and returns early (:35-38).
- Starting folder: Files' "Open terminal here" previews the `cd`, asks,
  and stages it ("Séance will not press Enter"), with one message per
  `TerminalStageResult` (`SA/lib/ui/files_pane.dart:1231-1302`); Git's
  repo-root action does the same (`SA/lib/ui/git_pane.dart:195-210`).
  Staging needs OSC 133 shell integration, which is opt-in
  (`seance/docs/SHELL_INTEGRATION.md`).
- Instances: the Linux runner is `G_APPLICATION_NON_UNIQUE`
  (`SA/linux/runner/my_application.cc:130-131`) and its
  `local_command_line` handles everything locally (:65-84); the Windows
  runner has no mutex (`SA/windows/runner/main.cpp:8-46`). This is open
  item STORE-02 (P1, `seance/ANALYSIS.md:789-806`): two instances clobber
  each other's stores.
- Plugins: `url_launcher`, `share_plus`, `file_picker`
  (`SA/pubspec.yaml:67,76,78`); no `app_links`. No ARB and no
  `l10n_contract` dev dependency; UI strings are literals.

### 1.7 Native registration today

| Platform | Poltergeist | Séance |
|---|---|---|
| Android | Launcher filter only (`PA/android/.../AndroidManifest.xml:31-34`); `<queries>` for `seance` (:47-52) | Launcher filter only (`SA/android/.../AndroidManifest.xml:39-42`); `singleTop` (:25) |
| iOS | No `CFBundleURLTypes`; `LSApplicationQueriesSchemes` `seance` (`PA/ios/Runner/Info.plist:29-32`); scene delegate (:46-47) | No `CFBundleURLTypes`; scene delegate (`SA/ios/Runner/Info.plist:44-45`) |
| macOS | `CFBundleURLTypes` `poltergeist` (`PA/macos/Runner/Info.plist:13-23`) | None |
| Linux | `MimeType=x-scheme-handler/poltergeist;`, `Exec=$2 %u` (`poltergeist/scripts/package-linux.sh:75-84`); unique GApplication with `HANDLES_COMMAND_LINE \| HANDLES_OPEN` (`PA/linux/runner/my_application.cc:153-154`), `local_command_line` returns `FALSE` (:105) | `Exec=$2` with no `%u` and no `MimeType` (`seance/scripts/package-linux.sh:295-311`); non-unique (1.6) |
| Windows | `deep_link_scheme.{h,cpp}` (30 and 270 lines): per-user `HKCU\Software\Classes\poltergeist` registration (:13-18, :167), named mutex claim-or-forward (:21-24, :216-265), wired in `main.cpp:11-21` and `flutter_window.cpp:126` | None |

Neither app sets `flutter_deeplinking_enabled` (Android) or
`FlutterDeepLinkingEnabled` (Apple); `app_links` 7.2.1's example sets both
to false. `app_links` 7.2.1 supports scene delegates on iOS
(`AppLinksIosPlugin.swift:22,62` in the pub cache) and reads Linux links
through the GApplication command line (`app_links_linux` 1.0.3,
`lib/app_links_linux.dart:24-29`).

`PA/test/platform_identity_test.dart` pins the registration:
`registers and forwards the Poltergeist URL scheme` (:145-219) and
`declares sibling-scheme visibility on mobile` (:221-235). Séance has no
platform identity test.

### 1.8 Klabautermann's needs

- X-03: `seance://connect?serverId=<uuid>` (03:4319).
- X-10: the same with `&cwd=<abs>`, applied through
  `buildChangeDirectoryCommand`, never a command parameter (03:4321;
  02:1164).
- X-04: `poltergeist://browse?serverId=<uuid>&path=<abs>` (03:4320;
  02:1158); a stack's folder is the compose `working_dir` label
  (`klabautermann/packages/klabautermann_docker/lib/src/compose/labels.dart:15`,
  `grouping.dart:59`).
- X-06 (v1.x): `klabautermann://server?serverId=<uuid>[&view=...]`
  (03:4323; 02:1160); `view` values are not defined anywhere yet.
- Klabautermann reaches `seance_core` only through reviewed `show`
  exports in `KC/lib/klabautermann_core.dart` (precedents :21-22, :141).
  `KA/pubspec.yaml` has no `url_launcher` or `app_links`.

All three apps need only builders on the sending side. Klabautermann
parses nothing until X-06.

### 1.9 Tests

| File | Lines | Covers |
|---|---|---|
| `PA/test/services/deep_links_test.dart` | 858 | Parser (:9-185), display (:187-260), coordinator (:261-858) |
| `PA/test/services/seance_links_test.dart` | 117 | Builder forms and the launcher probe |
| `PA/test/ui/deep_link_dialog_test.dart` | 465 | Review and failure dialogs |
| `PA/test/ui/deep_link_shell_test.dart` | 363 | Workspace handler binding |
| `PA/test/localization_contract_test.dart` | | Technical-literal allowlist entries for `deep_links.dart` (:1344-1360) and `seance_links.dart` (:1361-1374) |
| `SC/test/shell_command_test.dart` | | `buildChangeDirectoryCommand` (:79 on) |

## 2. Link contract

One grammar per form. Every parser refuses the whole link on any
deviation; there is no partial acceptance and no default.

| Form | Keys (exact set) | Rules |
|---|---|---|
| `seance://connect` by id | `serverId`, optional `cwd` | UUID, lowercased; `cwd` as below |
| `seance://connect` by identity (Q10) | `host`, `port`, `username` | Poltergeist's host, port and username rules (1.2); no `cwd` |
| `poltergeist://browse` by id | `serverId`, `path` | Unchanged (1.2) |
| `poltergeist://browse` by identity | `host`, `port`, `username`, `path` | Unchanged (1.2) |
| `klabautermann://server` | reserved | Refused by every parser until X-06 defines it |

Shared rules for all forms: scheme and route case-insensitive; no path
beyond `/`, fragment, authority port or userinfo; no repeated key; no
malformed percent-encoding.

`cwd` uses the browse path rule (absolute, at most 4,096 UTF-8 bytes,
components per `validatePathComponent`) and additionally refuses C0 and
C1 controls, the exact set `buildChangeDirectoryCommand` throws on
(`shell_command.dart:30-38`), so a link that parses can always be staged.
One path grammar for both apps keeps the corpus single; the cost is that
a folder whose name contains `\` cannot be linked, as in Poltergeist
today.

No key outside these sets is accepted. `cmd`, `command`, `exec`, `run`,
`script`, `snippet` and any unknown key refuse the link (D12, 03:401-403;
X8 in the M5 plan). The identity form takes no `cwd` because Poltergeist
never sends one (`seance_links.dart:22-26`) and Klabautermann always has
an id (1.8).

Builders validate with the same predicates and throw `ArgumentError`
otherwise, so `parse(build(x)) == x` for every valid input. Callers
normalize first: a trailing slash or `//` is refused, not repaired.

## 3. Q10: the identity form

Question (M5 plan Q10): Poltergeist sends `seance://connect?host&port&username`
when a bookmark has no server id (`seance_links.dart:18-27`), while D12
says a link picks "a server and a starting folder" only (03:401-403).

Answer: yes. Séance accepts the identity form only to look up a server it
already has, and refuses otherwise. It never creates, saves or edits a
server from a link.

- Match: stored servers (not tab snapshots, 1.6) whose host compares by
  Poltergeist's endpoint key (case-insensitive except an IPv6 zone id,
  `deep_links.dart:91-98`), with equal port and equal username.
- Exactly one match: the link continues as if it carried that server's
  id, through the same review (§6).
- No match: refused with "This link names a server Séance does not have."
- Several matches: refused with "Several saved servers match this link."
  A picker would let a link choose among servers, which D12 does not
  allow.
- The review shows Séance's own label and endpoint for the match, never
  link text.

## 4. Library placement and dependencies

```
seance/packages/seance_core/lib/
  seance_core.dart          + export 'src/links/suite_links.dart';
                            + export 'src/fs/path_component.dart'
                                show validatePathComponent,
                                     maxFileNameBytes, utf8ByteLength;
  src/links/suite_links.dart       NEW parsers, builders, models
  src/links/link_display.dart      NEW display safety (moved)
  src/fs/path_component.dart       NEW validatePathComponent (moved)
```

- The barrel export follows 03's tree (03:1514, :1521).
- `validatePathComponent` moves rather than being copied (AGENTS.md:
  shared implementations are never copied). Its byte counter and limit
  move with it, because `local_fs_safety.dart:287-291` also uses them;
  `poltergeist_core` imports all three from `seance_core` and keeps
  re-exporting `validatePathComponent` from its barrel (`PC/lib/poltergeist_core.dart:282-291`).
  Making `maxFileNameBytes` and `utf8ByteLength` public is the one API
  widening; the alternative, a private copy in each package, is the copy
  the rule forbids.
- `setEquals` becomes a length-plus-`containsAll` check; `@immutable`
  comes from `package:meta`. No behavior changes.
- Poltergeist reaches the library through `poltergeist_core`'s `show`
  list (`PC/lib/poltergeist_core.dart:11-14, :31`). Klabautermann adds
  `show buildSeanceConnect, buildPoltergeistBrowse` in M31.
- `tool/guards.yaml` needs no change: nothing imports
  `package:seance_core/src/links/`.

## 5. Public API

Names already used by Poltergeist keep their spelling (D3: move, then
switch; renames would churn four test files for no gain).

```dart
// suite_links.dart
const seanceDeepLinkScheme = 'seance';
const seanceConnectRoute = 'connect';
const poltergeistDeepLinkScheme = 'poltergeist';
const poltergeistBrowseRoute = 'browse';
const klabautermannDeepLinkScheme = 'klabautermann';   // F5d-2, reserved
const klabautermannServerRoute = 'server';             // F5d-2, reserved

enum DeepLinkFailureKind {
  unsupportedLink, invalidParameters, invalidPort, invalidPath,
  serverNotFound,
}
final class DeepLinkFailure { kind; String? serverId; }

// Poltergeist's forms, moved (F5d-1).
sealed class DeepLinkRequest { String remotePath; }
final class ServerDeepLink extends DeepLinkRequest { String serverId; }
final class HostDeepLink extends DeepLinkRequest {
  String host; int port; String username; int activationCount;
  ({String host, int port, String username}) get endpointKey;
  HostDeepLink coalesce(HostDeepLink newer);
}
final class DeepLinkParse { DeepLinkRequest? request; DeepLinkFailure? failure; }
DeepLinkParse parsePoltergeistDeepLink(Uri uri);

// Outbound Séance links, moved (F5d-1); validating from F5d-2.
Uri seanceConnectUriForBookmark(Bookmark bookmark);
Uri seanceConnectUriForServer(ServerConfig server);

// New (F5d-2).
sealed class SeanceConnectRequest {}
final class SeanceServerConnect extends SeanceConnectRequest {
  String serverId; String? cwd;
}
final class SeanceIdentityConnect extends SeanceConnectRequest {
  String host; int port; String username;
  ({String host, int port, String username}) get endpointKey;
}
final class SeanceConnectParse {
  SeanceConnectRequest? request; DeepLinkFailure? failure;
}
SeanceConnectParse parseSeanceConnect(Uri uri);
Uri buildSeanceConnect({required String serverId, String? cwd});
Uri buildPoltergeistBrowse({required String serverId, required String path});

// link_display.dart, moved (F5d-1).
class SafeDeepLinkDisplay { String text; bool removedControls; }
final class SafeDeepLinkHostDisplay extends SafeDeepLinkDisplay {
  bool internationalized; bool mixedScripts; bool unrecognizedScripts;
}
SafeDeepLinkDisplay safeDeepLinkDisplay(String value);
SafeDeepLinkHostDisplay safeDeepLinkHostDisplay(String value);
```

Notes:

- `DeepLinkFailureKind` is shared, so a new kind breaks both apps'
  exhaustive switches on purpose. `serverNotFound` stays in it because
  Poltergeist's coordinator reports it (:684-690). Séance's lookup
  outcomes (not found, ambiguous) are its intake's own enum, not new
  parser kinds.
- `HostDeepLink.target` returns Poltergeist's `QuickConnectTarget`, so it
  becomes an extension in the app's `deep_links.dart`
  (`extension HostDeepLinkQuickConnect on HostDeepLink`); call sites that
  import the file are unchanged (`workspace_shell.dart:26`).
- No `klabautermann://` parser or builder until X-06 defines `view`:
  only the two constants, so the corpus can assert that Séance's and
  Poltergeist's parsers refuse that scheme. A speculative parser would
  fix a grammar nobody has designed.
- Kept app-side in Poltergeist: `DeepLinkCoordinator`, the review and
  handler interfaces, `deepLinkVisibleQueueLimit`, the dialogs and
  `SeanceLinkLauncher`. `deep_links.dart` and `seance_links.dart` stay at
  their paths and re-export the moved names, so the four test files and
  `main.dart`, `app.dart`, `workspace_shell.dart`, `deep_link_dialogs.dart`
  and `seance_commands.dart` keep their imports.

## 6. Séance intake

New files: `SA/lib/services/link_intake.dart` (queue and outcome types)
and `SA/lib/ui/link_review_dialog.dart`. Modelled on Poltergeist's
coordinator (1.4), with three differences: every link is reviewed, the
queue has a hard limit, and there is no host coalescing.

Delivery:

- `main()` subscribes to `AppLinks().uriLinkStream` after the settings
  window's early return (`SA/lib/main.dart:35-38`) and before `runApp`,
  so a cold-start link is queued. The intake stores links durably first
  and raises the window second, as `_acceptDeepLink` does
  (`PA/lib/main.dart:781-794`).
- The handler binds once `_init` has produced the `AppState` and the root
  navigator exists (`main.dart:141-172`). Until then links wait.

Queue:

- `seanceLinkQueueLimit = 16` pending requests. Identical requests (same
  server id and `cwd`, or same identity key) coalesce. A link beyond the
  limit is dropped and counted; the next review shows "N more links were
  ignored." 16 is an assumption: large enough for a burst of hand-offs,
  small enough that a link flood cannot grow memory or keep dialogs
  coming.
- One review at a time. The review shows the current request, up to two
  waiting ones and a count, and offers "Discard waiting links", limited
  to the ones shown, as Poltergeist's does (:465-466).
- A handler error requeues the request at the head and pauses until the
  next link or rebind (Poltergeist's rule, :651-659).

Per request:

1. A parse failure shows a notice naming the problem ("This link is not
   a Séance link", "This link has parameters Séance does not accept", "The
   starting folder in this link is not valid"). Nothing connects.
2. Resolve: the id form looks up the stored server list only. The
   identity form follows §3. A miss or ambiguity shows a notice.
3. Review dialog ("Open a terminal from a link?"): the server's saved
   label and `user@host:port` from Séance's store; the starting folder
   from the link through `safeDeepLinkDisplay`, with "Hidden characters
   were removed from this folder name" when it removed any; and "Links
   cannot run commands. Séance types the cd command at the prompt and
   does not press Enter." Buttons: Cancel and Connect.
4. Connect without `cwd`: `openTerminal(config)`, the server row's
   focus-or-connect (`app_state.dart:1288-1301`).
5. Connect with `cwd`: `newTab(config)` (:1354-1371), so the `cd` lands
   at a fresh prompt and never in a tab with pending input. The intake
   then waits for that tab's `shellIntegration` to report a known shell
   at `acceptingInput` with no input, bounded at 20 seconds after
   `connected` (an assumption), and calls
   `engine.stageChangeDirectory(cwd)` (`xterm_engine.dart:351-371`). Any
   result but `staged`, or the timeout, shows a message naming the
   folder with a Copy path action, worded like Files'
   (`files_pane.dart:1287-1296`). Séance never sends Enter and never
   falls back to typing the path without integration.
6. Host-key, credential and app-lock prompts run on the normal connect
   path (`main.dart:148-157`); the intake bypasses none of them.

Strings are English literals, as elsewhere in Séance (1.6). The Séance
changelog records the intake in F5d-3a and the registration in F5d-3b/3c.

## 7. Native registration

Séance (F5d-3b and F5d-3c). `app_links` 7.2.1, the version Poltergeist
pins (`PA/pubspec.yaml:12`), with the license gate.

| Platform | Change | PR |
|---|---|---|
| Android | On `MainActivity`: an intent filter with `VIEW`, `DEFAULT`, `BROWSABLE` and `<data android:scheme="seance" android:host="connect"/>` next to the launcher filter (`AndroidManifest.xml:39-42`); `flutter_deeplinking_enabled` = false. `singleTop` (:25) keeps one activity | 3b |
| iOS | `CFBundleURLTypes` (name `ch.lkmc.seance`, scheme `seance`); `FlutterDeepLinkingEnabled` = false. The existing scene delegate stays (1.7) | 3b |
| macOS | `CFBundleURLTypes` as on iOS; `FlutterDeepLinkingEnabled` = false. LaunchServices delivers to the running instance | 3b |
| Linux | Unique GApplication with `HANDLES_COMMAND_LINE \| HANDLES_OPEN`, `local_command_line` returning `FALSE`, and the existing window presented on a forwarded launch, as Poltergeist's runner does (1.7); desktop entry `Exec=$2 %u` and `MimeType=x-scheme-handler/seance;` | 3c |
| Windows | Copy of Poltergeist's `deep_link_scheme.{h,cpp}` with Séance's names (`Software\Classes\seance`, `URL:Séance` spelled ASCII for MSVC, mutex and window property `ch.lkmc.seance.deep-link-primary-v1`), wired in `main.cpp` and `flutter_window.cpp` | 3c |

Linux and Windows registration requires single-instance forwarding:
without it a link starts a second Séance that writes the same stores
(STORE-02). The forward makes every relaunch focus the running window,
which is STORE-02's proposed native fix (`seance/ANALYSIS.md:799-801`).
That is a visible behavior change, so it gets its own PR (3c) and an open
question (§12). STORE-02's Dart lock backstop stays out of F5d.

Application ids and bundle identifiers do not change
(`ch.lkmc.seance`, `ch.lkmc.seanceApp`). The Flatpak repacks the `.deb`
(`seance/scripts/build-flatpak.sh:3-7`), so it inherits the desktop
entry; whether Flatpak exports the scheme handler is a manual check.

Poltergeist (F5d-4):

| Platform | Change |
|---|---|
| Android | Intent filter with `VIEW`, `DEFAULT`, `BROWSABLE` and `<data android:scheme="poltergeist" android:host="browse"/>`; `flutter_deeplinking_enabled` = false |
| iOS | `CFBundleURLTypes` (name `ch.lkmc.poltergeist`, scheme `poltergeist`, as `PA/macos/Runner/Info.plist:13-23`); `FlutterDeepLinkingEnabled` = false |

Poltergeist already listens on every platform (`PA/lib/main.dart:94`);
F5d-4 is manifest and plist work plus tests.

D32 check. D32's ledger is `klabautermann/docs/SHARED.md`, which records
Klabautermann's copies (SHARED.md:3-7). Séance's Windows copy is a
sibling port between Séance and Poltergeist; those are recorded in
`poltergeist/docs/PORTS.md` in both directions
(`seance/docs/POLTERGEIST.md:198-201`), in F5d-5. Scheme runner code then
exists in two apps; X-06 (v1.x) makes Klabautermann the third, with a
SHARED.md entry. D32's shared-plugin review is due before a fourth copy;
F5d-5's entry says so.

## 8. Staged PRs

Each PR moves code and switches at least one shipped app with its full
suite unchanged (D3). Changes under `seance/` merge one at a time with
merge commits and run the pin audit (06:54-55); `PORTS.md` is a root file
(06:48-53), so ledger work is batched in F5d-5.

| PR | Contents | Switches | Size | Gates |
|---|---|---|---|---|
| F5d-0 | This doc | none | ~600, docs | Review |
| F5d-1 [S] | `SC/lib/src/links/` (`deep_links.dart:17-415` minus the coordinator, `seance_links.dart:7-36`), `SC/lib/src/fs/path_component.dart` moved from `local_fs_safety.dart`, barrel exports; `poltergeist_core` imports the moved path rule and re-exports the link names; Poltergeist's two files become shims (coordinator and launcher stay); `HostDeepLink.target` becomes an app extension; moved literals leave the localization allowlist (:1344-1374), the coordinator's `'unknown deep-link request'` and the launcher's message stay | Poltergeist | ~1,000, move | Poltergeist full suite with the four link test files unchanged; `seance_core` tests gain the parser and display groups; pin audit refresh if `--print-findings` reports drift |
| F5d-2 [S] | `parseSeanceConnect` with `cwd` and the Q10 identity form; `buildSeanceConnect`, `buildPoltergeistBrowse`; the two outbound builders validate; reserved `klabautermann` constants; the link contract corpus (§9) | none | ~700 | Corpus green in `seance_core`; Poltergeist suite (corpus over its parser and coordinator); X8 command-key cases |
| F5d-3a [S] | Séance intake (§6), review dialog, Séance changelog | Séance (Dart) | ~1,200 | Séance full suite and captures unchanged; new widget tests (§9) |
| F5d-3b [S] | `app_links` 7.2.1; Android, iOS and macOS registration; Séance platform contract test | Séance | ~300 | License gate; platform test; manual device checks listed |
| F5d-3c [S] | Linux and Windows registration with single-instance forwarding (§7) | Séance | ~600 | Platform test; CI builds; manual relaunch and link checks on Linux and Windows |
| F5d-4 | Poltergeist Android and iOS registration | Poltergeist | ~200 | `platform_identity_test.dart` extended; CI builds; manual device checks |
| F5d-5 [R] | `PORTS.md`: the moved link files and `validatePathComponent`, Séance's Windows runner copy and D32's fourth-copy note | none | ~200 | Docs; `scripts/check-workflows.sh` unaffected |

Order: F5d-1 → F5d-2 → F5d-3a → F5d-3b → F5d-3c in the [S] queue.
F5d-4 depends on nothing and can merge any time. F5d-5 follows F5d-1,
F5d-3c and F5d-4. M31 needs F5d-2 for the builders, F5d-3b/3c for each
Séance platform it offers, and F5d-4 for Poltergeist on phones (D12:
"Until both land, the app does not offer hand-offs on that platform",
03:402-403).

F5d-4 shrinks from the plan's ~400 because Poltergeist's Dart side and
desktop runners already exist (1.7). Splitting F5d-3b adds one entry to
the [S] queue; if the queue is the constraint, 3b and 3c can merge as one
~900-line PR.

## 9. Tests

Link contract corpus (11.2 item 6). One JSON file,
`SC/test/fixtures/suite_link_corpus.json`, with `{uri, form, verdict,
kind}` rows. `seance_core` tests run it against the parsers; Séance's and
Poltergeist's intake tests read it by relative path (precedent:
`PA/test/platform_identity_test.dart:155` reads `../../scripts/`) and
assert that no refused row reaches a handler. Rows:

- Accepted, one per form, plus round trips through each builder:
  uppercase UUID (lowercased), `cwd` `/`, `cwd` with spaces, `'`, `"`,
  `$`, `;`, `+`, `%2B` and non-ASCII; IPv6 host with a zone id in the
  browse identity form.
- Refused, every form: wrong scheme, wrong route, path segment, fragment,
  authority port, userinfo, repeated key, `%ZZ`, empty query.
- Refused, keys: `cmd`, `command`, `exec`, `run`, `script`, `snippet`,
  an unknown key, `cwd` on the identity form, `path` on `seance://`,
  `cwd` on `poltergeist://`.
- Refused, values: non-UUID id, `local-shell`, relative `cwd`, `.` and
  `..` components, `//`, trailing slash, `%00`, `%0A`, `%C2%85`, `\`, a
  component over 255 bytes, a path over 4,096 bytes; port 0, 65536,
  `+22`, ` 22`.
- Refused by both parsers: `klabautermann://server?serverId=<uuid>`.

Per PR:

- F5d-1: Poltergeist's `deep_links_test.dart`, `seance_links_test.dart`,
  `deep_link_dialog_test.dart` and `deep_link_shell_test.dart` unchanged;
  `SC/test/links/suite_links_test.dart` holds copies of the parser and
  display groups (:9-260), which F5d-2 replaces with the corpus. Poltergeist's
  `local_fs_safety` tests unchanged.
- F5d-2: corpus; builder `ArgumentError` cases; parse-of-build property
  over generated folders.
- F5d-3a: unknown id refused with no connect; identity form with zero,
  one and two matches; tab snapshot not treated as known; the review
  shows stored label and endpoint, never link text, and strips hidden
  characters from the folder; Cancel connects nothing; Connect without
  `cwd` focuses an existing tab; Connect with `cwd` opens a tab and
  stages exactly `buildChangeDirectoryCommand(cwd)` with no `\r` or `\n`
  written; no integration and timeout paths show the copy message; queue
  limit and coalescing; links before `AppState` load are delivered after
  it; settings-window entry does not subscribe.
- F5d-3b/3c: a Séance platform test in the style of
  `PA/test/platform_identity_test.dart:145-235` (manifest filter, plists,
  desktop entry, GApplication flags, registry and mutex strings, the
  two deep-linking opt-outs).
- F5d-4: the mobile assertions added to `platform_identity_test.dart`.

Manual (AGENTS.md: compilation is not a device smoke test): a link from
another app on Android, iOS and macOS, cold and warm; on Linux and
Windows, a link and a plain relaunch with Séance running and not
running; Flatpak handler export.

## 10. Risks

1. Move drift: replacing `setEquals` and `@immutable`, and the
   `target` extension, are the only edits in F5d-1. Poltergeist's
   unchanged suites prove them.
2. Single instance: F5d-3c changes Séance's relaunch behavior on Linux
   and Windows. Users who run two Séance windows as two processes lose
   that; given STORE-02 they were already risking their stores.
3. Flutter's built-in deep linking: without the opt-out, Flutter may
   also push the URI as a route on Android and iOS [guess: the 3.47
   default is on]. Both apps set it explicitly; the platform tests pin it.
4. Spoofed folders: a bidi override or zero-width mark in `cwd` passes
   the path grammar. The review strips and flags them; the staged
   command is built from the parsed value, which the user sees in the
   prompt before pressing Enter.
5. Staging needs integration: most remote shells have no OSC 133 until
   the user sets it up, so X-10 often ends at the copy message. That is
   the cost of never pressing Enter; Klabautermann's menu entry text
   should not promise more.
6. Link floods: the hard limit bounds memory and dialogs; Poltergeist
   keeps its unbounded queue (1.4, §11).
7. Builder validation in F5d-2: `seanceConnectUriForBookmark` will throw
   `ArgumentError` for a non-UUID id before `SeanceLinkLauncher._open`'s
   `try` (`seance_links.dart:84-85, 91-98`). Catalog ids are UUIDs
   [guess for ids created by older builds]; the launcher wraps the call
   so a bad id reports through `onError` instead of throwing.
8. Second engines: both apps run a settings window engine that also
   registers plugins. `app_links` uses one shared instance on macOS
   (`AppLinksMacosPlugin.swift:16-26`) and only the main engine
   subscribes; Poltergeist ships this shape on macOS today. Manual check
   with the settings window open.
9. [S] queue: five Séance PRs. Each runs `--print-findings` early.

## 11. Corrections to the plan

1. "A bounded queue of pending links (Poltergeist's model)" (03:4328):
   Poltergeist bounds only the review's visible list (:19, :750-771);
   `_pending` has no limit (:476). Séance adds a hard limit (§6).
2. "A visible trust review before any connect" for every intake
   (03:4327): Poltergeist opens catalog-id links without a review (1.4).
   Séance reviews every link. Changing Poltergeist is out of scope and a
   follow-up candidate.
3. The parser cannot move verbatim (1.2): Flutter imports,
   `poltergeist_core`'s path rule and an app type. The display helpers
   must move with it, because the parser calls their predicate and
   Séance's review needs `safeDeepLinkDisplay`.
4. `seance_links.dart:7-36` moves whole: `Bookmark` and `ServerConfig`
   are `seance_protocol` types (1.5). No `poltergeist://browse` builder
   exists; F5d-2 adds one.
5. `buildChangeDirectoryCommand` does not apply a folder: it builds text
   for review. Séance's `stageChangeDirectory` stages it without Enter
   and needs opt-in OSC 133 integration (1.6).
6. Séance's desktop runners are multi-instance (1.6); registration there
   needs single-instance forwarding, hence F5d-3c.
7. D32's ledger is Klabautermann's; Séance's runner copy goes to
   `PORTS.md` (§7). F5d-5 also depends on F5d-3c.
8. Neither app opts out of Flutter's deep-link routing (1.7).

## 12. Open questions and recommendation

| # | Question | Recommendation |
|---|---|---|
| Q10 | Should Séance accept Poltergeist's identity form only to look up a known server, and refuse otherwise? | **Yes** (§3): exactly one stored match continues to the review; none or several refuse; no `cwd` on that form; Séance never creates a server from a link. |
| Q11 | May F5d-3c make Séance single-instance on Linux and Windows (a relaunch focuses the running window)? | **Yes.** Link delivery needs it, and it is STORE-02's proposed fix for store clobbering. If not, Séance registers its scheme on Android, iOS and macOS only and Klabautermann offers X-03 and X-10 there only. |

Decided here, not open: the display helpers move (§1.3); the path rule
moves to `seance_core` (§4); no `klabautermann://` parser before X-06
(§5); the `cd` is staged, never submitted (§6).

Estimates: `suite_links` production ~650 lines (moved ~430, new ~220);
Poltergeist shims ~60; Séance intake and dialog ~700 plus ~500 tests;
native ~500 across both apps; corpus ~150 rows. Total about 4,000
changed lines over seven PRs, consistent with 03's "M" for F5d (03:1834).

Recommendation: proceed as staged, with Q10 and Q11 answered yes.
