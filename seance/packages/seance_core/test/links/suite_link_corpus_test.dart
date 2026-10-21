// The link contract corpus (docs/design/suite-links.md section 9) against
// both parsers, and the builders against their parsers.
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _serverId = '123e4567-e89b-42d3-a456-426614174000';

/// The keys a sender might use to smuggle a command (X8).
const _commandKeys = ['cmd', 'command', 'exec', 'run', 'script', 'snippet'];

void main() {
  final rows = _loadCorpus();

  group('corpus', () {
    for (final row in rows) {
      test('${row.verdict} ${row.form}: ${row.label}', () {
        final uri = Uri.parse(row.uri);
        _expectSeance(row, parseSeanceConnect(uri));
        _expectPoltergeist(row, parsePoltergeistDeepLink(uri));
      });
    }

    test('refuses every command key on every form', () {
      for (final key in _commandKeys) {
        for (final form in ['seance:id', 'seance:identity', 'poltergeist:id']) {
          expect(
            rows.where(
              (row) =>
                  row.form == form &&
                  row.verdict == 'refuse' &&
                  _keys(row).contains(key),
            ),
            isNotEmpty,
            reason: '$key on $form',
          );
        }
      }
    });

    test('accepts at least one link of every form', () {
      expect(
        {
          for (final row in rows)
            if (row.verdict == 'accept') row.form,
        },
        {
          'seance:id',
          'seance:identity',
          'poltergeist:id',
          'poltergeist:identity',
        },
      );
    });
  });

  group('buildSeanceConnect', () {
    test('round trips every accepted id-form row', () {
      for (final row in rows.where((row) => row.form == 'seance:id')) {
        if (row.verdict != 'accept') continue;
        final serverId = row.expect['serverId'] as String;
        final cwd = row.expect['cwd'] as String?;
        final parsed = parseSeanceConnect(
          buildSeanceConnect(serverId: serverId.toUpperCase(), cwd: cwd),
        ).request;
        expect(
          parsed,
          isA<SeanceServerConnect>()
              .having((link) => link.serverId, 'serverId', serverId)
              .having((link) => link.cwd, 'cwd', cwd),
          reason: row.label,
        );
      }
    });

    test('throws for every folder the parser refuses', () {
      for (final row in rows.where((row) => row.kind == 'invalidPath')) {
        if (row.form != 'seance:id') continue;
        final cwd = Uri.parse(row.uri).queryParameters['cwd']!;
        expect(
          () => buildSeanceConnect(serverId: _serverId, cwd: cwd),
          throwsArgumentError,
          reason: row.label,
        );
      }
    });

    test('throws for an id that is not a UUID', () {
      for (final id in ['', 'srv-1', 'local-shell', '$_serverId ']) {
        expect(() => buildSeanceConnect(serverId: id), throwsArgumentError);
      }
    });

    test('round trips generated folders', () {
      // Fixed seed: a failure names a folder that reproduces.
      final random = Random(5);
      const alphabet = [
        'a',
        'Z',
        '0',
        ' ',
        "'",
        '"',
        r'$',
        ';',
        '+',
        '%',
        '&',
        '=',
        '#',
        '?',
        '*',
        '~',
        '-',
        '.',
        'é',
        '日',
        '\u{1F600}',
        '\u202e',
        '\u200b',
      ];
      for (var i = 0; i < 500; i++) {
        final folder = [
          for (var c = random.nextInt(4); c >= 0; c--)
            _component(random, alphabet),
        ].map((component) => '/$component').join();
        final parsed = parseSeanceConnect(
          buildSeanceConnect(serverId: _serverId, cwd: folder),
        ).request;
        expect(
          parsed,
          isA<SeanceServerConnect>().having((link) => link.cwd, 'cwd', folder),
          reason: folder,
        );
      }
    });
  });

  group('buildPoltergeistBrowse', () {
    test('round trips every accepted id-form row', () {
      for (final row in rows.where((row) => row.form == 'poltergeist:id')) {
        if (row.verdict != 'accept') continue;
        final serverId = row.expect['serverId'] as String;
        final path = row.expect['path'] as String;
        final parsed = parsePoltergeistDeepLink(
          buildPoltergeistBrowse(serverId: serverId, path: path),
        ).request;
        expect(
          parsed,
          isA<ServerDeepLink>()
              .having((link) => link.serverId, 'serverId', serverId)
              .having((link) => link.remotePath, 'remotePath', path),
        );
      }
    });

    test('throws for a path or id the parser refuses', () {
      for (final path in ['srv', '/srv/', '/srv//x', '/srv/../etc', '']) {
        expect(
          () => buildPoltergeistBrowse(serverId: _serverId, path: path),
          throwsArgumentError,
          reason: path,
        );
      }
      expect(
        () => buildPoltergeistBrowse(serverId: 'srv-1', path: '/'),
        throwsArgumentError,
      );
    });
  });

  group('outbound Séance links', () {
    test('a server id that is not a UUID throws', () {
      expect(
        () => seanceConnectUriForBookmark(
          _bookmark(const BookmarkServerRef(serverConfigId: 'srv-1')),
        ),
        throwsArgumentError,
      );
      expect(
        () => seanceConnectUriForServer(_server('srv-1')),
        throwsArgumentError,
      );
    });

    test('an identity the parser would refuse throws', () {
      for (final (host, port, username) in [
        ('', 22, 'ops'),
        ('files.example/x', 22, 'ops'),
        ('files.example', 22, 'ops\u202e'),
      ]) {
        expect(
          () => seanceConnectUriForBookmark(
            _bookmark(_identity(host: host, port: port, username: username)),
          ),
          throwsArgumentError,
          reason: '$host $port $username',
        );
      }
    });

    test('an identity link parses back to the identity form', () {
      final uri = seanceConnectUriForBookmark(
        _bookmark(
          _identity(host: 'fe80::1%en0', port: 2200, username: 'ops & build'),
        ),
      );
      expect(
        parseSeanceConnect(uri).request,
        isA<SeanceIdentityConnect>()
            .having((link) => link.host, 'host', 'fe80::1%en0')
            .having((link) => link.port, 'port', 2200)
            .having((link) => link.username, 'username', 'ops & build'),
      );
    });

    test('a server link parses back to the id form, without a folder', () {
      expect(
        parseSeanceConnect(
          seanceConnectUriForServer(_server(_serverId)),
        ).request,
        isA<SeanceServerConnect>()
            .having((link) => link.serverId, 'serverId', _serverId)
            .having((link) => link.cwd, 'cwd', isNull),
      );
    });
  });

  test('identity endpoint keys ignore host case except an IPv6 zone', () {
    const link = SeanceIdentityConnect(
      host: 'FE80::1%En0',
      port: 22,
      username: 'Ops',
    );
    expect(link.endpointKey, (host: 'fe80::1%En0', port: 22, username: 'Ops'));
  });
}

void _expectSeance(_Row row, SeanceConnectParse parse) {
  if (!row.form.startsWith('seance:')) {
    expect(parse.request, isNull);
    expect(parse.failure?.kind, DeepLinkFailureKind.unsupportedLink);
    return;
  }

  if (row.verdict == 'refuse') {
    expect(parse.request, isNull);
    expect(parse.failure?.kind.name, row.kind);
    return;
  }

  expect(parse.failure, isNull);
  final expect_ = row.expect;
  switch (row.form) {
    case 'seance:id':
      expect(
        parse.request,
        isA<SeanceServerConnect>()
            .having((link) => link.serverId, 'serverId', expect_['serverId'])
            .having((link) => link.cwd, 'cwd', expect_['cwd']),
      );
    case 'seance:identity':
      expect(
        parse.request,
        isA<SeanceIdentityConnect>()
            .having((link) => link.host, 'host', expect_['host'])
            .having((link) => link.port, 'port', expect_['port'])
            .having((link) => link.username, 'username', expect_['username']),
      );
    default:
      fail('unknown form ${row.form}');
  }
}

void _expectPoltergeist(_Row row, DeepLinkParse parse) {
  if (!row.form.startsWith('poltergeist:')) {
    expect(parse.request, isNull);
    expect(parse.failure?.kind, DeepLinkFailureKind.unsupportedLink);
    return;
  }

  if (row.verdict == 'refuse') {
    expect(parse.request, isNull);
    expect(parse.failure?.kind.name, row.kind);
    return;
  }

  expect(parse.failure, isNull);
  final expect_ = row.expect;
  switch (row.form) {
    case 'poltergeist:id':
      expect(
        parse.request,
        isA<ServerDeepLink>()
            .having((link) => link.serverId, 'serverId', expect_['serverId'])
            .having((link) => link.remotePath, 'remotePath', expect_['path']),
      );
    case 'poltergeist:identity':
      expect(
        parse.request,
        isA<HostDeepLink>()
            .having((link) => link.host, 'host', expect_['host'])
            .having((link) => link.port, 'port', expect_['port'])
            .having((link) => link.username, 'username', expect_['username'])
            .having((link) => link.remotePath, 'remotePath', expect_['path']),
      );
    default:
      fail('unknown form ${row.form}');
  }
}

/// The row's query keys, or none when its query does not decode.
Set<String> _keys(_Row row) {
  try {
    return Uri.parse(row.uri).queryParameters.keys.toSet();
  } on FormatException {
    return const {};
  }
}

String _component(Random random, List<String> alphabet) {
  while (true) {
    final component = [
      for (var i = random.nextInt(12); i >= 0; i--)
        alphabet[random.nextInt(alphabet.length)],
    ].join();
    if (component != '.' && component != '..') return component;
  }
}

final class _Row {
  _Row(Map<String, Object?> json)
    : uri = json['uri']! as String,
      form = json['form']! as String,
      verdict = json['verdict']! as String,
      kind = json['kind'] as String?,
      note = json['note'] as String?,
      expect = (json['expect'] as Map<String, Object?>?) ?? const {};

  final String uri;
  final String form;
  final String verdict;
  final String? kind;
  final String? note;
  final Map<String, Object?> expect;

  String get label => note ?? uri;
}

List<_Row> _loadCorpus() {
  final json =
      jsonDecode(
            File('test/fixtures/suite_link_corpus.json').readAsStringSync(),
          )
          as Map<String, Object?>;
  return [
    for (final row in json['rows']! as List<Object?>)
      _Row(row! as Map<String, Object?>),
  ];
}

BookmarkServerRef _identity({
  required String host,
  required int port,
  required String username,
}) => BookmarkServerRef(
  identity: EmbeddedHostIdentity(
    host: host,
    port: port,
    username: username,
    authMethod: AuthMethod.password,
  ),
);

ServerConfig _server(String id) => ServerConfig(
  id: id,
  label: 'Example',
  host: 'files.example',
  port: 22,
  username: 'ops',
  authMethod: AuthMethod.privateKey,
  createdAt: 0,
  updatedAt: 0,
);

Bookmark _bookmark(BookmarkServerRef server) => Bookmark(
  id: 'favorite-1',
  kind: BookmarkKind.remotePath,
  label: 'Example',
  server: server,
  sortKey: 'a',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);
