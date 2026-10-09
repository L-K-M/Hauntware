## PRRT_kwDOUIzfcM6h0cGa app/poltergeist_app/lib/services/engine_session.dart:367
Replace release-stripped assert with a StateError guard
```suggestion
if (reviewConfig.id != serverId) {
          throw StateError(
            'review-connect serverId ($serverId) must equal bookmark.id '
            '(${reviewConfig.id})',
          );
        }
```

## PRRT_kwDOUIzfcM6h0cGc app/poltergeist_app/lib/services/pane_controller.dart:172
Report engine-less connectRemote instead of silent no-op
```suggestion
if (_disposed) return;
    if (_lanes == null) {
      // Shell wiring bug: engine-less panes render the no-engine state and
      // must not offer connect. Surface it rather than swallowing the call.
      _report(
        StateError('connectRemote(${bookmark.id}) on a pane with no engine'),
        StackTrace.current,
      );
      return;
    }
```

## PRRT_kwDOUIzfcM6h0cGe app/poltergeist_app/lib/ui/connections/connections_view.dart:248
Gate the open-in-pane on a successful pop
```suggestion
final didPop =
    await Navigator.of(context, rootNavigator: true).maybePop();
if (!didPop) return;
onOpenInPane?.call(server);
```

## PRRT_kwDOUIzfcM6h0cGi app/poltergeist_app/lib/ui/panes/pane_commands.dart:198
Skip unmodified activators before duplicate-chord diagnostics
```suggestion
for (final activator in activators) {
        // Unmodified keys — any activator type — stay with the pane focus
        // nodes (02 §8.2), not only SingleActivator spellings.
        final bool unmodified = activator is SingleActivator
            ? !activator.control && !activator.meta && !activator.alt
            : activator is CharacterActivator &&
                  !activator.control &&
                  !activator.meta &&
                  !activator.alt;
        if (unmodified) {
          continue;
        }
        // Two commands claiming one chord is a registration bug; debug
        // builds fail it immediately (release keeps later-command-wins,
        // the documented fallback).
        assert(
          !bindings.containsKey(activator),
          'Duplicate shortcut activator $activator: later command wins',
        );
        // Release builds keep later-command-wins silently by design; the
        // print keeps user-reported "shortcut does nothing" diagnosable.
        if (bindings.containsKey(activator)) {
          debugPrint(
            'Duplicate shortcut activator $activator: later command wins',
          );
        }
        bindings[activator] = () {
          if (!command.enabled()) return;
          command.run(context);
        };
      }
```

## PRRT_kwDOUIzfcM6h0cGk app/poltergeist_app/lib/ui/panes/pane_format.dart:57
Fix comment to match future-mtime rendering
```suggestion
// Same calendar day → "today". Only mtimes beyond tomorrow fall
    // through to the absolute format; same-day clock skew still reads
    // as today.
```

## PRRT_kwDOUIzfcM6h0cGl app/poltergeist_app/lib/ui/panes/pane_format.dart:43
Document intl symbol initialization precondition
```suggestion
/// (02 §2.3). Links and unevaluated sizes carry null metadata — the dash.
/// Callers must have loaded date symbols for [localeName] (see
/// initializeDateFormatting) before invoking this.
```

## PRRT_kwDOUIzfcM6h0cGm app/poltergeist_app/lib/ui/panes/pane_view.dart:89
Scope semantics exclusion to the stale browsing listing
```suggestion
excluding:
                controller.connectionLost ||
                (controller.loading &&
                    graceVisible &&
                    controller.phase == PanePhase.browsing),
```

## PRRT_kwDOUIzfcM6h0cGo app/poltergeist_app/lib/ui/panes/pane_view.dart:235
Reveal path tail on first mount, not only on updates
```suggestion
@override
  void initState() {
    super.initState();
    _revealedPath = widget.controller.location?.path;
    if (_revealedPath != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_segmentScroll.hasClients) return;
        _segmentScroll.jumpTo(_segmentScroll.position.maxScrollExtent);
      });
    }
  }

  @override
  void dispose() {
    _segmentScroll.dispose();
    super.dispose();
  }
```

## PRRT_kwDOUIzfcM6h0cGq app/poltergeist_app/lib/ui/panes/pane_view.dart:113
Only scrim the stale browsing listing
```suggestion
if (controller.loading &&
            graceVisible &&
            controller.phase == PanePhase.browsing)
```

## PRRT_kwDOUIzfcM6h0cGs app/poltergeist_app/lib/ui/panes/pane_view.dart:248
Also re-reveal when the controller instance changes
```suggestion
final path = widget.controller.location?.path;
    if (path == _revealedPath &&
        identical(oldWidget.controller, widget.controller)) {
      return;
    }
```

## PRRT_kwDOUIzfcM6h0cGw app/poltergeist_app/test/services/pane_controller_test.dart:182
Register disposal via addTearDown so cleanup runs even when assertions fail
```suggestion
final controller = PaneController(paneTabId: 'pane.left', lanes: lanes);
    addTearDown(controller.dispose);
```

## PRRT_kwDOUIzfcM6h0cGy app/poltergeist_app/test/services/pane_controller_test.dart:80
Fail fast when emitting state for an unwatched server
```suggestion
void emitState(String serverId, ServerStatus status) {
    final states = statesControllers[serverId];
    assert(states != null, 'emitState($serverId) before watchServer($serverId)');
    states?.add(status);
  }
```

## PRRT_kwDOUIzfcM6h0cG2 app/poltergeist_app/test/services/pane_controller_test.dart:457
Wrap over-length expect to satisfy dart format
```suggestion
expect(
      controller.location,
      const RemotePaneLocation('srv-2', '/other/home'),
    );
```

## PRRT_kwDOUIzfcM6h0cG4 app/poltergeist_app/test/services/pane_controller_test.dart:566
Wrap over-length list assignment to satisfy dart format
```suggestion
channel.listings['/home/tester'] = [
      _entry('sub', type: RemoteFileType.directory),
    ];
```

## PRRT_kwDOUIzfcM6h0cG5 app/poltergeist_app/test/ui/panes/pane_commands_test.dart:124
Add fall-through test for unmatched chords
```suggestion
```dart
    testWidgets('an unmatched chord falls through to outer scopes', (
      tester,
    ) async {
      var outerSawKey = false;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CallbackShortcuts(
            bindings: {activator: () => outerSawKey = true},
            child: CommandChordScope(
              commands: [
                command(
                  'x',
                  activators: (_) => [
                    SingleActivator(LogicalKeyboardKey.keyS, control: true),
                  ],
                ),
              ],
              child: const Scaffold(
                body: Focus(autofocus: true, child: SizedBox.expand()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // No command claims Ctrl+R, so the command layer must let it
      // escape to the outer scope rather than swallowing every chord.
      expect(outerSawKey, isTrue);
    });
}```
```

## PRRT_kwDOUIzfcM6h0cG- app/poltergeist_app/test/ui/production_engine_wiring_test.dart:62
Clean up temp support directory
```suggestion
final supportDir = Directory.systemTemp
        .createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h0cHB app/poltergeist_app/test/ui/production_engine_wiring_test.dart:139
Clean up temp support directory
```suggestion
final supportDir = Directory.systemTemp
        .createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h0cHD app/poltergeist_app/test/ui/production_engine_wiring_test.dart:189
Clean up temp support directory
```suggestion
final supportDir = Directory.systemTemp
        .createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h043i app/poltergeist_app/lib/services/pane_controller.dart:125
Delegate loading getter to _loadingActive
```suggestion
bool get loading => _loadingActive();
```

## PRRT_kwDOUIzfcM6h044H app/poltergeist_app/lib/services/pane_controller.dart:601
Guard post-dispose teardown error reporting
```suggestion
} on Object catch (error, stackTrace) {
        if (!_disposed) {
          _report(error, stackTrace);
        }
      }
```

## PRRT_kwDOUIzfcM6h044l app/poltergeist_app/lib/ui/connections/connections_view.dart:242
Honor maybePop result before opening in pane
```suggestion
onPressed: () async {
                // Pop before the open runs: maybePop only pops after
                // awaiting willPop (a microtask later), so a synchronous
                // push from the open (e.g. the changed-key review) would
                // otherwise become the pop's target instead of this
                // route, and the session guard releases with the pop.
                final popped = await Navigator.of(
                  context,
                  rootNavigator: true,
                ).maybePop();
                // A vetoed pop leaves this route on top and the
                // session guard held; don't start the open then.
                if (!popped) return;
                onOpenInPane?.call(server);
              },
```

## PRRT_kwDOUIzfcM6h045g app/poltergeist_app/test/services/engine_session_test.dart:199
Include rootPath in the unscripted-channel error message
```suggestion
throw StateError('no local browse channel scripted for rootPath: $rootPath');
```
Additional context: Include the requested rootPath in the unscripted-channel error
```suggestion
throw StateError('no local browse channel scripted for $rootPath');
```

## PRRT_kwDOUIzfcM6h046c app/poltergeist_app/test/services/pane_controller_test.dart:569
Select the non-directory by name, not by index
```suggestion
controller.openEntry(controller.entries.firstWhere((e) => e.name == 'file.txt'));
```

## PRRT_kwDOUIzfcM6h046x app/poltergeist_app/test/services/pane_controller_test.dart:579
Select the directory by name, not by index
```suggestion
controller.openEntry(controller.entries.firstWhere((e) => e.name == 'folder'));
```

## PRRT_kwDOUIzfcM6h0467 app/poltergeist_app/test/services/pane_location_test.dart:35
Document the drive-root separator exception
```suggestion
// Forward-slash Windows forms keep their separator, except drive
    // roots, which normalize to the canonical backslash form.
```

## PRRT_kwDOUIzfcM6h047H docs/STATUS.md:3570
renumber duplicate open item to 14
```suggestion
14. **2026-09-12 — M3: `PaneLocation`'s home is `poltergeist_core` (02
```

## PRRT_kwDOUIzfcM6h047a docs/STATUS.md:37
update intro cross-reference to item 14
```suggestion
landed 2026-09-12 (dated section below; open item 14 tracks the
```

## PRRT_kwDOUIzfcM6h047p docs/STATUS.md:2475
update section cross-reference to item 14
```suggestion
item 14 with the NFC/case-fold keying rule.
```

## PRRT_kwDOUIzfcM6h1goB app/poltergeist_app/lib/services/engine_session.dart:54
Declare openLocalChannel on AppEngine
```suggestion
});

  /// A local-filesystem browse channel rooted at [rootPath] (03 §6).
  @override
  Future<AppBrowseChannel> openLocalChannel({required String rootPath});
```

## PRRT_kwDOUIzfcM6h1goP app/poltergeist_app/lib/services/pane_controller.dart:183
Cancel prior status watch before re-subscribing
```suggestion
await _statusWatch?.cancel();
        _statusWatch = lanes
```

## PRRT_kwDOUIzfcM6h1gob app/poltergeist_app/lib/ui/panes/pane_commands.dart:203
Default unknown activator types to unmodified (skip)
```suggestion
```dart
        bool isChord;
        if (activator is SingleActivator) {
          isChord =
              activator.control || activator.meta || activator.alt;
        } else if (activator is CharacterActivator) {
          isChord =
              activator.control || activator.meta || activator.alt;
        } else {
          // Unknown spellings cannot be proven modified; they stay
          // with the pane focus nodes (02 §8.2) rather than risk a
          // global capture.
          isChord = false;
        }
        if (!isChord) {
          continue;
        }
```
```

## PRRT_kwDOUIzfcM6h1gpL app/poltergeist_app/test/services/pane_controller_test.dart:80
Close fake's broadcast controllers
```suggestion
<pre>  void emitState(String serverId, ServerStatus status) {
    statesControllers[serverId]?.add(status);
  }

  void dispose() {
    for (final controller in statesControllers.values) {
      controller.close();
    }
  }
}</pre>
```

## PRRT_kwDOUIzfcM6h1gpn app/poltergeist_app/test/ui/panes/pane_view_test.dart:193
Wrap un-awaited navigate in unawaited
```suggestion
unawaited(left.navigate('/home/tester/gone'));
```

## PRRT_kwDOUIzfcM6h1gp2 app/poltergeist_app/test/ui/production_engine_wiring_test.dart:64
Hoist temp dir and register cleanup
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h1gqC app/poltergeist_app/test/ui/production_engine_wiring_test.dart:139
Hoist temp dir and register cleanup
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h1gqI app/poltergeist_app/test/ui/production_engine_wiring_test.dart:189
Hoist temp dir and register cleanup
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h1gqi docs/STATUS.md:38
Keep the open cancellable-listings blocker visible in the milestone summary
```suggestion
location type's move into core, and the upstream cancellable-listings VFS change remains open); the next M3 slices are recorded
```

## PRRT_kwDOUIzfcM6h1gqu docs/STATUS.md:3577
Qualify the raw-path claim to cover bookmark-sourced initial paths
```suggestion
case-insensitive volumes) ahead of `==`/hashCode. Today the type
    compares raw paths; listing-derived navigation arrives canonical,
    but the remote pane's initial `remotePath` comes from a bookmark,
    so variant spellings can compare unequal until the rule lands.
```

## PRRT_kwDOUIzfcM6h2OZJ app/poltergeist_app/lib/services/engine_session.dart:367
Enforce serverId == bookmark.id in release builds too
```suggestion
if (reviewConfig.id != serverId) {
          throw StateError(
            'review-connect serverId ($serverId) must equal bookmark.id '
            '(${reviewConfig.id})',
          );
        }
```

## PRRT_kwDOUIzfcM6h2OZe app/poltergeist_app/lib/services/pane_controller.dart:352
Clamp returns num; add toInt() for int assignment
```suggestion
final clamped = index.clamp(0, _entries.length - 1).toInt();
```

## PRRT_kwDOUIzfcM6h2OZ- app/poltergeist_app/lib/services/pane_controller.dart:346
Clamp returns num; add toInt() before int parameter
```suggestion
setCursorIndex(next.clamp(0, _entries.length - 1).toInt());
```

## PRRT_kwDOUIzfcM6h2Oaw app/poltergeist_app/lib/ui/workspace_shell.dart:116
Reuse _disposeWorkspace helper in didUpdateWidget
```suggestion
```dart
      _disposeWorkspace();
      _buildWorkspace();
```
```

## PRRT_kwDOUIzfcM6h2ObU app/poltergeist_app/lib/ui/workspace_shell.dart:164
Rename shadowed focus locals to leftNode/rightNode
```suggestion
```dart
      final leftNode = _leftFocus;
      final rightNode = _rightFocus;
      if (leftNode == null || rightNode == null) return;
      // Claim initial focus only when nothing else holds it: a session
      // rebind mid-interaction must not yank focus from a toolbar
      // control or field back to the left listing.
      final primary = FocusManager.instance.primaryFocus;
      final focusElsewhere =
          primary != null && primary != FocusManager.instance.rootScope;
      if (!focusElsewhere) {
        leftNode.requestFocus();
      }
```
```

## PRRT_kwDOUIzfcM6h2Ob7 app/poltergeist_app/lib/ui/workspace_shell.dart:309
Report unreachable null-binding cancel instead of silent no-op
```suggestion
final serverId = pane.remoteBookmark?.id;
    if (serverId == null) {
      // Should be unreachable while a recovery banner is visible; surface
      // the broken invariant instead of a silent dead button.
      ApplicationErrorReporter().report(
        StateError('cancelPaneRecovery: pane has no pending binding'),
        StackTrace.current,
      );
      return;
    }
```

## PRRT_kwDOUIzfcM6h2Oca app/poltergeist_app/test/services/engine_session_test.dart:245
Add unscripted-listing diagnostics to the fake
```suggestion
```dart
  final listCalls = <String>[];

  /// Paths requested without a scripted listing — non-empty usually means
  /// the test scripted a different path form than the pane requested
  /// (trailing separator, expanded home anchor).
  List<String> get unscriptedListings =>
      listCalls.where((path) => !listings.containsKey(path)).toList();
```
```

## PRRT_kwDOUIzfcM6h2Oc2 app/poltergeist_app/test/services/pane_controller_test.dart:187
pin the full engine call log
```suggestion
expect(lanes.calls, ['openLocal:~']);
```

## PRRT_kwDOUIzfcM6h2OdZ app/poltergeist_app/test/services/pane_controller_test.dart:355
mark the deliberately un-awaited retry
```suggestion
unawaited(controller.retry()); // in flight, will succeed when released
```

## PRRT_kwDOUIzfcM6h2Odr app/poltergeist_app/test/ui/panes/pane_view_test.dart:870
Enable semantics before bySemanticsLabel lookup
```suggestion
final semanticsHandle = tester.ensureSemantics();
    addTearDown(semanticsHandle.dispose);
    localChannelWithEntries();
```

## PRRT_kwDOUIzfcM6h2OeM app/poltergeist_app/test/ui/production_engine_wiring_test.dart:66
Delete the per-test temp dir in teardown
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h2Oea app/poltergeist_app/test/ui/production_engine_wiring_test.dart:139
Delete the per-test temp dir in teardown
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```
Additional context: Delete temp support dir in teardown
```suggestion
```dart
    final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```
```

## PRRT_kwDOUIzfcM6h2Oex app/poltergeist_app/test/ui/production_engine_wiring_test.dart:189
Delete the per-test temp dir in teardown
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```
Additional context: Delete temp support dir in teardown
```suggestion
```dart
    final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```
```

## PRRT_kwDOUIzfcM6h2OfB app/poltergeist_app/test/ui/panes/workspace_panes_test.dart:11
Import the connections command constants
```suggestion
import 'package:poltergeist_app/ui/connections/connections_command.dart';
import 'package:poltergeist_app/ui/panes/pane_commands.dart';
```

## PRRT_kwDOUIzfcM6h2OfY app/poltergeist_app/test/ui/panes/workspace_panes_test.dart:27
Use the command ID constant instead of a literal
```suggestion
const ValueKey('command.$kConnectionsCommandId'),
```

## PRRT_kwDOUIzfcM6h2Ofy docs/STATUS.md:None
Watch seam can't feed the controller while unwired
```suggestion
implemented below and feed the pane controller's transitions; the
engine-side local directory watch seam is likewise in place, though its
pane refresh wiring remains open.
```

## PRRT_kwDOUIzfcM6h3sD- app/poltergeist_app/lib/services/pane_location.dart:70
Document forward-slash drive-path contract
```suggestion
/// defaults to '/'. One definition, shared by parent and label logic.
///
/// Inputs must already be canonical: a drive-letter path using '/'
/// separators ('C:/Users') is treated as POSIX here and its parent
/// comes back in '\' form — Windows producers must emit '\'.
```

## PRRT_kwDOUIzfcM6h3sEa app/poltergeist_app/lib/ui/connections/connections_view.dart:248
Gate onOpenInPane on maybePop result
```suggestion
final popped =
    await Navigator.of(context, rootNavigator: true).maybePop();
// Only fire the open once this surface has actually popped, so a
// rejected pop never stacks the open's route on the still-present list.
if (popped) onOpenInPane?.call(server);
```

## PRRT_kwDOUIzfcM6h3sE3 app/poltergeist_app/lib/ui/workspace_shell.dart:169
Rename shadowing focus-node locals
```suggestion
```dart
      final leftNode = _leftFocus;
      final rightNode = _rightFocus;
      if (leftNode == null || rightNode == null) return;
      // Claim initial focus only when nothing else holds it: a session
      // rebind mid-interaction must not yank focus from a toolbar
      // control or field back to the left listing.
      final primary = FocusManager.instance.primaryFocus;
      final focusElsewhere =
          primary != null && primary != FocusManager.instance.rootScope;
      if (!focusElsewhere) {
        leftNode.requestFocus();
      }
```
```

## PRRT_kwDOUIzfcM6h3sFO app/poltergeist_app/test/services/engine_session_test.dart:199
Include the requested rootPath in the fake's failure message
```suggestion
throw StateError('no local browse channel scripted for rootPath: $rootPath');
```

## PRRT_kwDOUIzfcM6h3sFa app/poltergeist_app/test/services/pane_controller_test.dart:44
Park on hold before throwing so holdRemoteOpen is never orphaned
```suggestion
final hold = holdRemoteOpen;
    if (hold != null) {
      holdRemoteOpen = null;
      await hold.future;
    }
    final failure = remoteOpenFailure;
    if (failure != null) throw failure;
```

## PRRT_kwDOUIzfcM6h3sF3 app/poltergeist_app/test/services/pane_controller_test.dart:666
Pin the in-flight first listing with holdNext before cancelling
```suggestion
final firstListing = Completer<void>();
    channel.holdNext = firstListing;
    await controller.connectRemote(_remoteBookmark());
```

## PRRT_kwDOUIzfcM6h3sGJ app/poltergeist_app/test/services/pane_controller_test.dart:678
Release the parked first listing and assert it is dropped as stale
```suggestion
expect(controller.entries.single.name, 'www.txt');

    // Release the parked first listing; it must be dropped as stale.
    firstListing.complete();
    await Future<void>.delayed(Duration.zero);
    expect(controller.entries.single.name, 'www.txt');
```

## PRRT_kwDOUIzfcM6h3sGa app/poltergeist_app/test/ui/panes/pane_format_test.dart:111
Add year-rollover "yesterday" coverage
```suggestion
// DST boundaries are untestable in this fixed-UTC container, but\n      // calendar rollovers are: Dec 31 -> Jan 1 is still "yesterday".\n      expect(\n        formatPaneModified(\n          DateTime(2026, 12, 31, 23, 0),\n          now: DateTime(2027, 1, 1, 0, 30),\n          localeName: 'en',\n          today: (t) => 'T($t)',\n          yesterday: (t) => 'Y($t)',\n        ),\n        startsWith('Y('),\n      );
```

## PRRT_kwDOUIzfcM6h3sG2 app/poltergeist_app/test/ui/panes/pane_view_test.dart:325
Assert cursor moved before pressing Enter on macOS
```suggestion
expect(left.cursorIndex, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
```

## PRRT_kwDOUIzfcM6h3sHD app/poltergeist_app/test/ui/panes/pane_view_test.dart:704
Use .single so the listing finder fails loudly instead of picking an arbitrary ListView
```suggestion
final listing = tester
        .widgetList<ListView>(find.byType(ListView))
        .where((view) => view.controller != null)
        .single;
```

## PRRT_kwDOUIzfcM6h3sHZ app/poltergeist_app/test/ui/production_engine_wiring_test.dart:62
Delete temp support dir in teardown (site 1)
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() {
      if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
    });
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h3sH- app/poltergeist_app/test/ui/production_engine_wiring_test.dart:139
Delete temp support dir in teardown (site 2)
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() {
      if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
    });
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h3sIV app/poltergeist_app/test/ui/production_engine_wiring_test.dart:189
Delete temp support dir in teardown (site 3)
```suggestion
final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() {
      if (supportDir.existsSync()) supportDir.deleteSync(recursive: true);
    });
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```

## PRRT_kwDOUIzfcM6h3-kH app/poltergeist_app/lib/services/engine_session.dart:367
Add release-safe guard alongside the assert
```suggestion
assert(
          reviewConfig.id == serverId,
          'review-connect serverId must equal bookmark.id',
        );
        if (reviewConfig.id != serverId) return;
```

## PRRT_kwDOUIzfcM6h3-kY app/poltergeist_app/lib/services/pane_controller.dart:368
Route cancelRecovery through detachRemote when a connect is in flight
```suggestion
Future<void> cancelRecovery() async {
  final lanes = _lanes;
  final serverId = _pendingRemote?.id;
  if (_disposed || lanes == null || serverId == null) return;
  if (_phase == PanePhase.connectingRemote) {
    // A cancelled server must not re-bind through the in-flight
    // connect: detach invalidates the attempt and resets the binding.
    await detachRemote();
  }
  try {
    await lanes.disconnectServer(serverId);
  } on Object catch (error, stackTrace) {
    _report(error, stackTrace);
  }
}
```

## PRRT_kwDOUIzfcM6h3-kp app/poltergeist_app/lib/services/pane_controller.dart:472
Clear stale connection status when the bind-failure path drops the watch
```suggestion
void _dropStatusWatch() {
  unawaited(_statusWatch?.cancel());
  _statusWatch = null;
  _connectionStatus = null;
}
```

## PRRT_kwDOUIzfcM6h3-ky app/poltergeist_app/lib/services/pane_controller.dart:125
Delegate loading to _loadingActive to keep one definition
```suggestion
bool get loading => _loadingActive();
```

## PRRT_kwDOUIzfcM6h3-lE app/poltergeist_app/lib/ui/panes/pane_commands.dart:105
Put never-reserved Ctrl+PageUp first as advertised primary
```suggestion
```dart
        other: const [
          // Ctrl+PageUp is the deliverable primary: Ctrl+Alt+arrows is
          // OS-reserved on stock installs (Intel/AMD display rotation on
          // Windows, virtual-desktop switching on KDE/X11), so the spec
          // chord can silently never arrive. Keep it as the secondary
          // until the settings slice allows rebinding.
          SingleActivator(LogicalKeyboardKey.pageUp, control: true),
          SingleActivator(
            LogicalKeyboardKey.arrowLeft,
            control: true,
            alt: true,
          ),
        ],
```
```

## PRRT_kwDOUIzfcM6h3-lO app/poltergeist_app/lib/ui/panes/pane_commands.dart:133
Mirror focusLeft
```suggestion
list Ctrl+PageDown first:```dart
        other: const [
          // Mirror pane.focusLeft: the never-reserved Ctrl+PageDown is
          // the deliverable primary; the OS-reserved spec chord stays
          // secondary until rebinding lands.
          SingleActivator(LogicalKeyboardKey.pageDown, control: true),
          SingleActivator(
            LogicalKeyboardKey.arrowRight,
            control: true,
            alt: true,
          ),
        ],
```
```

## PRRT_kwDOUIzfcM6h3-la app/poltergeist_app/lib/ui/panes/pane_view.dart:302
Wrap banner overlay in BlockSemantics
```suggestion
return BlockSemantics(
      // AbsorbPointer only claims pointer events; semantic activation
      // bypasses hit testing, so the stale listing under the scrim must
      // also be dropped from the semantics tree (the ModalBarrier
      // pattern). This widget's own subtree stays exposed.
      child: Column(
        children: [
          Container(
            key: const ValueKey('pane.banner'),
            width: double.infinity,
            padding: const EdgeInsetsDirectional.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            color: colors.errorContainer,
            child: Row(
              children: [
                Icon(
                  Icons.cloud_off_outlined,
                  size: 16,
                  color: colors.onErrorContainer,
                ),
                const SizedBox(width: 8),
                Expanded(
                  // Live region: the banner's appearance is announced to
                  // assistive tech (the stale content beneath is now fully
                  // blocked from semantics, so the banner is the only signal).
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      l10n.paneConnectionLost(label),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: colors.onErrorContainer,
                      ),
                    ),
                  ),
                ),
                TextButton(
                  key: const ValueKey('pane.banner.cancel'),
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    foregroundColor: colors.onErrorContainer,
                  ),
                  child: Text(l10n.paneConnectionLostCancel),
                ),
              ],
            ),
          ),
          Expanded(
            // Absorb, not ignore: the stale listing under the scrim must
            // not take interactions while the transport is down (the
            // banner above the scrim stays reachable).
            child: AbsorbPointer(
              child: ColoredBox(
                color: colors.surfaceContainerLowest.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
```

## PRRT_kwDOUIzfcM6h3-lm app/poltergeist_app/lib/ui/workspace_shell.dart:115
Use _disposeWorkspace helper instead of inline teardown
```suggestion
[[suggestion
```

## PRRT_kwDOUIzfcM6h3-lr app/poltergeist_app/test/services/pane_controller_test.dart:569
Select the plain file by name instead of index
```suggestion
controller.openEntry(
      controller.entries.firstWhere((e) => e.name == 'file.txt'),
    );
    expect(channel.listCalls, ['/home/tester']);
```

## PRRT_kwDOUIzfcM6h3-l2 app/poltergeist_app/test/services/pane_location_test.dart:49
Add empty-string case to paneLastSegment test
```suggestion
expect(paneLastSegment(null), '');
    expect(paneLastSegment(''), '');
```

## PRRT_kwDOUIzfcM6h4mAV app/poltergeist_app/lib/services/pane_controller.dart:346
Pass raw index — setCursorIndex clamps internally (avoids num-returning clamp)
```suggestion
setCursorIndex(next);
```

## PRRT_kwDOUIzfcM6h4mAh app/poltergeist_app/lib/services/pane_controller.dart:352
clamp returns num — add .toInt()
```suggestion
final clamped = index.clamp(0, _entries.length - 1).toInt();
```

## PRRT_kwDOUIzfcM6h4mAq app/poltergeist_app/lib/services/pane_controller.dart:191
Clear frozen status on stream error so the banner can't latch
```suggestion
onError: (Object error, StackTrace stackTrace) {
                if (_disposed || attempt != _bindAttempt) return;
                _report(error, stackTrace);
                _connectionStatus = null;
                notifyListeners();
              },
```

## PRRT_kwDOUIzfcM6h4mA1 app/poltergeist_app/lib/services/pane_location.dart:22
Enforce the value-equality contract on subclasses
```suggestion
String get path;

  /// Subclasses must compare by value (see class docs): redeclared
  /// abstract so no subclass can silently inherit identity equality.
  @override
  bool operator ==(Object other);
  @override
  int get hashCode;
}
```

## PRRT_kwDOUIzfcM6h4mA9 app/poltergeist_app/lib/ui/panes/pane_view.dart:176
Pick separator from path content instead of leading slash
```suggestion
<final separator = path.lastIndexOf('\\') > path.lastIndexOf('/') ? '\\' : '/';>
```

## PRRT_kwDOUIzfcM6h4mBS app/poltergeist_app/lib/ui/panes/pane_view.dart:163
Add semantics label to the loading progress line
```suggestion
<if (controller.loading && widget.loadingVisible)
          SizedBox(
            key: ValueKey('${controller.paneTabId}.progress'),
            height: 2,
            child: Semantics(
              label: l10n.paneLoadingFolder(
                paneLastSegment(controller.location?.path),
              ),
              child: const LinearProgressIndicator(),
            ),
          ),>
```

## PRRT_kwDOUIzfcM6h4mBg app/poltergeist_app/test/services/pane_controller_test.dart:233
use settle() helper
```suggestion
await settle();
```

## PRRT_kwDOUIzfcM6h4mBx app/poltergeist_app/test/ui/production_engine_wiring_test.dart:67
Delete temp support dir in teardown
```suggestion
```dart
    final supportDir =
        Directory.systemTemp.createTempSync('pg-engine-session-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
```
```

## PRRT_kwDOUIzfcM6h4mCm docs/STATUS.md:3636
Renumber Quick Select open item from 17 to 16
```suggestion
16. **2026-09-13: M3 Quick Select performance at pane wiring (#85 review).**
```

## PRRT_kwDOUIzfcM6h5EV7 app/poltergeist_app/lib/services/pane_controller.dart:200
also clear the banner when the status lane closes cleanly
```suggestion
},
              onDone: () {
                if (_disposed || attempt != _bindAttempt) return;
                // A lane that closes cleanly must not pin the banner on
                // its last state either (same rule as a dead lane).
                _connectionStatus = null;
                notifyListeners();
              },
            );
```

## PRRT_kwDOUIzfcM6h5EWZ app/poltergeist_app/lib/services/pane_location.dart:None
Make bare-UNC self-parent a strict no-op
```suggestion
return path;
```

## PRRT_kwDOUIzfcM6h5yXe docs/STATUS.md:3052
Point the incident-store retry reference at item 20
```suggestion
passed on retry (item 20). Higher-ancestor renames remain item 19; Linux
```

## PRRT_kwDOUIzfcM6h5yXk docs/STATUS.md:3053
Point the Linux overflow reference at item 15
```suggestion
overflow remains item 15. M3 stays open.
```