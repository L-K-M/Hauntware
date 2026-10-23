/// Séance's intake for `seance://connect` links (docs/design/suite-links.md
/// section 6): a bounded queue, one review at a time, and the starting
/// folder staged at a verified empty prompt.
///
/// A link only names a server Séance already has and, optionally, a folder
/// to start in. Every link is reviewed before anything connects, the review
/// shows Séance's own record of the server rather than link text, and no
/// link can run a command: the `cd` is typed at the prompt and Enter is
/// left to the user.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import 'xterm_engine.dart';

/// The most links waiting behind the one under review. Large enough for a
/// burst of hand-offs, small enough that a link flood can neither grow
/// memory nor keep dialogs coming; a link beyond it is dropped and counted.
const int seanceLinkQueueLimit = 16;

/// How long a link's fresh tab may take, once connected, to show an empty
/// integrated prompt before its folder is given up.
const Duration seanceLinkPromptTimeout = Duration(seconds: 20);

/// The most waiting links a review names; the rest are a count.
const int seanceLinkReviewWaitingShown = 2;

/// Why a link did not reach a review.
enum SeanceLinkNoticeKind {
  /// Not a `seance://connect` link at all.
  notSeanceLink,

  /// A key outside the link's form, a repeated key or a bad value.
  unacceptedParameters,

  /// The starting folder failed the link grammar.
  invalidFolder,

  /// No saved server matches.
  unknownServer,

  /// More than one saved server matches the identity form.
  ambiguousServer,

  /// Links were dropped at the queue limit.
  ignoredLinks,
}

@immutable
final class SeanceLinkNotice {
  const SeanceLinkNotice(this.kind, {this.count = 0});

  final SeanceLinkNoticeKind kind;

  /// For [SeanceLinkNoticeKind.ignoredLinks], how many were dropped.
  final int count;
}

/// A link resolved to a saved server: what Connect would open.
@immutable
final class SeanceLinkTarget {
  const SeanceLinkTarget({required this.server, this.cwd});

  final ServerConfig server;

  /// The starting folder, as the link gave it; it has passed the link
  /// grammar, so `buildChangeDirectoryCommand` accepts it.
  final String? cwd;
}

/// The queue behind the link under review, as the review shows it.
@immutable
final class SeanceLinkQueue {
  const SeanceLinkQueue({
    this.waitingLabels = const [],
    this.waitingCount = 0,
    this.ignoredCount = 0,
  });

  /// The saved labels of up to [seanceLinkReviewWaitingShown] waiting
  /// links, null for one that names no single saved server.
  final List<String?> waitingLabels;

  /// Every link waiting behind the one under review.
  final int waitingCount;

  /// Links dropped at the queue limit since the last review.
  final int ignoredCount;
}

/// What a review shows: the link in hand, and the queue behind it, which
/// updates while the review is open.
abstract interface class SeanceLinkReview {
  SeanceLinkTarget get target;

  ValueListenable<SeanceLinkQueue> get queue;

  /// Records the queue the review last showed, so "Discard waiting links"
  /// drops exactly those links and the dropped-link count clears only
  /// what was shown: neither reaches one that arrived unseen.
  void markShown(SeanceLinkQueue shown);
}

enum SeanceLinkDecision {
  cancel,
  connect,

  /// Cancel this link and drop the waiting links the review last showed
  /// ([SeanceLinkReview.markShown]).
  discardWaiting,
}

/// The app side of the intake: the saved servers, the review dialog, the
/// connect and the notices.
abstract interface class SeanceLinkHandler {
  /// The saved servers. Open tabs' snapshots are not a saved server.
  List<ServerConfig> get servers;

  Future<SeanceLinkDecision> review(SeanceLinkReview review);

  Future<void> connect(SeanceLinkTarget target);

  Future<void> showNotice(SeanceLinkNotice notice);
}

typedef SeanceLinkErrorSink = void Function(Object error, StackTrace stack);

/// The queue between link delivery and the [SeanceLinkHandler].
///
/// Links are queued from the first [add], before a handler exists, so a
/// cold-start link waits for the app to load. Nothing is written to disk:
/// a link survives no restart, and a sender whose link was lost sends it
/// again. A handler that throws has its link put back at the head, and the
/// queue waits for the next link or [activate] (Poltergeist's rule).
final class SeanceLinkIntake {
  SeanceLinkIntake({SeanceLinkErrorSink? onError})
    : _onError = onError ?? _reportFlutterError;

  final SeanceLinkErrorSink _onError;
  final ListQueue<_Pending> _pending = ListQueue();
  SeanceLinkHandler? _handler;
  _Pending? _current;
  _Review? _review;
  bool _running = false;
  bool _paused = false;
  int _ignored = 0;
  Completer<void>? _idle;

  /// Completes when every queued link has been handled, the queue is
  /// waiting for a handler, or a handler error paused it until the next
  /// link or [activate].
  Future<void> get idle => _idle?.future ?? Future<void>.value();

  void add(Uri uri) {
    final parsed = parseSeanceConnect(uri);
    final pending = _Pending(parsed.request, parsed.failure);
    final key = pending.key;
    final duplicate =
        key != null &&
        (_current?.key == key || _pending.any((item) => item.key == key));
    if (!duplicate) {
      if (_pending.length >= seanceLinkQueueLimit) {
        _ignored++;
      } else {
        _pending.addLast(pending);
      }
    }
    final review = _review;
    final handler = _handler;
    if (review != null && handler != null) {
      review.queue.value = _queueState(handler.servers);
    }
    _paused = false;
    _pump();
  }

  void activate(SeanceLinkHandler handler) {
    _handler = handler;
    _paused = false;
    _pump();
  }

  /// Stops handing links to [handler]; the one in hand finishes.
  void deactivate(SeanceLinkHandler handler) {
    if (identical(_handler, handler)) _handler = null;
  }

  void _pump() {
    if (_running) return;
    if (_pending.isEmpty && _ignored == 0) {
      _completeIdle();
      return;
    }
    _idle ??= Completer<void>();
    if (_handler == null || _paused) {
      _completeIdle();
      return;
    }
    _running = true;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    try {
      while (true) {
        final handler = _handler;
        if (handler == null || _paused) break;
        if (_pending.isEmpty) {
          if (_ignored == 0) break;
          // Dropped links are reported even when no review is left to
          // carry the count.
          final ignored = _ignored;
          _ignored = 0;
          if (!await _guard(
            () => handler.showNotice(
              SeanceLinkNotice(
                SeanceLinkNoticeKind.ignoredLinks,
                count: ignored,
              ),
            ),
          )) {
            _ignored += ignored;
            break;
          }
          continue;
        }
        final item = _pending.removeFirst();
        _current = item;
        final handled = await _guard(() => _handle(handler, item));
        _current = null;
        if (!handled) {
          _pending.addFirst(item);
          _paused = true;
        }
      }
    } finally {
      _running = false;
      _completeIdle();
    }
  }

  Future<void> _handle(SeanceLinkHandler handler, _Pending item) async {
    final request = item.request;
    if (request == null) {
      await handler.showNotice(SeanceLinkNotice(_noticeFor(item.failure!)));
      return;
    }

    final resolved = resolveSeanceLink(request, handler.servers);
    final server = resolved.server;
    if (server == null) {
      await handler.showNotice(SeanceLinkNotice(resolved.miss!));
      return;
    }

    final cwd = switch (request) {
      SeanceServerConnect(:final cwd) => cwd,
      SeanceIdentityConnect() => null,
    };
    final review = _Review(
      SeanceLinkTarget(server: server, cwd: cwd),
      _queueState(handler.servers),
    );
    _review = review;
    final SeanceLinkDecision decision;
    try {
      decision = await handler.review(review);
    } finally {
      _review = null;
      review.queue.dispose();
    }
    // The drops the review showed are not reported again; any that arrived
    // after it last drew carry to the next review or notice.
    _ignored -= review.shown?.ignoredCount ?? 0;
    switch (decision) {
      case SeanceLinkDecision.cancel:
        return;
      case SeanceLinkDecision.discardWaiting:
        // Only the links the review showed: they are the oldest, since the
        // queue only ever appends.
        final shown = review.shown?.waitingCount ?? 0;
        for (var i = 0; i < shown && _pending.isNotEmpty; i++) {
          _pending.removeFirst();
        }
        return;
      case SeanceLinkDecision.connect:
        await handler.connect(review.target);
    }
  }

  SeanceLinkQueue _queueState(List<ServerConfig> servers) => SeanceLinkQueue(
    waitingLabels: [
      for (final pending in _pending.take(seanceLinkReviewWaitingShown))
        _labelOf(pending, servers),
    ],
    waitingCount: _pending.length,
    ignoredCount: _ignored,
  );

  Future<bool> _guard(Future<void> Function() body) async {
    try {
      await body();
      return true;
    } catch (error, stack) {
      _onError(error, stack);
      return false;
    }
  }

  void _completeIdle() {
    if (_running) return;
    final idle = _idle;
    if (idle == null) return;
    _idle = null;
    idle.complete();
  }

  static void _reportFlutterError(Object error, StackTrace stack) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'seance link intake',
      ),
    );
  }
}

/// The saved server [request] names, or why none is named: the id form
/// looks up the saved list by id, the identity form by host, port and
/// username, and only a single match counts (docs/design/suite-links.md
/// section 3).
({ServerConfig? server, SeanceLinkNoticeKind? miss}) resolveSeanceLink(
  SeanceConnectRequest request,
  List<ServerConfig> servers,
) {
  final matches = switch (request) {
    SeanceServerConnect(:final serverId) => [
      for (final server in servers)
        if (server.id.toLowerCase() == serverId) server,
    ],
    SeanceIdentityConnect(:final endpointKey) => [
      for (final server in servers)
        if (SeanceIdentityConnect(
              host: server.host,
              port: server.port,
              username: server.username,
            ).endpointKey ==
            endpointKey)
          server,
    ],
  };
  return switch (matches) {
    [final server] => (server: server, miss: null),
    [] => (server: null, miss: SeanceLinkNoticeKind.unknownServer),
    _ => (server: null, miss: SeanceLinkNoticeKind.ambiguousServer),
  };
}

String? _labelOf(_Pending pending, List<ServerConfig> servers) {
  final request = pending.request;
  if (request == null) return null;
  return resolveSeanceLink(request, servers).server?.label;
}

SeanceLinkNoticeKind _noticeFor(DeepLinkFailure failure) =>
    switch (failure.kind) {
      DeepLinkFailureKind.unsupportedLink => SeanceLinkNoticeKind.notSeanceLink,
      DeepLinkFailureKind.invalidPath => SeanceLinkNoticeKind.invalidFolder,
      DeepLinkFailureKind.serverNotFound => SeanceLinkNoticeKind.unknownServer,
      DeepLinkFailureKind.invalidParameters ||
      DeepLinkFailureKind.invalidPort =>
        SeanceLinkNoticeKind.unacceptedParameters,
    };

final class _Review implements SeanceLinkReview {
  _Review(this.target, SeanceLinkQueue queue) : queue = ValueNotifier(queue);

  @override
  final SeanceLinkTarget target;

  @override
  final ValueNotifier<SeanceLinkQueue> queue;

  SeanceLinkQueue? shown;

  @override
  void markShown(SeanceLinkQueue shown) => this.shown = shown;
}

final class _Pending {
  _Pending(this.request, this.failure);

  final SeanceConnectRequest? request;
  final DeepLinkFailure? failure;

  /// Identical requests coalesce; failures never do.
  Object? get key => switch (request) {
    SeanceServerConnect(:final serverId, :final cwd) => ('id', serverId, cwd),
    SeanceIdentityConnect(:final endpointKey) => ('identity', endpointKey),
    null => null,
  };
}

/// How a link's starting folder fared in its fresh tab.
enum SeanceLinkFolderOutcome {
  /// The `cd` is at the prompt, not submitted.
  staged,

  /// The tab failed, disconnected or was closed before it connected or
  /// before its prompt was ready.
  ended,

  /// The shell reports no integration, so Séance cannot see a prompt.
  shellIntegrationRequired,

  /// No empty prompt within [seanceLinkPromptTimeout].
  promptNotReady,

  /// Something was typed at the prompt first.
  pendingInput,
}

/// Waits for a fresh tab to connect and show an empty integrated prompt
/// on [engine], then stages `cd` to [folder] there without pressing Enter.
///
/// [status] reads the tab's status, null once it has left the strip, and
/// [changes] notifies when that may have changed. The wait has no bound
/// while the tab is connecting, since host-key and credential prompts wait
/// on the user, and is bounded by [timeout] once it has connected.
Future<SeanceLinkFolderOutcome> stageLinkFolder({
  required XtermTerminalEngine engine,
  required TerminalStatus? Function() status,
  required Listenable changes,
  required String folder,
  Duration timeout = seanceLinkPromptTimeout,
}) {
  final done = Completer<SeanceLinkFolderOutcome>();
  Timer? deadline;

  // Staging types at the prompt, which changes the prompt state and calls
  // back in here before the first call has returned.
  var staging = false;

  void check() {
    if (done.isCompleted || staging) return;
    switch (status()) {
      case TerminalStatus.connecting:
        return;
      case null || TerminalStatus.disconnected || TerminalStatus.error:
        done.complete(SeanceLinkFolderOutcome.ended);
        return;
      case TerminalStatus.connected:
        break;
    }
    deadline ??= Timer(timeout, () {
      if (done.isCompleted) return;
      done.complete(
        engine.shellIntegration.value.shell == null
            ? SeanceLinkFolderOutcome.shellIntegrationRequired
            : SeanceLinkFolderOutcome.promptNotReady,
      );
    });
    final state = engine.shellIntegration.value;
    if (state.shell == null ||
        state.phase != TerminalPromptPhase.acceptingInput) {
      return;
    }
    staging = true;
    done.complete(switch (engine.stageChangeDirectory(folder)) {
      TerminalStageResult.staged => SeanceLinkFolderOutcome.staged,
      TerminalStageResult.pendingInput => SeanceLinkFolderOutcome.pendingInput,
      TerminalStageResult.shellIntegrationRequired =>
        SeanceLinkFolderOutcome.shellIntegrationRequired,
      // The link grammar refuses every folder the builder would, so an
      // invalid path here is a prompt that changed under the check.
      TerminalStageResult.promptNotReady ||
      TerminalStageResult.invalidPath => SeanceLinkFolderOutcome.promptNotReady,
    });
  }

  changes.addListener(check);
  engine.shellIntegration.addListener(check);
  check();
  return done.future.whenComplete(() {
    deadline?.cancel();
    changes.removeListener(check);
    engine.shellIntegration.removeListener(check);
  });
}
