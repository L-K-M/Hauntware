// ACC-01 and ACC-02's Users section: it reads when it shows, flags the
// accounts that can become root, hides service accounts until asked,
// lists who is logged in, and reads again on request.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/account_reads.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/accounts.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

HostAccount _account(
  String name,
  int uid, {
  String shell = '/bin/bash',
  List<String> groups = const [],
  Set<RootEquivalence> root = const {},
}) => HostAccount(
  name: name,
  uid: uid,
  gid: uid,
  home: '/home/$name',
  shell: shell,
  groups: groups,
  rootEquivalence: root,
);

final _snapshot = AccountsSnapshot(
  accounts: [
    _account('root', 0, root: {RootEquivalence.uidZero}),
    _account('daemon', 1, shell: '/usr/sbin/nologin'),
    _account(
      'deploy',
      1000,
      groups: ['deploy', 'docker', 'sudo'],
      root: {RootEquivalence.adminGroup, RootEquivalence.dockerGroup},
    ),
    _account('guest', 1001),
  ],
  sessions: [
    HostSession(
      user: 'deploy',
      line: 'pts/0',
      since: DateTime.utc(2026, 10, 26, 1, 23),
      from: '203.0.113.7',
    ),
  ],
);

void main() {
  late FakeEngineClient engine;
  late AccountReads reads;

  setUp(() {
    engine = FakeEngineClient();
    reads = AccountReads(engine);
  });

  tearDown(() async {
    reads.dispose();
    await engine.close();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: AccountsSection(
              reads: reads,
              serverId: _server,
              tableId: 'accounts',
            ),
          ),
        ),
      ),
    );
  }

  ReadAccounts lastRead() =>
      engine.sentOfType<ReadAccounts>().last as ReadAccounts;

  Future<void> answer(
    WidgetTester tester, {
    AccountsSnapshot? snapshot,
    AccountsReportFailure? failure,
  }) async {
    engine.emit(
      AccountsReport(
        serverId: _server,
        requestId: lastRead().requestId,
        snapshot: snapshot,
        failure: failure,
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('it reads when it shows, flags root-equivalent accounts and '
      'hides service accounts until asked', (tester) async {
    await pump(tester);
    expect(lastRead().serverId, _server);
    expect(find.text('Reading accounts…'), findsOneWidget);

    await answer(tester, snapshot: _snapshot);
    expect(find.text('root'), findsOneWidget);
    expect(find.text('deploy'), findsWidgets);
    expect(find.text('guest'), findsOneWidget);
    expect(find.text('daemon'), findsNothing);
    expect(find.text('UID 0'), findsOneWidget);
    expect(
      find.text('sudo, wheel or admin group, docker group'),
      findsOneWidget,
    );

    await tester.tap(find.text('Show 1 service account'));
    await tester.pumpAndSettle();
    expect(find.text('daemon'), findsOneWidget);
    await tester.tap(find.text('Hide service accounts'));
    await tester.pumpAndSettle();
    expect(find.text('daemon'), findsNothing);
  });

  testWidgets('it lists who is logged in, and says when no one is or the '
      'list is unknown', (tester) async {
    await pump(tester);
    await answer(tester, snapshot: _snapshot);
    expect(find.text('Logged in'), findsOneWidget);
    expect(
      find.textContaining('deploy on pts/0 from 203.0.113.7, since '),
      findsOneWidget,
    );

    await tester.tap(find.text('Read again'));
    await tester.pump();
    await answer(
      tester,
      snapshot: AccountsSnapshot(accounts: _snapshot.accounts, sessions: []),
    );
    expect(find.text('No one is logged in.'), findsOneWidget);

    await tester.tap(find.text('Read again'));
    await tester.pump();
    await answer(
      tester,
      snapshot: AccountsSnapshot(
        accounts: _snapshot.accounts,
        sessions: [],
        sessionsRead: false,
      ),
    );
    expect(find.textContaining('Who is logged in is unknown'), findsOneWidget);
  });

  testWidgets('a failed read says why', (tester) async {
    await pump(tester);
    await answer(tester, failure: AccountsReportFailure.transport);
    expect(
      find.text('The connection failed while the accounts were read.'),
      findsOneWidget,
    );
    expect(find.text('Read again'), findsOneWidget);
  });
}
