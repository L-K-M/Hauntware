import 'package:seance_core/catalog.dart';
import 'package:test/test.dart';

EndpointPin _pin({
  String serverId = 'srv-1',
  String host = 'nas.local',
  int port = 22,
  String username = 'admin',
  List<String> jumpRouteIds = const ['srv-bastion', 'srv-inner'],
  DateTime? confirmedAt,
}) => EndpointPin(
  serverId: serverId,
  host: host,
  port: port,
  username: username,
  jumpRouteIds: jumpRouteIds,
  confirmedAt: confirmedAt ?? DateTime.utc(2026, 10, 16, 12),
);

void main() {
  group('EndpointPin', () {
    test('equal values are equal and hash alike', () {
      expect(_pin(), _pin());
      expect(_pin().hashCode, _pin().hashCode);
    });

    test('every element takes part in equality', () {
      final base = _pin();
      expect(_pin(serverId: 'srv-2'), isNot(base));
      expect(_pin(host: 'nas.example.com'), isNot(base));
      expect(_pin(port: 2222), isNot(base));
      expect(_pin(username: 'root'), isNot(base));
      expect(_pin(jumpRouteIds: const ['srv-bastion']), isNot(base));
      expect(_pin(jumpRouteIds: const []), isNot(base));
      expect(
        _pin(confirmedAt: DateTime.utc(2026, 10, 16, 12, 0, 1)),
        isNot(base),
      );
    });

    test('the jump route is compared in hop order', () {
      expect(
        _pin(jumpRouteIds: const ['srv-inner', 'srv-bastion']),
        isNot(_pin()),
      );
    });

    test('confirmedAt is kept in UTC to the millisecond', () {
      final instant = DateTime.utc(2026, 10, 16, 12, 0, 0, 5, 999);
      final pin = _pin(confirmedAt: instant.toLocal());

      expect(pin.confirmedAt.isUtc, isTrue);
      expect(pin.confirmedAt, DateTime.utc(2026, 10, 16, 12, 0, 0, 5));
      expect(pin, _pin(confirmedAt: DateTime.utc(2026, 10, 16, 12, 0, 0, 5)));
    });

    test('the route is copied and unmodifiable', () {
      final route = ['srv-bastion'];
      final pin = _pin(jumpRouteIds: route);
      route.add('srv-inner');

      expect(pin.jumpRouteIds, ['srv-bastion']);
      expect(() => pin.jumpRouteIds.add('srv-x'), throwsUnsupportedError);
    });

    test('round-trips through its JSON form', () {
      final pin = _pin();
      expect(EndpointPin.fromJson(pin.toJson()), pin);
      expect(
        EndpointPin.fromJson(_pin(jumpRouteIds: const []).toJson()),
        _pin(jumpRouteIds: const []),
      );
    });

    test('refuses values no file may hold', () {
      expect(() => _pin(serverId: ''), throwsArgumentError);
      expect(() => _pin(host: ''), throwsArgumentError);
      expect(() => _pin(port: 0), throwsArgumentError);
      expect(() => _pin(port: 65536), throwsArgumentError);
      expect(() => _pin(jumpRouteIds: const ['']), throwsArgumentError);
      expect(_pin(username: '').username, isEmpty);
    });

    test('rejects malformed stored entries explicitly', () {
      final valid = _pin().toJson();
      final malformed = <Object?>[
        null,
        'srv-1',
        [valid],
        {...valid}..remove('host'),
        {...valid, 'port': '22'},
        {...valid, 'port': 0},
        {...valid, 'host': ''},
        {...valid, 'username': null},
        {...valid, 'jumpRouteIds': 'srv-bastion'},
        {
          ...valid,
          'jumpRouteIds': ['srv-bastion', 7],
        },
        {...valid, 'confirmedAt': '2026-10-16T12:00:00Z'},
        {...valid, 'confirmedAt': 1.5},
      ];

      for (final entry in malformed) {
        expect(
          () => EndpointPin.fromJson(entry),
          throwsFormatException,
          reason: '$entry',
        );
      }
    });
  });
}
