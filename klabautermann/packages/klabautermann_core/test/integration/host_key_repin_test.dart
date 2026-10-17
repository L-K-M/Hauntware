// The engine's host-key pins against the sshd fixture (03 §4.6, §11.3;
// D61): a pin outlives the engine in host_keys.json, a host that gets new
// keys stays blocked after a restart, and the user's next Connect reviews
// the changed key, whose re-pin the next engine keeps. run.sh starts the
// fixture and runs this after or before the engine suite, one file at a
// time; without it the test skips. The sampled host keeps its new keys,
// and every suite reads the keys it expects when it starts.
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
