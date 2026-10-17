import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/endpoint_confirmation.dart';
import 'package:klabautermann_app/ui/fleet_rows.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';

const _desktop = Size(1280, 800);
const _phone = Size(390, 844);

const _twoPending = '2 synced servers wait for you to confirm their addresses.';
const _onePending = '1 synced server waits for you to confirm its address.';
const _title = 'Confirm server addresses';
const _changed = 'Changed since you confirmed it';

FleetEntry _synced(
  String id,
  EndpointConfirmation endpoint, {
  List<String>? jumpRoute,
}) => FleetEntry(
  serverId: id,
  label: 'label-$id',
  host: '$id.example.com',
  port: 2222,
  user: 'deploy',
  origin: FleetEntryOrigin.synced,
  jumpRoute: jumpRoute,
  searchText: 'label-$id deploy@$id.example.com:2222',
  endpoint: endpoint,
);

/// Two synced servers waiting (one new, one changed behind a route), one
/// confirmed, and an import, which never waits.
final _fleet = CatalogReplaced([
  _synced('a', EndpointConfirmation.unconfirmed, jumpRoute: ['edge', 'mid']),
  _synced('b', EndpointConfirmation.changed),
  _synced('c', EndpointConfirmation.confirmed),
  const FleetEntry(
    serverId: 'ssh-config:x',
    label: 'x',
    host: 'x.example.com',
    port: kSshDefaultPort,
    origin: FleetEntryOrigin.sshConfig,
  ),
]);

/// The fleet with [confirmed] confirmed too.
CatalogReplaced _after(Set<String> confirmed) => CatalogReplaced([
  for (final entry in _fleet.entries)
    if (entry.origin == FleetEntryOrigin.synced &&
        confirmed.contains(entry.serverId))
      _synced(entry.serverId, EndpointConfirmation.confirmed)
    else
      entry,
]);

Future<AppHarness> _withPending(
  WidgetTester tester, {
  Size size = _desktop,
}) async {
  final harness = await pumpApp(tester, size: size);
  harness.engine.emit(_fleet);
  await tester.pumpAndSettle();
  return harness;
}

/// [finder] within the confirmation list, not the fleet behind it.
Finder _inList(Finder finder) =>
    find.descendant(of: find.byType(Dialog), matching: finder);

Future<void> _openList(WidgetTester tester) async {
  // The notice scrolls with the fleet rows, as the rows scroll in the list.
  await tester.ensureVisible(find.text('Review'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Review'));
  await tester.pumpAndSettle();
  expect(find.text(_title), findsOneWidget);
}

/// Whether the row of [serverId] in the list is checked.
bool _checked(WidgetTester tester, String serverId) => tester
    .widget<CheckboxListTile>(
      find.ancestor(
        of: _inList(find.text('label-$serverId')),
        matching: find.byType(CheckboxListTile),
      ),
    )
    .value!;

bool _searchFocused(WidgetTester tester) => tester
    .widget<EditableText>(_inList(find.byType(EditableText)))
    .focusNode
    .hasFocus;

List<List<String>> _confirmed(AppHarness harness) => [
  for (final request in harness.engine.sentOfType<ConfirmEndpoints>())
    (request as ConfirmEndpoints).serverIds,
];

// 03 §4.3 step 3, §4.7, SAF-09: the batch endpoint confirmation.
void main() {
  for (final (name, size) in [('desktop', _desktop), ('phone', _phone)]) {
    testWidgets('the $name fleet tells of the pending servers and lists '
        'each with its host, port, user and route', (tester) async {
      await _withPending(tester, size: size);
      expect(find.text(_twoPending), findsOneWidget);

      await _openList(tester);
      expect(_inList(find.text('label-a')), findsOneWidget);
      expect(_inList(find.text('deploy@a.example.com:2222')), findsOneWidget);
      expect(_inList(find.text('via edge → mid')), findsOneWidget);
      await tester.scrollUntilVisible(
        _inList(find.text(_changed)),
        100,
        scrollable: _inList(find.byType(Scrollable)).first,
      );
      expect(_inList(find.text('label-b')), findsOneWidget);
      expect(_inList(find.text(_changed)), findsOneWidget);
      // Confirmed servers and imports are not asked about.
      expect(_inList(find.text('label-c')), findsNothing);
      expect(_inList(find.text('x')), findsNothing);
    });
  }

  testWidgets('a toggled row is confirmed, and the list closes once the '
      'engine lists it confirmed', (tester) async {
    final harness = await _withPending(tester);
    await _openList(tester);
    final confirm = find.widgetWithText(FilledButton, 'Confirm selected');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.tap(_inList(find.text('label-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm 1 server'));
    await tester.pump();
    expect(_confirmed(harness), [
      ['a'],
    ]);

    harness.engine.emit(_after({'a'}));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
    expect(find.text('Confirmed 1 server address.'), findsOneWidget);
    expect(find.text(_onePending), findsOneWidget);
  });

  testWidgets('the search narrows the rows, and confirm all shown confirms '
      'only those', (tester) async {
    final harness = await _withPending(tester);
    await _openList(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search servers'),
      'b.example',
    );
    await tester.pumpAndSettle();
    expect(_inList(find.text('label-a')), findsNothing);
    expect(_inList(find.text('label-b')), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search servers'),
      'nowhere',
    );
    await tester.pumpAndSettle();
    expect(find.text('No servers match your search.'), findsOneWidget);
    final all = find.widgetWithText(OutlinedButton, 'Confirm all shown');
    expect(tester.widget<OutlinedButton>(all).onPressed, isNull);

    await tester.enterText(
      find.widgetWithText(TextField, 'Search servers'),
      'b.example',
    );
    await tester.pumpAndSettle();
    await tester.tap(all);
    await tester.pump();
    expect(_confirmed(harness), [
      ['b'],
    ]);
  });

  testWidgets('a confirmation the engine could not save keeps the list '
      'open and says so', (tester) async {
    final harness = await _withPending(tester);
    await _openList(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Confirm all shown'));
    await tester.pump();
    expect(_confirmed(harness), [
      ['a', 'b'],
    ]);
    harness.engine
      ..emit(
        const RequestRejected('ConfirmEndpoints', 'endpoint_pins.json: io'),
      )
      ..emit(_fleet);
    await tester.pumpAndSettle();

    const failed =
        'The confirmation could not be saved on this device, so these '
        'servers stay unconfirmed. Try again.';
    expect(find.text(_title), findsOneWidget);
    expect(find.text(failed), findsOneWidget);
    expect(
      tester.getSemantics(find.text(failed)),
      isSemantics(label: failed, isLiveRegion: true),
    );
  });

  testWidgets('a server still waiting for a changed jump host stays listed, '
      'and the list says why', (tester) async {
    final harness = await _withPending(tester);
    await _openList(tester);

    await tester.tap(_inList(find.text('label-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm 1 server'));
    await tester.pump();
    // The engine pinned a, but a hop on its route changed since.
    harness.engine.emit(_fleet);
    await tester.pumpAndSettle();

    expect(find.text(_title), findsOneWidget);
    expect(
      find.text(
        'Some servers still need confirming: confirm the jump hosts they go '
        'through too.',
      ),
      findsOneWidget,
    );

    // The toggle stays, so trying again is one press.
    expect(_checked(tester, 'a'), isTrue);
    final again = find.widgetWithText(FilledButton, 'Confirm 1 server');
    expect(tester.widget<FilledButton>(again).onPressed, isNotNull);
    await tester.tap(again);
    await tester.pump();
    expect(_confirmed(harness), [
      ['a'],
      ['a'],
    ]);
  });

  testWidgets('Back and the barrier leave the list open while a '
      'confirmation runs, and close it after', (tester) async {
    final harness = await _withPending(tester);
    await _openList(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Confirm all shown'));
    await tester.pump();
    // The progress bar runs, so nothing settles while it shows.
    const closing = Duration(seconds: 1);
    await tester.tapAt(const Offset(4, 4));
    await tester.pump(closing);
    expect(find.text(_title), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pump(closing);
    expect(find.text(_title), findsOneWidget);

    // The answer shows in the list that stayed open.
    harness.engine.emit(_fleet);
    await tester.pumpAndSettle();
    expect(find.textContaining('Some servers still need'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(find.text(_title), findsNothing);
  });

  testWidgets('the search takes the focus on a desktop', (tester) async {
    await _withPending(tester);
    await _openList(tester);
    expect(_searchFocused(tester), isTrue);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('the search leaves the focus alone on a touch device, so no '
      'keyboard covers the rows', (tester) async {
    await _withPending(tester, size: _phone);
    await _openList(tester);
    expect(_searchFocused(tester), isFalse);
  }, variant: TargetPlatformVariant.mobile());

  testWidgets('rows toggle from the keyboard and read as checkboxes', (
    tester,
  ) async {
    final harness = await _withPending(tester);
    await _openList(tester);

    final row = find.ancestor(
      of: _inList(find.text('label-a')),
      matching: find.byType(CheckboxListTile),
    );
    expect(
      tester.getSemantics(row),
      isSemantics(
        hasCheckedState: true,
        isChecked: false,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
        label: 'label-a\ndeploy@a.example.com:2222\nvia edge → mid',
      ),
    );

    // The search field holds the focus first; the next stop is row a.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Confirm 1 server'));
    await tester.pump();
    expect(_confirmed(harness), [
      ['a'],
    ]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  for (final size in [_phone, const Size(360, 640), const Size(568, 320)]) {
    testWidgets('the list fits at 200 % text on a ${size.width.round()} x '
        '${size.height.round()} phone', (tester) async {
      final harness = await _withPending(tester, size: size);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // Opened directly: on the smallest screen the fleet rows' viewport
      // is shorter than the notice, which scrolls with them.
      unawaited(
        showEndpointConfirmation(
          tester.element(find.byType(FleetServerList)),
          harness.fleet,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(_title), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Confirm all shown'),
        100,
        scrollable: _inList(find.byType(Scrollable)).first,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a server view open when its endpoint changes connects again, '
      'so its banner says why', (tester) async {
    final harness = await _withPending(tester);
    await tester.tap(find.text('label-c'));
    await tester.pumpAndSettle();
    final connects = harness.engine.sentOfType<Connect>().length;

    harness.engine.emit(const EndpointChanged('c'));
    await tester.pumpAndSettle();
    expect(harness.engine.sentOfType<Connect>(), hasLength(connects + 1));
    harness.engine.emit(
      const ConnectRejected('c', ConnectRejectedReason.endpointNotConfirmed),
    );
    await tester.pumpAndSettle();
    expect(
      find.textContaining("isn't confirmed on this device"),
      findsOneWidget,
    );
  });
}
