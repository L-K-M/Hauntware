import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/deep_links.dart';

const _serverId = '123e4567-e89b-42d3-a456-426614174000';

void main() {
  group('parsePoltergeistDeepLink', () {
    test('parses catalog links and decoded remote paths', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse(
          'poltergeist://browse?serverId=$_serverId&'
          'path=%2Fsrv%2Freports%20%26%20plans',
        ),
      );

      expect(parsed.failure, isNull);
      expect(
        parsed.request,
        isA<ServerDeepLink>()
            .having((link) => link.serverId, 'serverId', _serverId)
            .having(
              (link) => link.remotePath,
              'remotePath',
              '/srv/reports & plans',
            ),
      );
    });

    test('parses host links without assuming a port', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse(
          'poltergeist://browse?host=fe80%3A%3A1%25en0&port=2200&'
          'username=ops%20%26%20build&path=%2Fsrv%2F%23daily%25',
        ),
      );

      expect(parsed.failure, isNull);
      expect(
        parsed.request,
        isA<HostDeepLink>()
            .having((link) => link.host, 'host', 'fe80::1%en0')
            .having((link) => link.port, 'port', 2200)
            .having((link) => link.username, 'username', 'ops & build')
            .having((link) => link.remotePath, 'remotePath', '/srv/#daily%'),
      );
    });

    test('rejects missing, malformed, and out-of-range ports', () {
      for (final query in [
        'host=example.com&username=ops&path=%2F',
        'host=example.com&port=ssh&username=ops&path=%2F',
        'host=example.com&port=%2B22&username=ops&path=%2F',
        'host=example.com&port=%2022%20&username=ops&path=%2F',
        'host=example.com&port=0x16&username=ops&path=%2F',
        'host=example.com&port=${'9' * 10000}&username=ops&path=%2F',
        'host=example.com&port=0&username=ops&path=%2F',
        'host=example.com&port=65536&username=ops&path=%2F',
      ]) {
        final parsed = parsePoltergeistDeepLink(
          Uri.parse('poltergeist://browse?$query'),
        );

        expect(parsed.failure?.kind, DeepLinkFailureKind.invalidPort);
        expect(parsed.request, isNull);
      }
    });

    test('accepts leading zeros in a decimal port', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse(
          'poltergeist://browse?host=example.com&port=000022&'
          'username=ops&path=%2F',
        ),
      );

      expect((parsed.request as HostDeepLink).port, 22);
    });

    test('rejects ambiguous, secret-bearing, and duplicate parameters', () {
      for (final raw in [
        'poltergeist://browse?serverId=$_serverId&host=example.com&'
            'port=22&username=ops&path=%2F',
        'poltergeist://browse?host=example.com&port=22&username=ops&'
            'password=secret&path=%2F',
        'poltergeist://browse?host=one&host=two&port=22&username=ops&'
            'path=%2F',
      ]) {
        final parsed = parsePoltergeistDeepLink(Uri.parse(raw));

        expect(parsed.failure?.kind, DeepLinkFailureKind.invalidParameters);
        expect(parsed.request, isNull);
      }
    });

    test('rejects unsafe remote path components', () {
      for (final path in ['/srv/../secret', '/srv//secret', r'/srv/a\b']) {
        final parsed = parsePoltergeistDeepLink(
          Uri(
            scheme: poltergeistDeepLinkScheme,
            host: poltergeistBrowseRoute,
            queryParameters: {
              'host': 'example.com',
              'port': '22',
              'username': 'ops',
              'path': path,
            },
          ),
        );

        expect(parsed.failure?.kind, DeepLinkFailureKind.invalidPath);
        expect(parsed.request, isNull);
      }
    });

    test('rejects invisible controls in endpoint values', () {
      for (final control in [
        '\u0085',
        '\u200e',
        '\u202e',
        '\ufeff',
        '\u{e0001}',
      ]) {
        for (final field in ['host', 'username']) {
          final parsed = parsePoltergeistDeepLink(
            Uri(
              scheme: poltergeistDeepLinkScheme,
              host: poltergeistBrowseRoute,
              queryParameters: {
                'host': field == 'host' ? 'files${control}example' : 'files',
                'port': '22',
                'username': field == 'username' ? 'op${control}s' : 'ops',
                'path': '/',
              },
            ),
          );

          expect(
            parsed.failure?.kind,
            DeepLinkFailureKind.invalidParameters,
            reason:
                '$field accepted U+${control.runes.single.toRadixString(16)}',
          );
          expect(parsed.request, isNull);
        }
      }
    });

    test('keeps ordinary printable endpoint values', () {
      final parsed = parsePoltergeistDeepLink(
        Uri(
          scheme: poltergeistDeepLinkScheme,
          host: poltergeistBrowseRoute,
          queryParameters: const {
            'host': 'files.example',
            'port': '22',
            'username': 'ops build',
            'path': '/',
          },
        ),
      );

      expect(parsed.failure, isNull);
      expect((parsed.request as HostDeepLink).username, 'ops build');
    });

    test('requires a UUID catalog id', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse('poltergeist://browse?serverId=server-1&path=%2F'),
      );

      expect(parsed.failure?.kind, DeepLinkFailureKind.invalidParameters);
    });

    test('canonicalizes accepted catalog ids for exact lookup', () {
      final parsed = parsePoltergeistDeepLink(
        Uri.parse(
          'poltergeist://browse?serverId=${_serverId.toUpperCase()}&path=%2F',
        ),
      );

      expect((parsed.request as ServerDeepLink).serverId, _serverId);
    });
  });

  group('safeDeepLinkDisplay', () {
    test('strips directional and line controls', () {
      final display = safeDeepLinkDisplay(
        'safe\u202Eevil\nname\u2066legacy\u206A',
      );

      expect(display.text, 'safeevilnamelegacy');
      expect(display.removedControls, isTrue);
    });

    test('strips default-ignorable format controls', () {
      final display = safeDeepLinkDisplay(
        'a\u00adb\u200bc\u200cd\u200de\u2060f\ufeffg',
      );

      expect(display.text, 'abcdefg');
      expect(display.removedControls, isTrue);
    });

    test('annotates internationalized and mixed-script hosts', () {
      final display = safeDeepLinkHostDisplay('paypa\u043b.example');

      expect(display.internationalized, isTrue);
      expect(display.mixedScripts, isTrue);
    });

    test('flags unknown-script and Cyrillic mixtures', () {
      final display = safeDeepLinkHostDisplay('\u0585\u0430.\u0440\u0444');

      expect(display.internationalized, isTrue);
      expect(display.mixedScripts, isTrue);
      expect(display.unrecognizedScripts, isFalse);
    });

    test('flags mixtures between unsupported scripts', () {
      final display = safeDeepLinkHostDisplay(
        '\u0561\u10d0.\u0570\u0561\u0575',
      );

      expect(display.internationalized, isTrue);
      expect(display.mixedScripts, isTrue);
    });

    test('does not flag scripts split across labels or Japanese labels', () {
      expect(
        safeDeepLinkHostDisplay(
          '\u043f\u0440\u0438\u043c\u0435\u0440.com',
        ).mixedScripts,
        isFalse,
      );
      expect(
        safeDeepLinkHostDisplay('\u4f8b\u3048.\u30c6\u30b9\u30c8').mixedScripts,
        isFalse,
      );
    });

    test('warns separately for an unrecognized writing system', () {
      final display = safeDeepLinkHostDisplay('\u0e44\u0e17\u0e22.example');

      expect(display.internationalized, isTrue);
      expect(display.mixedScripts, isFalse);
      expect(display.unrecognizedScripts, isTrue);
    });

    test('treats Unicode dot variants as label separators', () {
      final display = safeDeepLinkHostDisplay(
        '\u043f\u0440\u0438\u043c\u0435\u0440\u3002com',
      );

      expect(display.mixedScripts, isFalse);
      expect(display.unrecognizedScripts, isFalse);
    });
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

  void answer(DeepLinkReviewDecision decision) {
    if (reviews.isEmpty) {
      throw StateError('answer() called before a review was presented');
    }
    if (decision == DeepLinkReviewDecision.discardAllRemaining) {
      reviews.last.markRemainingReviewed(reviews.last.value);
    }
    _answers.add(decision);
  }

  void answerDiscarding(DeepLinkReviewSnapshot snapshot) {
    reviews.last.markRemainingReviewed(snapshot);
    _answers.add(DeepLinkReviewDecision.discardAllRemaining);
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
