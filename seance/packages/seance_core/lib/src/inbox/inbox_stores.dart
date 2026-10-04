import 'package:seance_protocol/seance_protocol.dart';

/// The apps this account has connected, including their keys. The app backs
/// the keys with the vault; see `FileInboxAppStore`.
abstract class InboxAppStore {
  Future<List<InboxApp>> listApps();
  Future<InboxApp?> getApp(String id);
  Future<void> putApp(InboxApp app);
}

/// Which proposals have been handled, on any device.
abstract class InboxStatusStore {
  Future<List<InboxStatus>> listStatuses();
  Future<InboxStatus?> getStatus(String appId, String proposalId);
  Future<void> putStatus(InboxStatus status);
  Future<void> deleteStatus(String appId, String proposalId);
}

/// A proposal this device fetched and could open, kept until it is handled
/// or expires. Device-local and never synced: every device fetches the same
/// items from the server.
class CachedProposal {
  final String appId;
  final String itemId;
  final int received;
  final InboxProposal proposal;

  const CachedProposal({
    required this.appId,
    required this.itemId,
    required this.received,
    required this.proposal,
  });

  Map<String, dynamic> toJson() => {
        'app': appId,
        'item': itemId,
        'received': received,
        'proposal': proposal.toJson(),
      };

  /// Re-validated on load like on arrival, but against the proposal's own
  /// creation time: a cached proposal was valid when fetched, and expiry is
  /// checked separately.
  factory CachedProposal.fromJson(Map<String, dynamic> json) {
    final proposal = (json['proposal'] as Map).cast<String, dynamic>();
    return CachedProposal(
      appId: json['app'] as String,
      itemId: json['item'] as String,
      received: (json['received'] as num).toInt(),
      proposal: InboxProposal.fromJson(
        proposal,
        now: DateTime.fromMillisecondsSinceEpoch(
          ((proposal['created'] as num?)?.toInt() ?? 0) * 1000,
        ),
      ),
    );
  }
}

/// This device's view of the server queue: the fetched proposals, the
/// `since` cursor, and per-app counts of items that could not be opened.
class InboxCache {
  final int cursor;
  final List<CachedProposal> proposals;
  final Map<String, int> failures;

  const InboxCache({
    this.cursor = 0,
    this.proposals = const [],
    this.failures = const {},
  });

  Map<String, dynamic> toJson() => {
        'cursor': cursor,
        'proposals': [for (final p in proposals) p.toJson()],
        if (failures.isNotEmpty) 'failures': failures,
      };

  /// A damaged entry costs only itself.
  factory InboxCache.fromJson(Map<String, dynamic> json) {
    final proposals = <CachedProposal>[];
    for (final raw in json['proposals'] as List? ?? const []) {
      try {
        proposals.add(
          CachedProposal.fromJson((raw as Map).cast<String, dynamic>()),
        );
      } catch (_) {
        continue;
      }
    }
    return InboxCache(
      cursor: (json['cursor'] as num?)?.toInt() ?? 0,
      proposals: proposals,
      failures: {
        for (final e
            in ((json['failures'] as Map?) ?? const {}).entries)
          if (e.key is String && e.value is num)
            e.key as String: (e.value as num).toInt(),
      },
    );
  }
}

abstract class InboxCacheStore {
  Future<InboxCache> load();
  Future<void> save(InboxCache cache);
}

class InMemoryInboxAppStore implements InboxAppStore {
  final Map<String, InboxApp> _apps = {};

  @override
  Future<List<InboxApp>> listApps() async => _apps.values.toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  @override
  Future<InboxApp?> getApp(String id) async => _apps[id];

  @override
  Future<void> putApp(InboxApp app) async => _apps[app.id] = app;
}

class InMemoryInboxStatusStore implements InboxStatusStore {
  final Map<String, InboxStatus> _statuses = {};

  @override
  Future<List<InboxStatus>> listStatuses() async => _statuses.values.toList();

  @override
  Future<InboxStatus?> getStatus(String appId, String proposalId) async =>
      _statuses[InboxStatus.recordIdFor(appId, proposalId)];

  @override
  Future<void> putStatus(InboxStatus status) async =>
      _statuses[status.recordId] = status;

  @override
  Future<void> deleteStatus(String appId, String proposalId) async =>
      _statuses.remove(InboxStatus.recordIdFor(appId, proposalId));
}

class InMemoryInboxCacheStore implements InboxCacheStore {
  InboxCache cache = const InboxCache();

  @override
  Future<InboxCache> load() async => cache;

  @override
  Future<void> save(InboxCache value) async => cache = value;
}
