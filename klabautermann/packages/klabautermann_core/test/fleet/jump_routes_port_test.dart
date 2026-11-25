import 'package:klabautermann_core/src/engine/protocol.dart'
    show kSshDefaultPort;
import 'package:klabautermann_core/src/fleet/jump_routes.dart';
import 'package:seance_core/seance_core.dart' show ImportedHost, parseSshPort;
import 'package:test/test.dart';

/// The port a one-hop `ProxyJump` of the form `h:<text>` yields, null where
/// the engine refuses the hop.
int? _hopPort(String text) => jumpRoutes([
  ImportedHost(alias: 't', proxyJump: 'h:$text'),
])['t']?.first.port;

void main() {
  group('jump hop ports (ENG-13)', () {
    test('reads the decimal ports ssh writes', () {
      expect(_hopPort('1'), 1);
      expect(_hopPort('22'), 22);
      expect(_hopPort('00022'), 22);
      expect(_hopPort('65535'), 65535);
      // An empty port is no port, so the hop keeps ssh's default.
      expect(_hopPort(''), kSshDefaultPort);
    });

    test('refuses the values outside the TCP range or its digits', () {
      for (final text in [
        '0',
        '65536',
        '+22',
        '-22',
        ' 22',
        '2 2',
        '22a',
        'ssh',
        'http',
        'https',
      ]) {
        expect(_hopPort(text), isNull, reason: text);
      }
    });

    test('keeps the hop parser narrower than seance_core\'s', () {
      // parseSshPort also reads a sign and the service names ssh knows,
      // while a ProxyJump hop's port stays decimal and unsigned here.
      for (final text in ['+1', '+22', '+65535']) {
        expect(parseSshPort(text), int.parse(text.substring(1)));
        expect(_hopPort(text), isNull, reason: text);
      }
      expect(
        (parseSshPort('ssh'), parseSshPort('http'), parseSshPort('https')),
        (22, 80, 443),
      );
      for (final text in ['ssh', 'http', 'https']) {
        expect(_hopPort(text), isNull, reason: text);
      }
    });
  });
}
