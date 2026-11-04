import 'package:seance_sync_server/src/client_address.dart';
import 'package:test/test.dart';

void main() {
  group('ClientAddressResolver', () {
    test('canonicalizes numeric addresses', () {
      expect(canonicalIpAddress('192.0.2.1'), '192.0.2.1');
      expect(canonicalIpAddress('2001:0db8::1'), '2001:db8::1');
      expect(canonicalIpAddress('::ffff:203.0.113.9'), '203.0.113.9');
      expect(canonicalIpAddress('::ffff:cb00:7104'), '203.0.113.4');
      expect(canonicalIpAddress('example.com'), isNull);
      expect(canonicalIpAddress('192.0.2.1:443'), isNull);
    });

    test('matches IPv4 proxies reported through a dual-stack listener', () {
      final resolver = ClientAddressResolver(const ['172.17.0.2']);

      expect(
        resolver.resolve(
          peerAddress: '::ffff:172.17.0.2',
          forwardedFor: '203.0.113.9',
        ),
        '203.0.113.9',
      );
    });

    test('normalizes mapped addresses throughout a trusted chain', () {
      final resolver = ClientAddressResolver(const [
        '172.17.0.2',
        '192.0.2.11',
      ]);

      expect(
        resolver.resolve(
          peerAddress: '::ffff:172.17.0.2',
          forwardedFor: '::ffff:203.0.113.9, ::ffff:192.0.2.11',
        ),
        '203.0.113.9',
      );
    });

    test('does not demote non-mapped IPv6 transition addresses', () {
      for (final address in const [
        '64:ff9b::ac11:2',
        '2002:ac11:2::',
        '::ac11:2',
        '::ffff:0:ac11:2',
      ]) {
        expect(canonicalIpAddress(address), isNot('172.17.0.2'));
      }
    });

    test('ignores a spoofed header from an untrusted peer', () {
      final resolver = ClientAddressResolver(const ['192.0.2.10']);

      expect(
        resolver.resolve(
          peerAddress: '198.51.100.7',
          forwardedFor: '203.0.113.4',
        ),
        '198.51.100.7',
      );
    });

    test('walks a trusted chain from the nearest proxy', () {
      final resolver = ClientAddressResolver(const [
        '192.0.2.10',
        '192.0.2.11',
      ]);

      expect(
        resolver.resolve(
          peerAddress: '192.0.2.10',
          forwardedFor: '203.0.113.4, 192.0.2.11',
        ),
        '203.0.113.4',
      );
    });

    test('uses the leftmost address when every hop is trusted', () {
      final resolver = ClientAddressResolver(const [
        '192.0.2.10',
        '192.0.2.11',
      ]);

      expect(
        resolver.resolve(
          peerAddress: '192.0.2.10',
          forwardedFor: '192.0.2.11, 192.0.2.10',
        ),
        '192.0.2.11',
      );
    });

    test('malformed and excessive chains fall back to the peer', () {
      final resolver = ClientAddressResolver(const ['192.0.2.10']);
      for (final header in [
        '203.0.113.4, not-an-ip',
        '203.0.113.4, ',
        '1' * (maxForwardedForLength + 1),
        List.filled(maxForwardedForHops + 1, '203.0.113.4').join(','),
      ]) {
        expect(
          resolver.resolve(peerAddress: '192.0.2.10', forwardedFor: header),
          '192.0.2.10',
          reason: header,
        );
      }
    });

    test('rejects non-IP trusted proxy entries', () {
      expect(
        () => ClientAddressResolver(const ['proxy.example.com']),
        throwsArgumentError,
      );
    });
  });
}
