import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/deep_links.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show
        LinkOpenResult,
        LinkOperation,
        LinkQueueHandler,
        LinkReview,
        LinkReviewDecision;

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

  // The queue's rules are seance_core's link_queue_test.dart. These cases
  // pin how Poltergeist's coordinator files its own links into it.
  group('createDeepLinkCoordinator', () {
    test('reviews host links and merges repeats by endpoint', () async {
      final handler = _Handler()..holdReviews = true;
      final coordinator = createDeepLinkCoordinator()..activate(handler);

      coordinator
        ..add(_hostUri('files.example', path: '/first'))
        ..add(_hostUri('files.example', path: '/latest'))
        ..add(_hostUri('files.example', port: 2200));
      await pumpEventQueue();

      final snapshot = handler.reviews.single.snapshot;
      expect(snapshot.current.remotePath, '/latest');
      expect(snapshot.current.activationCount, 2);
      expect(snapshot.visibleWaiting.single.port, 2200);
      handler.answer(LinkReviewDecision.discardAllRemaining);
      await coordinator.idle;
      expect(handler.opened, isEmpty);
    });

    test('opens catalog links without a review', () async {
      final handler = _Handler();
      final coordinator = createDeepLinkCoordinator()..activate(handler);

      coordinator.add(
        Uri.parse('poltergeist://browse?serverId=$_serverId&path=%2Fsrv'),
      );
      await coordinator.idle;

      expect(handler.reviews, isEmpty);
      expect(handler.servers.single.serverId, _serverId);
      expect(handler.servers.single.remotePath, '/srv');
    });

    test('shows a link that does not parse as a failure', () async {
      final handler = _Handler();
      final coordinator = createDeepLinkCoordinator()..activate(handler);

      coordinator.add(Uri.parse('seance://connect?serverId=$_serverId'));
      await coordinator.idle;

      expect(handler.failures.single.kind, DeepLinkFailureKind.unsupportedLink);
    });

    test('reports handler errors to its error sink', () async {
      final errors = <Object>[];
      final handler = _Handler()..failReviews = true;
      final coordinator = createDeepLinkCoordinator(
        onError: (error, _) => errors.add(error),
      )..activate(handler);

      coordinator.add(_hostUri('files.example'));
      await coordinator.idle;

      expect(errors.single, isA<StateError>());
    });
  });
}

Uri _hostUri(String host, {int port = 22, String path = '/'}) => Uri(
  scheme: poltergeistDeepLinkScheme,
  host: poltergeistBrowseRoute,
  queryParameters: {
    'host': host,
    'port': '$port',
    'username': 'ops',
    'path': path,
  },
);

final class _Handler implements LinkQueueHandler<HostDeepLink, ServerDeepLink> {
  final reviews = <LinkReview<HostDeepLink>>[];
  final opened = <HostDeepLink>[];
  final servers = <ServerDeepLink>[];
  final failures = <DeepLinkFailure>[];
  bool holdReviews = false;
  bool failReviews = false;
  Completer<LinkReviewDecision>? _open;

  void answer(LinkReviewDecision decision) {
    final review = reviews.last;
    review.markShown(review.snapshot);
    _open!.complete(decision);
  }

  @override
  Future<LinkReviewDecision> review(LinkReview<HostDeepLink> review) async {
    if (failReviews) throw StateError('no window');
    reviews.add(review);
    if (!holdReviews) return LinkReviewDecision.connect;
    return (_open = Completer<LinkReviewDecision>()).future;
  }

  @override
  Future<LinkOpenResult> open(
    HostDeepLink link,
    LinkOperation operation,
  ) async {
    opened.add(link);
    return LinkOpenResult.committed;
  }

  @override
  Future<LinkOpenResult> openDirect(
    ServerDeepLink link,
    LinkOperation operation,
  ) async {
    servers.add(link);
    return LinkOpenResult.committed;
  }

  @override
  Future<void> showFailure(
    DeepLinkFailure failure,
    LinkOperation operation,
  ) async => failures.add(failure);

  @override
  Future<void> showIgnoredLinks(int count, LinkOperation operation) async {}
}
