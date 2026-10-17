// The engine's channel shares (03 §5.2, M9): 2 short actions and 2
// followers a server, followers only while the link allows 4 sessions or
// more and only one under any learned limit, short actions waiting for a
// slot, and one quota per server that tells its consumers of a freed
// slot.
import 'dart:async';

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
      'and a short action take the rest; low-session mode keeps it at one '
      'above 4 (M9)', () {
    final quota = ChannelQuota();
    expect(quota.take(ChannelShare.follower, learnedSessionLimit: 4), isTrue);
    expect(quota.take(ChannelShare.follower, learnedSessionLimit: 4), isFalse);
    expect(quota.take(ChannelShare.follower, learnedSessionLimit: 7), isFalse);
    expect(quota.held(ChannelShare.follower), 1);
    expect(quota.take(ChannelShare.follower), isTrue);
    expect(quota.held(ChannelShare.follower), 2);
  });

  test('a short action waits for a slot, which a give hands on', () async {
    final quota = ChannelQuota();
    await quota.acquire(ChannelShare.shortAction);
    await quota.acquire(ChannelShare.shortAction);

    var third = false;
    unawaited(
      quota.acquire(ChannelShare.shortAction).then((_) => third = true),
    );
    await pumpEventQueue();
    expect(third, isFalse);

    quota.give(ChannelShare.shortAction);
    await pumpEventQueue();
    expect(third, isTrue);
    expect(quota.held(ChannelShare.shortAction), 2);
  });

  test('one quota per server, whose freed slots its listeners hear of '
      'after the give, once for slots freed together', () async {
    final quotas = ChannelQuotas();
    final heard = <String>[];
    quotas.onFreed(heard.add);
    final quota = quotas.of('srv-1');
    expect(quotas.of('srv-1'), same(quota));
    expect(quotas.of('srv-2'), isNot(same(quota)));

    quota
      ..take(ChannelShare.follower)
      ..take(ChannelShare.shortAction)
      ..give(ChannelShare.follower)
      ..give(ChannelShare.shortAction);
    expect(heard, isEmpty);
    await pumpEventQueue();
    expect(heard, ['srv-1']);

    quotas.retain({'srv-2'});
    expect(quotas.of('srv-1'), isNot(same(quota)));
  });
}
