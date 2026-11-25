import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

void main() {
  group('sshAcceptsProxyJump', () {
    test('accepts the forms ssh parse_jump reads', () {
      for (final value in [
        'none',
        'NONE',
        'gw',
        'user@gw',
        'x@y@gw',
        '[gw]:22',
        'u@[]',
        'gw:',
        'gw:+22',
        'a ,b',
        'ssh://9gw.',
        'ssh://u;x@gw:',
        'ssh://u%41@gw:22/',
      ]) {
        expect(sshAcceptsProxyJump(value), isTrue, reason: value);
      }
    });

    test('rejects the forms ssh parse_jump refuses', () {
      for (final value in [
        '',
        'a,,b',
        'a,b,',
        '@gw',
        '[gw',
        '[gw]x',
        'gw/2222',
        'gw:0',
        'gw:65536',
        '2001:db8::1',
        'ssh://_gw',
        'ssh://gw..x',
        'ssh://[::1]',
        'ssh://;x@gw',
        'ssh://u%zz@gw',
        'ssh://gw/path',
        'ssh://gw:22/x',
        'ssh://gw:/',
        'gw,ssh://_x',
      ]) {
        expect(sshAcceptsProxyJump(value), isFalse, reason: value);
      }
    });

    test('cuts a comment before it splits the hops', () {
      expect(sshAcceptsProxyJump('gw # old'), isTrue);
      expect(sshAcceptsProxyJump('gw, # old'), isFalse);
    });
  });

  group('splitSshHost', () {
    test('splits a bracketed host, a port or a path', () {
      expect(splitSshHost('gw'), (host: 'gw', delimiter: null, rest: ''));
      expect(splitSshHost('[gw]:22'), (host: 'gw', delimiter: ':', rest: '22'));
      expect(splitSshHost('gw/path'), (
        host: 'gw',
        delimiter: '/',
        rest: 'path',
      ));
    });

    test('returns null where ssh cannot read the host', () {
      expect(splitSshHost('[gw'), isNull);
      expect(splitSshHost('[gw]x'), isNull);
    });
  });
}
