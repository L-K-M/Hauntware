// OV-06: the Overview's card order and hidden cards, as settings.json
// keeps them.
import 'dart:io' show FileSystemException;

import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/overview_layout.dart';

void main() {
  test('a stored layout keeps its order, drops names it does not know, '
      'and puts a card it lacks at its default place', () {
    // History and quick actions came after this was stored.
    final layout = OverviewLayout.decode(
      [
        'memory',
        'gpu',
        for (final card in OverviewCard.values)
          if (card != OverviewCard.quickActions && card != OverviewCard.history)
            card.name,
      ],
      ['swap', 'nonsense'],
    );
    expect(layout.order, [
      OverviewCard.quickActions,
      OverviewCard.memory,
      OverviewCard.cpu,
      OverviewCard.load,
      OverviewCard.swap,
      OverviewCard.pressure,
      OverviewCard.disks,
      OverviewCard.network,
      OverviewCard.host,
      OverviewCard.docker,
      OverviewCard.topLists,
      OverviewCard.history,
    ]);
    expect(layout.hidden, {OverviewCard.swap});
    expect(layout.shown, isNot(contains(OverviewCard.swap)));
    expect(
      OverviewLayout.decode(layout.encodedOrder, layout.encodedHidden),
      layout,
    );
    expect(OverviewLayout.decode(const [], const []), OverviewLayout.standard);
  });

  test('a change applies before it is saved, says when it was not saved, '
      'and setting it again retries the save', () async {
    final saved = <(List<String>, List<String>)>[];
    var failing = true;
    final controller = OverviewLayoutController(
      save: (order, hidden) async {
        if (failing) throw const FileSystemException('disk full');
        saved.add((order, hidden));
      },
    );
    addTearDown(controller.dispose);
    final hidden = OverviewLayout(
      order: OverviewCard.values,
      hidden: {OverviewCard.history},
    );

    await expectLater(
      controller.setLayout(hidden),
      throwsA(isA<OverviewLayoutNotSavedException>()),
    );
    expect(controller.value, hidden);

    failing = false;
    await controller.setLayout(hidden);
    expect(saved.single.$1, OverviewLayout.standard.encodedOrder);
    expect(saved.single.$2, ['history']);
    await controller.setLayout(hidden);
    expect(saved, hasLength(1), reason: 'in force and saved');
  });
}
