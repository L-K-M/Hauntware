// The footprint page (SAF-14, 03 §8.11; M5 plan M18): what the engine
// verified, by scope and file, the backup removals it plans, and a
// restore that opens the editor with the backup.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/footprint_page.dart';
import 'package:klabautermann_app/ui/server_safety.dart' show SafetyScope;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_editor/planchette_editor.dart' show PlanchetteEditor;

import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _dir = '/home/deploy/.local/state/klabautermann/backups';
const _source = '/home/deploy/app/.env';

final _hashA = 'a' * 64;
final _hashB = 'b' * 64;

BackupEntry _entry(String sha, int day, {String source = _source}) =>
    BackupEntry(
      savedAt: DateTime.utc(2026, 10, day, 9),
      sha256: sha,
      source: source,
    );

FootprintState _state({
  List<FootprintBackup> backups = const [],
  bool rootUnchecked = true,
}) => FootprintState(
  _serverId,
  files: const [
    FootprintFile(
      FootprintScope.user,
      FootprintRow(_dir, FootprintKind.backupDirectory),
      present: true,
    ),
    FootprintFile(
      FootprintScope.user,
      FootprintRow('$_dir/index', FootprintKind.backupIndex),
      present: true,
    ),
  ],
  backups: backups,
  rootUnchecked: rootUnchecked,
);

final class _Page {
  _Page(this.engine);

  final FakeEngineClient engine;

  List<ActionIntent> get plans => [
    for (final plan in engine.sentOfType<PlanAction>().cast<PlanAction>())
      plan.intent,
  ];

  List<ReadEditable> get reads => engine.sentOfType<ReadEditable>().cast();

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  Future<void> answerRead(WidgetTester tester, EditReadResult result) {
    final read = reads.last;
    return emit(
      tester,
      EditRead(
        serverId: read.serverId,
        requestId: read.requestId,
        result: result,
      ),
    );
  }
}

Future<_Page> _pump(WidgetTester tester, {bool readOnly = false}) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final operations = OperationsController(engine);
  final safety = SafetyController(
    initial: SafetyPolicy(
      servers: {_serverId: ServerSafety(management: true, readOnly: readOnly)},
    ),
    apply: (_) {},
  );
  addTearDown(() async {
    safety.dispose();
    operations.dispose();
    await engine.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: GhostTheme.light(klabautermannThemeStyle),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => SafetyScope(
        safety: safety,
        child: OperationsScope(operations: operations, child: child!),
      ),
      home: FootprintPage(
        operations: operations,
        serverId: _serverId,
        serverName: 'alpha',
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Page(engine);
}

void main() {
  testWidgets('opening verifies the footprint and lists it by scope and '
      'file, each backup with its state', (tester) async {
    final page = await _pump(tester);

    expect(
      page.engine
          .sentOfType<FootprintQuery>()
          .cast<FootprintQuery>()
          .single
          .serverId,
      _serverId,
    );
    expect(find.textContaining('Checking what Klabautermann'), findsOneWidget);

    await page.emit(
      tester,
      _state(
        backups: [
          FootprintBackup(
            FootprintScope.user,
            _entry(_hashA, 18),
            FootprintBackupStatus.intact,
          ),
          FootprintBackup(
            FootprintScope.user,
            _entry(_hashB, 19),
            FootprintBackupStatus.modified,
          ),
        ],
      ),
    );

    expect(find.text('Footprint on alpha'), findsOneWidget);
    expect(find.text('Your account'), findsOneWidget);
    expect(find.text(_dir), findsOneWidget);
    expect(find.text('Backup directory · present'), findsOneWidget);
    expect(find.text(_source), findsOneWidget);
    expect(find.text('${'a' * 12} · unchanged'), findsOneWidget);
    expect(
      find.text('${'b' * 12} · changed on the host since it was recorded'),
      findsOneWidget,
    );
    // Only the unchanged backup restores.
    expect(find.text('Restore…'), findsOneWidget);
    expect(
      find.text("Root's backups and manifest are checked in admin mode."),
      findsOneWidget,
    );
    // Two backups of one file: nothing for "Keep last" to remove.
    expect(find.textContaining('Keep the newest'), findsNothing);
  });

  testWidgets('"Keep last" and "Remove all backups" plan their removals', (
    tester,
  ) async {
    final page = await _pump(tester);
    await page.emit(
      tester,
      _state(
        backups: [
          for (var day = 1; day <= 6; day++)
            FootprintBackup(
              FootprintScope.user,
              _entry(day.toRadixString(16).padLeft(64, '0'), day),
              FootprintBackupStatus.intact,
            ),
        ],
      ),
    );

    await tester.tap(find.text('Keep the newest 5 backups of each file'));
    await tester.pump();
    final keep = page.plans.single as KeepLastBackups;
    expect(
      (keep.serverId, keep.scope, keep.count),
      (_serverId, FootprintScope.user, 5),
    );
    await page.emit(
      tester,
      ActionRefused(ActionRefusalReason.noLink, intent: keep),
    );

    await tester.tap(find.text('Remove all backups'));
    await tester.pump();
    final remove = page.plans.last as RemoveBackups;
    expect((remove.scope, remove.source), (FootprintScope.user, _source));
    await page.emit(
      tester,
      ActionRefused(ActionRefusalReason.noLink, intent: remove),
    );
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a restore reads the backup and opens its file in the editor '
      'with it, unsaved', (tester) async {
    final page = await _pump(tester);
    await page.emit(
      tester,
      _state(
        backups: [
          FootprintBackup(
            FootprintScope.user,
            _entry(_hashA, 18),
            FootprintBackupStatus.intact,
          ),
        ],
      ),
    );

    await tester.tap(find.text('Restore…'));
    await tester.pump();
    final name = _entry(_hashA, 18).name;
    expect(page.reads.single.target, FileTarget('$_dir/$name'));
    await page.answerRead(
      tester,
      EditContent(
        text: 'TOKEN=old\n',
        sha256: _hashA,
        privileged: false,
        uid: 1000,
        gid: 1000,
        mode: 384,
      ),
    );

    // The editor reads the file itself for its base.
    expect(page.reads.last.target, const FileTarget(_source));
    await page.answerRead(
      tester,
      const EditContent(
        text: 'TOKEN=new\n',
        sha256: 'current',
        privileged: false,
        uid: 1000,
        gid: 1000,
        mode: 384,
      ),
    );
    final editor = tester.widget<PlanchetteEditor>(
      find.byType(PlanchetteEditor),
    );
    expect(editor.controller.text.text, 'TOKEN=old\n');
    expect(find.text('Not saved'), findsOneWidget);
  });

  testWidgets('a backup that reads back with another hash is not opened', (
    tester,
  ) async {
    final page = await _pump(tester);
    await page.emit(
      tester,
      _state(
        backups: [
          FootprintBackup(
            FootprintScope.user,
            _entry(_hashA, 18),
            FootprintBackupStatus.intact,
          ),
        ],
      ),
    );

    await tester.tap(find.text('Restore…'));
    await tester.pump();
    await page.answerRead(
      tester,
      const EditContent(
        text: 'tampered\n',
        sha256: 'other',
        privileged: false,
        uid: 1000,
        gid: 1000,
        mode: 384,
      ),
    );

    expect(find.byType(PlanchetteEditor), findsNothing);
    expect(
      find.text(
        'The backup changed since it was checked, so it was not '
        'opened.',
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a read-only server shows the footprint without its actions', (
    tester,
  ) async {
    final page = await _pump(tester, readOnly: true);
    await page.emit(
      tester,
      _state(
        backups: [
          for (var day = 1; day <= 6; day++)
            FootprintBackup(
              FootprintScope.user,
              _entry(day.toRadixString(16).padLeft(64, '0'), day),
              FootprintBackupStatus.intact,
            ),
        ],
      ),
    );

    expect(find.text(_source), findsOneWidget);
    expect(find.text('Restore…'), findsNothing);
    expect(find.text('Remove all backups'), findsNothing);
    expect(find.textContaining('Keep the newest'), findsNothing);
  });

  testWidgets('a host without a footprint says so', (tester) async {
    final page = await _pump(tester);
    await page.emit(
      tester,
      const FootprintState(_serverId, rootUnchecked: false),
    );
    expect(
      find.text('Klabautermann keeps nothing on this server.'),
      findsOneWidget,
    );
  });
}
