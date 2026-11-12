import 'persisted_setting.dart';

/// FL-08's layouts for the fleet board, the desktop workspace's view of
/// every server while none is open (03 §10.3): [auto] picks [cards] for
/// a small fleet and [grid] from [kFleetGridFrom] servers on, [tree] is
/// FL-11's connection tree, and [rows] leaves the rail's rows alone, with
/// the workspace's invitation.
enum FleetDensity {
  auto,
  cards,
  grid,
  tree,
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
final class FleetDensityController extends PersistedSetting<FleetDensity> {
  FleetDensityController({FleetDensity density = FleetDensity.auto, this._save})
    : super(density);

  final Future<void> Function(String name)? _save;

  /// Picks [density]; a no-op when it is in force and saved. Throws
  /// [FleetDensityNotSavedException] when it applied but was not saved.
  Future<void> setDensity(FleetDensity density) => change(density);

  @override
  Future<void>? save(FleetDensity density) => _save?.call(density.name);

  @override
  Exception notSaved(Object error) =>
      FleetDensityNotSavedException('The fleet layout was not saved: $error');
}
