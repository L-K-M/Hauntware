// The engine's channel shares (03 §5.2): 2 short actions and 2 followers
// a server, followers only while the link allows 4 sessions or more, and
// only one at 4.
import 'package:klabautermann_core/src/links/channel_quota.dart';
import 'package:test/test.dart';

void main() {
  test('each share holds 2 slots, apart from the other', () {
    final quota = ChannelQuota();
    for (final share in ChannelShare.values) {
      expect(quota.take(share), isTrue);
      expect(quota.take(share), isTrue);
      expect(quota.take(share), isFalse);
      expect(quota.held(share), 2);
    }

    quota.give(ChannelShare.shortAction);
    expect(quota.held(ChannelShare.shortAction), 1);
    expect(quota.take(ChannelShare.follower), isFalse);
    expect(quota.take(ChannelShare.shortAction), isTrue);
  });

  test('a follower waits under a learned session limit below 4; short '
      'actions do not', () {
    final quota = ChannelQuota();
    for (final limit in [0, 1, 2, 3]) {
      expect(
        quota.take(ChannelShare.follower, learnedSessionLimit: limit),
        isFalse,
        reason: 'limit $limit',
      );
    }
    expect(quota.held(ChannelShare.follower), 0);
    expect(
      quota.take(ChannelShare.shortAction, learnedSessionLimit: 2),
      isTrue,
    );

    expect(quota.take(ChannelShare.follower), isTrue);
    expect(quota.take(ChannelShare.follower), isTrue);
    expect(quota.held(ChannelShare.follower), 2);
  });

  test('at a learned limit of 4 one follower runs, since the two samplers '
      'and a short action take the rest; at 5 two do', () {
    final quota = ChannelQuota();
    expect(quota.take(ChannelShare.follower, learnedSessionLimit: 4), isTrue);
    expect(quota.take(ChannelShare.follower, learnedSessionLimit: 4), isFalse);
    expect(quota.take(ChannelShare.follower, learnedSessionLimit: 5), isTrue);
    expect(quota.take(ChannelShare.follower, learnedSessionLimit: 9), isFalse);
    expect(quota.held(ChannelShare.follower), 2);
  });
}
