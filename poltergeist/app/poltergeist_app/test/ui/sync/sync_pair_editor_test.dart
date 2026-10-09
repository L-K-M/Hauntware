// SyncPairEditorDialog regressions (D32 §7 task 4): a save must keep
// the ruleset fields the dialog does not show, and must not reset the
// pair state's case-sensitivity overrides it was never told about.
@TestOn('vm')
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/ui/sync/sync_pair_editor.dart';
import 'package:poltergeist_app/ui/sync/sync_rules_edit_request.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../../support/sync_harness.dart';

const _canonicalDocrootPaths = {
  SyncSide.right: SyncDocrootPathState(
    rootPath: '/var/www/site',
    trashPath: '/var/www/site/.poltergeist-trash',
    pathStyle: SyncTrashPathStyle.posix,
    pathCase: SyncTrashPathCase.sensitive,
  ),
};

/// Mounts a launcher that opens the editor and records what it pops.
Future<List<SyncPairEditorResult?>> _pumpEditor(
  WidgetTester tester, {
  SyncPair? initial,
  SyncCaseOverrides? initialCaseOverrides,
  SyncDocrootWarning? initialDocrootWarning,
  Map<SyncSide, SyncDocrootPathState> initialDocrootPaths = const {},
  SyncRulesEditTarget initialEditTarget = SyncRulesEditTarget.general,
  List<Bookmark> servers = const [],
}) async {
  final results = <SyncPairEditorResult?>[];
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async {
              results.add(
                await showDialog<SyncPairEditorResult>(
                  context: context,
                  builder: (_) => SyncPairEditorDialog(
                    initial: initial,
                    initialCaseOverrides: initialCaseOverrides,
                    initialDocrootWarning: initialDocrootWarning,
                    initialDocrootPaths: initialDocrootPaths,
                    initialEditTarget: initialEditTarget,
                    servers: servers,
                  ),
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return results;
}

Future<void> _save(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a save keeps acceptedTimeShifts and the symlink policy', (
    tester,
  ) async {
    final results = await _pumpEditor(
      tester,
      initial: testSyncPair(
        rules: const SyncRuleSet(
          acceptedTimeShifts: [3600],
          symlinks: SymlinkPolicy.copyAsLink,
          excludeGlobs: ['*.log'],
          trashPathRight: '/srv/trash',
        ),
      ),
    );
    await _save(tester);

    final rules = results.single!.pair.rules;
    // Before the fix `_result()` rebuilt the set from scratch and both
    // fields silently reverted to their defaults.
    expect(rules.acceptedTimeShifts, [3600]);
    expect(rules.symlinks, SymlinkPolicy.copyAsLink);
    expect(rules.excludeGlobs, ['*.log']);
    expect(rules.trashPathRight, '/srv/trash');
    expect(rules.trashPathLeft, isNull);
  });

  testWidgets('seeded case overrides show and survive an untouched save', (
    tester,
  ) async {
    final results = await _pumpEditor(
      tester,
      initial: testSyncPair(),
      initialCaseOverrides: const SyncCaseOverrides(left: true, right: false),
    );
    // The Options section holds the case fields.
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    expect(find.text('Case-sensitive'), findsOneWidget);
    expect(find.text('Case-insensitive'), findsOneWidget);

    await _save(tester);
    // Untouched fields over unchanged endpoints leave the stored pair
    // state authoritative — the old dialog returned auto/auto here and
    // the session's rescan cleared both overrides.
    expect(results.single!.caseOverrides, isNull);
  });

  testWidgets('an unseeded editor never resets overrides on save', (
    tester,
  ) async {
    final results = await _pumpEditor(tester, initial: testSyncPair());
    await _save(tester);
    expect(results.single!.caseOverrides, isNull);
  });

  testWidgets('a changed case field returns both sides', (tester) async {
    final results = await _pumpEditor(
      tester,
      initial: testSyncPair(),
      initialCaseOverrides: const SyncCaseOverrides(left: true),
    );
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Case-sensitive'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Case-insensitive').last);
    await tester.pumpAndSettle();
    await _save(tester);

    final overrides = results.single!.caseOverrides!;
    expect(overrides.left, isFalse);
    expect(overrides.right, isNull);
  });

  testWidgets('docroot warning prefills and focuses the affected trash path', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    const rightPath = '/var/www/\u05d0';
    final pair = testSyncPair(right: rightPath);
    final warning = syncDocrootWarnings(pair).single;
    final results = await _pumpEditor(tester, initial: pair);

    expect(find.text('Trash may be public'), findsOneWidget);
    expect(
      find.textContaining('replaced files may be downloadable over HTTP'),
      findsOneWidget,
    );
    expect(find.textContaining('\u2066$rightPath\u2069'), findsOneWidget);
    final warningAction = tester.widget<TextButton>(
      find.byKey(const ValueKey('sync.docrootWarningAction.right')),
    );
    expect(
      warningAction.style?.foregroundColor?.resolve(const <WidgetState>{}),
      Theme.of(
        tester.element(find.byType(SyncPairEditorDialog)),
      ).colorScheme.onErrorContainer,
    );

    final action = tester.getSemantics(
      find.byKey(const ValueKey('sync.docrootWarningAction.right')),
    );
    expect(action.getSemanticsData().hasAction(ui.SemanticsAction.tap), isTrue);
    action.owner!.performAction(action.id, ui.SemanticsAction.tap);
    await tester.pumpAndSettle();

    final rightField = tester.widget<TextField>(
      find.byKey(const ValueKey('sync.trashPath.right')),
    );
    final leftField = tester.widget<TextField>(
      find.byKey(const ValueKey('sync.trashPath.left')),
    );
    expect(rightField.controller!.text, warning.suggestedTrashPath);
    expect(rightField.focusNode!.hasFocus, isTrue);
    expect(leftField.controller!.text, isEmpty);
    expect(find.text('Trash may be public'), findsOneWidget);
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey('sync.docrootWarning.right')))
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey('sync.docrootWarningAction.right')),
          )
          .label,
      contains('right'),
    );

    await tester.enterText(
      find.byKey(const ValueKey('sync.trashPath.right')),
      'private/trash',
    );
    await tester.pump();
    expect(find.text('Trash may be public'), findsOneWidget);

    await _save(tester);
    expect(results.single!.pair.rules.trashPathRight, 'private/trash');
    semantics.dispose();
  });

  testWidgets('a targeted editor opens with the suggestion focused', (
    tester,
  ) async {
    final pair = testSyncPair(right: '/var/www/site');
    final warning = syncDocrootWarnings(pair).single;

    await _pumpEditor(tester, initial: pair, initialDocrootWarning: warning);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('sync.trashPath.right')),
    );
    expect(field.controller!.text, warning.suggestedTrashPath);
    expect(field.focusNode!.hasFocus, isTrue);
    expect(find.text('Trash may be public'), findsOneWidget);
  });

  testWidgets('a stale targeted warning is recalculated for the current root', (
    tester,
  ) async {
    final oldWarning = syncDocrootWarnings(
      testSyncPair(right: '/var/www/old'),
    ).single;
    final pair = testSyncPair(right: '/var/www/current');
    final currentWarning = syncDocrootWarnings(pair).single;

    await _pumpEditor(tester, initial: pair, initialDocrootWarning: oldWarning);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('sync.trashPath.right')),
    );
    expect(field.controller!.text, currentWarning.suggestedTrashPath);
    expect(field.controller!.text, isNot(oldWarning.suggestedTrashPath));
  });

  testWidgets('a canonical trash alias keeps the targeted suggestion', (
    tester,
  ) async {
    final pair = testSyncPair(
      right: '/published',
      rules: const SyncRuleSet(trashPathRight: '/srv/private/trash'),
    );
    final warning = syncDocrootWarnings(
      pair,
      resolvedPaths: _canonicalDocrootPaths,
    ).single;
    await _pumpEditor(
      tester,
      initial: pair,
      initialDocrootWarning: warning,
      initialDocrootPaths: _canonicalDocrootPaths,
    );

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('sync.trashPath.right')),
    );
    expect(field.controller!.text, warning.suggestedTrashPath);
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('edited trash paths discard the scanned trash location', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      initial: testSyncPair(right: '/published'),
      initialDocrootPaths: _canonicalDocrootPaths,
    );
    expect(find.text('Trash may be public'), findsOneWidget);
    await tester.tap(find.text('Options'));
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('sync.trashPath.right'));
    await tester.enterText(field, '/srv/private/trash');
    await tester.pump();
    expect(find.text('Trash may be public'), findsNothing);

    await tester.enterText(field, 'private/trash');
    await tester.pump();
    expect(find.text('Trash may be public'), findsOneWidget);
  });

  testWidgets('endpoint edits discard the scanned warning context', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      initial: testSyncPair(right: '/published'),
      initialDocrootPaths: _canonicalDocrootPaths,
    );
    expect(find.text('Trash may be public'), findsOneWidget);

    final field = find.widgetWithText(TextField, '/published');
    await tester.enterText(field, '/home/me/data');
    await tester.pump();
    expect(find.text('Trash may be public'), findsNothing);

    await tester.enterText(
      find.widgetWithText(TextField, '/home/me/data'),
      '/var/www/other',
    );
    await tester.pump();
    expect(find.textContaining('\u2066/var/www/other\u2069'), findsOneWidget);
  });

  testWidgets('a max-delete target expands and focuses its field', (
    tester,
  ) async {
    await _pumpEditor(
      tester,
      initial: testSyncPair(),
      initialEditTarget: SyncRulesEditTarget.maxDelete,
    );

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('sync.maxDelete')),
        matching: find.byType(TextField),
      ),
    );
    expect(field.focusNode!.hasFocus, isTrue);
  });

  testWidgets('an uncatalogued remote endpoint survives a rules edit', (
    tester,
  ) async {
    const server = BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.agent,
      ),
    );
    final pair = SyncPair(
      id: 'pair',
      name: 'Site',
      left: const LocalEndpoint('/site'),
      right: const RemoteEndpoint(server: server, path: '/var/www/site'),
      rules: const SyncRuleSet(),
    );
    final results = await _pumpEditor(tester, initial: pair);

    expect(find.text('deploy@web.example.com'), findsOneWidget);
    await _save(tester);

    final right = results.single!.pair.right as RemoteEndpoint;
    expect(right.server, same(server));
    expect(right.path, '/var/www/site');
  });

  testWidgets('a same-host bookmark cannot replace remote credentials', (
    tester,
  ) async {
    const initialServer = BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        identityFilePath: '/keys/site-a',
      ),
    );
    const catalogServer = BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        identityFilePath: '/keys/site-b',
      ),
    );
    final pair = SyncPair(
      id: 'pair',
      name: 'Site',
      left: const LocalEndpoint('/site'),
      right: const RemoteEndpoint(server: initialServer, path: '/var/www/site'),
      rules: const SyncRuleSet(),
    );
    final stamp = DateTime.utc(2026);
    final results = await _pumpEditor(
      tester,
      initial: pair,
      servers: [
        Bookmark(
          id: 'catalog-server',
          kind: BookmarkKind.remotePath,
          label: 'Site B',
          server: catalogServer,
          remotePath: '/',
          sortKey: 'a',
          createdAt: stamp,
          updatedAt: stamp,
        ),
      ],
    );

    await _save(tester);

    final right = results.single!.pair.right as RemoteEndpoint;
    expect(right.server, same(initialServer));
  });
}
