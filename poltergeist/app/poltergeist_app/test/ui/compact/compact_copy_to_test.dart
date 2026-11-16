// UI-06: the phone selection bar's "Copy to…" names its destination
// before anything is queued: a confirmation sheet shows the other pane's
// host and folder, with Copy, Change folder (a folder picker that starts
// at the other pane's folder) and Cancel.
@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_app/ui/compact/compact_posture.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'compact_harness.dart';

Finder _key<T>(T value) => find.byKey(ValueKey<T>(value));

/// Opens pane A on "This device", points pane B at [folderB] (a row of
/// pane B's home), switches back to A and selects [row].
Future<void> _selectForCopy(
  WidgetTester tester, {
  required String row,
  String? folderB,
}) async {
  await tester.tap(find.text('This device'));
  await tester.pumpAndSettle();
  if (folderB != null) {
    await tester.tap(_key(CompactKey.paneSwitcher));
    await tester.pumpAndSettle();
    await tester.tap(compactRow(folderB));
    await tester.pumpAndSettle();
    await tester.tap(_key(CompactKey.paneSwitcher));
    await tester.pumpAndSettle();
  }
  await tester.longPress(compactRow(row));
  await tester.pumpAndSettle();
}

String _fieldText(WidgetTester tester, CompactKey field) => tester
    .widgetList<Text>(
      find.descendant(of: _key(field), matching: find.byType(Text)),
    )
    .map((text) => text.data!)
    .join(' | ');

void main() {
  testWidgets('the bar says "Copy to…", not the hidden pane\'s letter', (
    tester,
  ) async {
    final harness = CompactHarness();
    await harness.pump(tester);
    await _selectForCopy(tester, row: '/home/deploy/photo.jpg');

    expect(find.text('Copy to…'), findsOneWidget);
    expect(find.text('Copy to B'), findsNothing);
  });

  testWidgets('the sheet names host and folder; Copy queues exactly that', (
    tester,
  ) async {
    final harness = CompactHarness();
    harness.rightChannel.listings['/home/deploy/backups'] = const [];
    await harness.pump(tester);
    await _selectForCopy(
      tester,
      row: '/home/deploy/photo.jpg',
      folderB: '/home/deploy/backups',
    );

    await tester.tap(_key(CompactKey.actionCopy));
    await tester.pumpAndSettle();

    expect(_key(CompactKey.copyToSheet), findsOneWidget);
    expect(find.text('Copy 1 item'), findsOneWidget);
    expect(_fieldText(tester, CompactKey.copyToHost), 'Host | This device');
    expect(
      _fieldText(tester, CompactKey.copyToFolder),
      contains('/home/deploy/backups'),
    );
    // Nothing is queued until the user confirms.
    expect(harness.queue.enqueuedSpecs, isEmpty);
    // The Copy button tells a screen reader the full destination.
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Copy to This device, /home/deploy/backups$'),
      ),
      findsOneWidget,
    );

    await tester.tap(_key(CompactKey.copyToConfirm));
    // The queued copy's pill spinner never settles: pump past the
    // sheet's exit animation instead.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(_key(CompactKey.copyToSheet), findsNothing);
    final spec = harness.queue.enqueuedSpecs.single;
    expect(spec.operation, TransferOperation.copy);
    expect(spec.rootPaths, ['/home/deploy/photo.jpg']);
    expect(spec.destination, const LocalFsLocation());
    expect(spec.destinationDir, '/home/deploy/backups');
  });

  testWidgets('Cancel closes the sheet and queues nothing', (tester) async {
    final harness = CompactHarness();
    await harness.pump(tester);
    await _selectForCopy(tester, row: '/home/deploy/photo.jpg');

    await tester.tap(_key(CompactKey.actionCopy));
    await tester.pumpAndSettle();
    await tester.tap(_key(CompactKey.copyToCancel));
    await tester.pumpAndSettle();

    expect(_key(CompactKey.copyToSheet), findsNothing);
    expect(harness.queue.enqueuedSpecs, isEmpty);
    // The selection survives, so the user can try again.
    expect(harness.compact(tester).selecting, isTrue);
  });

  testWidgets('Change folder starts at the other pane\'s folder and the '
      'pick becomes the destination', (tester) async {
    final harness = CompactHarness();
    harness.rightChannel.listings['/home/deploy/backups'] = [
      folderEntry('/home/deploy/backups', 'daily'),
      folderEntry('/home/deploy/backups', 'Archive'),
      fileEntry('/home/deploy/backups', 'dump.sql', size: 10),
    ];
    harness.rightChannel.listings['/home/deploy/backups/daily'] = const [];
    await harness.pump(tester);
    await _selectForCopy(
      tester,
      row: '/home/deploy/photo.jpg',
      folderB: '/home/deploy/backups',
    );
    final paneB = harness.workspace(tester).right.activeTab!.controller;

    await tester.tap(_key(CompactKey.actionCopy));
    await tester.pumpAndSettle();
    await tester.tap(_key(CompactKey.copyToChangeFolder));
    await tester.pumpAndSettle();

    expect(_key(CompactKey.folderPicker), findsOneWidget);
    expect(
      tester.widget<Text>(_key(CompactKey.folderPickerPath)).data,
      contains('/home/deploy/backups'),
    );
    // Folders only, sorted by name regardless of case.
    final rows = tester
        .widgetList<ListTile>(
          find.descendant(
            of: _key(CompactKey.folderPicker),
            matching: find.byType(ListTile),
          ),
        )
        .map((tile) => (tile.title! as Text).data)
        .toList();
    expect(rows, ['Archive', 'daily']);

    await tester.tap(
      _key((CompactKey.folderPickerRow, '/home/deploy/backups/daily')),
    );
    await tester.pumpAndSettle();
    expect(find.text('No folders here'), findsOneWidget);
    await tester.tap(_key(CompactKey.folderPickerChoose));
    await tester.pumpAndSettle();

    expect(_key(CompactKey.folderPicker), findsNothing);
    expect(
      _fieldText(tester, CompactKey.copyToFolder),
      contains('/home/deploy/backups/daily'),
    );
    // Browsing the picker never moved pane B.
    expect(paneB.location!.path, '/home/deploy/backups');

    await tester.tap(_key(CompactKey.copyToConfirm));
    await tester.pump();
    expect(
      harness.queue.enqueuedSpecs.single.destinationDir,
      '/home/deploy/backups/daily',
    );
  });

  testWidgets('the picker goes up, retries a failed listing, and Cancel '
      'keeps the sheet\'s folder', (tester) async {
    final harness = CompactHarness();
    harness.rightChannel.listings['/home/deploy/backups'] = const [];
    await harness.pump(tester);
    await _selectForCopy(
      tester,
      row: '/home/deploy/photo.jpg',
      folderB: '/home/deploy/backups',
    );

    await tester.tap(_key(CompactKey.actionCopy));
    await tester.pumpAndSettle();
    await tester.tap(_key(CompactKey.copyToChangeFolder));
    await tester.pumpAndSettle();

    harness.rightChannel.listingFailures['/home/deploy'] =
        const RemoteFileException(
          kind: RemoteFileErrorKind.permissionDenied,
          operation: 'list',
          message: 'denied',
        );
    await tester.tap(_key(CompactKey.folderPickerUp));
    await tester.pumpAndSettle();
    expect(find.text('This folder can\'t be listed.'), findsOneWidget);
    // An unlisted folder cannot be picked blind.
    expect(
      tester
          .widget<FilledButton>(_key(CompactKey.folderPickerChoose))
          .onPressed,
      isNull,
    );

    harness.rightChannel.listingFailures.clear();
    await tester.tap(_key(CompactKey.folderPickerRetry));
    await tester.pumpAndSettle();
    expect(
      _key((CompactKey.folderPickerRow, '/home/deploy/backups')),
      findsOneWidget,
    );

    await tester.tap(_key(CompactKey.folderPickerCancel));
    await tester.pumpAndSettle();
    expect(
      _fieldText(tester, CompactKey.copyToFolder),
      contains('/home/deploy/backups'),
    );
    expect(
      _fieldText(tester, CompactKey.copyToFolder),
      isNot(endsWith('/home/deploy')),
    );
  });

  testWidgets('a remote destination is named by its server', (tester) async {
    final harness = CompactHarness();
    await harness.pump(tester);
    // Pane A on the demo server, then pane B (local) is the source.
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.demo')));
    await tester.pumpAndSettle();
    await tester.tap(_key(CompactKey.paneSwitcher));
    await tester.pumpAndSettle();
    await tester.longPress(compactRow('/home/deploy/old.log'));
    await tester.pumpAndSettle();

    await tester.tap(_key(CompactKey.actionCopy));
    await tester.pumpAndSettle();
    expect(_fieldText(tester, CompactKey.copyToHost), 'Host | demo');
    expect(_fieldText(tester, CompactKey.copyToFolder), contains('/srv/www'));

    await tester.tap(_key(CompactKey.copyToConfirm));
    await tester.pump();
    final spec = harness.queue.enqueuedSpecs.single;
    expect(spec.source, const LocalFsLocation());
    expect(spec.destination, const ServerFsLocation('demo'));
    expect(spec.destinationDir, '/srv/www');
  });

  testWidgets('the sheet keeps naming the server while the destination pane '
      'rebinds to this device', (tester) async {
    final harness = CompactHarness(
      bookmarks: [serverBookmark('demo', label: 'Demo box')],
    );
    await harness.pump(tester);
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.demo')));
    await tester.pumpAndSettle();
    final paneA = harness.workspace(tester).left.activeTab!.controller;
    await tester.tap(_key(CompactKey.paneSwitcher));
    await tester.pumpAndSettle();
    await tester.longPress(compactRow('/home/deploy/old.log'));
    await tester.pumpAndSettle();
    await tester.tap(_key(CompactKey.actionCopy));
    await tester.pumpAndSettle();
    expect(_fieldText(tester, CompactKey.copyToHost), 'Host | Demo box');

    // Pane A starts back to this device under the open sheet; the local
    // open is held, so the pane has left the server but not landed.
    final gate = harness.engine.localOpenGate = Completer<void>();
    final rebind = paneA.openLocalHome();
    await tester.pump();
    expect(paneA.location, isNot(isA<RemotePaneLocation>()));
    expect(paneA.remoteBookmark, isNull);

    // Anything that rebuilds the sheet (here a theme change) must still
    // name the host Copy enqueues to.
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pump();
    expect(_fieldText(tester, CompactKey.copyToHost), 'Host | Demo box');
    await tester.tap(_key(CompactKey.copyToConfirm));
    await tester.pump();
    final spec = harness.queue.enqueuedSpecs.single;
    expect(spec.destination, const ServerFsLocation('demo'));
    expect(spec.destinationDir, '/srv/www');

    gate.complete();
    await rebind;
    // The queued copy's pill spinner never settles.
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a folder inside the copied folder disables Copy and says why', (
    tester,
  ) async {
    final harness = CompactHarness();
    // Pane B is local too: one filesystem, so containment applies.
    harness.rightChannel.listings['/home/deploy'] = [
      folderEntry('/home/deploy', 'Documents'),
      folderEntry('/home/deploy', 'backups'),
    ];
    await harness.pump(tester);
    await _selectForCopy(tester, row: '/home/deploy/Documents');

    await tester.tap(_key(CompactKey.actionCopy));
    await tester.pumpAndSettle();
    expect(_key(CompactKey.copyToNotAllowed), findsNothing);

    await tester.tap(_key(CompactKey.copyToChangeFolder));
    await tester.pumpAndSettle();
    await tester.tap(
      _key((CompactKey.folderPickerRow, '/home/deploy/Documents')),
    );
    await tester.pumpAndSettle();
    await tester.tap(_key(CompactKey.folderPickerChoose));
    await tester.pumpAndSettle();

    expect(_key(CompactKey.copyToNotAllowed), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_key(CompactKey.copyToConfirm)).onPressed,
      isNull,
    );
    await tester.tap(_key(CompactKey.copyToConfirm), warnIfMissed: false);
    await tester.pump();
    expect(harness.queue.enqueuedSpecs, isEmpty);
  });
}
