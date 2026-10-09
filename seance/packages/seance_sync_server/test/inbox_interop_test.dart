@Timeout(Duration(seconds: 60))
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:seance_protocol/seance_protocol.dart';
import 'package:seance_sync_server/seance_sync_server.dart';
import 'package:seance_sync_server/src/inbox_docs.dart';
import 'package:test/test.dart';

/// The reference client the server hands out, run for real against a live
/// server: what it seals with PyNaCl must open with [InboxCrypto] and parse
/// as an [InboxProposal]. This is the check that the docs, the Python and
/// the Dart agree byte for byte. Skipped where python3 or PyNaCl is missing.
void main() {
  // A missing python3 throws rather than exiting non-zero, and must skip.
  bool pythonReady;
  try {
    pythonReady =
        Process.runSync('python3', [
          '-c',
          'import nacl.bindings',
        ], runInShell: false).exitCode ==
        0;
  } on ProcessException {
    pythonReady = false;
  }

  test('seance-propose.py deposits a proposal Séance can open', () async {
    final server = SyncServer(
      storage: InMemoryStorage(),
      settings: const ServerSettings(
        openRegistration: true,
        bindAddress: '127.0.0.1',
        port: 0,
      ),
    );
    final running = await server.start();
    addTearDown(running.close);
    final url = 'http://${running.host}:${running.port}';

    final register = await http.post(
      Uri.parse('$url/v1/register'),
      body: jsonEncode(
        RegisterRequest(
          username: 'alice',
          authVerifier: base64.encode(secureRandomBytes(32)),
          argonSalt: base64.encode(secureRandomBytes(16)),
          argonParams: const Argon2Params.fast(),
        ).toJson(),
      ),
    );
    expect(register.statusCode, 200, reason: register.body);
    final session = jsonDecode(register.body)['token'] as String;
    final auth = {'authorization': 'Bearer $session'};

    final pairing = InboxPairing(
      url: '$url/',
      appId: newInboxAppId(),
      token: newInboxToken(),
      key: newInboxKey(),
    );
    final created = await http.post(
      Uri.parse('$url/v1/apps'),
      headers: auth,
      body: jsonEncode(
        CreateInboxAppRequest(
          appId: pairing.appId,
          name: 'agent',
          token: pairing.token,
        ).toJson(),
      ),
    );
    expect(created.statusCode, 201);

    // Served, not the copy in the repo: this is what an agent downloads.
    final dir = Directory.systemTemp.createTempSync('seance-propose-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final script = File('${dir.path}/seance-propose.py');
    script.writeAsStringSync(
      (await http.get(Uri.parse('$url/v1/inbox/seance-propose.py'))).body,
    );
    expect(script.readAsStringSync(), inboxProposePy);
    const body =
        'systemctl restart queue-worker@3\n'
        'systemctl status queue-worker@3 --no-pager\n';
    File('${dir.path}/fix.sh').writeAsStringSync(body);

    final run = await Process.run(
      'python3',
      [
        script.path,
        '--host',
        'prod-db-1',
        '--title',
        'Restart stuck queue worker',
        '--reason',
        'Backlog since 09:12; worker 3 logs “lease lost”.',
        '--id',
        'fix-42',
        '--expires-in',
        '3600',
        '${dir.path}/fix.sh',
      ],
      environment: {'SEANCE_INBOX': pairing.encode()},
    );
    expect(run.exitCode, 0, reason: '${run.stdout}\n${run.stderr}');
    expect('${run.stdout}${run.stderr}', isNot(contains(pairing.token)));
    final itemId = (run.stdout as String).trim();

    final list = await http.get(Uri.parse('$url/v1/inbox'), headers: auth);
    final item = InboxItem.fromJson(
      (jsonDecode(list.body)['items'] as List).single as Map<String, dynamic>,
    );
    expect(item.itemId, itemId);
    final proposal = InboxProposal.parse(
      await InboxCrypto.open(pairing.key, pairing.appId, item.blob),
      now: DateTime.now(),
    );
    expect(proposal.id, 'fix-42');
    expect(proposal.host, 'prod-db-1');
    expect(proposal.title, 'Restart stuck queue worker');
    expect(proposal.reason, 'Backlog since 09:12; worker 3 logs “lease lost”.');
    expect(proposal.script, body);
    expect(proposal.expires - proposal.created, 3600);

    // A limit is refused before anything is sent, with a clear message.
    final tooLong = await Process.run(
      'python3',
      [
        script.path,
        '--host',
        'prod-db-1',
        '--title',
        'x' * (kInboxMaxTitleChars + 1),
        '${dir.path}/fix.sh',
      ],
      environment: {'SEANCE_INBOX': pairing.encode()},
    );
    expect(tooLong.exitCode, 2);
    expect(tooLong.stderr, contains('--title'));

    // A wrong token surfaces the server's error and a failing exit code.
    final wrong = InboxPairing(
      url: url,
      appId: pairing.appId,
      token: newInboxToken(),
      key: pairing.key,
    );
    final refused = await Process.run(
      'python3',
      [script.path, '--host', 'h', '--title', 't', '${dir.path}/fix.sh'],
      environment: {'SEANCE_INBOX': wrong.encode()},
    );
    expect(refused.exitCode, 1);
    expect(refused.stderr, contains('401'));
    expect(refused.stderr, contains('unauthorized'));
    expect('${refused.stdout}${refused.stderr}', isNot(contains(wrong.token)));
  }, skip: pythonReady ? false : 'python3 with PyNaCl is not installed');
}
