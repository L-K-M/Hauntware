// The queue both apps' link intakes run on. Its cases came from
// Poltergeist's DeepLinkCoordinator tests and Séance's SeanceLinkIntake
// tests; Poltergeist's link grammar stands in for an app's links.
import 'dart:async';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

const _serverId = '123e4567-e89b-42d3-a456-426614174000';

void main() {
  group('LinkQueue', () {
    test('coalesces an endpoint and bounds its visible queue', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);

      coordinator.add(_hostUri('one.example', path: '/first'));
      await handler.waitForReviews(1);
      coordinator
        ..add(_hostUri('one.example', path: '/latest'))
        ..add(_hostUri('two.example'))
        ..add(_hostUri('three.example'))
        ..add(_hostUri('four.example'))
        ..add(_hostUri('five.example'));

      final snapshot = handler.reviews.single.snapshot;
      expect(snapshot.current.activationCount, 2);
      expect(snapshot.current.remotePath, '/latest');
      expect(snapshot.visibleWaiting.map((link) => link.host), [
        'two.example',
        'three.example',
      ]);
      expect(snapshot.overflow.map((link) => link.host), [
        'four.example',
        'five.example',
      ]);

      handler.answer(LinkReviewDecision.connect);
      await handler.waitForOpens(1);

      expect(handler.opened.single.host, 'one.example');
      expect(handler.opened.single.remotePath, '/latest');
      expect(handler.opened.single.activationCount, 2);

      await handler.waitForReviews(2);
      handler.answer(LinkReviewDecision.discardAllRemaining);
      await coordinator.idle;
    });

    test(
      'serializes distinct endpoints and discards only by user action',
      () async {
        final handler = _Handler();
        final coordinator = _queue();
        coordinator.activate(handler);

        coordinator
          ..add(_hostUri('one.example'))
          ..add(_hostUri('two.example'))
          ..add(_hostUri('three.example'));
        await handler.waitForReviews(1);
        await pumpEventQueue(times: 20);
        expect(handler.reviews, hasLength(1));

        handler.answer(LinkReviewDecision.cancel);
        await handler.waitForReviews(2);
        expect(handler.reviews[1].snapshot.current.host, 'two.example');

        handler.answer(LinkReviewDecision.discardAllRemaining);
        await coordinator.idle;

        expect(handler.opened, isEmpty);
        expect(handler.reviews, hasLength(2));
      },
    );

    test('preserves every overflow endpoint in review order', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);

      for (final host in [
        'one.example',
        'two.example',
        'three.example',
        'four.example',
        'five.example',
      ]) {
        coordinator.add(_hostUri(host));
      }

      final reviewed = <String>[];
      for (var count = 1; count <= 5; count++) {
        await handler.waitForReviews(count);
        reviewed.add(handler.reviews[count - 1].snapshot.current.host);
        handler.answer(LinkReviewDecision.cancel);
      }
      await coordinator.idle;

      expect(reviewed, [
        'one.example',
        'two.example',
        'three.example',
        'four.example',
        'five.example',
      ]);
    });

    test('keeps an emitted overflow snapshot stable while draining', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);

      for (final host in [
        'one.example',
        'two.example',
        'three.example',
        'four.example',
        'five.example',
      ]) {
        coordinator.add(_hostUri(host));
      }
      await handler.waitForReviews(1);
      final overflow = handler.reviews.single.snapshot.overflow;

      handler.answer(LinkReviewDecision.cancel);
      await handler.waitForReviews(2);

      expect(overflow.map((link) => link.host), [
        'four.example',
        'five.example',
      ]);
      handler.answer(LinkReviewDecision.discardAllRemaining);
      await coordinator.idle;
    });

    test('keeps scoped IPv6 zone identifiers case-sensitive', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);

      coordinator
        ..add(_hostUri('fe80::1%en0'))
        ..add(_hostUri('fe80::1%EN0'));

      await handler.waitForReviews(1);
      expect(handler.reviews.single.snapshot.current.activationCount, 1);
      handler.answer(LinkReviewDecision.cancel);

      await handler.waitForReviews(2);
      expect(handler.reviews[1].snapshot.current.host, 'fe80::1%EN0');
      handler.answer(LinkReviewDecision.cancel);
      await coordinator.idle;
    });

    test('coalesces repeats already waiting in the queue', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);
      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);

      coordinator
        ..add(_hostUri('two.example', path: '/first'))
        ..add(_hostUri('two.example', path: '/latest'));

      final waiting = handler.reviews.single.snapshot.visibleWaiting.single;
      expect(waiting.remotePath, '/latest');
      expect(waiting.activationCount, 2);
      handler.answer(LinkReviewDecision.cancel);
      await handler.waitForReviews(2);
      handler.answer(LinkReviewDecision.cancel);
      await coordinator.idle;
      expect(handler.reviews, hasLength(2));
    });

    test('keeps port and username in the endpoint identity', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);
      coordinator.add(_hostUri('same.example'));
      await handler.waitForReviews(1);

      coordinator
        ..add(_hostUri('same.example', port: 2200))
        ..add(_hostUri('same.example', username: 'root'));

      final waiting = handler.reviews.single.snapshot.visibleWaiting;
      expect(waiting, hasLength(2));
      expect(waiting[0].port, 2200);
      expect(waiting[1].username, 'root');
      expect(waiting.every((link) => link.activationCount == 1), isTrue);
      handler.answer(LinkReviewDecision.discardAllRemaining);
      await coordinator.idle;
    });

    test('requeues an in-flight review when handler ownership moves', () async {
      final first = _Handler();
      final second = _Handler();
      final coordinator = _queue();
      coordinator.activate(first);
      coordinator.add(_hostUri('files.example'));
      await first.waitForReviews(1);

      coordinator.activate(second);

      await second.waitForReviews(1);
      expect(first.opened, isEmpty);
      second.answer(LinkReviewDecision.connect);
      await coordinator.idle;

      expect(second.opened.single.host, 'files.example');
    });

    test('requeues a failed review for the next handler', () async {
      final first = _Handler();
      final second = _Handler();
      final errors = <Object>[];
      final coordinator = _queue(onError: (error, _) => errors.add(error));
      coordinator.activate(first);
      coordinator.add(_hostUri('files.example'));
      await first.waitForReviews(1);

      first.failReview(StateError('handler closed'));
      await _waitFor(() => errors.isNotEmpty, 'reported review error');
      coordinator.activate(second);

      await second.waitForReviews(1);
      second.answer(LinkReviewDecision.cancel);
      await coordinator.idle;

      expect(errors, hasLength(1));
      expect(second.reviews.single.snapshot.current.host, 'files.example');
    });

    test(
      'preserves repeats added while a review failure is reported',
      () async {
        final first = _Handler();
        final second = _Handler();
        late final LinkQueue<HostDeepLink, ServerDeepLink> coordinator;
        var reported = false;
        coordinator = _queue(
          onError: (_, _) {
            reported = true;
            coordinator.add(_hostUri('files.example', path: '/during-error'));
          },
        );
        coordinator.activate(first);
        coordinator.add(_hostUri('files.example', path: '/first'));
        await first.waitForReviews(1);

        first.failReview(StateError('handler closed'));
        await _waitFor(() => reported, 'reported review error');
        coordinator.activate(second);

        await second.waitForReviews(1);
        final retried = second.reviews.single.snapshot.current;
        expect(retried.activationCount, 2);
        expect(retried.remotePath, '/during-error');
        second.answer(LinkReviewDecision.cancel);
        await coordinator.idle;
      },
    );

    test('queues a repeated endpoint while its confirmed open runs', () async {
      final handler = _Handler(hostOpen: _HostOpenBehavior.waitAfterCommit);
      final coordinator = _queue();
      coordinator.activate(handler);
      coordinator.add(_hostUri('files.example', path: '/first'));
      await handler.waitForReviews(1);
      handler.answer(LinkReviewDecision.connect);
      await handler.waitForOpens(1);

      coordinator.add(_hostUri('files.example', path: '/second'));
      handler.releaseHostOpen();

      await handler.waitForReviews(2);
      expect(handler.reviews[1].snapshot.current.remotePath, '/second');
      handler.answer(LinkReviewDecision.cancel);
      await coordinator.idle;
    });

    test('does not replay a committed open after ownership moves', () async {
      final first = _Handler(hostOpen: _HostOpenBehavior.waitAfterCommit);
      final second = _Handler();
      final coordinator = _queue();
      coordinator.activate(first);
      coordinator.add(_hostUri('files.example'));
      await first.waitForReviews(1);
      first.answer(LinkReviewDecision.connect);
      await first.waitForOpens(1);

      coordinator.activate(second);
      await pumpEventQueue(times: 20);

      final replayed = second.reviews.isNotEmpty;
      if (replayed) second.answer(LinkReviewDecision.cancel);
      await coordinator.idle;
      expect(replayed, isFalse);
    });

    test('coalesces a repeat when an uncommitted open moves', () async {
      final first = _Handler(hostOpen: _HostOpenBehavior.waitBeforeCommit);
      final second = _Handler();
      final coordinator = _queue();
      coordinator.activate(first);
      coordinator.add(_hostUri('files.example', path: '/first'));
      await first.waitForReviews(1);
      first.answer(LinkReviewDecision.connect);
      await first.waitForHostAttempts(1);

      coordinator.add(_hostUri('files.example', path: '/second'));
      coordinator.activate(second);

      await second.waitForReviews(1);
      final link = second.reviews.single.snapshot.current;
      expect(link.remotePath, '/second');
      expect(link.activationCount, 2);
      second.answer(LinkReviewDecision.cancel);
      await coordinator.idle;
      expect(second.reviews, hasLength(1));
    });

    test('moves an in-flight failure dialog to the active handler', () async {
      final first = _Handler(failure: _FailureBehavior.waitForCancellation);
      final second = _Handler();
      final coordinator = _queue();
      coordinator.activate(first);
      coordinator.add(Uri.parse('poltergeist://unknown'));
      await first.waitForFailures(1);

      coordinator.activate(second);

      await second.waitForFailures(1);
      await coordinator.idle;
      expect(first.failures, hasLength(1));
      expect(second.failures, hasLength(1));
    });

    test('moves an in-flight catalog open to the active handler', () async {
      final first = _Handler(serverOpen: _ServerOpenBehavior.waitBeforeCommit);
      final second = _Handler();
      final coordinator = _queue();
      coordinator.activate(first);
      coordinator.add(
        Uri.parse('poltergeist://browse?serverId=$_serverId&path=%2Fsrv'),
      );
      await first.waitForServerAttempts(1);

      coordinator.activate(second);

      await second.waitForServers(1);
      await coordinator.idle;
      expect(first.servers, isEmpty);
      expect(second.servers, hasLength(1));
    });

    test(
      'does not replay a committed catalog open after ownership moves',
      () async {
        final first = _Handler(serverOpen: _ServerOpenBehavior.waitAfterCommit);
        final second = _Handler();
        final coordinator = _queue();
        coordinator.activate(first);
        coordinator.add(
          Uri.parse('poltergeist://browse?serverId=$_serverId&path=%2Fsrv'),
        );
        await first.waitForServers(1);

        coordinator.activate(second);
        await coordinator.idle;

        expect(first.servers, hasLength(1));
        expect(second.serverAttempts, isEmpty);
      },
    );

    test(
      'discard all clears hosts but preserves non-interstitial links',
      () async {
        final handler = _Handler();
        final coordinator = _queue();
        coordinator.activate(handler);
        coordinator.add(_hostUri('one.example'));
        await handler.waitForReviews(1);

        coordinator
          ..add(
            Uri.parse('poltergeist://browse?serverId=$_serverId&path=%2Fsrv'),
          )
          ..add(Uri.parse('poltergeist://unknown'))
          ..add(_hostUri('two.example'));
        handler.answer(LinkReviewDecision.discardAllRemaining);
        await coordinator.idle;

        expect(handler.servers, hasLength(1));
        expect(handler.failures, hasLength(1));
        expect(handler.reviews, hasLength(1));
      },
    );

    test(
      'discard preserves endpoints arriving after the reviewed list',
      () async {
        final handler = _Handler();
        final coordinator = _queue();
        coordinator.activate(handler);
        for (final host in [
          'one.example',
          'two.example',
          'three.example',
          'four.example',
        ]) {
          coordinator.add(_hostUri(host));
        }
        await handler.waitForReviews(1);
        final reviewed = handler.reviews.single.snapshot;

        coordinator.add(_hostUri('new.example'));
        handler.answerDiscarding(reviewed);

        await handler.waitForReviews(2);
        expect(handler.reviews[1].snapshot.current.host, 'new.example');
        handler.answer(LinkReviewDecision.cancel);
        await coordinator.idle;
      },
    );

    test('caps the pending queue and counts what it drops', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);

      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);

      for (var i = 0; i < linkQueueLimit; i++) {
        coordinator.add(_hostUri('queued$i.example'));
      }
      for (var i = 0; i < 3; i++) {
        coordinator.add(_hostUri('dropped$i.example'));
      }
      // A repeat of a queued endpoint coalesces rather than dropping.
      coordinator.add(_hostUri('queued0.example', path: '/again'));

      final snapshot = handler.reviews.single.snapshot;
      expect(snapshot.remainingCount, linkQueueLimit);
      expect(snapshot.ignoredCount, 3);
      expect(
        snapshot.visibleWaiting.length + snapshot.overflow.length,
        linkQueueLimit,
      );
      expect(snapshot.visibleWaiting.first.remotePath, '/again');
      expect(snapshot.visibleWaiting.first.activationCount, 2);

      // The review that showed the count consumes it.
      handler.answer(LinkReviewDecision.cancel, shown: snapshot);
      for (var i = 0; i < linkQueueLimit; i++) {
        await handler.waitForReviews(i + 2);
        expect(handler.reviews[i + 1].snapshot.ignoredCount, 0);
        handler.answer(LinkReviewDecision.cancel);
      }
      await coordinator.idle;

      expect(handler.reviews, hasLength(linkQueueLimit + 1));
      expect(handler.reviews.map((review) => review.snapshot.current.host), [
        'one.example',
        for (var i = 0; i < linkQueueLimit; i++) 'queued$i.example',
      ]);
      expect(handler.reviews[1].snapshot.current.activationCount, 2);
      expect(handler.reviews[1].snapshot.current.remotePath, '/again');
      expect(handler.ignoredReports, isEmpty);
    });

    test('carries drops the last drawn review missed to the next', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);

      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);
      for (var i = 0; i < linkQueueLimit; i++) {
        coordinator.add(_hostUri('queued$i.example'));
      }
      final drawn = handler.reviews.single.snapshot;
      expect(drawn.ignoredCount, 0);

      coordinator
        ..add(_hostUri('dropped0.example'))
        ..add(_hostUri('dropped1.example'));
      expect(handler.reviews.single.snapshot.ignoredCount, 2);

      // The dialog decided on the snapshot it last drew, before the drops.
      handler.answer(LinkReviewDecision.cancel, shown: drawn);

      await handler.waitForReviews(2);
      expect(handler.reviews[1].snapshot.ignoredCount, 2);
      handler.answer(LinkReviewDecision.discardAllRemaining);
      await coordinator.idle;

      expect(handler.ignoredReports, isEmpty);
    });

    test('reports dropped links when no review carries the count', () async {
      final handler = _Handler();
      final coordinator = _queue();

      // With no handler bound the queue fills without draining, so every
      // link beyond the limit drops.
      for (var i = 0; i < linkQueueLimit + 2; i++) {
        coordinator.add(Uri.parse('poltergeist://unknown'));
      }
      coordinator.activate(handler);
      await coordinator.idle;

      expect(handler.reviews, isEmpty);
      expect(handler.failures, hasLength(linkQueueLimit));
      expect(handler.ignoredReports, [2]);
    });
    test('queues links until a handler binds', () async {
      final coordinator = _queue();
      coordinator.add(_hostUri('one.example'));
      // Nothing can progress without a handler, so the queue is idle.
      await coordinator.idle;

      final handler = _Handler();
      coordinator.activate(handler);
      await handler.waitForReviews(1);
      handler.answer(LinkReviewDecision.connect);
      await coordinator.idle;

      expect(handler.opened.single.host, 'one.example');
    });

    test('keeps a link whose review failed until the next link', () async {
      final errors = <Object>[];
      final handler = _Handler();
      final coordinator = _queue(onError: (error, _) => errors.add(error));
      coordinator.activate(handler);

      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);
      handler.failReview(StateError('no window'));
      // Paused with the link at the head: idle, nothing lost.
      await coordinator.idle;
      expect(errors, hasLength(1));
      expect(handler.reviews, hasLength(1));

      coordinator.add(_hostUri('two.example'));
      await handler.waitForReviews(2);
      expect(handler.reviews[1].snapshot.current.host, 'one.example');
      handler.answer(LinkReviewDecision.connect);
      await handler.waitForReviews(3);
      expect(handler.reviews[2].snapshot.current.host, 'two.example');
      handler.answer(LinkReviewDecision.connect);
      await coordinator.idle;

      expect(handler.opened.map((link) => link.host), [
        'one.example',
        'two.example',
      ]);
    });

    test('keeps a link whose open did not commit until rebound', () async {
      final handler = _Handler(hostOpen: _HostOpenBehavior.notCommitted);
      final coordinator = _queue();
      coordinator.activate(handler);

      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);
      handler.answer(LinkReviewDecision.connect);
      await coordinator.idle;
      expect(handler.hostAttempts, hasLength(1));

      coordinator.activate(handler);
      await handler.waitForReviews(2);
      expect(handler.reviews[1].snapshot.current.host, 'one.example');
      handler.answer(LinkReviewDecision.cancel);
      await coordinator.idle;
    });

    test('deactivating cancels the review and keeps its link', () async {
      final first = _Handler();
      final coordinator = _queue();
      coordinator.activate(first);
      coordinator.add(_hostUri('one.example', path: '/first'));
      await first.waitForReviews(1);
      final review = first.reviews.single;

      coordinator.deactivate(first);
      await coordinator.idle;
      expect(review.isCancelled, isTrue);
      expect(first.opened, isEmpty);

      coordinator.add(_hostUri('one.example', path: '/again'));
      final second = _Handler();
      coordinator.activate(second);
      await second.waitForReviews(1);
      final link = second.reviews.single.snapshot.current;
      expect(link.remotePath, '/again');
      expect(link.activationCount, 2);
      second.answer(LinkReviewDecision.connect);
      await coordinator.idle;
      expect(second.opened.single.host, 'one.example');
    });

    test('a stale deactivation leaves the active handler bound', () async {
      final first = _Handler();
      final second = _Handler();
      final coordinator = _queue()
        ..activate(first)
        ..activate(second)
        ..deactivate(first);

      coordinator.add(_hostUri('one.example'));
      await second.waitForReviews(1);
      second.answer(LinkReviewDecision.cancel);
      await coordinator.idle;
      expect(first.reviews, isEmpty);
    });

    test('publishes each change to an open review', () async {
      final handler = _Handler();
      final coordinator = _queue();
      coordinator.activate(handler);
      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);
      final published = <LinkReviewSnapshot<HostDeepLink>>[];
      final subscription = handler.reviews.single.snapshots.listen(
        published.add,
      );

      coordinator
        ..add(_hostUri('two.example'))
        ..add(_hostUri('one.example', path: '/again'));
      await pumpEventQueue();

      expect(published, hasLength(2));
      expect(published.last.remainingCount, 1);
      expect(published.last.current.remotePath, '/again');
      expect(published.last, same(handler.reviews.single.snapshot));
      handler.answer(LinkReviewDecision.discardAllRemaining);
      await coordinator.idle;
      await subscription.cancel();
    });
  });
}

LinkQueue<HostDeepLink, ServerDeepLink> _queue({LinkErrorSink? onError}) =>
    LinkQueue(
      classify: (uri) {
        final parsed = parsePoltergeistDeepLink(uri);
        return switch (parsed.request) {
          final HostDeepLink host => ReviewedLinkEntry(host),
          final ServerDeepLink server => DirectLinkEntry(server),
          null => FailedLinkEntry(parsed.failure!),
        };
      },
      keyOf: (link) => link.endpointKey,
      coalesce: (queued, incoming) => queued.coalesce(incoming),
      onError: onError ?? (error, stackTrace) => throw error,
    );

Uri _hostUri(
  String host, {
  int port = 22,
  String username = 'ops',
  String path = '/',
}) => Uri(
  scheme: poltergeistDeepLinkScheme,
  host: poltergeistBrowseRoute,
  queryParameters: {
    'host': host,
    'port': '$port',
    'username': username,
    'path': path,
  },
);

enum _FailureBehavior { immediate, waitForCancellation }

enum _HostOpenBehavior {
  immediate,
  waitBeforeCommit,
  waitAfterCommit,
  notCommitted,
}

enum _ServerOpenBehavior { immediate, waitBeforeCommit, waitAfterCommit }

final class _Handler implements LinkQueueHandler<HostDeepLink, ServerDeepLink> {
  _Handler({
    this.failure = _FailureBehavior.immediate,
    this.hostOpen = _HostOpenBehavior.immediate,
    this.serverOpen = _ServerOpenBehavior.immediate,
  });

  final _FailureBehavior failure;
  final _HostOpenBehavior hostOpen;
  final _ServerOpenBehavior serverOpen;
  final reviews = <LinkReview<HostDeepLink>>[];
  final hostAttempts = <HostDeepLink>[];
  final opened = <HostDeepLink>[];
  final serverAttempts = <ServerDeepLink>[];
  final servers = <ServerDeepLink>[];
  final failures = <DeepLinkFailure>[];
  final ignoredReports = <int>[];
  final _answers = StreamController<LinkReviewDecision>.broadcast();
  final _hostOpenRelease = Completer<void>();

  @override
  Future<LinkReviewDecision> review(LinkReview<HostDeepLink> review) async {
    reviews.add(review);
    final decision = Completer<LinkReviewDecision>();
    final subscription = _answers.stream.listen(
      decision.complete,
      onError: decision.completeError,
      cancelOnError: true,
    );
    try {
      return await Future.any([
        decision.future,
        review.cancelled.then((_) => LinkReviewDecision.cancel),
      ]);
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<LinkOpenResult> open(
    HostDeepLink link,
    LinkOperation operation,
  ) async {
    hostAttempts.add(link);
    if (hostOpen == _HostOpenBehavior.notCommitted) {
      return LinkOpenResult.notCommitted;
    }
    if (hostOpen == _HostOpenBehavior.waitBeforeCommit) {
      await operation.cancelled;
    }
    if (operation.isCancelled) return LinkOpenResult.notCommitted;

    opened.add(link);
    if (hostOpen == _HostOpenBehavior.waitAfterCommit) {
      await Future.any([_hostOpenRelease.future, operation.cancelled]);
    }
    return LinkOpenResult.committed;
  }

  @override
  Future<LinkOpenResult> openDirect(
    ServerDeepLink link,
    LinkOperation operation,
  ) async {
    serverAttempts.add(link);
    if (serverOpen == _ServerOpenBehavior.waitBeforeCommit) {
      await operation.cancelled;
    }
    if (operation.isCancelled) return LinkOpenResult.notCommitted;

    servers.add(link);
    if (serverOpen == _ServerOpenBehavior.waitAfterCommit) {
      await operation.cancelled;
    }

    return LinkOpenResult.committed;
  }

  @override
  Future<void> showFailure(
    DeepLinkFailure failure,
    LinkOperation operation,
  ) async {
    if (operation.isCancelled) return;
    failures.add(failure);
    if (this.failure == _FailureBehavior.waitForCancellation) {
      await operation.cancelled;
    }
  }

  @override
  Future<void> showIgnoredLinks(int count, LinkOperation operation) async {
    if (operation.isCancelled) return;
    ignoredReports.add(count);
  }

  /// Answers the open review on the snapshot the decision covered, which
  /// is what it shows now unless a test passes an older one.
  void answer(
    LinkReviewDecision decision, {
    LinkReviewSnapshot<HostDeepLink>? shown,
  }) {
    if (reviews.isEmpty) {
      throw StateError('answer() called before a review was presented');
    }
    reviews.last.markShown(shown ?? reviews.last.snapshot);
    _answers.add(decision);
  }

  void answerDiscarding(LinkReviewSnapshot<HostDeepLink> snapshot) {
    answer(LinkReviewDecision.discardAllRemaining, shown: snapshot);
  }

  void failReview(Object error) => _answers.addError(error, StackTrace.empty);

  void releaseHostOpen() {
    if (!_hostOpenRelease.isCompleted) _hostOpenRelease.complete();
  }

  Future<void> waitForReviews(int count) =>
      _waitFor(() => reviews.length >= count, 'review count $count');

  Future<void> waitForOpens(int count) =>
      _waitFor(() => opened.length >= count, 'open count $count');

  Future<void> waitForHostAttempts(int count) =>
      _waitFor(() => hostAttempts.length >= count, 'host attempt count $count');

  Future<void> waitForServers(int count) =>
      _waitFor(() => servers.length >= count, 'server count $count');

  Future<void> waitForServerAttempts(int count) => _waitFor(
    () => serverAttempts.length >= count,
    'server attempt count $count',
  );

  Future<void> waitForFailures(int count) =>
      _waitFor(() => failures.length >= count, 'failure count $count');
}

Future<void> _waitFor(bool Function() done, String description) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (done()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for $description');
}
