// `SshLink` reports the server's identification line (RFC 4253 §4.2) in
// what it has seen of the peer, so an app can read the server software,
// such as a Dropbear release with known gaps.
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import 'support/ssh_channel_peer.dart';

void main() {
  test(
    'a ready link carries the identification line the server sent',
    () async {
      final link = await openTestLink(
        closeTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(link.link.close);

      expect(link.link.seen.serverIdentification, 'SSH-2.0-SeanceTestPeer');
      expect(
        (link.link.state as SshLinkReady).seen.serverIdentification,
        'SSH-2.0-SeanceTestPeer',
      );
    },
  );

  test('what was seen compares by every field', () {
    const banner = 'SSH-2.0-dropbear_2024.86';
    expect(
      const SshLinkSeen(serverIdentification: banner),
      const SshLinkSeen(serverIdentification: banner),
    );
    expect(
      const SshLinkSeen(serverIdentification: banner),
      isNot(const SshLinkSeen()),
    );
  });
}
