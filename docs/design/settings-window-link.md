# Design: move the desktop Settings-window link engine into `ghost_desktop`

Status: approved by the owner on 2026-10-08 as recommended: all three PRs
in §5's order, including Séance's `_Link` enum conversion. Prepared from a read-only research pass (GLM 5.3) over main at 7b41780a; file sizes spot-checked. All paths relative to the repo root; line numbers verified against this checkout of main.

---

## 1. What is generic vs product-specific today

Two implementations exist: Séance's `seance/app/seance_app/lib/services/settings_window.dart` (604 lines, one file) and Poltergeist's `poltergeist/app/poltergeist_app/lib/services/settings_window/` (three files, 1326 lines: `settings_window_link.dart` 281, `settings_window_host.dart` 455, `remote_settings.dart` 590). Poltergeist's copy is a port of Séance's: its native runner files carry the "Ported from Séance … @ 38b7a42; see docs/PORTS.md" stamp, and the Dart header comment at `settings_window_host.dart:9` cites "measured in Séance, whose window this ports; docs/PORTS.md".

### 1.1 The generic engine (identical in both copies, modulo naming)

| Concern | Séance | Poltergeist |
|---|---|---|
| Control channel (`<product>/settings_window`, `open` in / `closed` out) | `settings_window.dart:48-50`, handler `_handleControl` 195-208 | `settings_window_link.dart:20-22`, `settings_window_host.dart:199-211` |
| Link channel (`<product>/settings_link`, relayed by the runners) | `settings_window.dart:53-55` | `settings_window_link.dart:25-27` |
| Host: handler registration, `_connected`/`_visible`/`_tab`/`_lastSnapshot`/`_snapshotScheduled` state | 103-144 | 78-118 |
| `open(tab)`: selectTab vs show+snapshot, `MissingPluginException` reconnect path, control `open`, route/dialog fallback on `MissingPluginException`/`PlatformException`, trailing `_scheduleSnapshot` | 149-187 | 144-188 |
| `dispose()` | 189-193 | 190-197 |
| Closed → `_visible=false`, `_lastSnapshot=null`, send `hidden` | 195-208 | 199-211 |
| Snapshot coalescing (microtask, one per event-loop turn, none while hidden) | 213-220 | 215-222 |
| Snapshot send with string dedupe, and the two failure paths (`MissingPluginException` → disconnect; `PlatformException` → forget dedupe so it retries) | 222-238 | 224-240 |
| Hello handshake (snapshot built first, marks connected+visible, returns `{snapshot, tab}`) | 259-265 | 339-348 |
| Call/reply serialization: JSON-string envelope both directions, decode-what-was-encoded | doc 45-47; `_handleLink` 240-254; `_call` 454-460 | doc 9-10; `_handleLink` 308-320; `_Link.call` 47-53 |
| Error mapping app→window (wrap app-side throw as `PlatformException` so the window can show it) | 249-253 | 323-330 |
| Connection loss window-side (`MissingPluginException` on a call) | 463-467 | `_Link.onLost` + `lost` 44-60, 77-81 |
| `SettingsWindowPage {tab, generation}` (fresh screen per showing) | 331-341 | `remote_settings.dart:24-34` |
| Window side `connect()`: set handler, hello, apply first snapshot, seed page(generation: 0), unhook on failure | 381-401 | 98-122 |
| Window-side `_handle`: `snapshot`/`selectTab`/`hidden`/`show` cases, generation counter | 426-452 | 273-306 |
| `tabRequests` broadcast stream | 353-354, 376, 434-435 | 84-85, 93, 284-285 |
| `requestAppExit` round trip, "no app left → exit" | host 322-323, window 587-594 | host 441-442, window 214-221 |
| Unknown method → `MissingPluginException` | 324-325, 446-449 | 308-314, 300-303 |

### 1.2 Near-verbatim overlaps (quoted)

`_scheduleSnapshot` is character-identical apart from whitespace (`settings_window.dart:213-220` vs `settings_window_host.dart:215-222`):

```dart
void _scheduleSnapshot() {
  if (!_connected || !_visible || _snapshotScheduled) return;
  _snapshotScheduled = true;
  scheduleMicrotask(() {
    _snapshotScheduled = false;
    unawaited(_sendSnapshot());
  });
}
```

`_sendSnapshot` is identical including both comments (`settings_window.dart:222-238` vs `settings_window_host.dart:224-240`), e.g. the identical PlatformException comment: "The window failed to apply it. Forgotten, so the next change sends it again rather than the dedupe skipping what never arrived; and caught, since nothing awaits this."

`open()`'s reconnect block is identical (`settings_window.dart:151-187` vs `settings_window_host.dart:146-188`):

```dart
} on MissingPluginException {
  // The engine went away after all; a new one says hello, and opens
  // on `_tab`.
  _connected = false;
}
```

The hello case is identical (`settings_window.dart:259-265` vs `settings_window_host.dart:339-348`): "Built first: a window whose hello failed is not connected", build snapshot → set `_lastSnapshot` → `_connected = _visible = true` → return `{snapshot, tab}`.

The window-side `show` case is identical (`settings_window.dart:438-445` vs `remote_settings.dart:288-299`): apply, notify, `page.value = SettingsWindowPage(tab: …, generation: _generation++)`.

The macOS runners are line-for-line identical except the four product constants and one comment: `seance/.../macos/Runner/SettingsWindow.swift:18-195` vs `poltergeist/.../macos/Runner/SettingsWindow.swift:20-198` (diff: `controlChannel`/`linkChannel` 19-20 vs 21-22; `windowArgument` 24 vs 26; controller subclass `SeanceFlutterViewController` :90 vs `PoltergeistFlutterViewController` :92; the ⌘W menu comment 132-137 vs 132-140). The Linux runners (`linux/runner/settings_window.cc`, 202 vs 208 lines) differ only in channel names/argument/title (:9-17 vs :10-21), the g_object data key (:200 vs :206), and Poltergeist's transparent `FlView` background (`poltergeist .../settings_window.cc:136-140`, absent in Séance). The Windows runners (209 vs 210 lines) differ only in names, argument, title, and comments (seance :17-25 vs poltergeist :18-25). Even `main()`'s dispatch is the same shape: `seance_app/lib/main.dart:34-37` vs `poltergeist_app/lib/main.dart:78-81`.

### 1.3 Every behavioral difference between the two Dart copies

1. **Method/key naming.** Séance: `abstract final class _Link` of string constants (`settings_window.dart:62-90`), whose own doc says "each is spelled on both sides of an isolate boundary where a typo is a silent `null`". Poltergeist: `enum SettingsLinkMethod` (`settings_window_link.dart:45-76`), `enum SettingsWindowControl` (:80), `enum SettingsLinkKey` (:84-130), "a typo is a compile error rather than a silent `null`" (:43-44).
2. **Host state binding.** Séance binds `AppState` in the constructor and never rebinds (`settings_window.dart:109-114`). Poltergeist has `attach(SettingsWindowSources)` with listener rebinding because its sections come from whichever workspace window is active (`settings_window_host.dart:122-139`; attached from `ui/workspace_shell.dart:707, 819, 830`).
3. **Snapshot shape.** Séance: fixed three keys `settings`/`llmConfigVersion`/`syncStatus` (`_snapshotOf`, :94-98). Poltergeist: section map, absent sections null (`_snapshot`, :244-279).
4. **Error mapping.** Séance: one generic code, `PlatformException(code: 'settings-failed', message: '$e')` (:252); window wraps any `PlatformException` into `SettingsBackendException(e.message ?? e.code)` (:461-462). Poltergeist: typed `SettingsLinkError` codes with `details` payloads, rebuilt into real exception types window-side (`encodeLinkError`/`decodeLinkError`, `settings_window_link.dart:136-191`), plus `FlutterError.reportError` on the host before rethrow (`settings_window_host.dart:323-330`; Séance reports nothing).
5. **Connection-loss surface.** Séance throws `SettingsBackendException('Séance is not responding. Close this window and open Settings again.')`, user-facing text in the library (:463-466). Poltergeist sets a `lost` flag and notifies (:44-60, 77-81); its message `'Settings link closed'` is "a diagnostic, never shown" (:63-65).
6. **Window-side model shape.** Séance's `RemoteSettingsBackend` implements the product's `SettingsBackend` interface over one settings copy (:349-604), and computes `localShell` locally in the window's engine because the process is shared (:477-482). Poltergeist's `RemoteSettings` exposes per-section `ChangeNotifier`s with null-means-absent semantics (:124-195) plus separate remote models (:320-590).
7. **Exit-failure catch breadth.** Séance catches `SettingsBackendException` (:591); Poltergeist catches `Exception` (:218) before answering `exit`.
8. **Window-directed methods reaching the host.** Poltergeist's dispatch explicitly rejects `snapshot`/`selectTab`/`hidden`/`show` ("goes to the window", :443-447); Séance's `default` covers them implicitly (:324-325).
9. **Missing sections.** Poltergeist's `_require` throws `StateError('This section is not available.')` (:452-454); Séance always has a backend.
10. **Window app shell.** Séance reuses `SettingsScreen` with a presentation enum (`settings_window_app.dart:83-89`, `ui/settings_screen.dart:58, 249-253`); Poltergeist has a dedicated tabbed window app with l10n and per-tab section presence (`settings_window_app.dart:126-271`).

---

## 2. Proposed `ghost_desktop` API

New library `planchette/packages/ghost_desktop/lib/src/settings_link.dart`, exported from `ghost_desktop.dart` alongside the existing modules. Naming follows the package's `Ghost*` convention (README "What it owns", `ghost_desktop/README.md:8-24`).

```dart
/// The wire methods the engine owns. Products must not define a method
/// whose name collides; the engine forwards everything else to the product.
enum GhostSettingsLinkMethod { hello, snapshot, selectTab, hidden, show }

/// The control channel's two methods.
enum GhostSettingsControlMethod { open, closed }

/// One reserved payload key of the engine's own envelopes.
enum GhostSettingsLinkKey { snapshot, tab }

/// The two channels, named and owned by the product (wire identity).
final class GhostSettingsChannels {
  const GhostSettingsChannels({required this.control, required this.link});
  final MethodChannel control; // '<product>/settings_window'
  final MethodChannel link;    // '<product>/settings_link'
}

/// What a page the window shows: product tab + generation.
@immutable
final class GhostSettingsPage<TTab extends Enum> {
  const GhostSettingsPage({required this.tab, required this.generation});
  final TTab tab;
  final int generation;
}
```

App side (replaces both `SettingsWindowHost` cores; keeps Poltergeist's rebindable `attach`, which is the superset of Séance's fixed binding):

```dart
final class GhostSettingsWindowHost<TTab extends Enum> {
  GhostSettingsWindowHost({
    required GhostSettingsChannels channels,
    required TTab Function(String name) tabFromName,
    this.requestAppExit,            // defaults WidgetsBinding.instance.handleRequestAppExit
    PlatformException Function(Object error)? encodeError,
  });

  void attach(GhostSettingsSections<TTab> sections);  // rebindable, as today
  Future<bool> open(TTab tab);                        // false → product falls back to route/dialog
  void dispose();
  @visibleForTesting bool get connected;
  @visibleForTesting bool get visible;
}

/// How a product registers its sections: snapshot builder, dispatch, change sources.
final class GhostSettingsSections<TTab extends Enum> {
  const GhostSettingsSections({
    required this.snapshot,      // Map<String, Object?> Function()
    required this.handleCall,    // Future<Object?> Function(String method, Object? argument)
    this.changes = const [],     // List<Listenable>
  });
}
```

Window side (base for `RemoteSettingsBackend` / `RemoteSettings`):

```dart
abstract base class GhostSettingsWindowClient<TTab extends Enum>
    extends ChangeNotifier {
  @protected
  Future<void> initialize();     // hello + first snapshot; subclass static connect() calls it

  late final ValueNotifier<GhostSettingsPage<TTab>?> page;
  Stream<TTab> get tabRequests;
  bool get lost;                 // a call found no app to answer

  @protected
  Future<Object?> call(String method, [Object? argument]); // JSON envelope + error decode
  @protected
  void applySnapshot(Map<String, Object?> snapshot);       // product decodes its sections

  Future<AppExitResponse> requestAppExit();  // engine-owned round trip
  Exception Function(PlatformException) decodeError;       // product error codec hook

  @override
  void dispose();
}
```

Public-member justification (everything else private):

- `GhostSettingsWindowHost`: `attach`/`open`/`dispose` are the app's entire use today (`app_menus.dart:25-45`, `main.dart:157`; `workspace_shell.dart:707`, `:1684`); `connected`/`visible` are `@visibleForTesting`, as in both current hosts (`settings_window.dart:140-144`, `settings_window_host.dart:114-118`).
- `GhostSettingsSections`: the three members are exactly what Poltergeist's `SettingsWindowSources` collapses to once the product dispatch is one callback; `changes` generalizes Séance's `_state.addListener` (:114).
- `GhostSettingsWindowClient`: `page`, `tabRequests`, `lost`, `requestAppExit`, `dispose` are what both window apps consume today (`settings_window_app.dart:77-97`; `settings_window_app.dart:81-104, 173-175`); `call`/`applySnapshot`/`initialize` are `@protected`, the product subclass (`RemoteSettingsBackend implements SettingsBackend`, `RemoteSettings` exposing its sections) is the only public face.
- The three enums are public because they document the reserved wire namespace and let product tests assert without re-spelling strings (Séance's own lesson, `settings_window.dart:60-62`).
- `requestAppExit` moves from product method tables into the engine (both products currently spell it: `settings_window.dart:83, 322-323, 587-594`; `settings_window_link.dart:69`, host :441-442, remote :214-221). Its name becomes reserved.

Generics: `TTab extends Enum` with `tabFromName` (products pass `SettingsTab.values.byName` / `SettingsWindowTab.values.byName`), both products already move tabs as `tab.name` strings (`settings_window.dart:154, 162`; `settings_window_host.dart:151, 161-163`). Error codecs stay product hooks (`encodeError` default = Séance's `settings-failed` shape, `settings_window.dart:252`; Poltergeist passes its `encodeLinkError`, `settings_window_link.dart:151-170`) so wire behavior is preserved per product. Products keep their `SettingsWindowPage` names via `typedef SettingsWindowPage = GhostSettingsPage<SettingsTab>;`, zero call-site churn.

What stays in each product: snapshot building and section models (Séance `_snapshotOf` :94-98 + `LocalSettingsBackend` dispatch :266-321; Poltergeist `SettingsWindowSources` :32-76, `_snapshot` :244-306, dispatch :349-441), all codecs (`settings_window_link.dart:207-281`), the window app widgets, the launch-argument constant, and the app-side fallback (`app_menus.dart:25-45`; `OpenSettingsWindow` typedef `settings_window_link.dart:41`).

---

## 3. Dependencies

- `ghost_desktop` gains **no new pubspec dependencies**. The engine uses only `flutter/services` (`MethodChannel`, `MethodCall`, `MissingPluginException`, `PlatformException`), `flutter/foundation` (`ChangeNotifier`, `Listenable`, `@immutable`, `@visibleForTesting`, `FlutterError`), and `flutter/widgets` (`WidgetsBinding`), all part of the `flutter` SDK dependency it already declares (`planchette/packages/ghost_desktop/pubspec.yaml:13-17`). No change to its existing `window_manager`/`screen_retriever` deps.
- No product package leaks in: the engine's only types are its own plus Dart/Flutter SDK types. It references no `SettingsBackend`, `AppSettings`, `poltergeist_core`, or Séance type, the section codec is the product's side of the `attach`/`applySnapshot` seam, matching the package's existing host-neutrality rule ("shared document/UI packages remain host-neutral", root `AGENTS.md:42`).
- Both consumers already path-depend on it: `seance/app/seance_app/pubspec.yaml:17-18`, `poltergeist/app/poltergeist_app/pubspec.yaml:47-48`. Planchette is unaffected (its Settings is in-app; it takes the new export without using it).

---

## 4. Native side

**The runners can stay per product, unchanged.** The runners are byte relays: they forward link-channel messages between engines verbatim with replies (macOS `SettingsWindow.swift:55-67, 94-102`; Linux `settings_window.cc:53-78, 143-151, 197-204`; Windows same pattern, 209 lines) and implement only control `open` plus a `closed` notification. The Dart move preserves the wire format exactly (same channel names, same JSON-string envelopes, same five engine method names, same `open`/`closed`), so nothing native can observe it.

Per-product facts that must stay per product:

- Channel names are product-prefixed wire identity ("Preserve … wire formats", root `AGENTS.md:44`): `seance/settings_window`/`seance/settings_link` vs `poltergeist/settings_window`/`poltergeist/settings_link`.
- The settings-window launch flag is a contract between each product's `main()` and its runner: `--seance-settings-window` (`settings_window.dart:58`; macos :24, linux .cc:14, windows .cpp:22) vs `--poltergeist-settings-window` (`settings_window_link.dart:31`; macos :26, linux .cc:15, windows .cpp:23). The shared engine never sees it; each product keeps the constant next to its `main()` dispatch (`main.dart:34` / `main.dart:78`).
- Identity/compatibility deltas that already differ on purpose: the macOS view-controller subclass (`SeanceFlutterViewController` :90 vs `PoltergeistFlutterViewController` :92, the accessibility guard), window titles, Linux transparent background (`poltergeist .cc:136-140`), the ⌘W-menu comment, and g-object data keys. Native folders "carry reviewed identities and compatibility fixes" (root `AGENTS.md:45`) and cannot be shared from a Flutter package anyway.

Only optional follow-ups: refresh runner comments that point at Dart file paths (e.g. linux `.cc:13` comment naming `settingsWindowArgument` in Dart; poltergeist windows `.cpp:98-100` already points at the moved file), and a paragraph in `ghost_desktop/README.md` documenting the runner contract (control `open`/`closed`; link relayed byte-for-byte; engine launched with the product flag; hide-not-destroy) so the third host could reuse it.

---

## 5. Migration plan

Three PRs against main, in this order (each independently revertable; one monorepo PR would also work but mixes three workspaces' resolution and both products' behavior deltas in a single review):

**PR 1, `planchette/`: add the engine.** New `src/settings_link.dart` (~500 lines) + `test/settings_link_test.dart`, exported from the barrel. The test harness adapts the relay both products built (`seance test/settings_window_test.dart:41-51`, `poltergeist test/services/settings_window_test.dart:189-199`, `channelBuffers.push` between two channel names) into ghost_desktop's existing `test/fakes.dart` conventions; protocol cases are lifted verbatim from the duplicated suites: hello+first snapshot (seance :105-116), closed→hidden→reopen-fresh (seance :275-302; pg :617-641), selectTab on a showing window (seance :304-316; pg :643-653), snapshot coalescing + dedupe (seance :256-273; pg :596-616), requestAppExit incl. app-gone (seance :318-339; pg :655-685), runner-without-window and runner-refused fallbacks (seance :350-368), connection loss (pg :687-699), theme-only rebuild suppression (seance :167-179; pg :460-503 stays partly product). Version follows the root suite cadence (release tooling bumps all pubspecs in lockstep).

**PR 2, `poltergeist/`: adopt.** Its architecture already matches the proposal, so this is mostly deletion: `SettingsWindowHost` becomes a thin subclass/composition over `GhostSettingsWindowHost<SettingsWindowTab>` keeping `SettingsWindowSources` as the sections; `_Link` and the protocol half of `RemoteSettings`/`_handle`/`connect` collapse into a `GhostSettingsWindowClient<SettingsWindowTab>` subclass that keeps `applySnapshot` (:223-271) and the per-section remotes (:320-590). Keep: `SettingsLinkMethod`'s product values, `SettingsLinkKey`, all codecs, `SettingsWindowTab`, `OpenSettingsWindow`, the window app. Tests: `test/services/settings_window_test.dart` keeps every product case (sections, pin conflicts, per-model writes) against the shared engine; drop cases now covered in ghost_desktop only if redundant. `test/ui/settings/settings_window_app_test.dart` unchanged. Native untouched.

**PR 3, `seance/`: adopt.** `SettingsWindowHost(state)` composes the engine with sections over `LocalSettingsBackend`; `RemoteSettingsBackend` becomes `extends GhostSettingsWindowClient<SettingsTab> implements SettingsBackend`, keeping its ~230 lines of method forwards (:473-576) and window-local `localShell` (:477-482). Recommended in the same PR: convert `_Link`'s string constants (:62-90) to a product enum to reach Poltergeist's typo safety, optional, separable, and the AGENTS seam doc ("A new setting is a backend method plus a `_Link` case", `seance/AGENTS.md:614-620`) still reads true. Tests: `test/settings_window_test.dart` keeps product coverage (writes landing on disk :118-146, results crossing back :181-198, inbox :200-230, error message propagation :232-254); `test/settings_window_app_test.dart` (theme-following window) unchanged. Two disclosed behavior deltas from PR 1's engine: link dispatch errors are now also reported via `FlutterError.reportError` (Poltergeist's behavior, strictly more diagnostics), and unknown-method handling is the engine's single path.

**What each product keeps, in one line:** sections, keys, methods, codecs, snapshot builders, window UI, launch-flag constant, runner code, and the route/dialog fallback.

**Risks:**
- *String-typed method names across isolates.* The five engine names plus `requestAppExit` are reserved; a product enum value colliding with one would be silently swallowed by the engine. Mitigation: document the reservation on `GhostSettingsLinkMethod`, and have each product's test suite assert its enum's names are disjoint from the reserved set (cheap, catches the real failure mode both files warn about: `settings_window.dart:60-62`, `settings_window_link.dart:43-44`).
- *Test harnesses that relay channels.* Both products' suites depend on pushing into `channelBuffers` between two mock channel names; after the move the products construct the engine with injected channels exactly as today (`SettingsWindowHost(state, control: _control, link: _appLink)` seance :80; `SettingsWindowHost(control:, link:)` pg :271-275), so the harnesses keep working; the shared protocol tests live once in ghost_desktop instead of twice.
- *Wire-format drift during refactor.* Both engines are the same binary, so there is no skew window, but the PR must not "clean up" the JSON-string envelope or the `{snapshot, tab}` hello shape; the runners and the window's error text depend on them.
- *Poltergeist's rebind semantics.* `attach()` must stay callable repeatedly with listener teardown (`settings_window_host.dart:122-139`; driven from `workspace_shell.dart:707, 819, 830`), the engine's contract, tested in PR 1.

---

## 6. Size and recommendation

Approximate, from the line counts above:

| | Lines today | Moves to ghost_desktop | Stays per product |
|---|---|---|---|
| Séance `settings_window.dart` | 604 | ~300 (host core, page, remote core, handshake) | ~300 (snapshot, dispatch, `SettingsBackend` forwards) |
| Poltergeist `settings_window/` | 1326 | ~300 (same core, `_Link`, protocol cases) | ~1000 (keys, codecs, sources, sections, window models) |
| ghost_desktop | | +~500 lib, +~400 test | |

Net monorepo delta is small in lines (about +900 new, −600 deleted, so about +300); the gain is not size but single-source correctness for the protocol that encodes three hard-won platform traps (hide-not-destroy second engine, `seance/AGENTS.md:543-560`; macOS exit-handler stealing, `settings_window.dart:578-586`; snapshot dedupe/retry semantics). Poltergeist's copy is already a stamped fork of Séance's (`docs/PORTS.md`), which the family rules say not to create silently.

**Recommendation: do it, staged as the three PRs above**, move only the engine, keep sections/keys/codecs per product. Reasons: two consumers already exist and already diverged in exactly the dimensions this split formalizes (enums vs strings, typed errors, rebindable sources); both already depend on `ghost_desktop`; native sides are untouched; the protocol is the risky part and is currently the duplicated part. The honest counterweight: Planchette, the package's third host, does not need a Settings window, so `ghost_desktop` grows a two-consumer feature, acceptable under its "shared desktop window state" charter, and the fallback (share only the host half) would split the handshake across packages and is not worth it. If the owner prefers minimal churn now, deferring PR 3 (Séance) is safe; PRs 1-2 still delete the larger, cleaner duplication.

Unverified here: nothing was built or tested (read-only checkout, per instructions); all line references were read from source. The two `settings_window_app_test.dart` widget suites were counted but only Poltergeist's by name list; its content was not read line-by-line.

## Resolved during implementation

- The engine reserves `requestAppExit` alongside `hello`, `snapshot`,
  `selectTab`, `hidden` and `show` (`GhostSettingsLinkMethod`).
- The client takes `decodeError` and `lostError` as constructor
  parameters. Séance passes its user-facing "Séance is not responding…"
  message as `lostError`, so that text survives; both products also gain
  the `lost` flag.
- The host adds `snapshotChanged()` for changes no `Listenable` reports
  (Poltergeist's preview cache capacity and threshold), and `connected`
  and `visible` are plain getters so product wrappers can forward them to
  their tests.
- The client's `page` starts as a null `ValueNotifier` rather than `late`.
