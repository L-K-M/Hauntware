import 'dart:io';

import 'package:klabautermann_core/src/links/credential_source.dart';
import 'package:seance_core/seance_core.dart'
    show
        AuthMethod,
        CredentialResolver,
        IdentityAuditLog,
        IdentityReadEvent,
        ServerConfig;
import 'package:test/test.dart';

const _pem =
    '-----BEGIN OPENSSH'
    ' PRIVATE KEY-----\nnot a real key\n';

ServerConfig _config({
  AuthMethod authMethod = AuthMethod.privateKey,
  String? identityFilePath = '~/.ssh/id_test',
  String? secretRef,
}) => ServerConfig(
  id: 'ssh-config:web',
  label: 'web',
  host: '192.0.2.10',
  port: 22,
  username: 'me',
  authMethod: authMethod,
  identityFilePath: identityFilePath,
  secretRef: secretRef,
  createdAt: 0,
  updatedAt: 0,
);

void main() {
  late Directory temp;
  late String home;
  late IdentityAuditLog audit;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('klab-credentials-');
    home = '${temp.path}/home';
    await Directory('$home/.ssh').create(recursive: true);
    audit = identityAuditLogIn('${temp.path}/support');
  });

  tearDown(() async {
    // Undo the access test's mode so the directory can be removed.
    final ssh = Directory('$home/.ssh');
    if (!Platform.isWindows && await ssh.exists()) {
      await Process.run('chmod', ['-R', 'u+rwX', ssh.path]);
    }
    await temp.delete(recursive: true);
  });

  EngineCredentialSource source({Map<String, String> extra = const {}}) =>
      EngineCredentialSource(
        audit,
        environment: {'HOME': home, ...extra},
        isMacOS: false,
      );

  Future<IdentityFileUnavailable> unavailable(
    EngineCredentialSource source, [
    ServerConfig? config,
  ]) async {
    try {
      await source.identityFile(config ?? _config(), null);
    } on IdentityFileUnavailable catch (error) {
      return error;
    }
    fail('the read succeeded');
  }

  test('agent auth resolves without reading a file or a secret', () async {
    final credentials = await CredentialResolver(
      source(),
    ).resolve(_config(authMethod: AuthMethod.agent, identityFilePath: null));

    expect(credentials.method, AuthMethod.agent);
    expect(await audit.readAll(), isEmpty);
  });

  test('reads a plain key from the expanded path and audits it', () async {
    await File('$home/.ssh/id_test').writeAsString(_pem);

    final credentials = await CredentialResolver(
      source(),
    ).resolve(_config(secretRef: 'passphrase-ref'));

    expect(credentials.method, AuthMethod.privateKey);
    expect(credentials.privateKeyPem, _pem);
    // No vault, so no stored passphrase beside the key file.
    expect(credentials.keyPassphrase, isNull);
    expect(await source().storedSecret('passphrase-ref'), isNull);
    expect(
      [for (final event in await audit.readAll()) _summary(event)],
      ['ssh-config:web web $home/.ssh/id_test ok'],
    );
  });

  test(
    'a missing key fails as not found, and the attempt is audited',
    () async {
      final error = await unavailable(source());

      expect(error.failure, IdentityFileFailure.notFound);
      expect(error.path, '$home/.ssh/id_test');
      final [event] = await audit.readAll();
      expect(_summary(event), 'ssh-config:web web $home/.ssh/id_test failed');
      expect(event.error, contains('id_test'));
    },
  );

  for (final (name, write) in <(String, Future<void> Function(String))>[
    ('a directory', (path) => Directory(path).create()),
    ('bytes that are not UTF-8', (path) => File(path).writeAsBytes([0xff])),
    (
      'a file over 1 MiB',
      (path) => File(path).writeAsBytes(List.filled((1 << 20) + 1, 0x41)),
    ),
  ]) {
    test('$name is unreadable', () async {
      await write('$home/.ssh/id_test');

      expect(
        (await unavailable(source())).failure,
        IdentityFileFailure.unreadable,
      );
    });
  }

  test(
    'a FIFO is unreadable without waiting for a writer',
    () async {
      final key = '$home/.ssh/id_test';
      final made = await Process.run('mkfifo', [key]);
      expect(made.exitCode, 0, reason: '${made.stderr}');

      expect(
        (await unavailable(source())).failure,
        IdentityFileFailure.unreadable,
      );
    },
    testOn: '!windows',
    timeout: const Timeout(Duration(seconds: 5)),
  );

  test(
    'a character device is unreadable, since a tty would wait for input',
    () async {
      // /dev/null answers a read at once, so the test cannot hang; a tty
      // at the same place would block until someone typed.
      await Link('$home/.ssh/id_test').create('/dev/null');

      expect(
        (await unavailable(source())).failure,
        IdentityFileFailure.unreadable,
      );
    },
    testOn: '!windows',
  );

  test('a symlink to a key is read through the link', () async {
    await File('$home/.ssh/id_real').writeAsString(_pem);
    await Link('$home/.ssh/id_test').create('$home/.ssh/id_real');

    expect(await source().identityFile(_config(), null), _pem);
  }, testOn: '!windows');

  test('a file of exactly 1 MiB is read', () async {
    await File('$home/.ssh/id_test').writeAsBytes(List.filled(1 << 20, 0x41));

    expect(await source().identityFile(_config(), null), hasLength(1 << 20));
  });

  test('a key the process may not read fails as access denied, inside a '
      'Flatpak too', () async {
    final key = File('$home/.ssh/id_test');
    await key.writeAsString(_pem);
    await Process.run('chmod', ['000', key.path]);
    try {
      await key.readAsString();
      markTestSkipped('this user reads files whatever their mode (root)');
      return;
    } on FileSystemException {
      // Denied, as the test needs.
    }

    for (final extra in [
      const <String, String>{},
      // The sandbox hides what it does not grant; a refusal is the file's.
      const {'FLATPAK_ID': 'ch.lkmc.klabautermann'},
    ]) {
      expect(
        (await unavailable(source(extra: extra))).failure,
        IdentityFileFailure.accessDenied,
      );
    }
  }, testOn: '!windows');

  test('inside a Flatpak a missing key is a sandbox denial', () async {
    final flatpak = source(extra: {'FLATPAK_ID': 'ch.lkmc.klabautermann'});
    expect(
      (await unavailable(flatpak)).failure,
      IdentityFileFailure.sandboxDenied,
    );

    // A file the sandbox shows but cannot use stays unreadable.
    await Directory('$home/.ssh/id_test').create();
    expect(
      (await unavailable(flatpak)).failure,
      IdentityFileFailure.unreadable,
    );
  });

  test('on macOS ~ is the real home, not a sandbox container', () async {
    final error = await unavailable(
      EngineCredentialSource(
        audit,
        environment: {
          'HOME': '${temp.path}/Users/me/Library/Containers/app/Data',
        },
        isMacOS: true,
      ),
    );

    expect(error.path, '${temp.path}/Users/me/.ssh/id_test');
  });

  test('a failing audit log does not fail the read', () async {
    await File('$home/.ssh/id_test').writeAsString(_pem);
    // The log's directory is a file, so every record throws.
    await File('${temp.path}/blocked').writeAsString('');
    final blocked = identityAuditLogIn('${temp.path}/blocked');

    final pem = await EngineCredentialSource(
      blocked,
      environment: {'HOME': home},
      isMacOS: false,
    ).identityFile(_config(), null);
    expect(pem, _pem);
  });

  test(
    'the audit log stays owner-only through its rotation',
    () async {
      final log = File('${temp.path}/support/$identityAuditLogFileName');
      final event = IdentityReadEvent(
        at: '2026-10-14T00:00:00.000Z',
        serverId: 'ssh-config:web',
        serverLabel: 'web',
        path: '/k',
        viaBookmark: false,
        ok: true,
      );
      // Past twice the 500 kept entries, so the last record rotates.
      for (var i = 0; i < 1001; i++) {
        await audit.record(event);
      }

      expect(await audit.readAll(), hasLength(500));
      expect((await log.stat()).mode & 0x3f, 0);
      expect(
        temp
            .listSync(recursive: true)
            .where((entity) => entity.path.contains('.tmp-')),
        isEmpty,
      );
    },
    // A thousand appends and a rotation rewrite: a loaded CI disk has
    // taken longer than the default 30 seconds.
    timeout: const Timeout(Duration(minutes: 2)),
    testOn: 'linux || mac-os',
  );
}

String _summary(IdentityReadEvent event) =>
    '${event.serverId} ${event.serverLabel} ${event.path} '
    '${event.ok ? 'ok' : 'failed'}';
