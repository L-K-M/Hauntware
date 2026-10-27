import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart' show UnitScope;

/// The most services one server pins to its Overview's quick actions: a
/// card of buttons, not a second Services tab.
const int kPinnedServicesMax = 5;

/// A unit pinned to a server's quick actions (OV-08): its name and the
/// manager it belongs to (SVC-09).
@immutable
final class PinnedService {
  const PinnedService(this.unit, {this.scope = UnitScope.system});

  final String unit;
  final UnitScope scope;

  /// The stored form, `<scope>/<unit>`: a unit name holds no slash.
  String get encoded => '${scope.name}/$unit';

  /// The pin [encoded] names, or null for a form this version does not
  /// read, which is left out.
  static PinnedService? parse(String encoded) {
    final slash = encoded.indexOf('/');
    if (slash <= 0 || slash == encoded.length - 1) return null;
    final scope = UnitScope.values.asNameMap()[encoded.substring(0, slash)];
    final unit = encoded.substring(slash + 1);
    if (scope == null || unit.contains('/')) return null;
    return PinnedService(unit, scope: scope);
  }

  @override
  bool operator ==(Object other) =>
      other is PinnedService && other.unit == unit && other.scope == scope;

  @override
  int get hashCode => Object.hash(unit, scope);
}

/// A pin that changed but was not saved: it lasts until the app restarts
/// unless a later save carries it. [message] is what the failed save
/// printed.
final class PinnedServicesNotSavedException implements Exception {
  const PinnedServicesNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The device's pinned services, by server id (OV-08): the composition
/// root restores them from `settings.json` and saves every change there;
/// without a save callback, as in most tests, they are held in memory
/// only. A change applies before it is saved.
final class PinnedServicesController extends ChangeNotifier
    implements ValueListenable<Map<String, List<PinnedService>>> {
  PinnedServicesController({
    Map<String, List<PinnedService>> pins = const {},
    this._save,
  }) : _value = Map.unmodifiable(pins);

  Map<String, List<PinnedService>> _value;
  final Future<void> Function(String serverId, List<String> pins)? _save;

  @override
  Map<String, List<PinnedService>> get value => _value;

  /// [serverId]'s pins, in the order pinned.
  List<PinnedService> pinsFor(String serverId) => _value[serverId] ?? const [];

  /// Whether [serverId] holds [kPinnedServicesMax] pins, so [pin] would
  /// not take another.
  bool fullFor(String serverId) =>
      pinsFor(serverId).length >= kPinnedServicesMax;

  /// Pins [service] on [serverId] when it is not, else unpins it. A pin
  /// past [kPinnedServicesMax] does nothing. Throws
  /// [PinnedServicesNotSavedException] when the change applied but was
  /// not saved.
  Future<void> toggle(String serverId, PinnedService service) async {
    final pins = [...pinsFor(serverId)];
    if (!pins.remove(service)) {
      if (pins.length >= kPinnedServicesMax) return;
      pins.add(service);
    }
    _value = Map.unmodifiable({
      for (final MapEntry(:key, :value) in _value.entries)
        if (key != serverId) key: value,
      if (pins.isNotEmpty) serverId: List<PinnedService>.unmodifiable(pins),
    });
    notifyListeners();
    try {
      await _save?.call(serverId, [for (final pin in pins) pin.encoded]);
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        PinnedServicesNotSavedException(
          'The pinned services were not saved: $error',
        ),
        stackTrace,
      );
    }
  }
}
