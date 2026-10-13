// The Sync Files sheet (D32 §7): the options drive the plan sentence
// live, Both Ways hides behind ⋯, remote-only availability is honest,
// and each verb hands the configured pair back to the shell.
@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/rsync_endpoints.dart';
import 'package:poltergeist_app/services/skip_rule_sets.dart';
import 'package:poltergeist_app/services/skip_rule_sets_controller.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/sync/sync_rule_sets.dart';
import 'package:poltergeist_app/ui/sync/sync_setup_sheet.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../support/sync_harness.dart';

/// The sheet's recorded outcome — `closed` flips once it pops.
final class _Outcome {
  bool closed = false;
  SyncSheetResult? result;
}

Future<_Outcome> _pumpSheet(
  WidgetTester tester, {
  SyncSheetMode mode = SyncSheetMode.adHoc,
  SyncPair? initial,
  bool Function(SyncEndpoint endpoint)? endpointAvailable,
  Future<bool> Function(SyncPair pair)? onSaveFavorite,
  RsyncEndpointResolver? rsyncEndpoints,
  SkipRuleSetsController? skipRuleSets,
  Size size = const Size(1200, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final outcome = _Outcome();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildPoltergeistTheme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                outcome.result = await showSyncSetupSheet(
                  context,
                  mode: mode,
                  initial:
                      initial ??
                      (mode == SyncSheetMode.newSaved
                          ? null
                          : testSyncPair(
                              left: '/Users/me/site',
                              right: '/Volumes/Backup/site-copy',
                            )),
                  endpointAvailable: endpointAvailable ?? (_) => true,
                  onSaveFavorite: onSaveFavorite,
                  rsyncEndpoints: rsyncEndpoints,
                  skipRuleSets: skipRuleSets,
                );
                outcome.closed = true;
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return outcome;
}

String _plan(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('sync.sheet.plan')))
    .textSpan!
    .toPlainText();

Future<void> _tapKey(WidgetTester tester, String key) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

/// Taps a rule-set control. Generic so the key keeps its static type:
/// a ValueKey only equals one of the same type argument.
Future<void> _tapRuleSet<T>(WidgetTester tester, T key) async {
  await tester.tap(find.byKey(ValueKey<T>(key)));
  await tester.pumpAndSettle();
}

String _rulesField(WidgetTester tester) => tester
    .widget<TextField>(find.byKey(const ValueKey('sync.rules.field')))
    .controller!
    .text;

SkipRuleSetsController _ruleSets(List<SkipRuleSet> initial) {
  final sets = SkipRuleSetsController(initial: initial);
  addTearDown(sets.dispose);
  return sets;
}

final _web = SkipRuleSet(name: 'Web', patterns: ['node_modules/', '*.log']);

const _remoteRight = RemoteEndpoint(
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: '127.0.0.1',
      port: 2222,
      username: 'demo',
      authMethod: AuthMethod.password,
    ),
  ),
  path: '/var/www/site',
);

void main() {
  testWidgets('renders the tiles and the default plan sentence', (
    tester,
  ) async {
    await _pumpSheet(tester);
    expect(find.text('Sync Files'), findsOneWidget);
    expect(find.text('This computer'), findsNWidgets(2));
    expect(find.text('…/Volumes/Backup/site-copy'), findsNothing);
    expect(find.text('/Volumes/Backup/site-copy'), findsOneWidget);
    expect(find.text('Here’s the plan:'), findsOneWidget);
    expect(
      _plan(tester),
      startsWith(
        'Your local folder “site-copy” will be updated from your local '
        'folder “site”.',
      ),
    );
    expect(_plan(tester), endsWith('No files will be deleted.'));
    // The engine cannot follow symlinks or filter by age — neither is
    // offered (D32 §7's hidden rows).
    expect(find.textContaining('symbolic'), findsNothing);
    expect(find.textContaining('days'), findsNothing);
  });

  testWidgets('the direction toggle swaps source and destination', (
    tester,
  ) async {
    final outcome = await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.direction');
    expect(
      _plan(tester),
      startsWith(
        'Your local folder “site” will be updated from your local folder '
        '“site-copy”.',
      ),
    );
    await _tapKey(tester, 'sync.sheet.simulate');
    expect(outcome.result!.action, SyncSheetAction.simulate);
    expect(outcome.result!.pair.rules.direction, SyncDirection.rightToLeft);
  });

  testWidgets('a screen reader can swap the direction too', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pumpSheet(tester);
    final node = tester.getSemantics(
      find.byKey(const ValueKey('sync.sheet.direction')),
    );
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(
      _plan(tester),
      startsWith(
        'Your local folder “site” will be updated from your local folder '
        '“site-copy”.',
      ),
    );
    semantics.dispose();
  });

  testWidgets('the compare dropdown rewrites the replacement clause', (
    tester,
  ) async {
    await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.compare');
    await tester.tap(find.text('File Size').last);
    await tester.pumpAndSettle();
    expect(
      _plan(tester),
      contains('Files that differ in size will be replaced'),
    );
    expect(find.text('Modification dates aren’t compared'), findsOneWidget);

    await _tapKey(tester, 'sync.sheet.compare');
    await tester.tap(find.text('Checksum').last);
    await tester.pumpAndSettle();
    expect(_plan(tester), contains('compared by checksum'));
  });

  testWidgets('the delete checkbox turns on Mirror with a red clause', (
    tester,
  ) async {
    final outcome = await _pumpSheet(tester);
    expect(find.byKey(const ValueKey('sync.sheet.plan.warning')), findsNothing);
    await _tapKey(tester, 'sync.sheet.deleteOrphans');
    expect(
      _plan(tester),
      contains(
        'Files in “site-copy” that aren’t in “site” will be deleted '
        '(moved to .poltergeist-trash).',
      ),
    );
    expect(_plan(tester), isNot(contains('No files will be deleted.')));
    expect(
      find.byKey(const ValueKey('sync.sheet.plan.warning')),
      findsOneWidget,
    );

    await _tapKey(tester, 'sync.sheet.deletePermanent');
    expect(_plan(tester), contains('will be deleted permanently.'));

    await _tapKey(tester, 'sync.sheet.synchronize');
    expect(outcome.result!.action, SyncSheetAction.synchronize);
    expect(outcome.result!.pair.rules.deletions, DeletionPolicy.permanent);
  });

  testWidgets('Both Ways lives in the ⋯ menu and disables deletions', (
    tester,
  ) async {
    final outcome = await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.deleteOrphans');
    await _tapKey(tester, 'sync.sheet.more');
    await _tapKey(tester, 'sync.sheet.more.bothWays');

    expect(_plan(tester), contains('will each receive the files'));
    expect(_plan(tester), endsWith('No files will be deleted.'));
    expect(find.text('Not available when syncing both ways'), findsOneWidget);
    final checkbox = tester.widget<Checkbox>(
      find.byKey(const ValueKey('sync.sheet.deleteOrphans')),
    );
    expect(checkbox.value, isFalse);
    expect(checkbox.onChanged, isNull);

    // The toggle returns to one-way; it can never select Both Ways.
    await _tapKey(tester, 'sync.sheet.direction');
    expect(_plan(tester), startsWith('Your local folder “site-copy” will be'));

    await _tapKey(tester, 'sync.sheet.more');
    await _tapKey(tester, 'sync.sheet.more.bothWays');
    await _tapKey(tester, 'sync.sheet.simulate');
    final rules = outcome.result!.pair.rules;
    expect(rules.direction, SyncDirection.bidirectional);
    expect(rules.deletions, DeletionPolicy.none);
  });

  testWidgets('hidden files and skip rules feed the sentence and result', (
    tester,
  ) async {
    final outcome = await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.includeHidden');
    expect(_plan(tester), contains('Hidden files are left out.'));

    // Checking "Skip items" with no rules opens the editor.
    await _tapKey(tester, 'sync.sheet.skipRules');
    expect(find.text('Skip Rules'), findsOneWidget);
    // The engine's built-in patterns are listed read-only.
    expect(find.text('.DS_Store'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('sync.rules.field')),
      '*.log\nbuild/\n',
    );
    await _tapKey(tester, 'sync.rules.done');
    expect(find.text('2 rules'), findsOneWidget);
    expect(_plan(tester), contains('Items matching 2 rules are left out.'));

    // Unchecking keeps the rules for a re-check but runs without them.
    await _tapKey(tester, 'sync.sheet.skipRules');
    expect(_plan(tester), isNot(contains('rules are left out')));
    await _tapKey(tester, 'sync.sheet.skipRules');
    await _tapKey(tester, 'sync.sheet.simulate');
    final rules = outcome.result!.pair.rules;
    expect(rules.includeHidden, isFalse);
    expect(rules.excludeGlobs, ['*.log', 'build/']);
  });

  group('rule sets', () {
    testWidgets('Add Rule Set appends only the lines the pair lacks', (
      tester,
    ) async {
      final outcome = await _pumpSheet(
        tester,
        initial: testSyncPair(
          left: '/a/site',
          right: '/b/site-copy',
          rules: const SyncRuleSet(excludeGlobs: ['*.log', '!keep.log']),
        ),
        skipRuleSets: _ruleSets([_web]),
      );
      await _tapKey(tester, 'sync.sheet.editRules');
      await _tapRuleSet(tester, SkipRuleSetKey.addMenu);
      // Each set in the menu shows how many lines it holds.
      expect(
        find.descendant(
          of: find.byKey(const ValueKey((SkipRuleSetKey.addItem, 'Web'))),
          matching: find.text('2 rules'),
        ),
        findsOneWidget,
      );
      await _tapRuleSet(tester, (SkipRuleSetKey.addItem, 'Web'));

      // The pair's own lines keep their order, so its re-include holds.
      expect(_rulesField(tester), '*.log\n!keep.log\nnode_modules/');
      await _tapKey(tester, 'sync.rules.done');
      await _tapKey(tester, 'sync.sheet.simulate');
      expect(outcome.result!.pair.rules.excludeGlobs, [
        '*.log',
        '!keep.log',
        'node_modules/',
      ]);
    });

    testWidgets('Escape closes only the menu, keeping the typed rules', (
      tester,
    ) async {
      await _pumpSheet(tester, skipRuleSets: _ruleSets([_web]));
      await _tapKey(tester, 'sync.sheet.editRules');
      await tester.enterText(
        find.byKey(const ValueKey('sync.rules.field')),
        'typed/',
      );
      await _tapRuleSet(tester, SkipRuleSetKey.addMenu);
      expect(
        find.byKey(const ValueKey((SkipRuleSetKey.addItem, 'Web'))),
        findsOneWidget,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey((SkipRuleSetKey.addItem, 'Web'))),
        findsNothing,
      );
      expect(find.text('Skip Rules'), findsOneWidget);
      expect(_rulesField(tester), 'typed/');
    });

    testWidgets('an empty menu says there are no saved sets', (tester) async {
      await _pumpSheet(tester, skipRuleSets: _ruleSets(const []));
      await _tapKey(tester, 'sync.sheet.editRules');
      await _tapRuleSet(tester, SkipRuleSetKey.addMenu);

      expect(find.text('No saved rule sets'), findsOneWidget);
    });

    testWidgets('Save as Rule Set stores the lines without committing them', (
      tester,
    ) async {
      final sets = _ruleSets([_web]);
      final outcome = await _pumpSheet(tester, skipRuleSets: sets);
      await _tapKey(tester, 'sync.sheet.editRules');
      // Nothing to save until the field holds a pattern.
      final saveAs = find.byKey(const ValueKey(SkipRuleSetKey.saveAs));
      expect(tester.widget<TextButton>(saveAs).onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('sync.rules.field')),
        '# site\n*.tmp\nbuild/\n',
      );
      await tester.pump();
      await _tapRuleSet(tester, SkipRuleSetKey.saveAs);

      // Names ignore case, so "web" is taken.
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorName)),
        ' web ',
      );
      await _tapRuleSet(tester, SkipRuleSetKey.editorSave);
      expect(
        find.text('A rule set named “Web” already exists.'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorName)),
        ' Build ',
      );
      await _tapRuleSet(tester, SkipRuleSetKey.editorSave);

      expect(
        sets.value.last,
        SkipRuleSet(name: 'Build', patterns: ['# site', '*.tmp', 'build/']),
      );
      // Cancelling the Skip Rules dialog leaves the pair's rules alone.
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      await _tapKey(tester, 'sync.sheet.simulate');
      expect(outcome.result!.pair.rules.excludeGlobs, isEmpty);
    });

    testWidgets('a set needs a name and a pattern', (tester) async {
      final sets = _ruleSets(const []);
      await _pumpSheet(tester, skipRuleSets: sets);
      await _tapKey(tester, 'sync.sheet.editRules');
      await _tapRuleSet(tester, SkipRuleSetKey.manage);
      await _tapRuleSet(tester, SkipRuleSetKey.managerNew);
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorPatterns)),
        '# only a comment',
      );
      await _tapRuleSet(tester, SkipRuleSetKey.editorSave);

      expect(find.text('Enter a name.'), findsOneWidget);
      expect(find.text('Add at least one pattern.'), findsOneWidget);
      expect(sets.value, isEmpty);
    });

    testWidgets('Manage edits and deletes sets; pairs keep their copy', (
      tester,
    ) async {
      final sets = _ruleSets([_web]);
      final outcome = await _pumpSheet(tester, skipRuleSets: sets);
      await _tapKey(tester, 'sync.sheet.editRules');
      await _tapRuleSet(tester, SkipRuleSetKey.addMenu);
      await _tapRuleSet(tester, (SkipRuleSetKey.addItem, 'Web'));

      await _tapRuleSet(tester, SkipRuleSetKey.manage);
      expect(find.text('Rule Sets'), findsOneWidget);
      await _tapRuleSet(tester, (SkipRuleSetKey.managerEdit, 'Web'));
      expect(find.text('Edit Rule Set'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorName)),
        'Site',
      );
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorPatterns)),
        'dist/',
      );
      await _tapRuleSet(tester, SkipRuleSetKey.editorSave);
      expect(sets.value, [
        SkipRuleSet(name: 'Site', patterns: ['dist/']),
      ]);
      expect(find.text('Site'), findsOneWidget);

      await _tapRuleSet(tester, (SkipRuleSetKey.managerDelete, 'Site'));
      expect(find.text('Delete “Site”?'), findsOneWidget);
      await _tapRuleSet(tester, SkipRuleSetKey.deleteConfirm);
      expect(sets.value, isEmpty);
      expect(find.textContaining('Save a sync'), findsOneWidget);
      await tester.tap(find.text('Done').last);
      await tester.pumpAndSettle();

      // Neither the edit nor the delete reached the lines already added.
      expect(_rulesField(tester), 'node_modules/\n*.log');
      await _tapKey(tester, 'sync.rules.done');
      await _tapKey(tester, 'sync.sheet.simulate');
      expect(outcome.result!.pair.rules.excludeGlobs, [
        'node_modules/',
        '*.log',
      ]);
    });

    testWidgets('a failed save says so and lists nothing new', (tester) async {
      final sets = SkipRuleSetsController(
        put: (_, {replacing}) => Future.error(StateError('disk full')),
      );
      addTearDown(sets.dispose);
      final semantics = tester.ensureSemantics();
      await _pumpSheet(tester, skipRuleSets: sets);
      await _tapKey(tester, 'sync.sheet.editRules');
      await _tapRuleSet(tester, SkipRuleSetKey.manage);
      await _tapRuleSet(tester, SkipRuleSetKey.managerNew);
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorName)),
        'Web',
      );
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorPatterns)),
        '*.log',
      );
      await _tapRuleSet(tester, SkipRuleSetKey.editorSave);

      expect(
        find.text('The rule set could not be saved. Try again.'),
        findsOneWidget,
      );
      // Read out when it appears, not only when someone reaches it.
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey(SkipRuleSetKey.editorError)),
        ),
        isSemantics(isLiveRegion: true),
      );
      expect(find.text('Edit Rule Set'), findsNothing);
      expect(find.text('New Rule Set'), findsOneWidget);
      expect(sets.value, isEmpty);
      semantics.dispose();
    });

    testWidgets('the editor stays put while a save is writing', (tester) async {
      final write = Completer<List<SkipRuleSet>>();
      final sets = SkipRuleSetsController(
        put: (_, {replacing}) => write.future,
      );
      addTearDown(sets.dispose);
      await _pumpSheet(tester, skipRuleSets: sets);
      await _tapKey(tester, 'sync.sheet.editRules');
      await tester.enterText(
        find.byKey(const ValueKey('sync.rules.field')),
        '*.log',
      );
      await tester.pump();
      await _tapRuleSet(tester, SkipRuleSetKey.saveAs);
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorName)),
        'Logs',
      );
      await tester.tap(find.byKey(const ValueKey(SkipRuleSetKey.editorSave)));
      await tester.pump();

      // Neither Escape nor Cancel closes it mid-write.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(find.text('New Rule Set'), findsOneWidget);

      write.complete([
        SkipRuleSet(name: 'Logs', patterns: ['*.log']),
      ]);
      await tester.pumpAndSettle();
      // Only the editor closed; the Skip Rules dialog is still open.
      expect(find.text('New Rule Set'), findsNothing);
      expect(find.text('Skip Rules'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a name the store already holds is refused in the editor', (
      tester,
    ) async {
      // The list on screen is empty, as after a launch whose read failed.
      final sets = SkipRuleSetsController(
        put: (_, {replacing}) =>
            Future.error(const SkipRuleSetNameTaken('Web')),
      );
      addTearDown(sets.dispose);
      await _pumpSheet(tester, skipRuleSets: sets);
      await _tapKey(tester, 'sync.sheet.editRules');
      await _tapRuleSet(tester, SkipRuleSetKey.manage);
      await _tapRuleSet(tester, SkipRuleSetKey.managerNew);
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorName)),
        'web',
      );
      await tester.enterText(
        find.byKey(const ValueKey(SkipRuleSetKey.editorPatterns)),
        'dist/',
      );
      await _tapRuleSet(tester, SkipRuleSetKey.editorSave);

      expect(
        find.text('A rule set named “Web” already exists.'),
        findsOneWidget,
      );
      expect(find.text('New Rule Set'), findsOneWidget);
    });

    testWidgets('a failed delete says so and keeps the set', (tester) async {
      final sets = SkipRuleSetsController(
        initial: [_web],
        remove: (_) => Future.error(StateError('disk full')),
      );
      addTearDown(sets.dispose);
      final semantics = tester.ensureSemantics();
      await _pumpSheet(tester, skipRuleSets: sets);
      await _tapKey(tester, 'sync.sheet.editRules');
      await _tapRuleSet(tester, SkipRuleSetKey.manage);
      await _tapRuleSet(tester, (SkipRuleSetKey.managerDelete, 'Web'));
      await _tapRuleSet(tester, SkipRuleSetKey.deleteConfirm);

      expect(
        find.text('The rule set could not be deleted. Try again.'),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(
          find.byKey(const ValueKey(SkipRuleSetKey.managerError)),
        ),
        isSemantics(isLiveRegion: true),
      );
      expect(sets.value, [_web]);
      semantics.dispose();
    });

    testWidgets('the Advanced editor offers the sets too', (tester) async {
      final outcome = await _pumpSheet(tester, skipRuleSets: _ruleSets([_web]));
      await _tapKey(tester, 'sync.sheet.more');
      await _tapKey(tester, 'sync.sheet.more.advanced');
      await tester.tap(find.text('Options'));
      await tester.pumpAndSettle();
      await _tapRuleSet(tester, SkipRuleSetKey.addMenu);
      await _tapRuleSet(tester, (SkipRuleSetKey.addItem, 'Web'));
      await tester.tap(find.widgetWithText(FilledButton, 'Done').last);
      await tester.pumpAndSettle();
      await _tapKey(tester, 'sync.sheet.simulate');

      expect(outcome.result!.pair.rules.excludeGlobs, [
        'node_modules/',
        '*.log',
      ]);
    });

    testWidgets('without the model the controls stay out', (tester) async {
      await _pumpSheet(tester);
      await _tapKey(tester, 'sync.sheet.editRules');

      expect(find.byKey(const ValueKey(SkipRuleSetKey.addMenu)), findsNothing);
      expect(find.byKey(const ValueKey(SkipRuleSetKey.manage)), findsNothing);
    });

    testWidgets('the dialogs fit a phone', (tester) async {
      await _pumpSheet(
        tester,
        skipRuleSets: _ruleSets([
          _web,
          SkipRuleSet(
            name: 'A rule set with a rather long name for a phone',
            patterns: ['x/'],
          ),
        ]),
        size: const Size(390, 844),
      );
      await _tapKey(tester, 'sync.sheet.editRules');
      expect(tester.takeException(), isNull);
      await _tapRuleSet(tester, SkipRuleSetKey.manage);
      expect(tester.takeException(), isNull);
      await _tapRuleSet(tester, (SkipRuleSetKey.managerEdit, 'Web'));
      expect(tester.takeException(), isNull);
    });
  });

  testWidgets('Time Offset sets the tolerance and the 1-hour shift', (
    tester,
  ) async {
    final outcome = await _pumpSheet(
      tester,
      initial: testSyncPair(
        left: '/a/site',
        right: '/b/site-copy',
        rules: const SyncRuleSet(acceptedTimeShifts: [7200]),
      ),
    );
    expect(
      find.text(
        'Modification date tolerance: 2 seconds, plus 1 custom time shift',
      ),
      findsOneWidget,
    );
    await _tapKey(tester, 'sync.sheet.timeOffset');
    await tester.enterText(
      find.byKey(const ValueKey('sync.timeOffset.tolerance')),
      '5',
    );
    await _tapKey(tester, 'sync.timeOffset.hourShift');
    await _tapKey(tester, 'sync.timeOffset.done');
    expect(
      find.text(
        'Modification date tolerance: 5 seconds, ignoring exact 1-hour '
        'differences, plus 1 custom time shift',
      ),
      findsOneWidget,
    );
    await _tapKey(tester, 'sync.sheet.simulate');
    final rules = outcome.result!.pair.rules;
    expect(rules.mtimeToleranceSecs, 5);
    // The 7200 shift the dialog does not own survives.
    expect(rules.acceptedTimeShifts, [3600, 7200]);
  });

  testWidgets('an unavailable remote side keeps the verbs disabled', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      initial: SyncPair(
        id: 'p',
        name: 'site ⇄ site',
        left: const LocalEndpoint('/Users/me/site'),
        right: _remoteRight,
        rules: const SyncRuleSet(),
      ),
      endpointAvailable: (endpoint) => endpoint is LocalEndpoint,
      rsyncEndpoints: resolveRsyncEndpoints,
    );
    expect(find.text('demo@127.0.0.1:2222'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sync.sheet.unavailable')),
      findsOneWidget,
    );
    FilledButton synchronize() => tester.widget<FilledButton>(
      find.byKey(const ValueKey('sync.sheet.synchronize')),
    );
    expect(synchronize().onPressed, isNull);
    expect(
      tester
          .widget<OutlinedButton>(
            find.byKey(const ValueKey('sync.sheet.simulate')),
          )
          .onPressed,
      isNull,
    );
    // The rsync export still works — it needs no engine verbs.
    await _tapKey(tester, 'sync.sheet.more');
    final rsync = tester.widget<PopupMenuItem<Object?>>(
      find.byKey(const ValueKey('sync.sheet.more.rsync')),
    );
    expect(rsync.enabled, isTrue);
  });

  testWidgets('Save as Favorite asks for a name and persists', (tester) async {
    final saved = <SyncPair>[];
    await _pumpSheet(
      tester,
      onSaveFavorite: (pair) async {
        saved.add(pair);
        return true;
      },
    );
    await _tapKey(tester, 'sync.sheet.more');
    await _tapKey(tester, 'sync.sheet.more.saveFavorite');
    await tester.enterText(
      find.byKey(const ValueKey('sync.favoriteName.field')),
      'Site backup',
    );
    await _tapKey(tester, 'sync.favoriteName.save');
    expect(saved.single.name, 'Site backup');
    expect(saved.single.id, 'pair-1');
    // The sheet stays open for the run.
    expect(find.byKey(const ValueKey('sync.sheet')), findsOneWidget);
  });

  testWidgets('new saved sync needs a name, then Save hands it back', (
    tester,
  ) async {
    final outcome = await _pumpSheet(
      tester,
      mode: SyncSheetMode.newSaved,
      initial: testSyncPair(name: '', left: '/a/site', right: '/b/copy'),
    );
    expect(find.text('New Saved Sync'), findsOneWidget);
    OutlinedButton save() => tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('sync.sheet.save')),
    );
    expect(save().onPressed, isNull);
    await tester.enterText(
      find.byKey(const ValueKey('sync.sheet.name')),
      'Nightly',
    );
    await tester.pump();
    await _tapKey(tester, 'sync.sheet.save');
    expect(outcome.result!.action, SyncSheetAction.save);
    expect(outcome.result!.pair.name, 'Nightly');
  });

  testWidgets('a new saved sync without panes asks for folders', (
    tester,
  ) async {
    await _pumpSheet(tester, mode: SyncSheetMode.newSaved);
    expect(find.text('Choose Folders…'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('sync.sheet.plan')), findsNothing);
    await tester.tap(find.text('Choose Folders…').first);
    await tester.pumpAndSettle();
    // The full pair editor collects the endpoints.
    expect(find.text('Sync pair'), findsOneWidget);
  });

  testWidgets('a reopened favorite names itself under the title', (
    tester,
  ) async {
    await _pumpSheet(
      tester,
      mode: SyncSheetMode.saved,
      initial: testSyncPair(name: 'Nightly site backup'),
    );
    expect(find.text('Sync Files'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('sync.sheet.favoriteName')),
      findsOneWidget,
    );
    expect(find.text('Nightly site backup'), findsOneWidget);
  });

  testWidgets('Enter is the default button: Synchronize', (tester) async {
    final outcome = await _pumpSheet(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(outcome.result!.action, SyncSheetAction.synchronize);
  });

  testWidgets('Cancel closes without a result', (tester) async {
    final outcome = await _pumpSheet(tester);
    await _tapKey(tester, 'sync.sheet.cancel');
    expect(outcome.closed, isTrue);
    expect(outcome.result, isNull);
  });

  testWidgets('below 600 px the sheet is a full-screen dialog', (tester) async {
    await _pumpSheet(tester, size: const Size(420, 860));
    final dialog = tester.widget<Dialog>(
      find.byKey(const ValueKey('sync.sheet')),
    );
    expect(dialog.insetPadding, EdgeInsets.zero);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.text('Sync Files'), findsOneWidget);
  });
}
