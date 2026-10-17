/// Endpoint confirmation (SAF-09, decision D16, 03-ARCHITECTURE.md 4.7):
/// any device on the account can rewrite a server's host through LWW, so
/// background connections (fleet sampling, probes, Docker events) run only
/// against the endpoint the user confirmed on this device. The pins are
/// device-local and never sync (03 4.9).
library;

import 'package:meta/meta.dart';

/// The endpoint the user confirmed for one server on this device.
///
/// A background connection matches only when every element equals the
/// server's current values; a synced change to any of them means asking
/// again. [jumpRouteIds] is the route's server ids in hop order, so the
/// same hops in another order are a different route.
///
/// Immutable with value equality. [confirmedAt] is kept in UTC to the
/// millisecond, the precision `endpoint_pins.json` stores, so a pin
/// equals itself after a round trip through the file.
@immutable
final class EndpointPin {
  /// Throws [ArgumentError] for a value no file may hold: an empty
  /// [serverId], [host] or jump-route id, or a [port] outside 1 to 65535.
  /// The constructor checks what `confirm` would otherwise write and a
  /// later load would reject.
  EndpointPin({
    required this.serverId,
    required this.host,
    required this.port,
    required this.username,
    required Iterable<String> jumpRouteIds,
    required DateTime confirmedAt,
  }) : jumpRouteIds = List.unmodifiable(jumpRouteIds),
       confirmedAt = DateTime.fromMillisecondsSinceEpoch(
         confirmedAt.millisecondsSinceEpoch,
         isUtc: true,
       ) {
    if (serverId.isEmpty) {
      throw ArgumentError.value(serverId, 'serverId', 'must not be empty');
    }
    if (host.isEmpty) {
      throw ArgumentError.value(host, 'host', 'must not be empty');
    }
    if (port < _minPort || port > _maxPort) {
      throw ArgumentError.value(port, 'port', 'must be 1 to 65535');
    }
    if (this.jumpRouteIds.any((id) => id.isEmpty)) {
      throw ArgumentError.value(
        this.jumpRouteIds,
        'jumpRouteIds',
        'must not contain an empty id',
      );
    }
  }

  static const _minPort = 1;
  static const _maxPort = 65535;

  static const _serverIdKey = 'serverId';
  static const _hostKey = 'host';
  static const _portKey = 'port';
  static const _usernameKey = 'username';
  static const _jumpRouteIdsKey = 'jumpRouteIds';
  static const _confirmedAtKey = 'confirmedAt';

  /// The `ServerConfig.id` this pin belongs to.
  final String serverId;

  /// `ServerConfig.host` as confirmed, compared verbatim.
  final String host;

  final int port;

  /// `ServerConfig.username` as confirmed; may be empty, as the server's
  /// own field may be.
  final String username;

  /// The jump route's server ids in hop order, empty for a direct
  /// connection; unmodifiable.
  final List<String> jumpRouteIds;

  /// When the user confirmed this endpoint, in UTC.
  final DateTime confirmedAt;

  /// Decodes one stored pin. Throws [FormatException] for anything that
  /// is not a valid pin, so a damaged entry is never read as a weaker one.
  factory EndpointPin.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('endpoint pin entry');

    final serverId = json[_serverIdKey];
    final host = json[_hostKey];
    final port = json[_portKey];
    final username = json[_usernameKey];
    final jumpRouteIds = json[_jumpRouteIdsKey];
    final confirmedAt = json[_confirmedAtKey];
    if (serverId is! String ||
        host is! String ||
        port is! int ||
        username is! String ||
        jumpRouteIds is! List ||
        jumpRouteIds.any((id) => id is! String) ||
        confirmedAt is! int) {
      throw FormatException('endpoint pin fields for $serverId');
    }

    try {
      return EndpointPin(
        serverId: serverId,
        host: host,
        port: port,
        username: username,
        jumpRouteIds: jumpRouteIds.cast<String>(),
        confirmedAt: DateTime.fromMillisecondsSinceEpoch(
          confirmedAt,
          isUtc: true,
        ),
      );
    } on ArgumentError catch (error) {
      throw FormatException('endpoint pin values for $serverId: $error');
    }
  }

  /// The stored form: [confirmedAt] as milliseconds since the epoch, like
  /// `HostKey.pinnedAt` in `host_keys.json`.
  Map<String, Object> toJson() => {
    _serverIdKey: serverId,
    _hostKey: host,
    _portKey: port,
    _usernameKey: username,
    _jumpRouteIdsKey: jumpRouteIds,
    _confirmedAtKey: confirmedAt.millisecondsSinceEpoch,
  };

  @override
  bool operator ==(Object other) =>
      other is EndpointPin &&
      other.serverId == serverId &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      _sameRoute(other.jumpRouteIds, jumpRouteIds) &&
      other.confirmedAt == confirmedAt;

  @override
  int get hashCode => Object.hash(
    serverId,
    host,
    port,
    username,
    Object.hashAll(jumpRouteIds),
    confirmedAt,
  );

  @override
  String toString() =>
      'EndpointPin($serverId: $username@$host:$port via $jumpRouteIds, '
      'confirmed ${confirmedAt.toIso8601String()})';

  static bool _sameRoute(List<String> a, List<String> b) {
    if (a.length != b.length) return false;

    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The confirmed endpoint per server on this device (D16, 03 4.7).
/// `FileEndpointPinStore` keeps them in `endpoint_pins.json`.
abstract interface class EndpointPinStore {
  /// The pin for [serverId], or null when this device has confirmed no
  /// endpoint for it.
  Future<EndpointPin?> pinFor(String serverId);

  /// Records [pin] as the confirmed endpoint of its server, replacing any
  /// earlier pin for that server whole. Completes once the pin is stored.
  Future<void> confirm(EndpointPin pin);

  /// Forgets the pin for [serverId]. A server with no pin is left as it
  /// is: the store already holds what was asked.
  Future<void> drop(String serverId);
}
