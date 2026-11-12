import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/deep_links.dart';

const _serverId = '123e4567-e89b-42d3-a456-426614174000';

void main() {
  // The parser and display helpers live in seance_core, whose
  // suite_links_test.dart owns their cases. This proves the app's
  // re-export still resolves to them.
  test('the deep_links re-export resolves to the shared parser', () {
    final parsed = parsePoltergeistDeepLink(
      Uri.parse('poltergeist://browse?serverId=$_serverId&path=%2Fsrv'),
    );
    expect(parsed.failure, isNull);
    expect(parsed.request, isA<ServerDeepLink>());
    expect(safeDeepLinkDisplay('example.com').text, 'example.com');
  });

  group('DeepLinkCoordinator', () {
    test('coalesces an endpoint and bounds its visible queue', () async {
      final handler = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(handler);

      coordinator.add(_hostUri('one.example', path: '/first'));
      await handler.waitForReviews(1);
      coordinator
        ..add(_hostUri('one.example', path: '/latest'))
        ..add(_hostUri('two.example'))
        ..add(_hostUri('three.example'))
        ..add(_hostUri('four.example'))
        ..add(_hostUri('five.example'));

      final snapshot = handler.reviews.single.value;
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

      handler.answer(DeepLinkReviewDecision.connect);
      await handler.waitForOpens(1);

      expect(handler.opened.single.host, 'one.example');
      expect(handler.opened.single.remotePath, '/latest');
      expect(handler.opened.single.activationCount, 2);

      await handler.waitForReviews(2);
      handler.answer(DeepLinkReviewDecision.discardAllRemaining);
      await coordinator.idle;
    });

    test(
      'serializes distinct endpoints and discards only by user action',
      () async {
        final handler = _Handler();
        final coordinator = DeepLinkCoordinator();
        coordinator.activate(handler);

        coordinator
          ..add(_hostUri('one.example'))
          ..add(_hostUri('two.example'))
          ..add(_hostUri('three.example'));
        await handler.waitForReviews(1);
        await pumpEventQueue(times: 20);
        expect(handler.reviews, hasLength(1));

        handler.answer(DeepLinkReviewDecision.cancel);
        await handler.waitForReviews(2);
        expect(handler.reviews[1].value.current.host, 'two.example');

        handler.answer(DeepLinkReviewDecision.discardAllRemaining);
        await coordinator.idle;

        expect(handler.opened, isEmpty);
        expect(handler.reviews, hasLength(2));
      },
    );

    test('preserves every overflow endpoint in review order', () async {
      final handler = _Handler();
      final coordinator = DeepLinkCoordinator();
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
        reviewed.add(handler.reviews[count - 1].value.current.host);
        handler.answer(DeepLinkReviewDecision.cancel);
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
      final coordinator = DeepLinkCoordinator();
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
      final overflow = handler.reviews.single.value.overflow;

      handler.answer(DeepLinkReviewDecision.cancel);
      await handler.waitForReviews(2);

      expect(overflow.map((link) => link.host), [
        'four.example',
        'five.example',
      ]);
      handler.answer(DeepLinkReviewDecision.discardAllRemaining);
      await coordinator.idle;
    });

    test('keeps scoped IPv6 zone identifiers case-sensitive', () async {
      final handler = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(handler);

      coordinator
        ..add(_hostUri('fe80::1%en0'))
        ..add(_hostUri('fe80::1%EN0'));

      await handler.waitForReviews(1);
      expect(handler.reviews.single.value.current.activationCount, 1);
      handler.answer(DeepLinkReviewDecision.cancel);

      await handler.waitForReviews(2);
      expect(handler.reviews[1].value.current.host, 'fe80::1%EN0');
      handler.answer(DeepLinkReviewDecision.cancel);
      await coordinator.idle;
    });

    test('coalesces repeats already waiting in the queue', () async {
      final handler = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(handler);
      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);

      coordinator
        ..add(_hostUri('two.example', path: '/first'))
        ..add(_hostUri('two.example', path: '/latest'));

      final waiting = handler.reviews.single.value.visibleWaiting.single;
      expect(waiting.remotePath, '/latest');
      expect(waiting.activationCount, 2);
      handler.answer(DeepLinkReviewDecision.cancel);
      await handler.waitForReviews(2);
      handler.answer(DeepLinkReviewDecision.cancel);
      await coordinator.idle;
      expect(handler.reviews, hasLength(2));
    });

    test('keeps port and username in the endpoint identity', () async {
      final handler = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(handler);
      coordinator.add(_hostUri('same.example'));
      await handler.waitForReviews(1);

      coordinator
        ..add(_hostUri('same.example', port: 2200))
        ..add(_hostUri('same.example', username: 'root'));

      final waiting = handler.reviews.single.value.visibleWaiting;
      expect(waiting, hasLength(2));
      expect(waiting[0].port, 2200);
      expect(waiting[1].username, 'root');
      expect(waiting.every((link) => link.activationCount == 1), isTrue);
      handler.answer(DeepLinkReviewDecision.discardAllRemaining);
      await coordinator.idle;
    });

    test('requeues an in-flight review when handler ownership moves', () async {
      final first = _Handler();
      final second = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(first);
      coordinator.add(_hostUri('files.example'));
      await first.waitForReviews(1);

      coordinator.activate(second);

      await second.waitForReviews(1);
      expect(first.opened, isEmpty);
      second.answer(DeepLinkReviewDecision.connect);
      await coordinator.idle;

      expect(second.opened.single.host, 'files.example');
    });

    test('requeues a failed review for the next handler', () async {
      final first = _Handler();
      final second = _Handler();
      final errors = <Object>[];
      final coordinator = DeepLinkCoordinator(
        onError: (error, _) => errors.add(error),
      );
      coordinator.activate(first);
      coordinator.add(_hostUri('files.example'));
      await first.waitForReviews(1);

      first.failReview(StateError('handler closed'));
      await _waitFor(() => errors.isNotEmpty, 'reported review error');
      coordinator.activate(second);

      await second.waitForReviews(1);
      second.answer(DeepLinkReviewDecision.cancel);
      await coordinator.idle;

      expect(errors, hasLength(1));
      expect(second.reviews.single.value.current.host, 'files.example');
    });

    test(
      'preserves repeats added while a review failure is reported',
      () async {
        final first = _Handler();
        final second = _Handler();
        late final DeepLinkCoordinator coordinator;
        var reported = false;
        coordinator = DeepLinkCoordinator(
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
        final retried = second.reviews.single.value.current;
        expect(retried.activationCount, 2);
        expect(retried.remotePath, '/during-error');
        second.answer(DeepLinkReviewDecision.cancel);
        await coordinator.idle;
      },
    );

    test('queues a repeated endpoint while its confirmed open runs', () async {
      final handler = _Handler(hostOpen: _HostOpenBehavior.waitAfterCommit);
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(handler);
      coordinator.add(_hostUri('files.example', path: '/first'));
      await handler.waitForReviews(1);
      handler.answer(DeepLinkReviewDecision.connect);
      await handler.waitForOpens(1);

      coordinator.add(_hostUri('files.example', path: '/second'));
      handler.releaseHostOpen();

      await handler.waitForReviews(2);
      expect(handler.reviews[1].value.current.remotePath, '/second');
      handler.answer(DeepLinkReviewDecision.cancel);
      await coordinator.idle;
    });

    test('does not replay a committed open after ownership moves', () async {
      final first = _Handler(hostOpen: _HostOpenBehavior.waitAfterCommit);
      final second = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(first);
      coordinator.add(_hostUri('files.example'));
      await first.waitForReviews(1);
      first.answer(DeepLinkReviewDecision.connect);
      await first.waitForOpens(1);

      coordinator.activate(second);
      await pumpEventQueue(times: 20);

      final replayed = second.reviews.isNotEmpty;
      if (replayed) second.answer(DeepLinkReviewDecision.cancel);
      await coordinator.idle;
      expect(replayed, isFalse);
    });

    test('coalesces a repeat when an uncommitted open moves', () async {
      final first = _Handler(hostOpen: _HostOpenBehavior.waitBeforeCommit);
      final second = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(first);
      coordinator.add(_hostUri('files.example', path: '/first'));
      await first.waitForReviews(1);
      first.answer(DeepLinkReviewDecision.connect);
      await first.waitForHostAttempts(1);

      coordinator.add(_hostUri('files.example', path: '/second'));
      coordinator.activate(second);

      await second.waitForReviews(1);
      final link = second.reviews.single.value.current;
      expect(link.remotePath, '/second');
      expect(link.activationCount, 2);
      second.answer(DeepLinkReviewDecision.cancel);
      await coordinator.idle;
      expect(second.reviews, hasLength(1));
    });

    test('moves an in-flight failure dialog to the active handler', () async {
      final first = _Handler(failure: _FailureBehavior.waitForCancellation);
      final second = _Handler();
      final coordinator = DeepLinkCoordinator();
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
      final coordinator = DeepLinkCoordinator();
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
        final coordinator = DeepLinkCoordinator();
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
        final coordinator = DeepLinkCoordinator();
        coordinator.activate(handler);
        coordinator.add(_hostUri('one.example'));
        await handler.waitForReviews(1);

        coordinator
          ..add(
            Uri.parse('poltergeist://browse?serverId=$_serverId&path=%2Fsrv'),
          )
          ..add(Uri.parse('poltergeist://unknown'))
          ..add(_hostUri('two.example'));
        handler.answer(DeepLinkReviewDecision.discardAllRemaining);
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
        final coordinator = DeepLinkCoordinator();
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
        final reviewed = handler.reviews.single.value;

        coordinator.add(_hostUri('new.example'));
        handler.answerDiscarding(reviewed);

        await handler.waitForReviews(2);
        expect(handler.reviews[1].value.current.host, 'new.example');
        handler.answer(DeepLinkReviewDecision.cancel);
        await coordinator.idle;
      },
    );

    test('dead-ends an unresolved catalog id', () async {
      final handler = _Handler(serverResult: DeepLinkServerResult.notFound);
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(handler);

      coordinator.add(
        Uri.parse('poltergeist://browse?serverId=$_serverId&path=%2Fsrv'),
      );
      await coordinator.idle;

      expect(handler.servers, hasLength(1));
      expect(handler.opened, isEmpty);
      expect(handler.failures.single.kind, DeepLinkFailureKind.serverNotFound);
    });

    test('caps the pending queue and counts what it drops', () async {
      final handler = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(handler);

      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);

      for (var i = 0; i < poltergeistLinkQueueLimit; i++) {
        coordinator.add(_hostUri('queued$i.example'));
      }
      for (var i = 0; i < 3; i++) {
        coordinator.add(_hostUri('dropped$i.example'));
      }
      // A repeat of a queued endpoint coalesces rather than dropping.
      coordinator.add(_hostUri('queued0.example', path: '/again'));

      final snapshot = handler.reviews.single.value;
      expect(snapshot.remainingCount, poltergeistLinkQueueLimit);
      expect(snapshot.ignoredCount, 3);
      expect(
        snapshot.visibleWaiting.length + snapshot.overflow.length,
        poltergeistLinkQueueLimit,
      );
      expect(snapshot.visibleWaiting.first.remotePath, '/again');
      expect(snapshot.visibleWaiting.first.activationCount, 2);

      // The review that showed the count consumes it.
      handler.answer(DeepLinkReviewDecision.cancel, shown: snapshot);
      for (var i = 0; i < poltergeistLinkQueueLimit; i++) {
        await handler.waitForReviews(i + 2);
        expect(handler.reviews[i + 1].value.ignoredCount, 0);
        handler.answer(DeepLinkReviewDecision.cancel);
      }
      await coordinator.idle;

      expect(handler.reviews, hasLength(poltergeistLinkQueueLimit + 1));
      expect(handler.reviews.map((review) => review.value.current.host), [
        'one.example',
        for (var i = 0; i < poltergeistLinkQueueLimit; i++) 'queued$i.example',
      ]);
      expect(handler.reviews[1].value.current.activationCount, 2);
      expect(handler.reviews[1].value.current.remotePath, '/again');
      expect(handler.ignoredReports, isEmpty);
    });

    test('carries drops the last drawn review missed to the next', () async {
      final handler = _Handler();
      final coordinator = DeepLinkCoordinator();
      coordinator.activate(handler);

      coordinator.add(_hostUri('one.example'));
      await handler.waitForReviews(1);
      for (var i = 0; i < poltergeistLinkQueueLimit; i++) {
        coordinator.add(_hostUri('queued$i.example'));
      }
      final drawn = handler.reviews.single.value;
      expect(drawn.ignoredCount, 0);

      coordinator
        ..add(_hostUri('dropped0.example'))
        ..add(_hostUri('dropped1.example'));
      expect(handler.reviews.single.value.ignoredCount, 2);

      // The dialog decided on the snapshot it last drew, before the drops.
      handler.answer(DeepLinkReviewDecision.cancel, shown: drawn);

      await handler.waitForReviews(2);
      expect(handler.reviews[1].value.ignoredCount, 2);
      handler.answer(DeepLinkReviewDecision.discardAllRemaining);
      await coordinator.idle;

      expect(handler.ignoredReports, isEmpty);
    });

    test('reports dropped links when no review carries the count', () async {
      final handler = _Handler();
      final coordinator = DeepLinkCoordinator();

      // With no handler bound the queue fills without draining, so every
      // link beyond the limit drops.
      for (var i = 0; i < poltergeistLinkQueueLimit + 2; i++) {
        coordinator.add(Uri.parse('poltergeist://unknown'));
      }
      coordinator.activate(handler);
      await coordinator.idle;

      expect(handler.reviews, isEmpty);
      expect(handler.failures, hasLength(poltergeistLinkQueueLimit));
      expect(handler.ignoredReports, [2]);
    });
  });
}

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

enum _HostOpenBehavior { immediate, waitBeforeCommit, waitAfterCommit }

enum _ServerOpenBehavior { immediate, waitBeforeCommit, waitAfterCommit }

final class _Handler implements DeepLinkHandler {
  _Handler({
    this.serverResult = DeepLinkServerResult.opened,
    this.failure = _FailureBehavior.immediate,
    this.hostOpen = _HostOpenBehavior.immediate,
    this.serverOpen = _ServerOpenBehavior.immediate,
  });

  final DeepLinkServerResult serverResult;
  final _FailureBehavior failure;
  final _HostOpenBehavior hostOpen;
  final _ServerOpenBehavior serverOpen;
  final reviews = <DeepLinkReview>[];
  final hostAttempts = <HostDeepLink>[];
  final opened = <HostDeepLink>[];
  final serverAttempts = <ServerDeepLink>[];
  final servers = <ServerDeepLink>[];
  final failures = <DeepLinkFailure>[];
  final ignoredReports = <int>[];
  final _answers = StreamController<DeepLinkReviewDecision>.broadcast();
  final _hostOpenRelease = Completer<void>();

  @override
  Future<DeepLinkReviewDecision> reviewHost(DeepLinkReview review) async {
    reviews.add(review);
    final decision = Completer<DeepLinkReviewDecision>();
    final subscription = _answers.stream.listen(
      decision.complete,
      onError: decision.completeError,
      cancelOnError: true,
    );
    try {
      return await Future.any([
        decision.future,
        review.cancelled.then((_) => DeepLinkReviewDecision.cancel),
      ]);
    } finally {
      await subscription.cancel();
    }
  }

  @override
  Future<DeepLinkHostResult> openHost(
    HostDeepLink link,
    DeepLinkOperation operation,
  ) async {
    hostAttempts.add(link);
    if (hostOpen == _HostOpenBehavior.waitBeforeCommit) {
      await operation.cancelled;
    }
    if (operation.isCancelled) return DeepLinkHostResult.notCommitted;

    opened.add(link);
    if (hostOpen == _HostOpenBehavior.waitAfterCommit) {
      await Future.any([_hostOpenRelease.future, operation.cancelled]);
    }
    return DeepLinkHostResult.committed;
  }

  @override
  Future<DeepLinkServerResult> openServer(
    ServerDeepLink link,
    DeepLinkOperation operation,
  ) async {
    serverAttempts.add(link);
    if (serverOpen == _ServerOpenBehavior.waitBeforeCommit) {
      await operation.cancelled;
    }
    if (operation.isCancelled) return DeepLinkServerResult.notFound;

    servers.add(link);
    if (serverOpen == _ServerOpenBehavior.waitAfterCommit) {
      await operation.cancelled;
    }

    return serverResult;
  }

  @override
  Future<void> showFailure(
    DeepLinkFailure failure,
    DeepLinkOperation operation,
  ) async {
    if (operation.isCancelled) return;
    failures.add(failure);
    if (this.failure == _FailureBehavior.waitForCancellation) {
      await operation.cancelled;
    }
  }

  @override
  Future<void> showIgnoredLinks(int count, DeepLinkOperation operation) async {
    if (operation.isCancelled) return;
    ignoredReports.add(count);
  }

  /// Answers the open review on the snapshot the decision covered, which
  /// is what it shows now unless a test passes an older one.
  void answer(
    DeepLinkReviewDecision decision, {
    DeepLinkReviewSnapshot? shown,
  }) {
    if (reviews.isEmpty) {
      throw StateError('answer() called before a review was presented');
    }
    reviews.last.markSnapshotShown(shown ?? reviews.last.value);
    _answers.add(decision);
  }

  void answerDiscarding(DeepLinkReviewSnapshot snapshot) {
    answer(DeepLinkReviewDecision.discardAllRemaining, shown: snapshot);
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
