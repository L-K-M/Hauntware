import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

HttpHeaders headersOf(Map<String, String> m) =>
    HttpHeaders(m.entries.map((e) => (e.key, e.value)));

void main() {
  group('ApiVersion', () {
    test('parses 1.44 and v1.44, rejects junk', () {
      expect(ApiVersion.tryParse('1.44'), const ApiVersion(1, 44));
      expect(ApiVersion.tryParse('v1.44'), const ApiVersion(1, 44));
      expect(ApiVersion.tryParse(' 1.41 '), const ApiVersion(1, 41));
      expect(ApiVersion.tryParse('1.44.5'), isNull);
      expect(ApiVersion.tryParse('x'), isNull);
      expect(ApiVersion.tryParse(''), isNull);
      expect(ApiVersion.tryParse(null), isNull);
    });

    test('compares and renders the path segment', () {
      expect(const ApiVersion(1, 44) < const ApiVersion(1, 52), isTrue);
      expect(const ApiVersion(1, 52) > const ApiVersion(1, 44), isTrue);
      expect(const ApiVersion(1, 44), const ApiVersion(1, 44));
      expect(const ApiVersion(1, 44) == const ApiVersion(2, 44), isFalse);
      expect(const ApiVersion(1, 44).pathSegment, 'v1.44');
      expect('${const ApiVersion(1, 44)}', '1.44');
    });
  });

  group('parsePingHeaders', () {
    test('reads every negotiation header (03 §5.8)', () {
      final r = parsePingHeaders(
        headersOf({
          'Api-Version': '1.52',
          'Docker-Experimental': 'true',
          'OSType': 'linux',
          'Builder-Version': '2',
        }),
      );
      expect(r.warnings, isEmpty);
      expect(r.value.apiVersion, const ApiVersion(1, 52));
      expect(r.value.dockerExperimental, isTrue);
      expect(r.value.osType, 'linux');
      expect(r.value.builderVersion, '2');
      expect(r.value.isPodman, isFalse);
    });

    test('Libpod-API-Version marks Podman', () {
      final r = parsePingHeaders(
        headersOf({'Api-Version': '1.44', 'Libpod-API-Version': '5.4.1'}),
      );
      expect(r.value.isPodman, isTrue);
      expect(r.value.libpodApiVersion, '5.4.1');
    });

    test('unparseable values warn, never throw', () {
      final r = parsePingHeaders(
        headersOf({'Api-Version': 'banana', 'Docker-Experimental': 'maybe'}),
      );
      expect(r.value.apiVersion, isNull);
      expect(r.value.dockerExperimental, isNull);
      expect(r.warnings, hasLength(2));
    });
  });

  group('parseServerVersion', () {
    test('parses the hand-written Docker 29.3 fixture', () {
      final doc = jsonDecode(fixtureString('version-docker-29.3.json'));
      final r = parseServerVersion(doc);
      expect(r.warnings, isEmpty);
      expect(r.value.version, '29.3.1');
      expect(r.value.apiVersion, const ApiVersion(1, 55));
      expect(r.value.minApiVersion, const ApiVersion(1, 40));
      expect(r.value.os, 'linux');
      expect(r.value.isPodman, isFalse);
    });

    test('parses the hand-written Podman fixture and detects Podman', () {
      final doc = jsonDecode(fixtureString('version-podman.json'));
      final r = parseServerVersion(doc);
      expect(r.value.apiVersion, const ApiVersion(1, 44));
      expect(r.value.minApiVersion, const ApiVersion(1, 24));
      expect(r.value.isPodman, isTrue);
    });

    test('a non-object document warns instead of throwing', () {
      final r = parseServerVersion('nope');
      expect(r.warnings, isNotEmpty);
      expect(r.value.apiVersion, isNull);
    });

    test('malformed fields land in warnings', () {
      final r = parseServerVersion({
        'ApiVersion': 42,
        'MinAPIVersion': 'x.y',
        'Version': true,
      });
      expect(r.value.apiVersion, isNull);
      expect(r.warnings.length, greaterThanOrEqualTo(3));
    });
  });

  group('negotiateApiVersion (03 §5.8)', () {
    // The client was tested up to 1.55 with a floor of 1.41.
    DockerNegotiation? tryNegotiate(
      String? max, {
      String? min,
      bool podman = false,
    }) {
      try {
        return negotiateApiVersion(
          serverMax: ApiVersion.tryParse(max),
          serverMin: ApiVersion.tryParse(min),
          isPodman: podman,
        );
      } on NegotiationRefusedException {
        return null;
      }
    }

    test('negotiated = min(clientMaxTested, serverMax)', () {
      expect(tryNegotiate('1.55')!.negotiated, const ApiVersion(1, 55));
      expect(tryNegotiate('1.52')!.negotiated, const ApiVersion(1, 52));
      expect(tryNegotiate('1.44')!.negotiated, const ApiVersion(1, 44));
      expect(tryNegotiate('1.41')!.negotiated, const ApiVersion(1, 41));
    });

    test('Docker 29.0 to 29.2 floor 1.44 is honored', () {
      final n = negotiateApiVersion(
        serverMax: const ApiVersion(1, 52),
        serverMin: const ApiVersion(1, 44),
      );
      expect(n.negotiated, const ApiVersion(1, 52));
      // A clientMax below the 29.0 floor would be refused.
      final e = expectThrows<NegotiationRefusedException>(
        Future.sync(
          () => negotiateApiVersion(
            serverMax: const ApiVersion(1, 52),
            serverMin: const ApiVersion(1, 44),
            clientMax: const ApiVersion(1, 43),
          ),
        ),
      );
      return e.then((e) {
        expect(e.reason, NegotiationRefusal.belowServerMinimum);
      });
    });

    test('Docker 29.3 floor 1.40 accepts the client floor edge', () {
      final n = negotiateApiVersion(
        serverMax: const ApiVersion(1, 55),
        serverMin: const ApiVersion(1, 40),
      );
      expect(n.negotiated, const ApiVersion(1, 55));
    });

    test('a server max below the client floor 1.41 is refused', () {
      final e = expectThrows<NegotiationRefusedException>(
        Future.sync(
          () => negotiateApiVersion(serverMax: const ApiVersion(1, 40)),
        ),
      );
      return e.then((e) {
        expect(e.reason, NegotiationRefusal.belowClientFloor);
        expect(e.negotiated, const ApiVersion(1, 40));
        expect(e.serverMax, const ApiVersion(1, 40));
      });
    });

    test('an unversioned server is refused with a clear reason', () {
      final e = expectThrows<NegotiationRefusedException>(
        Future.sync(() => negotiateApiVersion(serverMax: null)),
      );
      return e.then((e) {
        expect(e.reason, NegotiationRefusal.serverVersionUnknown);
        expect(e.message, contains('did not report'));
      });
    });

    test('negotiated below the server minimum is refused', () {
      final e = expectThrows<NegotiationRefusedException>(
        Future.sync(
          () => negotiateApiVersion(
            serverMax: const ApiVersion(1, 55),
            serverMin: const ApiVersion(1, 50),
            clientMax: const ApiVersion(1, 44),
          ),
        ),
      );
      return e.then((e) {
        expect(e.reason, NegotiationRefusal.belowServerMinimum);
        expect(e.negotiated, const ApiVersion(1, 44));
        expect(e.serverMin, const ApiVersion(1, 50));
      });
    });

    test('Podman compat layer: max 1.44, min 1.24 negotiates 1.44', () {
      final n = negotiateApiVersion(
        serverMax: const ApiVersion(1, 44),
        serverMin: const ApiVersion(1, 24),
        isPodman: true,
      );
      expect(n.negotiated, const ApiVersion(1, 44));
      expect(n.isPodman, isTrue);
      expect(n.gates.hasLogsContentType, isTrue);
      expect(n.gates.usesEventV2, isFalse);
    });
  });

  group('ApiFeatureGates (03 §5.8)', () {
    ApiFeatureGates gates(int minor) => ApiFeatureGates(ApiVersion(1, minor));

    test('logs Content-Type from 1.42', () {
      expect(gates(41).hasLogsContentType, isFalse);
      expect(gates(42).hasLogsContentType, isTrue);
      expect(gates(55).hasLogsContentType, isTrue);
    });

    test('volume prune all filter from 1.42', () {
      expect(gates(41).hasVolumePruneAll, isFalse);
      expect(gates(42).hasVolumePruneAll, isTrue);
    });

    test('image Containers count from 1.51', () {
      expect(gates(50).hasImageContainersCount, isFalse);
      expect(gates(51).hasImageContainersCount, isTrue);
    });

    test('event shape v2 from 1.52', () {
      expect(gates(51).usesEventV2, isFalse);
      expect(gates(52).usesEventV2, isTrue);
    });

    test('system df shapes at 1.52 and 1.53', () {
      expect(gates(51).systemDfShape, SystemDfShape.legacy);
      expect(gates(52).systemDfShape, SystemDfShape.v152);
      expect(gates(53).systemDfShape, SystemDfShape.v153);
      expect(gates(55).systemDfShape, SystemDfShape.v153);
    });

    test('attestations from 1.55', () {
      expect(gates(54).hasAttestations, isFalse);
      expect(gates(55).hasAttestations, isTrue);
    });
  });
}
