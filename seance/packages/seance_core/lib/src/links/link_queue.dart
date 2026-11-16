/// The suite's queue for incoming links: one review at a time, a hard
/// limit with a count of what it dropped, and handoff between windows
/// (docs/design/suite-links.md section 6). Séance's `seance://connect`
/// intake and Poltergeist's `poltergeist://browse` intake both run on it;
/// each app keeps its own parsing, review UI and opening.
///
/// A link is classified once, as it arrives, into one of three lanes:
///
/// - reviewed: shown to the user before anything opens. Repeats of a
///   reviewed link coalesce, with the one under review or with one
///   waiting, by the app's key and merge.
/// - direct: opened without a review (Poltergeist's catalog links).
/// - failed: a link that did not parse, shown as a failure.
///
/// The queue is in memory only: a link survives no restart, and a sender
/// whose link was lost sends it again.
library;

import 'dart:async';

import 'suite_links.dart' show DeepLinkFailure;

/// The most links waiting behind the one in hand. Large enough for a
/// burst of hand-offs, small enough that a link flood can neither grow
/// memory nor keep dialogs coming; a link beyond it is dropped and
/// counted.
const int linkQueueLimit = 16;

/// The most waiting reviewed links a review lists by name; the rest are
/// its [LinkReviewSnapshot.overflow].
const int linkReviewVisibleWaiting = 2;

enum LinkReviewDecision {
  connect,
  cancel,

  /// Cancel this link and drop the waiting reviewed links the review last
  /// showed ([LinkReview.markShown]). Direct and failed links stay.
  discardAllRemaining,
}

/// Whether an open took effect. [notCommitted] keeps the link at the
/// head of the queue: it is handed to the next handler if ownership
/// moved, and otherwise waits for the next link or [LinkQueue.activate].
enum LinkOpenResult { committed, notCommitted }

/// How [LinkQueue] files an incoming link; see the library comment.
sealed class LinkEntry<R, D> {
  const LinkEntry();
}

final class ReviewedLinkEntry<R, D> extends LinkEntry<R, D> {
  const ReviewedLinkEntry(this.link);

  final R link;
}

final class DirectLinkEntry<R, D> extends LinkEntry<R, D> {
  const DirectLinkEntry(this.link);

  final D link;
}

final class FailedLinkEntry<R, D> extends LinkEntry<R, D> {
  const FailedLinkEntry(this.failure);

  final DeepLinkFailure failure;
}

/// One step the queue handed to a handler. It is cancelled when another
/// handler takes the queue or the handler leaves, so a dialog it opened
/// can close; the queue then hands the link to the next handler unless
/// the step had already committed.
abstract interface class LinkOperation {
  bool get isCancelled;

  Future<void> get cancelled;
}

/// What a review shows: the link in hand and the reviewed links waiting
/// behind it.
final class LinkReviewSnapshot<R> {
  const LinkReviewSnapshot({
    required this.current,
    this.visibleWaiting = const [],
    this.overflow = const [],
    this.remainingCount = 0,
    this.ignoredCount = 0,
  });

  final R current;

  /// Up to [linkReviewVisibleWaiting] waiting reviewed links, oldest first.
  final List<R> visibleWaiting;

  /// The waiting reviewed links after [visibleWaiting], oldest first.
  final List<R> overflow;

  /// Every waiting reviewed link: [visibleWaiting] and [overflow].
  final int remainingCount;

  /// Links dropped at [linkQueueLimit] that no review has reported yet.
  final int ignoredCount;
}

/// A review in progress. Its snapshot follows the queue while it is open:
/// a repeat of the link under review merges into [snapshot]'s current, and
/// new arrivals extend the waiting lists.
abstract interface class LinkReview<R> implements LinkOperation {
  LinkReviewSnapshot<R> get snapshot;

  /// Each new [snapshot] while the review is open; done once it is decided.
  Stream<LinkReviewSnapshot<R>> get snapshots;

  /// Records the snapshot on screen when the decision was made, so a
  /// discard drops exactly the links it listed and the ignored count it
  /// carried is reported once. Neither reaches a link that arrived unseen.
  void markShown(LinkReviewSnapshot<R> shown);
}

/// The app side of a [LinkQueue]: `R` is a reviewed link, `D` a direct one
/// (`Never` for an app that reviews every link).
abstract interface class LinkQueueHandler<R, D> {
  /// Shows [review] and returns the user's decision. Returns
  /// [LinkReviewDecision.cancel] when the review is cancelled.
  Future<LinkReviewDecision> review(LinkReview<R> review);

  /// Opens a link the user chose to connect.
  Future<LinkOpenResult> open(R link, LinkOperation operation);

  Future<LinkOpenResult> openDirect(D link, LinkOperation operation);

  Future<void> showFailure(DeepLinkFailure failure, LinkOperation operation);

  /// Reports links dropped at [linkQueueLimit] once the queue has drained
  /// and no review was left to carry the count.
  Future<void> showIgnoredLinks(int count, LinkOperation operation);
}

typedef LinkErrorSink = void Function(Object error, StackTrace stackTrace);

/// The queue between link delivery and the active [LinkQueueHandler].
///
/// Links queue from the first [add], before a handler exists, so a
/// cold-start link waits for the app to load. One link is handled at a
/// time, in arrival order. A handler that throws, or does not commit an
/// open, keeps its link at the head, and the queue waits for the next link
/// or [activate].
final class LinkQueue<R, D> {
  LinkQueue({
    required this._classify,
    required this._keyOf,
    required this._coalesce,
    required this._onError,
  });

  final LinkEntry<R, D> Function(Uri uri) _classify;

  /// Reviewed links with equal keys are one request.
  final Object Function(R link) _keyOf;

  /// Merges a repeat into the reviewed link it repeats.
  final R Function(R queued, R incoming) _coalesce;

  final LinkErrorSink _onError;
  final List<_Pending<R, D>> _pending = [];
  LinkQueueHandler<R, D>? _handler;
  _Review<R>? _review;
  _CancelableOperation? _operation;

  /// Moves whenever the handler changes, so a step that started under an
  /// earlier handler can tell that ownership moved.
  int _handlerEpoch = 0;
  bool _draining = false;
  bool _paused = false;
  int _ignored = 0;
  Completer<void>? _idle;

  /// Completes when every queued link has been handled, the queue is
  /// waiting for a handler, or a failed step paused it until the next link
  /// or [activate].
  Future<void> get idle => _idle?.future ?? Future<void>.value();

  /// Makes [handler] the one that shows links. Another handler's step in
  /// progress is cancelled, and its link is handed to [handler].
  void activate(LinkQueueHandler<R, D> handler) {
    if (!identical(_handler, handler)) {
      _handler = handler;
      _handlerEpoch++;
      _operation?.cancel();
    }
    _paused = false;
    _pump();
  }

  /// Stops handing links to [handler]; its step in progress is cancelled
  /// and its link waits for the next handler.
  void deactivate(LinkQueueHandler<R, D> handler) {
    if (!identical(_handler, handler)) return;

    _handler = null;
    _handlerEpoch++;
    _operation?.cancel();
    _pump();
  }

  void add(Uri uri) {
    switch (_classify(uri)) {
      case ReviewedLinkEntry(:final link):
        _addReviewed(link);
      case DirectLinkEntry(:final link):
        _enqueue(_PendingDirect(link));
      case FailedLinkEntry(:final failure):
        _enqueue(_PendingFailure(failure));
    }
    _paused = false;
    _refreshReview();
    _pump();
  }

  void _addReviewed(R incoming) {
    final key = _keyOf(incoming);
    final review = _review;
    if (review != null &&
        review.acceptsActivations &&
        _keyOf(review.snapshot.current) == key) {
      // [add] republishes the whole snapshot next.
      review.current = _coalesce(review.snapshot.current, incoming);
      return;
    }
    final queued = _queuedReviewed(key);
    if (queued != null) {
      queued.link = _coalesce(queued.link, incoming);
      return;
    }
    _enqueue(_PendingReviewed(incoming));
  }

  /// Queues [item], or counts it dropped at [linkQueueLimit].
  void _enqueue(_Pending<R, D> item) {
    if (_pending.length >= linkQueueLimit) {
      _ignored++;
      return;
    }
    _pending.add(item);
  }

  _PendingReviewed<R, D>? _queuedReviewed(Object key) {
    for (final item in _pending) {
      if (item is _PendingReviewed<R, D> && _keyOf(item.link) == key) {
        return item;
      }
    }
    return null;
  }

  void _refreshReview() {
    final review = _review;
    if (review == null || !review.acceptsActivations) return;

    review.publish(_snapshot(review.snapshot.current));
  }

  void _pump() {
    if (_draining) return;
    if (_handler == null || _paused || (_pending.isEmpty && _ignored == 0)) {
      _completeIdle();
      return;
    }
    _idle ??= Completer<void>();
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (true) {
        final handler = _handler;
        if (handler == null) return;

        final epoch = _handlerEpoch;
        if (_pending.isEmpty) {
          // Dropped links reach the user through the next review, or
          // through a report once nothing is left to carry the count.
          if (_ignored == 0) return;
          final ignored = _ignored;
          _ignored = 0;
          final result = await _run(handler, epoch, (operation) async {
            await handler.showIgnoredLinks(ignored, operation);
            return _committedUnlessMoved(handler, epoch, operation);
          }, requeue: () => _ignored += ignored);
          if (result == _Dispatch.paused) {
            _paused = true;
            return;
          }
          continue;
        }

        final item = _pending.removeAt(0);
        final result = switch (item) {
          _PendingReviewed(:final link) => await _handleReviewed(
            handler,
            epoch,
            link,
          ),
          _PendingDirect(:final link) => await _run(
            handler,
            epoch,
            (operation) => handler.openDirect(link, operation),
            requeue: () => _pending.insert(0, item),
          ),
          _PendingFailure(:final failure) => await _run(handler, epoch, (
            operation,
          ) async {
            await handler.showFailure(failure, operation);
            return _committedUnlessMoved(handler, epoch, operation);
          }, requeue: () => _pending.insert(0, item)),
        };
        if (result == _Dispatch.paused) {
          _paused = true;
          return;
        }
      }
    } finally {
      _draining = false;
      _pump();
    }
  }

  /// A step that only shows something has committed once shown, unless
  /// ownership moved while it was on screen: then the next handler shows
  /// it again.
  LinkOpenResult _committedUnlessMoved(
    LinkQueueHandler<R, D> handler,
    int epoch,
    LinkOperation operation,
  ) => _ownershipMoved(handler, epoch, operation)
      ? LinkOpenResult.notCommitted
      : LinkOpenResult.committed;

  Future<_Dispatch> _run(
    LinkQueueHandler<R, D> handler,
    int epoch,
    Future<LinkOpenResult> Function(LinkOperation operation) step, {
    required void Function() requeue,
  }) async {
    final operation = _Operation();
    _startOperation(operation);
    try {
      if (await step(operation) == LinkOpenResult.committed) {
        return _Dispatch.completed;
      }
      requeue();
      return _requeuedOrPaused(handler, epoch, operation);
    } on Object catch (error, stackTrace) {
      requeue();
      _onError(error, stackTrace);
      return _requeuedOrPaused(handler, epoch, operation);
    } finally {
      _finishOperation(operation);
    }
  }

  Future<_Dispatch> _handleReviewed(
    LinkQueueHandler<R, D> handler,
    int epoch,
    R link,
  ) async {
    final review = _Review<R>(_snapshot(link));
    _review = review;
    _startOperation(review);
    try {
      final decision = await handler.review(review);
      review.stopAcceptingActivations();
      final reviewed = review.snapshot.current;
      if (_ownershipMoved(handler, epoch, review)) {
        _requeueReviewedFirst(reviewed);
        return _Dispatch.requeued;
      }

      switch (decision) {
        case LinkReviewDecision.connect:
          final result = await handler.open(reviewed, review);
          if (result == LinkOpenResult.committed) break;
          _requeueReviewedFirst(reviewed);
          return _requeuedOrPaused(handler, epoch, review);
        case LinkReviewDecision.cancel:
          break;
        case LinkReviewDecision.discardAllRemaining:
          _discard(review.shownWaitingKeys(_keyOf));
      }
      return _Dispatch.completed;
    } on Object catch (error, stackTrace) {
      review.stopAcceptingActivations();
      // Requeued before the error is reported, so a link the reporter
      // adds coalesces with it.
      _requeueReviewedFirst(review.snapshot.current);
      _onError(error, stackTrace);
      return _requeuedOrPaused(handler, epoch, review);
    } finally {
      if (identical(_review, review)) _review = null;
      _ignored -= review.shownIgnoredCount;
      _finishOperation(review);
      review.close();
    }
  }

  _Dispatch _requeuedOrPaused(
    LinkQueueHandler<R, D> handler,
    int epoch,
    LinkOperation operation,
  ) => _ownershipMoved(handler, epoch, operation)
      ? _Dispatch.requeued
      : _Dispatch.paused;

  bool _ownershipMoved(
    LinkQueueHandler<R, D> handler,
    int epoch,
    LinkOperation operation,
  ) =>
      operation.isCancelled ||
      epoch != _handlerEpoch ||
      !identical(_handler, handler);

  void _startOperation(_CancelableOperation operation) {
    assert(_operation == null, 'one link step at a time');
    _operation = operation;
  }

  void _finishOperation(_CancelableOperation operation) {
    if (identical(_operation, operation)) _operation = null;
  }

  /// Puts [link] back at the head, merged with a repeat that arrived
  /// after its review closed.
  void _requeueReviewedFirst(R link) {
    final queued = _queuedReviewed(_keyOf(link));
    if (queued != null) {
      _pending.remove(queued);
      link = _coalesce(link, queued.link);
    }
    _pending.insert(0, _PendingReviewed(link));
  }

  void _discard(Set<Object> shown) {
    if (shown.isEmpty) return;

    _pending.removeWhere(
      (item) =>
          item is _PendingReviewed<R, D> && shown.contains(_keyOf(item.link)),
    );
  }

  LinkReviewSnapshot<R> _snapshot(R current) {
    final waiting = [
      for (final item in _pending)
        if (item is _PendingReviewed<R, D>) item.link,
    ];
    final visible = waiting.length < linkReviewVisibleWaiting
        ? waiting.length
        : linkReviewVisibleWaiting;
    return LinkReviewSnapshot(
      current: current,
      visibleWaiting: List.unmodifiable(waiting.take(visible)),
      overflow: List.unmodifiable(waiting.skip(visible)),
      remainingCount: waiting.length,
      ignoredCount: _ignored,
    );
  }

  void _completeIdle() {
    final idle = _idle;
    if (idle == null) return;
    _idle = null;
    idle.complete();
  }
}

enum _Dispatch { completed, requeued, paused }

sealed class _Pending<R, D> {}

final class _PendingReviewed<R, D> extends _Pending<R, D> {
  _PendingReviewed(this.link);

  /// Replaced as repeats coalesce into it.
  R link;
}

final class _PendingDirect<R, D> extends _Pending<R, D> {
  _PendingDirect(this.link);

  final D link;
}

final class _PendingFailure<R, D> extends _Pending<R, D> {
  _PendingFailure(this.failure);

  final DeepLinkFailure failure;
}

abstract interface class _CancelableOperation implements LinkOperation {
  void cancel();
}

final class _Operation implements _CancelableOperation {
  final Completer<void> _cancellation = Completer<void>();

  @override
  bool get isCancelled => _cancellation.isCompleted;

  @override
  Future<void> get cancelled => _cancellation.future;

  @override
  void cancel() {
    if (!isCancelled) _cancellation.complete();
  }
}

final class _Review<R> implements LinkReview<R>, _CancelableOperation {
  _Review(this._snapshot);

  final _Operation _operation = _Operation();
  final StreamController<LinkReviewSnapshot<R>> _snapshots =
      StreamController.broadcast();
  LinkReviewSnapshot<R> _snapshot;
  LinkReviewSnapshot<R>? _shown;
  bool _acceptsActivations = true;

  /// False once the review is decided: a repeat then queues anew instead
  /// of merging into a link already on its way.
  bool get acceptsActivations => _acceptsActivations;

  @override
  LinkReviewSnapshot<R> get snapshot => _snapshot;

  @override
  Stream<LinkReviewSnapshot<R>> get snapshots => _snapshots.stream;

  /// Replaces the link under review without publishing; the queue
  /// publishes the refreshed snapshot.
  set current(R link) => _snapshot = LinkReviewSnapshot(
    current: link,
    visibleWaiting: _snapshot.visibleWaiting,
    overflow: _snapshot.overflow,
    remainingCount: _snapshot.remainingCount,
    ignoredCount: _snapshot.ignoredCount,
  );

  void publish(LinkReviewSnapshot<R> snapshot) {
    _snapshot = snapshot;
    if (!_snapshots.isClosed) _snapshots.add(snapshot);
  }

  Set<Object> shownWaitingKeys(Object Function(R link) keyOf) {
    final shown = _shown;
    if (shown == null) return const {};
    return {
      for (final link in shown.visibleWaiting) keyOf(link),
      for (final link in shown.overflow) keyOf(link),
    };
  }

  int get shownIgnoredCount => _shown?.ignoredCount ?? 0;

  @override
  void markShown(LinkReviewSnapshot<R> shown) => _shown = shown;

  @override
  bool get isCancelled => _operation.isCancelled;

  @override
  Future<void> get cancelled => _operation.cancelled;

  @override
  void cancel() => _operation.cancel();

  void stopAcceptingActivations() => _acceptsActivations = false;

  void close() => unawaited(_snapshots.close());
}
