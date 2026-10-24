/// Validated `poltergeist://` intake and its serialized trust-review queue.
///
/// Native delivery stops here. The coordinator exposes domain requests to the
/// active workspace, which alone may show UI or open a pane.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show
        DeepLinkFailure,
        DeepLinkFailureKind,
        HostDeepLink,
        ServerDeepLink,
        parsePoltergeistDeepLink;

import 'quick_connect_address.dart';

// The link grammar and display safety moved to seance_core
// (docs/design/suite-links.md section 5); re-exported so this file's
// importers do not change.
export 'package:poltergeist_core/poltergeist_core.dart'
    show
        DeepLinkFailure,
        DeepLinkFailureKind,
        DeepLinkParse,
        DeepLinkRequest,
        HostDeepLink,
        SafeDeepLinkDisplay,
        SafeDeepLinkHostDisplay,
        ServerDeepLink,
        parsePoltergeistDeepLink,
        poltergeistBrowseRoute,
        poltergeistDeepLinkScheme,
        safeDeepLinkDisplay,
        safeDeepLinkHostDisplay;

const deepLinkVisibleQueueLimit = 3;

/// The Quick Connect target a host link opens; app-side because
/// [QuickConnectTarget] is Poltergeist's.
extension HostDeepLinkQuickConnect on HostDeepLink {
  QuickConnectTarget get target => QuickConnectTarget(
    username: username,
    host: host,
    port: port,
    remotePath: remotePath,
  );
}

enum DeepLinkReviewDecision { connect, cancel, discardAllRemaining }

enum DeepLinkHostResult { committed, notCommitted }

enum DeepLinkServerResult { opened, notFound }

@immutable
final class DeepLinkReviewSnapshot {
  const DeepLinkReviewSnapshot({
    required this.current,
    required this.visibleWaiting,
    required this.overflow,
    required this.remainingCount,
  });

  final HostDeepLink current;
  final List<HostDeepLink> visibleWaiting;
  final Iterable<HostDeepLink> overflow;
  final int remainingCount;
}

abstract interface class DeepLinkHandler {
  Future<DeepLinkReviewDecision> reviewHost(DeepLinkReview review);

  Future<DeepLinkHostResult> openHost(
    HostDeepLink link,
    DeepLinkOperation operation,
  );

  Future<DeepLinkServerResult> openServer(
    ServerDeepLink link,
    DeepLinkOperation operation,
  );

  Future<void> showFailure(
    DeepLinkFailure failure,
    DeepLinkOperation operation,
  );
}

abstract interface class DeepLinkOperation {
  bool get isCancelled;

  Future<void> get cancelled;
}

abstract interface class DeepLinkReview
    implements ValueListenable<DeepLinkReviewSnapshot>, DeepLinkOperation {
  /// Limits a discard decision to the pending endpoints this snapshot showed.
  void markRemainingReviewed(DeepLinkReviewSnapshot snapshot);
}

typedef DeepLinkErrorSink = void Function(Object error, StackTrace stackTrace);

final class DeepLinkCoordinator {
  DeepLinkCoordinator({DeepLinkErrorSink? onError})
    : _onError = onError ?? _reportFlutterError;

  final DeepLinkErrorSink _onError;
  final ListQueue<Object> _pending = ListQueue();
  final Map<({String host, int port, String username}), _PendingHost>
  _pendingHosts = {};
  List<_PendingHost> _pendingHostOrder = [];
  int _pendingHostHead = 0;
  DeepLinkHandler? _handler;
  _DeepLinkReview? _review;
  _CancelableDeepLinkOperation? _operation;
  int _handlerEpoch = 0;
  bool _draining = false;
  bool _pausedAfterHandlerFailure = false;
  Completer<void>? _idleCompleter;

  Future<void> get idle => _idleCompleter?.future ?? Future<void>.value();

  void activate(DeepLinkHandler handler) {
    if (!identical(_handler, handler)) {
      _handler = handler;
      _handlerEpoch++;
      _operation?.cancel();
    }
    _pausedAfterHandlerFailure = false;
    _pump();
  }

  void deactivate(DeepLinkHandler handler) {
    if (!identical(_handler, handler)) return;

    _handler = null;
    _handlerEpoch++;
    _operation?.cancel();
  }

  void add(Uri uri) {
    final parsed = parsePoltergeistDeepLink(uri);
    final request = parsed.request;
    if (request case final HostDeepLink host) {
      _addHost(host);
    } else if (request != null) {
      _pending.addLast(request);
    } else {
      _pending.addLast(parsed.failure!);
    }
    _idleCompleter ??= Completer<void>();
    _pausedAfterHandlerFailure = false;
    _refreshReview();
    _pump();
  }

  void _addHost(HostDeepLink incoming) {
    final review = _review;
    if (review != null &&
        review.acceptsActivations &&
        review.value.current.endpointKey == incoming.endpointKey) {
      _replaceReviewCurrent(review.value.current.coalesce(incoming));
      return;
    }
    final queued = _pendingHosts[incoming.endpointKey];
    if (queued != null) {
      queued.link = queued.link.coalesce(incoming);
      return;
    }

    final pending = _PendingHost(incoming);
    _pendingHosts[incoming.endpointKey] = pending;
    _pendingHostOrder.add(pending);
    _pending.addLast(pending);
  }

  void _replaceReviewCurrent(HostDeepLink current) {
    final review = _review;
    if (review == null || !review.acceptsActivations) return;
    review.value = DeepLinkReviewSnapshot(
      current: current,
      visibleWaiting: review.value.visibleWaiting,
      overflow: review.value.overflow,
      remainingCount: review.value.remainingCount,
    );
  }

  void _refreshReview() {
    final review = _review;
    if (review == null || !review.acceptsActivations) return;

    review.value = _reviewSnapshot(review.value.current);
  }

  void _pump() {
    if (_draining ||
        _pausedAfterHandlerFailure ||
        _handler == null ||
        _pending.isEmpty) {
      return;
    }
    _draining = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty) {
        final handler = _handler;
        if (handler == null) return;
        final handlerEpoch = _handlerEpoch;
        final request = _takeFirst();
        final result = switch (request) {
          final HostDeepLink host => await _reviewHost(
            handler,
            handlerEpoch,
            host,
          ),
          final ServerDeepLink server => await _openServer(
            handler,
            handlerEpoch,
            server,
          ),
          final DeepLinkFailure failure => await _showFailure(
            handler,
            handlerEpoch,
            failure,
          ),
          _ => throw StateError('unknown deep-link request'),
        };
        if (result == _DispatchResult.paused) {
          _pausedAfterHandlerFailure = true;
          return;
        }
      }
    } finally {
      _draining = false;
      if (_pending.isEmpty) {
        _idleCompleter?.complete();
        _idleCompleter = null;
      } else {
        _pump();
      }
    }
  }

  Future<_DispatchResult> _reviewHost(
    DeepLinkHandler handler,
    int handlerEpoch,
    HostDeepLink host,
  ) async {
    final review = _DeepLinkReview(_reviewSnapshot(host));
    _review = review;
    _startOperation(review);
    var reviewedHost = host;
    try {
      final decision = await handler.reviewHost(review);
      review.stopAcceptingActivations();
      reviewedHost = review.value.current;
      if (_ownershipMoved(handler, handlerEpoch, review)) {
        _requeueHostFirst(reviewedHost);
        return _DispatchResult.requeued;
      }

      switch (decision) {
        case DeepLinkReviewDecision.connect:
          final result = await handler.openHost(reviewedHost, review);
          if (result == DeepLinkHostResult.committed) {
            break;
          }
          _requeueHostFirst(reviewedHost);
          if (_ownershipMoved(handler, handlerEpoch, review)) {
            return _DispatchResult.requeued;
          }
          return _DispatchResult.paused;
        case DeepLinkReviewDecision.cancel:
          break;
        case DeepLinkReviewDecision.discardAllRemaining:
          _clearPendingHosts(review.reviewedRemaining);
      }
      _compactPendingHostOrder();
      return _DispatchResult.completed;
    } on Object catch (error, stackTrace) {
      review.stopAcceptingActivations();
      reviewedHost = review.value.current;
      _requeueHostFirst(reviewedHost);
      _onError(error, stackTrace);

      return _ownershipMoved(handler, handlerEpoch, review)
          ? _DispatchResult.requeued
          : _DispatchResult.paused;
    } finally {
      if (identical(_review, review)) _review = null;
      _finishOperation(review);
      review.dispose();
    }
  }

  Future<_DispatchResult> _openServer(
    DeepLinkHandler handler,
    int handlerEpoch,
    ServerDeepLink server,
  ) async {
    final operation = _DeepLinkOperation();
    _startOperation(operation);
    try {
      final result = await handler.openServer(server, operation);
      if (result == DeepLinkServerResult.opened) {
        return _DispatchResult.completed;
      }
      if (_ownershipMoved(handler, handlerEpoch, operation)) {
        _pending.addFirst(server);
        return _DispatchResult.requeued;
      }

      await handler.showFailure(
        DeepLinkFailure(
          DeepLinkFailureKind.serverNotFound,
          serverId: server.serverId,
        ),
        operation,
      );
      if (_ownershipMoved(handler, handlerEpoch, operation)) {
        _pending.addFirst(server);
        return _DispatchResult.requeued;
      }
      return _DispatchResult.completed;
    } on Object catch (error, stackTrace) {
      _pending.addFirst(server);
      _onError(error, stackTrace);
      return _ownershipMoved(handler, handlerEpoch, operation)
          ? _DispatchResult.requeued
          : _DispatchResult.paused;
    } finally {
      _finishOperation(operation);
    }
  }

  Future<_DispatchResult> _showFailure(
    DeepLinkHandler handler,
    int handlerEpoch,
    DeepLinkFailure failure,
  ) async {
    final operation = _DeepLinkOperation();
    _startOperation(operation);
    try {
      await handler.showFailure(failure, operation);
      if (_ownershipMoved(handler, handlerEpoch, operation)) {
        _pending.addFirst(failure);
        return _DispatchResult.requeued;
      }
      return _DispatchResult.completed;
    } on Object catch (error, stackTrace) {
      _pending.addFirst(failure);
      _onError(error, stackTrace);
      return _ownershipMoved(handler, handlerEpoch, operation)
          ? _DispatchResult.requeued
          : _DispatchResult.paused;
    } finally {
      _finishOperation(operation);
    }
  }

  bool _ownershipMoved(
    DeepLinkHandler handler,
    int handlerEpoch,
    DeepLinkOperation operation,
  ) =>
      operation.isCancelled ||
      handlerEpoch != _handlerEpoch ||
      !identical(_handler, handler);

  void _startOperation(_CancelableDeepLinkOperation operation) {
    assert(_operation == null);
    _operation = operation;
  }

  void _finishOperation(_CancelableDeepLinkOperation operation) {
    if (identical(_operation, operation)) _operation = null;
  }

  DeepLinkReviewSnapshot _reviewSnapshot(HostDeepLink current) {
    final visibleCapacity = deepLinkVisibleQueueLimit - 1;
    final pendingHostCount = _pendingHostOrder.length - _pendingHostHead;
    final visibleCount = pendingHostCount < visibleCapacity
        ? pendingHostCount
        : visibleCapacity;
    final visible = List<HostDeepLink>.generate(
      visibleCount,
      (index) => _pendingHostOrder[_pendingHostHead + index].link,
      growable: false,
    );
    return DeepLinkReviewSnapshot(
      current: current,
      visibleWaiting: List.unmodifiable(visible),
      overflow: _PendingHostOverflow(
        _pendingHostOrder,
        start: _pendingHostHead + visibleCount,
        length: pendingHostCount - visibleCount,
      ),
      remainingCount: pendingHostCount,
    );
  }

  Object _takeFirst() {
    final pending = _pending.removeFirst();
    if (pending is! _PendingHost) return pending;

    _pendingHosts.remove(pending.link.endpointKey);
    assert(identical(_pendingHostOrder[_pendingHostHead], pending));
    _pendingHostHead++;
    return pending.link;
  }

  void _requeueHostFirst(HostDeepLink host) {
    final queued = _pendingHosts.remove(host.endpointKey);
    final remaining = _pendingHostOrder
        .skip(_pendingHostHead)
        .where((pending) => !identical(pending, queued));
    if (queued != null) {
      _pending.remove(queued);
      host = host.coalesce(queued.link);
    }

    final pending = _PendingHost(host);
    _pendingHosts[host.endpointKey] = pending;
    _pendingHostOrder = [pending, ...remaining];
    _pendingHostHead = 0;
    _pending.addFirst(pending);
  }

  void _clearPendingHosts(
    Set<({String host, int port, String username})> reviewed,
  ) {
    if (reviewed.isEmpty) return;

    _pending.removeWhere(
      (request) =>
          request is _PendingHost &&
          reviewed.contains(request.link.endpointKey),
    );
    for (final endpoint in reviewed) {
      _pendingHosts.remove(endpoint);
    }
    _pendingHostOrder = [
      for (final pending in _pendingHostOrder.skip(_pendingHostHead))
        if (!reviewed.contains(pending.link.endpointKey)) pending,
    ];
    _pendingHostHead = 0;
  }

  void _compactPendingHostOrder() {
    if (_pendingHostHead == _pendingHostOrder.length) {
      _pendingHostOrder = [];
      _pendingHostHead = 0;
      return;
    }
    if (_pendingHostHead < 64 ||
        _pendingHostHead * 2 < _pendingHostOrder.length) {
      return;
    }

    _pendingHostOrder = _pendingHostOrder.sublist(_pendingHostHead);
    _pendingHostHead = 0;
  }

  static void _reportFlutterError(Object error, StackTrace stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(exception: error, stack: stackTrace),
    );
  }
}

enum _DispatchResult { completed, requeued, paused }

abstract interface class _CancelableDeepLinkOperation
    implements DeepLinkOperation {
  void cancel();
}

class _DeepLinkOperation implements _CancelableDeepLinkOperation {
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

final class _DeepLinkReview extends ValueNotifier<DeepLinkReviewSnapshot>
    implements DeepLinkReview, _CancelableDeepLinkOperation {
  _DeepLinkReview(super.value);

  final _DeepLinkOperation _operation = _DeepLinkOperation();
  bool _acceptsActivations = true;
  Set<({String host, int port, String username})> _reviewedRemaining = const {};

  bool get acceptsActivations => _acceptsActivations;

  Set<({String host, int port, String username})> get reviewedRemaining =>
      _reviewedRemaining;

  @override
  bool get isCancelled => _operation.isCancelled;

  @override
  Future<void> get cancelled => _operation.cancelled;

  @override
  void cancel() => _operation.cancel();

  @override
  void markRemainingReviewed(DeepLinkReviewSnapshot snapshot) {
    _reviewedRemaining = {
      for (final link in snapshot.visibleWaiting) link.endpointKey,
      for (final link in snapshot.overflow) link.endpointKey,
    };
  }

  void stopAcceptingActivations() => _acceptsActivations = false;
}

final class _PendingHost {
  _PendingHost(this.link);

  HostDeepLink link;
}

final class _PendingHostOverflow extends IterableBase<HostDeepLink> {
  _PendingHostOverflow(
    this._order, {
    required this.start,
    required this.length,
  });

  final List<_PendingHost> _order;
  final int start;

  @override
  final int length;

  @override
  HostDeepLink elementAt(int index) {
    RangeError.checkValidIndex(index, this);
    return _order[start + index].link;
  }

  @override
  Iterator<HostDeepLink> get iterator =>
      Iterable<HostDeepLink>.generate(length, elementAt).iterator;
}
