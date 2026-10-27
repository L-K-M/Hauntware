import 'package:flutter/foundation.dart';

/// FL-08's layouts for the fleet board, the desktop workspace's view of
/// every server while none is open (03 §10.3): [auto] picks [cards] for
/// a small fleet and [grid] from [kFleetGridFrom] servers on, and [rows]
/// leaves the rail's rows alone, with the workspace's invitation.
enum FleetDensity {
  auto,
  cards,
  grid,
  rows;

  /// The layout [name] names, or [auto] for null or a name this version
  /// does not know.
  static FleetDensity parse(String? name) => switch (name) {
    final name? => values.asNameMap()[name] ?? auto,
    null => auto,
  };

  /// The layout this one shows for a fleet of [servers]: [auto] resolved,
  /// the others as they are.
  FleetDensity resolve(int servers) => switch (this) {
    auto => servers >= kFleetGridFrom ? grid : cards,
    _ => this,
  };
}

/// From how many servers [FleetDensity.auto] packs the board as a grid:
/// past a dozen, cards no longer fit a desktop window without scrolling,
/// and FL-08's grid is meant for 40 and more.
const int kFleetGridFrom = 12;

/// A layout that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class FleetDensityNotSavedException implements Exception {
  const FleetDensityNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The device's board layout (FL-08): the composition root restores it
/// from `settings.json` and saves every change there; without a save
/// callback, as in most tests, it is held in memory only. A change
/// applies before it is saved, and picking the same layout after a failed
/// save tries the save again.
final class FleetDensityController extends ChangeNotifier
    implements ValueListenable<FleetDensity> {
  FleetDensityController({FleetDensity density = FleetDensity.auto, this._save})
    : _value = density,
      _saved = density;

  FleetDensity _value;
  FleetDensity _saved;
  final Future<void> Function(String name)? _save;

  @override
  FleetDensity get value => _value;

  /// Picks [density]; a no-op when it is in force and saved. Throws
  /// [FleetDensityNotSavedException] when it applied but was not saved.
  Future<void> setDensity(FleetDensity density) async {
    if (density == _value && density == _saved) return;
    if (density != _value) {
      _value = density;
      notifyListeners();
    }
    try {
      await _save?.call(density.name);
      _saved = density;
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        FleetDensityNotSavedException('The fleet layout was not saved: $error'),
        stackTrace,
      );
    }
  }
}
