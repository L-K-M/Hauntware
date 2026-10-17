import 'dart:io';

import 'package:seance_core/catalog.dart'
    show
        EndpointPin,
        EndpointPinStore,
        FileEndpointPinStore,
        endpointPinsFileName;

import '../settings/instance_lock.dart' show SupportDirectoryAccess;

/// Opens the engine's endpoint pins in [supportDirectory] (03 §4.7,
/// §4.10, D16). With [SupportDirectoryAccess.exclusive] access they are
/// `seance_core`'s [FileEndpointPinStore] over [endpointPinsFileName], so
/// a confirmation outlives the engine. Without it they are kept in memory
/// only, starting empty, and nothing in the directory is read or written:
/// such an engine lists no synced server (sync needs the directory alone,
/// D63), so no pin of the file could apply, and another instance may be
/// writing it.
///
/// The engine opens one store and keeps it: a [FileEndpointPinStore]
/// loads its file once and then writes its whole cache, so a second
/// instance over the same file would undo the first one's pins.
EndpointPinStore openEndpointPins(
  String supportDirectory, {
  required SupportDirectoryAccess access,
}) => switch (access) {
  SupportDirectoryAccess.exclusive => FileEndpointPinStore(
    File('$supportDirectory${Platform.pathSeparator}$endpointPinsFileName'),
  ),
  SupportDirectoryAccess.unguarded => _MemoryEndpointPins(),
};

/// Pins for this engine's lifetime only.
final class _MemoryEndpointPins implements EndpointPinStore {
  final Map<String, EndpointPin> _pins = {};

  @override
  Future<EndpointPin?> pinFor(String serverId) async => _pins[serverId];

  @override
  Future<void> confirm(EndpointPin pin) async => _pins[pin.serverId] = pin;

  @override
  Future<void> drop(String serverId) async => _pins.remove(serverId);
}
