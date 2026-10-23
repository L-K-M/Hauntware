// The parser and display groups of Poltergeist's
// test/services/deep_links_test.dart and the builder cases of its
// seance_links_test.dart, copied with the code they cover
// (docs/design/suite-links.md section 9, F5d-1). F5d-2 replaces them with
// the link contract corpus.
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _serverId = '123e4567-e89b-42d3-a456-426614174000';

void main() {
  group('parsePoltergeistDeepLink', () {
    test('parses catalog links and decoded remote paths', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse(
          'poltergeist://browse?serverId=$_serverId&'
          'path=%2Fsrv%2Freports%20%26%20plans',
        ),
      );

      expect(parsed.failure, isNull);
      expect(
        parsed.request,
        isA<ServerDeepLink>()
            .having((link) => link.serverId, 'serverId', _serverId)
            .having(
              (link) => link.remotePath,
              'remotePath',
              '/srv/reports & plans',
            ),
      );
    });

    test('parses host links without assuming a port', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse(
          'poltergeist://browse?host=fe80%3A%3A1%25en0&port=2200&'
          'username=ops%20%26%20build&path=%2Fsrv%2F%23daily%25',
        ),
      );

      expect(parsed.failure, isNull);
      expect(
        parsed.request,
        isA<HostDeepLink>()
            .having((link) => link.host, 'host', 'fe80::1%en0')
            .having((link) => link.port, 'port', 2200)
            .having((link) => link.username, 'username', 'ops & build')
            .having((link) => link.remotePath, 'remotePath', '/srv/#daily%'),
      );
    });

    test('rejects missing, malformed, and out-of-range ports', () {
      for (final query in [
        'host=example.com&username=ops&path=%2F',
        'host=example.com&port=ssh&username=ops&path=%2F',
        'host=example.com&port=%2B22&username=ops&path=%2F',
        'host=example.com&port=%2022%20&username=ops&path=%2F',
        'host=example.com&port=0x16&username=ops&path=%2F',
        'host=example.com&port=${'9' * 10000}&username=ops&path=%2F',
        'host=example.com&port=0&username=ops&path=%2F',
        'host=example.com&port=65536&username=ops&path=%2F',
      ]) {
        final parsed = parsePoltergeistDeepLink(
          Uri.parse('poltergeist://browse?$query'),
        );

        expect(parsed.failure?.kind, DeepLinkFailureKind.invalidPort);
        expect(parsed.request, isNull);
      }
    });

    test('accepts leading zeros in a decimal port', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse(
          'poltergeist://browse?host=example.com&port=000022&'
          'username=ops&path=%2F',
        ),
      );

      expect((parsed.request as HostDeepLink).port, 22);
    });

    test('rejects ambiguous, secret-bearing, and duplicate parameters', () {
      for (final raw in [
        'poltergeist://browse?serverId=$_serverId&host=example.com&'
            'port=22&username=ops&path=%2F',
        'poltergeist://browse?host=example.com&port=22&username=ops&'
            'password=secret&path=%2F',
        'poltergeist://browse?host=one&host=two&port=22&username=ops&'
            'path=%2F',
      ]) {
        final parsed = parsePoltergeistDeepLink(Uri.parse(raw));

        expect(parsed.failure?.kind, DeepLinkFailureKind.invalidParameters);
        expect(parsed.request, isNull);
      }
    });

    test('rejects unsafe remote path components', () {
      for (final path in ['/srv/../secret', '/srv//secret', r'/srv/a\b']) {
        final parsed = parsePoltergeistDeepLink(
          Uri(
            scheme: poltergeistDeepLinkScheme,
            host: poltergeistBrowseRoute,
            queryParameters: {
              'host': 'example.com',
              'port': '22',
              'username': 'ops',
              'path': path,
            },
          ),
        );

        expect(parsed.failure?.kind, DeepLinkFailureKind.invalidPath);
        expect(parsed.request, isNull);
      }
    });

    test('rejects invisible controls in endpoint values', () {
      for (final control in [
        '\u0085',
        '\u200e',
        '\u202e',
        '\ufeff',
        '\u{e0001}',
      ]) {
        for (final field in ['host', 'username']) {
          final parsed = parsePoltergeistDeepLink(
            Uri(
              scheme: poltergeistDeepLinkScheme,
              host: poltergeistBrowseRoute,
              queryParameters: {
                'host': field == 'host' ? 'files${control}example' : 'files',
                'port': '22',
                'username': field == 'username' ? 'op${control}s' : 'ops',
                'path': '/',
              },
            ),
          );

          expect(
            parsed.failure?.kind,
            DeepLinkFailureKind.invalidParameters,
            reason:
                '$field accepted U+${control.runes.single.toRadixString(16)}',
          );
          expect(parsed.request, isNull);
        }
      }
    });

    test('keeps ordinary printable endpoint values', () {
      final parsed = parsePoltergeistDeepLink(
        Uri(
          scheme: poltergeistDeepLinkScheme,
          host: poltergeistBrowseRoute,
          queryParameters: const {
            'host': 'files.example',
            'port': '22',
            'username': 'ops build',
            'path': '/',
          },
        ),
      );

      expect(parsed.failure, isNull);
      expect((parsed.request as HostDeepLink).username, 'ops build');
    });

    test('requires a UUID catalog id', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse('poltergeist://browse?serverId=server-1&path=%2F'),
      );

      expect(parsed.failure?.kind, DeepLinkFailureKind.invalidParameters);
    });

    test('canonicalizes accepted catalog ids for exact lookup', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse(
          'poltergeist://browse?serverId=${_serverId.toUpperCase()}&path=%2F',
        ),
      );

      expect((parsed.request as ServerDeepLink).serverId, _serverId);
    });
  });

  group('safeDeepLinkDisplay', () {
    test('strips directional and line controls', () {
      final display = safeDeepLinkDisplay(
        'safe\u202Eevil\nname\u2066legacy\u206A',
      );

      expect(display.text, 'safeevilnamelegacy');
      expect(display.removedControls, isTrue);
    });

    test('strips default-ignorable format controls', () {
      final display = safeDeepLinkDisplay(
        'a\u00adb\u200bc\u200cd\u200de\u2060f\ufeffg',
      );

      expect(display.text, 'abcdefg');
      expect(display.removedControls, isTrue);
    });

    test('annotates internationalized and mixed-script hosts', () {
      final display = safeDeepLinkHostDisplay('paypa\u043b.example');

      expect(display.internationalized, isTrue);
      expect(display.mixedScripts, isTrue);
    });

    test('flags unknown-script and Cyrillic mixtures', () {
      final display = safeDeepLinkHostDisplay('\u0585\u0430.\u0440\u0444');

      expect(display.internationalized, isTrue);
      expect(display.mixedScripts, isTrue);
      expect(display.unrecognizedScripts, isFalse);
    });

    test('flags mixtures between unsupported scripts', () {
      final display = safeDeepLinkHostDisplay(
        '\u0561\u10d0.\u0570\u0561\u0575',
      );

      expect(display.internationalized, isTrue);
      expect(display.mixedScripts, isTrue);
    });

    test('does not flag scripts split across labels or Japanese labels', () {
      expect(
        safeDeepLinkHostDisplay(
          '\u043f\u0440\u0438\u043c\u0435\u0440.com',
        ).mixedScripts,
        isFalse,
      );
      expect(
        safeDeepLinkHostDisplay('\u4f8b\u3048.\u30c6\u30b9\u30c8').mixedScripts,
        isFalse,
      );
    });

    test('warns separately for an unrecognized writing system', () {
      final display = safeDeepLinkHostDisplay('\u0e44\u0e17\u0e22.example');

      expect(display.internationalized, isTrue);
      expect(display.mixedScripts, isFalse);
      expect(display.unrecognizedScripts, isTrue);
    });

    test('treats Unicode dot variants as label separators', () {
      final display = safeDeepLinkHostDisplay(
        '\u043f\u0440\u0438\u043c\u0435\u0440\u3002com',
      );

      expect(display.mixedScripts, isFalse);
      expect(display.unrecognizedScripts, isFalse);
    });
  });

  group('seanceConnectUriForBookmark', () {
    test('uses only the synchronized server id when one exists', () {
      final bookmark = _bookmark(
        const BookmarkServerRef(
          serverConfigId: '123e4567-e89b-42d3-a456-426614174000',
        ),
      );

      expect(
        seanceConnectUriForBookmark(bookmark).toString(),
        'seance://connect?serverId=123e4567-e89b-42d3-a456-426614174000',
      );
    });

    test('percent-encodes every embedded endpoint value', () {
      final bookmark = _bookmark(
        const BookmarkServerRef(
          identity: EmbeddedHostIdentity(
            host: 'fe80::1%en0',
            port: 2200,
            username: 'ops & build',
            authMethod: AuthMethod.password,
            secretRef: 'vault-password',
            identityFilePath: '~/.ssh/private-key',
          ),
        ),
      );

      final uri = seanceConnectUriForBookmark(bookmark);
      expect(uri.scheme, seanceDeepLinkScheme);
      expect(uri.host, seanceConnectRoute);
      expect(uri.queryParameters, {
        'host': 'fe80::1%en0',
        'port': '2200',
        'username': 'ops & build',
      });
      expect(uri.toString(), contains('host=fe80%3A%3A1%25en0'));
      expect(uri.toString(), contains('username=ops+%26+build'));
      expect(uri.toString(), isNot(contains('vault-password')));
      expect(uri.toString(), isNot(contains('private-key')));
      expect(uri.toString(), isNot(contains('secretRef')));
    });
  });
}

Bookmark _bookmark(BookmarkServerRef server) => Bookmark(
  id: 'favorite-1',
  kind: BookmarkKind.remotePath,
  label: 'Example',
  server: server,
  sortKey: 'a',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);
