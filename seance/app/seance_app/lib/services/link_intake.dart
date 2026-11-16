/// Séance's intake for `seance://connect` links (docs/design/suite-links.md
/// section 6): the suite's shared [LinkQueue], one review at a time, and
/// the starting folder staged at a verified empty prompt.
///
/// A link only names a server Séance already has and, optionally, a folder
/// to start in. Every link is reviewed before anything connects, the review
/// shows Séance's own record of the server rather than link text, and no
/// link can run a command: the `cd` is typed at the prompt and Enter is
/// left to the user.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:seance_core/seance_core.dart';

import '../app_state.dart';
import 'xterm_engine.dart';

/// How long a link's fresh tab may take, once connected, to show an empty
/// integrated prompt before its folder is given up.
const Duration seanceLinkPromptTimeout = Duration(seconds: 20);

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

/// Séance's links on the shared queue: every `seance://connect` request is
/// reviewed, and none skips the review (`Never`).
typedef SeanceLinkIntake = LinkQueue<SeanceConnectRequest, Never>;

/// The intake [main] feeds from launch. Identical requests (the same id
/// and folder, or the same identity) coalesce; failures never do.
SeanceLinkIntake createSeanceLinkIntake({LinkErrorSink? onError}) => LinkQueue(
  classify: _classify,
  keyOf: _keyOf,
  // A repeat is the same request, so the queued one stands.
  coalesce: (queued, _) => queued,
  onError: onError ?? _reportFlutterError,
);

LinkEntry<SeanceConnectRequest, Never> _classify(Uri uri) {
  final parsed = parseSeanceConnect(uri);
  final request = parsed.request;
  if (request == null) return FailedLinkEntry(parsed.failure!);
  return ReviewedLinkEntry(request);
}

Object _keyOf(SeanceConnectRequest request) => switch (request) {
  SeanceServerConnect(:final serverId, :final cwd) => ('id', serverId, cwd),
  SeanceIdentityConnect(:final endpointKey) => ('identity', endpointKey),
};

void _reportFlutterError(Object error, StackTrace stack) {
  FlutterError.reportError(
    FlutterErrorDetails(
      exception: error,
      stack: stack,
      library: 'seance link intake',
    ),
  );
}

/// What Séance's review dialog shows: the queue's review of a request,
/// with the saved server it resolved to.
final class SeanceLinkReview {
  const SeanceLinkReview({
    required this.target,
    required this.link,
    required this._servers,
  });

  final SeanceLinkTarget target;

  /// The shared review: the waiting requests, which follow arrivals, the
  /// cancellation and the record of what was shown.
  final LinkReview<SeanceConnectRequest> link;

  final List<ServerConfig> _servers;

  /// The saved label of a waiting request, null for one that names no
  /// single saved server.
  String? labelOf(SeanceConnectRequest request) =>
      resolveSeanceLink(request, _servers).server?.label;
}

/// The app's window on the intake: the saved servers, the review dialog,
/// the connect and the notices.
abstract interface class SeanceLinkHost {
  /// The saved servers. Open tabs' snapshots are not a saved server.
  List<ServerConfig> get servers;

  /// Shows [review] until decided or until its link is cancelled.
  Future<LinkReviewDecision> review(SeanceLinkReview review);

  Future<void> connect(SeanceLinkTarget target);

  Future<void> showNotice(SeanceLinkNotice notice);
}

/// Séance's rules between the queue and the [SeanceLinkHost]: a request
/// resolves against the saved servers when it is reviewed and again when
/// it connects, so a server removed in between is not opened, and every
/// failure or miss is a notice.
final class SeanceLinkHandler
    implements LinkQueueHandler<SeanceConnectRequest, Never> {
  SeanceLinkHandler(this._host);

  final SeanceLinkHost _host;

  @override
  Future<LinkReviewDecision> review(
    LinkReview<SeanceConnectRequest> review,
  ) async {
    final request = review.snapshot.current;
    final resolved = _resolve(request);
    final server = resolved.server;
    if (server == null) {
      await _host.showNotice(SeanceLinkNotice(resolved.miss!));
      return LinkReviewDecision.cancel;
    }
    return _host.review(
      SeanceLinkReview(
        target: SeanceLinkTarget(server: server, cwd: _cwdOf(request)),
        link: review,
        servers: _host.servers,
      ),
    );
  }

  @override
  Future<LinkOpenResult> open(
    SeanceConnectRequest link,
    LinkOperation operation,
  ) async {
    final resolved = _resolve(link);
    final server = resolved.server;
    if (server == null) {
      await _host.showNotice(SeanceLinkNotice(resolved.miss!));
      return LinkOpenResult.committed;
    }
    await _host.connect(SeanceLinkTarget(server: server, cwd: _cwdOf(link)));
    return LinkOpenResult.committed;
  }

  /// Unreachable: Séance reviews every link.
  @override
  Future<LinkOpenResult> openDirect(Never link, LinkOperation operation) =>
      link;

  @override
  Future<void> showFailure(DeepLinkFailure failure, LinkOperation operation) =>
      _host.showNotice(SeanceLinkNotice(_noticeFor(failure)));

  @override
  Future<void> showIgnoredLinks(int count, LinkOperation operation) =>
      _host.showNotice(
        SeanceLinkNotice(SeanceLinkNoticeKind.ignoredLinks, count: count),
      );

  ({ServerConfig? server, SeanceLinkNoticeKind? miss}) _resolve(
    SeanceConnectRequest request,
  ) => resolveSeanceLink(request, _host.servers);

  static String? _cwdOf(SeanceConnectRequest request) => switch (request) {
    SeanceServerConnect(:final cwd) => cwd,
    SeanceIdentityConnect() => null,
  };
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

SeanceLinkNoticeKind _noticeFor(DeepLinkFailure failure) =>
    switch (failure.kind) {
      DeepLinkFailureKind.unsupportedLink => SeanceLinkNoticeKind.notSeanceLink,
      DeepLinkFailureKind.invalidPath => SeanceLinkNoticeKind.invalidFolder,
      DeepLinkFailureKind.serverNotFound => SeanceLinkNoticeKind.unknownServer,
      DeepLinkFailureKind.invalidParameters ||
      DeepLinkFailureKind.invalidPort =>
        SeanceLinkNoticeKind.unacceptedParameters,
    };

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
