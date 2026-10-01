import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/import/bookmark_import_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final _fixedNow = DateTime.utc(2026, 10, 1);

BookmarkImportDialogRow _row(int index, {VoidCallback? onMaterialized}) =>
    BookmarkImportDialogRow(
      id: 'row-$index',
      label: 'Host $index',
      endpoint: 'host-$index.example.com:22',
      username: 'deploy',
      authentication: (_) => 'ssh-agent',
      details: [(_) => 'Start: /srv/application/$index'],
      notes: const [],
      importable: true,
      importByDefault: true,
      toBookmark: (now) {
        onMaterialized?.call();

        return Bookmark(
          id: 'bookmark-$index',
          kind: BookmarkKind.remotePath,
          label: 'Host $index',
          server: BookmarkServerRef(
            identity: EmbeddedHostIdentity(
              host: 'host-$index.example.com',
              port: 22,
              username: 'deploy',
              authMethod: AuthMethod.agent,
            ),
          ),
          remotePath: '/',
          sortKey: 'bookmark-$index',
          createdAt: now,
          updatedAt: now,
        );
      },
    );

BookmarkImportDialogSpec _spec({
  required Future<BookmarkImportDialogPreview> Function() load,
  VoidCallback? cancelLoad,
}) => BookmarkImportDialogSpec(
  title: (_) => 'Import bookmarks',
  sourceLabel: (_) => 'bookmarks.xml',
  emptyMessage: (_) => 'No bookmarks',
  failureMessage: (_, error) => 'Failed: $error',
  load: load,
  cancelLoad: cancelLoad,
);

Widget _harness(
  BookmarkImportDialogSpec spec, {
  ValueChanged<BookmarkImportDialogResult>? onResult,
}) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => FilledButton(
          onPressed: () {
            final result = showBookmarkImportDialog(
              context,
              spec: spec,
              clock: () => _fixedNow,
            );
            unawaited(result.then((value) => onResult?.call(value)));
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester, BookmarkImportDialogSpec spec) async {
  await tester.pumpWidget(_harness(spec));
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows retry when a loader throws an Error', (tester) async {
    await _open(
      tester,
      _spec(load: () async => throw StateError('worker failed')),
    );

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Failed: Bad state: worker failed'), findsOneWidget);
    expect(find.text('Try Again'), findsOneWidget);
  });

  testWidgets('virtualizes a 10,000-row preview', (tester) async {
    final rows = List.generate(10000, _row, growable: false);

    await _open(
      tester,
      _spec(load: () async => BookmarkImportDialogPreview(rows: rows)),
    );

    expect(find.text('Host 0'), findsOneWidget);
    expect(find.text('Host 9999'), findsNothing);
    expect(find.byType(Checkbox).evaluate().length, lessThan(100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('materializes 10,000 selected rows across UI turns', (
    tester,
  ) async {
    var materialized = 0;
    BookmarkImportDialogResult? result;
    final rows = List.generate(
      10000,
      (index) => _row(index, onMaterialized: () => materialized++),
      growable: false,
    );
    final spec = _spec(
      load: () async => BookmarkImportDialogPreview(rows: rows),
    );

    await tester.pumpWidget(
      _harness(spec, onResult: (value) => result = value),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Import 10000'));

    expect(materialized, greaterThan(0));
    expect(materialized, lessThan(rows.length));
    expect(result, isNull);

    await tester.pump();

    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Import 10000'),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
          .onPressed,
      isNull,
    );

    await tester.pumpAndSettle();

    expect(materialized, rows.length);
    expect(result?.exit, BookmarkImportDialogExit.imported);
    expect(result?.bookmarks, hasLength(rows.length));
  });

  testWidgets('uses a compact row without overflow at 360 logical pixels', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(360, 640);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await _open(
      tester,
      _spec(load: () async => BookmarkImportDialogPreview(rows: [_row(0)])),
    );

    expect(find.text('Host 0'), findsOneWidget);
    expect(find.text('host-0.example.com:22'), findsOneWidget);
    expect(find.text('Start: /srv/application/0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cancel stops an active load and ignores its late result', (
    tester,
  ) async {
    final load = Completer<BookmarkImportDialogPreview>();
    var cancellations = 0;

    await tester.pumpWidget(
      _harness(
        _spec(load: () => load.future, cancelLoad: () => cancellations++),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(cancellations, 1);

    load.complete(BookmarkImportDialogPreview(rows: [_row(0)]));
    await tester.pump();

    expect(find.text('Host 0'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
