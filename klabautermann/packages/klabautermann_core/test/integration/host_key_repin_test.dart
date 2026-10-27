// The engine's host-key pins against the sshd fixture (03 §4.6, §11.3;
// D61): a pin outlives the engine in host_keys.json, a host that gets new
// keys stays blocked after a restart, and the user's next Connect reviews
// the changed key, whose re-pin the next engine keeps. run.sh starts the
// fixture and runs this after or before the engine suite, one file at a
// time; without it the test skips. The sampled host keeps its new keys,
// and every suite reads the keys it expects when it starts. The server
// editor's connection test asks about the same keys and pins none.
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// The fingerprints `host_keys.json` in [support] pins.
Future<List<String>> _pinned(Directory support) async => [
  for (final json
      in jsonDecode(await File('${support.path}/host_keys.json').readAsString())
          as List)
    (json as Map)['fingerprintSha256'] as String,
];

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the host-key re-pin suite', () {}, skip: fixtureSkipReason);
    return;
  }

  test('the editor\'s connection test asks for the host key, pins nothing '
      'and reports a refused sign-in (FL-03, M5 M09b)', () async {
    final support = await fixture.supportDirectory();
    addTearDown(() => support.delete(recursive: true));
    final engine = await FixtureEngine.start(
      fixture,
      'connection test',
      support: support,
      access: SupportDirectoryAccess.exclusive,
    );
    final keys = (await fixture.hostKeys())[fixture.direct]!;
    var tests = 0;

    /// Tests [user] with the fixture's key file, trusting the host key
    /// when [trust] says so.
    Future<ServerConnectionTested> tryConnection(
      String user, {
      required bool trust,
    }) async {
      final requestId = 'connection-test-${tests++}';
      engine.send(
        TestServerConnection(
          requestId: requestId,
          draft: ServerDraft(
            id: '0b0c2f4e-5f1d-4d6a-9a43-3c1f00000001',
            label: 'direct',
            host: fixture.direct.host,
            port: fixture.direct.port,
            username: user,
            auth: ServerDraftAuth.privateKey,
            identityFilePath: fixture.identityFile,
          ),
          credential: const ServerCredentialEntry(referenceKeyFile: true),
        ),
      );
      final prompt = await engine.until<Prompt>();
      final request = prompt.request as HostKeyPromptRequest;
      expect(keys, contains(request.fingerprintSha256));
      expect(request.pinnedFingerprintSha256, isNull);
      engine.send(AnswerPrompt(prompt.promptId, PromptTrustAnswer(trust)));

      // An account the key cannot sign in as gets sshd's keyboard-
      // interactive password question next, which the test declines.
      while (true) {
        final event = await engine.until<EngineEvent>(
          (event) =>
              event is Prompt ||
              event is ServerConnectionTested && event.requestId == requestId,
        );
        if (event is ServerConnectionTested) return event;
        final question = event as Prompt;
        expect(question.request, isA<KeyboardInteractivePromptRequest>());
        engine.send(
          AnswerPrompt(question.promptId, const PromptCancelAnswer()),
        );
      }
    }

    final passed = await tryConnection(fixture.user, trust: true);
    expect(passed.ok, isTrue, reason: passed.log);
    expect(passed.summary, contains('${fixture.user}@'));

    // Trusted for that attempt only: the next test asks again.
    final pins = File('${support.path}/host_keys.json');
    expect(await pins.exists() ? await _pinned(support) : const [], isEmpty);
    final declined = await tryConnection(fixture.user, trust: false);
    expect(declined.ok, isFalse);

    final refused = await tryConnection('no-such-user', trust: true);
    expect(refused.ok, isFalse);
    expect(refused.log, isNotEmpty);
    expect(await pins.exists() ? await _pinned(support) : const [], isEmpty);
    await engine.stop('connection test');
  });

  test('a regenerated host key blocks after a restart until the user\'s '
      'Connect re-pins it, and the next engine keeps the new pin', () async {
    final support = await fixture.supportDirectory();
    addTearDown(() => support.delete(recursive: true));
    Future<FixtureEngine> start(String name) => FixtureEngine.start(
      fixture,
      name,
      support: support,
      access: SupportDirectoryAccess.exclusive,
    );

    final before = await fixture.hostKeys();
    final first = await start('re-pin first run');
    expect(await first.connect(directServer, before), [fixture.direct]);
    final pinned = await _pinned(support);
    expect(pinned, hasLength(1));
    expect(before[fixture.direct], contains(pinned.single));
    await first.stop('re-pin first run');

    first.note('! new host keys for sshd');
    await fixture.regenerateHostKeys(FixtureService.sshd);
    final after = await fixture.hostKeys();
    expect(
      after[fixture.direct]!.intersection(before[fixture.direct]!),
      isEmpty,
    );

    // The restarted engine reads the old pin: the new key blocks, unasked.
    final second = await start('re-pin second run');
    second.send(const Connect(directServer));
    await second.until<LinkState>(
      (event) =>
          event.serverId == directServer &&
          event.status == const LinkBlocked(LinkBlockedReason.hostKeyChanged),
    );

    // The user's next Connect reviews the changed key against the pin.
    second.send(const Connect(directServer));
    final prompt = await second.until<Prompt>();
    expect(
      (prompt.host, prompt.port),
      (fixture.direct.host, fixture.direct.port),
    );
    final request = prompt.request as HostKeyPromptRequest;
    expect(after[fixture.direct], contains(request.fingerprintSha256));
    expect(request.pinnedFingerprintSha256, pinned.single);
    expect(request.pinnedKeyType, isNotNull);
    second.send(AnswerPrompt(prompt.promptId, const PromptTrustAnswer(true)));
    await second.until<LinkState>(
      (event) =>
          event.serverId == directServer && event.status == const LinkReady(),
    );
    expect(await _pinned(support), [request.fingerprintSha256]);
    await second.stop('re-pin second run');

    // The next engine connects on the new pin without asking.
    final third = await start('re-pin third run');
    expect(await third.connect(directServer, after), isEmpty);
  });
}
