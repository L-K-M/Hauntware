/// Validated `poltergeist://` intake on the suite's shared link queue.
///
/// Native delivery stops here. The queue hands domain requests to the
/// active workspace, which alone may show UI or open a pane.
library;

import 'package:flutter/foundation.dart';
import 'package:poltergeist_core/poltergeist_core.dart'
    show
        FailedLinkEntry,
        DirectLinkEntry,
        HostDeepLink,
        LinkErrorSink,
        LinkQueue,
        ReviewedLinkEntry,
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

/// Poltergeist's links on the shared queue: a host link is reviewed, a
/// catalog link opens directly, and a link that does not parse is a
/// failure.
typedef DeepLinkCoordinator = LinkQueue<HostDeepLink, ServerDeepLink>;

/// The coordinator [main] feeds from launch. Repeats of a host link
/// coalesce by endpoint, keeping the newest folder and counting the
/// activations; catalog links and failures never coalesce.
DeepLinkCoordinator createDeepLinkCoordinator({LinkErrorSink? onError}) =>
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
      onError: onError ?? _reportFlutterError,
    );

void _reportFlutterError(Object error, StackTrace stackTrace) {
  FlutterError.reportError(
    FlutterErrorDetails(exception: error, stack: stackTrace),
  );
}

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
