import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/theme/app_theme.dart'
    show poltergeistMonoTextStyle;
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

BookmarkImportDialogRow _configuredRow(
  int index, {
  bool importable = true,
  bool importByDefault = true,
  BookmarkImportTextStyle authenticationStyle = BookmarkImportTextStyle.plain,
}) {
  final row = _row(index);

  return BookmarkImportDialogRow(
    id: row.id,
    label: row.label,
    endpoint: row.endpoint,
    username: row.username,
    authentication: row.authentication,
    authenticationStyle: authenticationStyle,
    details: row.details,
    notes: row.notes,
    importable: importable,
    importByDefault: importByDefault,
    toBookmark: row.toBookmark,
  );
}

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

Future<void> _open(
  WidgetTester tester,
  BookmarkImportDialogSpec spec, {
  ValueChanged<BookmarkImportDialogResult>? onResult,
}) async {
  await tester.pumpWidget(_harness(spec, onResult: onResult));
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

  testWidgets('default selection excludes non-importable rows', (tester) async {
    BookmarkImportDialogResult? result;
    final spec = _spec(
      load: () async => BookmarkImportDialogPreview(
        rows: [
          _row(0),
          _configuredRow(1, importByDefault: false),
          _configuredRow(2, importable: false),
        ],
      ),
    );

    await _open(tester, spec, onResult: (value) => result = value);

    final checkboxes = find.byType(Checkbox);
    expect(tester.widget<Checkbox>(checkboxes.at(0)).value, isTrue);
    expect(tester.widget<Checkbox>(checkboxes.at(1)).value, isFalse);
    expect(tester.widget<Checkbox>(checkboxes.at(2)).value, isFalse);
    expect(find.widgetWithText(FilledButton, 'Import 1'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Import 1'));
    await tester.pumpAndSettle();

    expect(result?.bookmarks.map((bookmark) => bookmark.id), ['bookmark-0']);
  });

  testWidgets('empty preview has no import action', (tester) async {
    await _open(
      tester,
      _spec(load: () async => const BookmarkImportDialogPreview(rows: [])),
    );

    expect(find.text('No bookmarks'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Import'), findsNothing);
  });

  testWidgets('machine-readable fields use the app monospace stack', (
    tester,
  ) async {
    await _open(
      tester,
      _spec(
        load: () async => BookmarkImportDialogPreview(
          rows: [
            _configuredRow(
              0,
              authenticationStyle: BookmarkImportTextStyle.monospace,
            ),
          ],
        ),
      ),
    );

    Finder selectableText(String value) => find.byWidgetPredicate(
      (widget) => widget is SelectableText && widget.data == value,
    );

    final source = tester.widget<SelectableText>(
      selectableText('bookmarks.xml'),
    );
    final endpoint = tester.widget<SelectableText>(
      selectableText('host-0.example.com:22'),
    );
    final authentication = tester.widget<Text>(find.text('ssh-agent'));

    for (final style in [source.style, endpoint.style, authentication.style]) {
      expect(style?.fontFamily, poltergeistMonoTextStyle.fontFamily);
      expect(
        style?.fontFamilyFallback,
        poltergeistMonoTextStyle.fontFamilyFallback,
      );
      expect(style?.fontFeatures, poltergeistMonoTextStyle.fontFeatures);
    }
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

    await _open(tester, spec, onResult: (value) => result = value);

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
