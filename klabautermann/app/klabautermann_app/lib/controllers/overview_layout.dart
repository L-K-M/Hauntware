import 'package:flutter/foundation.dart';

/// The Overview's cards a user arranges (OV-06). The health card and the
/// panel's notices head the panel and the coverage card ends it, so they
/// stay out of the arrangement.
/// In their default order: a phone shows them so, and a wide panel splits
/// each run of half-width cards between two columns, the first half on
/// the left.
enum OverviewCard {
  quickActions,
  cpu,
  load,
  memory,
  swap,
  pressure,
  disks,
  network,
  host,
  docker,
  topLists,
  history;

  /// Whether the card takes the panel's full width; the others pair up in
  /// two columns on a wide panel.
  bool get fullWidth => switch (this) {
    quickActions || topLists || history => true,
    _ => false,
  };
}

/// The Overview's cards in the order this device shows them, and those
/// hidden (OV-06).
@immutable
final class OverviewLayout {
  OverviewLayout({
    required List<OverviewCard> order,
    Set<OverviewCard> hidden = const {},
  }) : order = List.unmodifiable(order),
       hidden = Set.unmodifiable(hidden);

  /// Every card in its default place, none hidden.
  static final OverviewLayout standard = OverviewLayout(
    order: OverviewCard.values,
  );

  /// The layout [order] and [hidden] name, as `settings.json` keeps them:
  /// a name this version does not know is left out, and a card the stored
  /// order lacks, such as one a later version added, takes its default
  /// place after the card it follows there.
  factory OverviewLayout.decode(List<String> order, List<String> hidden) {
    final byName = OverviewCard.values.asNameMap();
    final cards = <OverviewCard>[for (final name in order) ?byName[name]];
    final known = cards.toSet();
    cards.retainWhere(known.remove);
    for (final card in OverviewCard.values) {
      if (cards.contains(card)) continue;
      final before = OverviewCard.values
          .take(card.index)
          .lastWhere(cards.contains, orElse: () => card);
      cards.insert(before == card ? 0 : cards.indexOf(before) + 1, card);
    }
    return OverviewLayout(
      order: cards,
      hidden: {for (final name in hidden) ?byName[name]},
    );
  }

  final List<OverviewCard> order;
  final Set<OverviewCard> hidden;

  /// The cards shown, in order.
  List<OverviewCard> get shown => [
    for (final card in order)
      if (!hidden.contains(card)) card,
  ];

  List<String> get encodedOrder => [for (final card in order) card.name];
  List<String> get encodedHidden => [
    for (final card in order)
      if (hidden.contains(card)) card.name,
  ];

  @override
  bool operator ==(Object other) =>
      other is OverviewLayout &&
      listEquals(other.order, order) &&
      setEquals(other.hidden, hidden);

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(order), Object.hashAll(encodedHidden));
}

/// A layout that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class OverviewLayoutNotSavedException implements Exception {
  const OverviewLayoutNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The device's Overview layout (OV-06): the composition root restores it
/// from `settings.json` and saves every change there; without a save
/// callback, as in most tests, it is held in memory only. A change
/// applies before it is saved, and setting the same layout again after a
/// failed save tries the save again.
final class OverviewLayoutController extends ChangeNotifier
    implements ValueListenable<OverviewLayout> {
  OverviewLayoutController({OverviewLayout? layout, this._save})
    : _value = layout ?? OverviewLayout.standard,
      _saved = layout ?? OverviewLayout.standard;

  OverviewLayout _value;
  OverviewLayout _saved;
  final Future<void> Function(List<String> order, List<String> hidden)? _save;

  /// The last change's apply and save: a change waits for the one before
  /// it, so overlapping saves land in order and the file ends with the
  /// last one.
  Future<void> _changes = Future<void>.value();

  @override
  OverviewLayout get value => _value;

  /// Puts [layout] in force and saves it. Throws
  /// [OverviewLayoutNotSavedException] when it applied but was not saved.
  Future<void> setLayout(OverviewLayout layout) {
    final change = _changes.then((_) => _apply(layout));
    // A failed save leaves the queue running; its caller sees the error.
    _changes = change.then<void>((_) {}, onError: (Object _) {});
    return change;
  }

  Future<void> _apply(OverviewLayout layout) async {
    if (layout == _value && layout == _saved) return;
    if (layout != _value) {
      _value = layout;
      notifyListeners();
    }
    try {
      await _save?.call(layout.encodedOrder, layout.encodedHidden);
      _saved = layout;
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        OverviewLayoutNotSavedException(
          'The Overview layout was not saved: $error',
        ),
        stackTrace,
      );
    }
  }
}
