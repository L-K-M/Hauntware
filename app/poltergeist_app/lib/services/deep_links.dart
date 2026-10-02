/// Validated `poltergeist://` intake and its serialized trust-review queue.
///
/// Native delivery stops here. The coordinator exposes domain requests to the
/// active workspace, which alone may show UI or open a pane.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show validatePathComponent;

import 'quick_connect_address.dart';

const poltergeistDeepLinkScheme = 'poltergeist';
const poltergeistBrowseRoute = 'browse';
const deepLinkVisibleQueueLimit = 3;
const _maxRemotePathBytes = 4096;
const _maxEndpointValueLength = 1024;

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

enum DeepLinkFailureKind {
  unsupportedLink,
  invalidParameters,
  invalidPort,
  invalidPath,
  serverNotFound,
}

@immutable
final class DeepLinkFailure {
  const DeepLinkFailure(this.kind, {this.serverId});

  final DeepLinkFailureKind kind;
  final String? serverId;
}

sealed class DeepLinkRequest {
  const DeepLinkRequest({required this.remotePath});

  final String remotePath;
}

@immutable
final class ServerDeepLink extends DeepLinkRequest {
  const ServerDeepLink({required this.serverId, required super.remotePath});

  final String serverId;
}

@immutable
final class HostDeepLink extends DeepLinkRequest {
  const HostDeepLink({
    required this.host,
    required this.port,
    required this.username,
    required super.remotePath,
    this.activationCount = 1,
  });

  final String host;
  final int port;
  final String username;
  final int activationCount;

  ({String host, int port, String username}) get endpointKey =>
      (host: _endpointHostKey(host), port: port, username: username);

  QuickConnectTarget get target => QuickConnectTarget(
    username: username,
    host: host,
    port: port,
    remotePath: remotePath,
  );

  HostDeepLink coalesce(HostDeepLink newer) => HostDeepLink(
    host: newer.host,
    port: newer.port,
    username: newer.username,
    remotePath: newer.remotePath,
    activationCount: activationCount + newer.activationCount,
  );
}

String _endpointHostKey(String host) {
  final zoneStart = host.indexOf('%');
  if (zoneStart < 0) return host.toLowerCase();

  // IPv6 addresses are case-insensitive, but interface names are not.
  return '${host.substring(0, zoneStart).toLowerCase()}'
      '${host.substring(zoneStart)}';
}

@immutable
final class DeepLinkParse {
  const DeepLinkParse._({this.request, this.failure});

  const DeepLinkParse.request(DeepLinkRequest request)
    : this._(request: request);

  const DeepLinkParse.failure(DeepLinkFailure failure)
    : this._(failure: failure);

  final DeepLinkRequest? request;
  final DeepLinkFailure? failure;
}

DeepLinkParse parsePoltergeistDeepLink(Uri uri) {
  if (uri.scheme.toLowerCase() != poltergeistDeepLinkScheme ||
      uri.host.toLowerCase() != poltergeistBrowseRoute ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasFragment ||
      uri.hasPort ||
      uri.userInfo.isNotEmpty) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.unsupportedLink),
    );
  }

  late final Map<String, List<String>> parameters;
  try {
    parameters = uri.queryParametersAll;
  } on FormatException {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }
  if (parameters.values.any((values) => values.length != 1)) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }

  final keys = parameters.keys.toSet();
  if (keys.contains('serverId')) {
    if (!setEquals(keys, const {'serverId', 'path'})) {
      return const DeepLinkParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
      );
    }
    final serverId = parameters['serverId']!.single;
    final path = parameters['path']!.single;
    if (!_uuidPattern.hasMatch(serverId)) {
      return const DeepLinkParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
      );
    }
    if (!_validRemotePath(path)) {
      return const DeepLinkParse.failure(
        DeepLinkFailure(DeepLinkFailureKind.invalidPath),
      );
    }
    return DeepLinkParse.request(
      ServerDeepLink(serverId: serverId.toLowerCase(), remotePath: path),
    );
  }

  if (!keys.contains('port') &&
      keys.containsAll(const {'host', 'username', 'path'})) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPort),
    );
  }
  if (!setEquals(keys, const {'host', 'port', 'username', 'path'})) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }
  final rawPort = parameters['port']!.single;
  final port = _parseDecimalPort(rawPort);
  if (port == null ||
      port < quickConnectMinPort ||
      port > quickConnectMaxPort) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPort),
    );
  }
  final host = parameters['host']!.single;
  final username = parameters['username']!.single;
  final path = parameters['path']!.single;
  if (!_validHost(host) || !_validUsername(username)) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidParameters),
    );
  }
  if (!_validRemotePath(path)) {
    return const DeepLinkParse.failure(
      DeepLinkFailure(DeepLinkFailureKind.invalidPath),
    );
  }
  return DeepLinkParse.request(
    HostDeepLink(host: host, port: port, username: username, remotePath: path),
  );
}

int? _parseDecimalPort(String value) {
  if (value.isEmpty) return null;

  var port = 0;
  for (final unit in value.codeUnits) {
    if (unit < 0x30 || unit > 0x39) return null;
    port = port * 10 + unit - 0x30;
    if (port > quickConnectMaxPort) return null;
  }
  return port;
}

bool _validHost(String value) {
  if (value.isEmpty || value.length > _maxEndpointValueLength) return false;
  for (final rune in value.runes) {
    if (rune <= 0x20 || rune == 0x7f) return false;
    if (const [0x2f, 0x5c, 0x40, 0x3f, 0x23, 0x26].contains(rune)) {
      return false;
    }
  }
  return true;
}

bool _validUsername(String value) {
  if (value.length > _maxEndpointValueLength) return false;
  return value.runes.every((rune) => rune >= 0x20 && rune != 0x7f);
}

bool _validRemotePath(String path) {
  if (!path.startsWith('/') || utf8.encode(path).length > _maxRemotePathBytes) {
    return false;
  }
  if (path == '/') return true;
  final components = path.substring(1).split('/');
  try {
    for (final component in components) {
      validatePathComponent(component);
    }
  } on FormatException {
    return false;
  }
  return true;
}

@immutable
class SafeDeepLinkDisplay {
  const SafeDeepLinkDisplay({
    required this.text,
    required this.removedControls,
  });

  final String text;
  final bool removedControls;
}

@immutable
final class SafeDeepLinkHostDisplay extends SafeDeepLinkDisplay {
  const SafeDeepLinkHostDisplay({
    required super.text,
    required super.removedControls,
    required this.internationalized,
    required this.mixedScripts,
    required this.unrecognizedScripts,
  });

  final bool internationalized;
  final bool mixedScripts;
  final bool unrecognizedScripts;
}

SafeDeepLinkDisplay safeDeepLinkDisplay(String value) {
  final safe = StringBuffer();
  var removed = false;
  for (final rune in value.runes) {
    if (_isUnsafeDisplayControl(rune)) {
      removed = true;
      continue;
    }
    safe.writeCharCode(rune);
  }
  return SafeDeepLinkDisplay(text: safe.toString(), removedControls: removed);
}

SafeDeepLinkHostDisplay safeDeepLinkHostDisplay(String value) {
  final safe = safeDeepLinkDisplay(value);
  var internationalized = false;
  var mixedScripts = false;
  var unrecognizedScripts = false;
  for (final label in safe.text.split(RegExp(r'[.\u3002\uff0e\uff61]'))) {
    final scripts = <_WritingScript>{};
    var hasUnclassified = false;
    for (final rune in label.runes) {
      if (rune > 0x7f) internationalized = true;
      final script = _scriptOf(rune);
      if (script != null) {
        scripts.add(script);
      } else if (_isUnclassifiedScriptCharacter(rune)) {
        hasUnclassified = true;
      }
    }
    mixedScripts |= _scriptsAreMixed(scripts);
    unrecognizedScripts |= hasUnclassified;
  }
  return SafeDeepLinkHostDisplay(
    text: safe.text,
    removedControls: safe.removedControls,
    internationalized: internationalized,
    mixedScripts: mixedScripts,
    unrecognizedScripts: unrecognizedScripts,
  );
}

bool _scriptsAreMixed(Set<_WritingScript> scripts) {
  if (scripts.length < 2) return false;
  if (scripts.difference(const {
    _WritingScript.han,
    _WritingScript.hiragana,
    _WritingScript.katakana,
  }).isEmpty) {
    return false;
  }
  if (scripts.difference(const {
    _WritingScript.han,
    _WritingScript.hangul,
  }).isEmpty) {
    return false;
  }
  return true;
}

bool _isUnclassifiedScriptCharacter(int rune) {
  if (rune <= 0x7f) return false;
  if ((rune >= 0x0300 && rune <= 0x036f) ||
      (rune >= 0x1ab0 && rune <= 0x1aff) ||
      (rune >= 0x1dc0 && rune <= 0x1dff) ||
      (rune >= 0x20d0 && rune <= 0x20ff) ||
      (rune >= 0xfe20 && rune <= 0xfe2f)) {
    return false;
  }
  return true;
}

bool _isUnsafeDisplayControl(int rune) =>
    rune < 0x20 ||
    (rune >= 0x7f && rune <= 0x9f) ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    _isDefaultIgnorableFormat(rune);

bool _isDefaultIgnorableFormat(int rune) =>
    rune == 0x00ad ||
    rune == 0x034f ||
    rune == 0x061c ||
    (rune >= 0x115f && rune <= 0x1160) ||
    (rune >= 0x17b4 && rune <= 0x17b5) ||
    (rune >= 0x180b && rune <= 0x180f) ||
    (rune >= 0x200b && rune <= 0x200f) ||
    (rune >= 0x202a && rune <= 0x202e) ||
    (rune >= 0x2060 && rune <= 0x206f) ||
    rune == 0x3164 ||
    (rune >= 0xfe00 && rune <= 0xfe0f) ||
    rune == 0xfeff ||
    rune == 0xffa0 ||
    (rune >= 0xfff0 && rune <= 0xfff8) ||
    (rune >= 0x1bca0 && rune <= 0x1bcaf) ||
    (rune >= 0x1d173 && rune <= 0x1d17a) ||
    (rune >= 0xe0000 && rune <= 0xe0fff);

enum _WritingScript {
  latin,
  greek,
  cyrillic,
  armenian,
  georgian,
  hebrew,
  arabic,
  devanagari,
  han,
  hiragana,
  katakana,
  hangul,
}

_WritingScript? _scriptOf(int rune) {
  if ((rune >= 0x41 && rune <= 0x5a) ||
      (rune >= 0x61 && rune <= 0x7a) ||
      (rune >= 0x00c0 && rune <= 0x024f)) {
    return _WritingScript.latin;
  }
  if (rune >= 0x0370 && rune <= 0x03ff) return _WritingScript.greek;
  if (rune >= 0x0400 && rune <= 0x052f) return _WritingScript.cyrillic;
  if (rune >= 0x0530 && rune <= 0x058f) return _WritingScript.armenian;
  if ((rune >= 0x10a0 && rune <= 0x10ff) ||
      (rune >= 0x1c90 && rune <= 0x1cbf)) {
    return _WritingScript.georgian;
  }
  if (rune >= 0x0590 && rune <= 0x05ff) return _WritingScript.hebrew;
  if ((rune >= 0x0600 && rune <= 0x06ff) ||
      (rune >= 0x0750 && rune <= 0x077f)) {
    return _WritingScript.arabic;
  }
  if (rune >= 0x0900 && rune <= 0x097f) return _WritingScript.devanagari;
  if (rune >= 0x3040 && rune <= 0x309f) return _WritingScript.hiragana;
  if (rune >= 0x30a0 && rune <= 0x30ff) return _WritingScript.katakana;
  if ((rune >= 0x3400 && rune <= 0x4dbf) ||
      (rune >= 0x4e00 && rune <= 0x9fff)) {
    return _WritingScript.han;
  }
  if ((rune >= 0x1100 && rune <= 0x11ff) ||
      (rune >= 0xac00 && rune <= 0xd7af)) {
    return _WritingScript.hangul;
  }
  return null;
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
