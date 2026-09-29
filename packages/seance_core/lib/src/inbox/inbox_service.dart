import 'dart:developer' as developer;

import 'package:seance_protocol/seance_protocol.dart';

import 'inbox_api.dart';
import 'inbox_stores.dart';

const String _inboxLoggerName = 'seance.inbox';
const int _warningLogLevel = 900;

/// How long a handled status is kept and published. Proposals live at most
/// [kInboxRetention], so a status older than this names nothing any server
/// still holds; the margin covers a device that was offline for a while.
const Duration kInboxStatusRetention = Duration(days: 30);

/// Where a proposal may run, or why it may not.
enum InboxTargetProblem {
  /// No server's label or host matches the proposal's `host`.
  noMatch,

  /// More than one server matches, and Séance never guesses.
  ambiguous,

  /// The match is outside the servers the app may target.
  notAllowed,
}

class InboxTarget {
  final ServerConfig? server;
  final InboxTargetProblem? problem;

  const InboxTarget.server(ServerConfig this.server) : problem = null;
  const InboxTarget.unassigned(InboxTargetProblem this.problem) : server = null;

  bool get isAssigned => server != null;
}

/// Resolve a proposal's `host` against the user's servers: the label first,
/// then the host name, both case-insensitive and exact. Only a unique match
/// that the app is allowed to target counts.
InboxTarget resolveInboxTarget(
  String host,
  InboxApp app,
  List<ServerConfig> servers,
) {
  final wanted = host.trim().toLowerCase();
  var matches = [
    for (final s in servers)
      if (s.label.trim().toLowerCase() == wanted) s,
  ];
  if (matches.isEmpty) {
    matches = [
      for (final s in servers)
        if (s.host.trim().toLowerCase() == wanted) s,
    ];
  }
  if (matches.isEmpty) {
    return const InboxTarget.unassigned(InboxTargetProblem.noMatch);
  }
  if (matches.length > 1) {
    return const InboxTarget.unassigned(InboxTargetProblem.ambiguous);
  }
  final server = matches.single;
  if (!app.allowsServer(server.id)) {
    return const InboxTarget.unassigned(InboxTargetProblem.notAllowed);
  }
  return InboxTarget.server(server);
}

/// A pending proposal as the UI shows it.
class PendingProposal {
  final InboxApp app;
  final CachedProposal cached;

  const PendingProposal(this.app, this.cached);

  InboxProposal get proposal => cached.proposal;
}

/// The outcome of [InboxService.claim].
enum InboxClaim {
  /// This device holds the proposal now and may stage it.
  claimed,

  /// Another device ran or dismissed it first.
  handledElsewhere,

  /// It expired, or its app was removed, before it could run.
  unavailable,
}

/// Fetches, opens and settles proposals, and connects and removes apps.
///
/// Does not sync records itself: statuses and apps travel through
/// `SyncCoordinator`, and the caller is expected to run a sync round before
/// [claim] so a status written by another device is seen first. [claim]'s
/// server-side delete closes the window that leaves.
class InboxService {
  final InboxApi api;
  final InboxAppStore apps;
  final InboxStatusStore statuses;
  final InboxCacheStore cache;
  final DateTime Function() now;

  InboxService({
    required this.api,
    required this.apps,
    required this.statuses,
    required this.cache,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  int get _nowMs => now().millisecondsSinceEpoch;

  /// Register a new app and return the pairing string's contents. The app is
  /// stored only once the server has accepted it, so a failed registration
  /// leaves nothing behind.
  Future<InboxPairing> addApp({
    required String name,
    required String serverUrl,
    List<String> allowedServerIds = const [],
  }) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > kInboxMaxNameChars) {
      throw ArgumentError.value(
        name,
        'name',
        'must be 1 to $kInboxMaxNameChars characters',
      );
    }
    final id = newInboxAppId();
    final token = newInboxToken();
    final key = newInboxKey();
    await api.createApp(
      CreateInboxAppRequest(appId: id, name: trimmed, token: token),
    );
    final stamp = _nowMs;
    await apps.putApp(InboxApp(
      id: id,
      name: trimmed,
      key: key,
      allowedServerIds: allowedServerIds,
      createdAt: stamp,
      updatedAt: stamp,
    ));
    return InboxPairing(url: serverUrl, appId: id, token: token, key: key);
  }

  Future<void> updateApp(
    String appId, {
    String? name,
    List<String>? allowedServerIds,
  }) async {
    final trimmed = name?.trim();
    if (trimmed != null &&
        (trimmed.isEmpty || trimmed.length > kInboxMaxNameChars)) {
      throw ArgumentError.value(
        name,
        'name',
        'must be 1 to $kInboxMaxNameChars characters',
      );
    }
    final app = await apps.getApp(appId);
    if (app == null || app.removed) return;
    await apps.putApp(app.copyWith(
      name: trimmed,
      allowedServerIds: allowedServerIds,
      updatedAt: _nowMs > app.updatedAt ? _nowMs : app.updatedAt + 1,
    ));
  }

  /// Revoke an app: the server drops its token and pending items, and the
  /// removal marker replaces the key on every device.
  ///
  /// The server goes first. Revoking the token is what actually stops the
  /// producer, so if that fails nothing changes here and the user can retry;
  /// forgetting the key first would leave a live token with no app in
  /// Settings to remove it from.
  Future<void> removeApp(String appId) async {
    await api.deleteApp(appId);
    final app = await apps.getApp(appId);
    if (app != null && !app.removed) {
      await apps.putApp(app.asRemoved(
        updatedAt: _nowMs > app.updatedAt ? _nowMs : app.updatedAt + 1,
      ));
    }
    final current = await cache.load();
    await cache.save(InboxCache(
      cursor: current.cursor,
      proposals: [
        for (final p in current.proposals)
          if (p.appId != appId) p,
      ],
      failures: {...current.failures}..remove(appId),
    ));
  }

  /// Fetch new items, open and validate them, and return what is pending.
  ///
  /// An item that cannot be opened or validated is deleted on the server and
  /// counted against its app, so a misconfigured producer shows up in
  /// Settings instead of filling the queue. An item for an app this device
  /// does not know yet is left alone, and the cursor stops before it, because
  /// the app record may simply not have synced here yet.
  Future<List<PendingProposal>> refresh() async {
    final current = await cache.load();
    final items = await api.listItems(since: current.cursor);
    final proposals = [...current.proposals];
    final failures = {...current.failures};
    var cursor = current.cursor;
    var blocked = false;

    for (final item in items) {
      final app = await apps.getApp(item.appId);
      if (app == null) {
        blocked = true;
        continue;
      }
      if (!blocked && item.received > cursor) cursor = item.received;
      if (proposals.any((p) => p.itemId == item.itemId)) continue;

      if (app.removed) {
        await _deleteQuietly(item.appId, item.itemId);
        continue;
      }
      final CachedProposal cached;
      try {
        final clear = await InboxCrypto.open(app.key!, app.id, item.blob);
        cached = CachedProposal(
          appId: app.id,
          itemId: item.itemId,
          received: item.received,
          proposal: InboxProposal.parse(clear, now: now()),
        );
      } catch (error) {
        // The type only: the message of a validation error can quote the
        // producer's input, which is not for the log.
        developer.log(
          'Inbox item ${item.itemId} from app ${app.id} refused: '
          '${error.runtimeType}',
          name: _inboxLoggerName,
          level: _warningLogLevel,
        );
        failures[app.id] = (failures[app.id] ?? 0) + 1;
        await _deleteQuietly(item.appId, item.itemId);
        continue;
      }
      // A proposal id is unique per app. A repeat is a replay (or a
      // producer bug) and must not re-announce something already handled.
      final handled =
          await statuses.getStatus(app.id, cached.proposal.id) != null;
      final duplicate = proposals.any(
        (p) => p.appId == app.id && p.proposal.id == cached.proposal.id,
      );
      if (handled || duplicate) {
        await _deleteQuietly(item.appId, item.itemId);
        continue;
      }
      proposals.add(cached);
    }

    await cache.save(InboxCache(
      cursor: cursor,
      proposals: await _live(proposals),
      failures: failures,
    ));
    return pending();
  }

  /// The proposals still waiting for the user, newest first. Reads only local
  /// state, so it reflects statuses another device synced in since the last
  /// [refresh].
  Future<List<PendingProposal>> pending() async {
    final current = await cache.load();
    final out = <PendingProposal>[];
    for (final cached in await _live(current.proposals)) {
      final app = await apps.getApp(cached.appId);
      if (app == null || app.removed) continue;
      out.add(PendingProposal(app, cached));
    }
    out.sort((a, b) => b.cached.received.compareTo(a.cached.received));
    return out;
  }

  /// Items refused per app since it was connected on this device.
  Future<Map<String, int>> failures() async => (await cache.load()).failures;

  /// Take a proposal before running it. Records `ran` only once the server
  /// has confirmed this device removed the item, so two devices cannot both
  /// run it. A breached server answering "already gone" can stop a proposal
  /// from running, but cannot make one run.
  Future<InboxClaim> claim(PendingProposal pending) async {
    final cached = pending.cached;
    final app = await apps.getApp(cached.appId);
    if (app == null || app.removed || cached.proposal.isExpiredAt(now())) {
      return InboxClaim.unavailable;
    }
    if (await statuses.getStatus(cached.appId, cached.proposal.id) != null) {
      await _forget(cached);
      return InboxClaim.handledElsewhere;
    }
    final removed = await api.deleteItem(cached.appId, cached.itemId);
    if (!removed) {
      await _forget(cached);
      return InboxClaim.handledElsewhere;
    }
    await _settle(cached, InboxStatusState.ran);
    return InboxClaim.claimed;
  }

  /// Dismiss a proposal. The status is written first, so it stops being
  /// announced everywhere even if the server cannot be reached now; the item
  /// then goes at retention, and any device that fetches it meanwhile finds
  /// the status and deletes it.
  Future<void> dismiss(PendingProposal pending) async {
    final cached = pending.cached;
    await _settle(cached, InboxStatusState.dismissed);
    await _deleteQuietly(cached.appId, cached.itemId);
  }

  /// Drop statuses too old to name anything a server still holds.
  Future<void> pruneStatuses() async {
    final cutoff = _nowMs - kInboxStatusRetention.inMilliseconds;
    for (final status in await statuses.listStatuses()) {
      if (status.updatedAt < cutoff) {
        await statuses.deleteStatus(status.appId, status.proposalId);
      }
    }
  }

  Future<void> _settle(CachedProposal cached, InboxStatusState state) async {
    await statuses.putStatus(InboxStatus(
      appId: cached.appId,
      proposalId: cached.proposal.id,
      state: state,
      updatedAt: _nowMs,
    ));
    await _forget(cached);
  }

  Future<void> _forget(CachedProposal cached) async {
    final current = await cache.load();
    await cache.save(InboxCache(
      cursor: current.cursor,
      proposals: [
        for (final p in current.proposals)
          if (p.itemId != cached.itemId) p,
      ],
      failures: current.failures,
    ));
  }

  /// Cached proposals that are neither expired nor handled.
  Future<List<CachedProposal>> _live(List<CachedProposal> proposals) async {
    final at = now();
    final out = <CachedProposal>[];
    for (final p in proposals) {
      if (p.proposal.isExpiredAt(at)) continue;
      if (await statuses.getStatus(p.appId, p.proposal.id) != null) continue;
      out.add(p);
    }
    return out;
  }

  /// Best effort: the server drops the item at retention anyway, and a
  /// failure here must not cost the rest of the refresh.
  Future<void> _deleteQuietly(String appId, String itemId) async {
    try {
      await api.deleteItem(appId, itemId);
    } catch (error) {
      developer.log(
        'Could not delete inbox item $itemId: ${error.runtimeType}',
        name: _inboxLoggerName,
        level: _warningLogLevel,
      );
    }
  }
}
