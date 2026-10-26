/// One server's Docker watches (03 §7.12 DKE-02, CST-01; M7, M9): the
/// `/events` stream while any watch holds, the lists it keeps current,
/// and the list stats.
///
/// ```text
///   attach(endpoint) ─▶ GET /events (since the last event, when the
///     │                 stream was lost 60 s ago or less on this socket)
///     ├─ resume ─▶ re-list every watched list (a restarted daemon
///     │            replays nothing)
///     ├─ no resume ─▶ full re-list, and a new stats baseline
///     ▼
///   event ─▶ planEventRefresh ─▶ container ids, or whole lists
///     └─ 250 ms batch ─▶ ids: one list filtered to them, merged in
///                        lists: read again
///   stream lost ─▶ open again after 1 s, 2 s, ... 30 s
///   no channel for the stream (a relay's follower share full, or
///     low-session mode; M9) ─▶ re-list every 15 s, trying it again then
///   every 5 s ─▶ one-shot stats for statsFor (4 at once on streamlocal,
///                one at a time on a relay or in low-session mode) ─▶ deltas
///   stacks sent with a project not checked ─▶ check its files, then
///                send the stacks again with its verdict
///   detach (endpoint dropped) keeps the lists and the resume point;
///   close (last unwatch, session end) forgets them
/// ```
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:klabautermann_docker/klabautermann_docker.dart';

import '../engine/protocol.dart';
import 'docker_ladder.dart';
import 'inspect_masking.dart';
import 'stack_sources.dart';

/// Events arriving within this window after the first are refreshed
/// together (DKE-02's debounce [E]), so a `compose up` re-lists once.
const kDockerEventBatch = Duration(milliseconds: 250);

/// The list stats cadence (CST-01 [E]): 03 §6.4's desktop overview
/// column.
const kDockerStatsInterval = Duration(seconds: 5);

/// One-shot stats reads at once over streamlocal (03 §7.12 CST-01). A
/// relay reads one at a time: each connection there holds a session
/// channel (M9). So does low-session mode, on every rank.
const kDockerStatsInFlight = 4;

/// How often the watched lists are read again while the events stream
/// has no channel (M9 [E]): a relay whose follower share is full, or
/// low-session mode.
const kDockerListPoll = Duration(seconds: 15);

/// The most containers one batch re-reads by id [E]; more re-list them
/// all.
const _targetedMax = 16;

/// The newest events timeline entries the watcher keeps (DKE-03 [E]).
const kDockerEventsKept = 500;

/// The event types the stream asks for (03 §7.12 DKE-02).
const _eventTypes = ['container', 'image', 'volume', 'network'];

/// Container actions that change nothing a list shows: a health check
/// alone execs every interval.
const _quietActions = {
  'attach',
  'detach',
  'resize',
  'top',
  'archive-path',
  'extract-to-dir',
  'export',
  'copy',
};

const _retryBase = Duration(seconds: 1);
const _retryCap = Duration(seconds: 30);

/// The endpoint a [DockerWatcher] reads over, as the router hands it.
abstract interface class DockerWatchTarget {
  DockerRank get rank;
  String get socketPath;

  /// Runs [read] over the endpoint's pooled connections, which stay open
  /// while it runs.
  Future<T> use<T>(Future<T> Function(DockerClient client) read);

  /// Whether 03 §5.2's low-session mode holds, which reads stats one at
  /// a time (M9).
  bool get lowSession;

  /// A connection of its own for the events stream, or null when it gets
  /// no channel: on a relay it takes a follower slot, and gets none in
  /// low-session mode (M9).
  DockerStreamLease? openEvents();

  /// The endpoint's stack checks (03 §7.16 STK-01).
  StackSources get stacks;
}

/// A stream's client over a connection of its own, with the channel slot
/// it holds on a relay, which [close] gives back (M9).
final class DockerStreamLease {
  DockerStreamLease(this.client, {this._release});

  final DockerClient client;
  void Function()? _release;

  /// Closes the connection and gives back its slot; once.
  Future<void> close() {
    final release = _release;
    _release = null;
    release?.call();
    return client.close();
  }
}

/// [failure] read from a Docker call that threw [error], and whether the
/// connection dropped, so the endpoint is found again.
({DockerQueryFailed failure, bool dropped}) dockerReadFailure(
  DockerException error,
) => switch (error) {
  DockerNotFoundException(:final daemonMessage) => (
    failure: DockerQueryFailed(
      DockerQueryFailure.notFound,
      detail: daemonMessage,
    ),
    dropped: false,
  ),
  DockerApiException(:final daemonMessage, :final statusCode) => (
    failure: DockerQueryFailed(
      DockerQueryFailure.daemonError,
      detail: daemonMessage ?? 'HTTP $statusCode',
    ),
    dropped: false,
  ),
  // A channel or relay that went answers no more: a relay's exit reads
  // as a response that never came.
  _ => (
    failure: DockerQueryFailed(
      DockerQueryFailure.connectionFailed,
      detail: '${error.cause ?? error.message}',
    ),
    dropped:
        error is DockerTransportException || error is DockerProtocolException,
  ),
};

/// Owned by the Docker router, one per server with a watch: [watch]
/// with every watch the server holds, [attach] once its endpoint is
/// ready, [detach] when it drops, [close] with the last watch.
final class DockerWatcher {
  /// [dropped] tells the router a pooled read lost its connection.
  DockerWatcher({
    required this.serverId,
    required this._emit,
    required this._dropped,
    required this._now,
    required this._startTimer,
  });

  final String serverId;
  final void Function(EngineEvent event) _emit;
  final void Function() _dropped;
  final DateTime Function() _now;
  final Timer Function(Duration duration, void Function() callback) _startTimer;

  // What the watches ask for.
  Set<DockerWatchList> _lists = const {};
  Set<String> _statsFor = const {};

  // The endpoint and its stream. The epoch is bumped on each detach, so
  // reads under way when it went drop their answers.
  DockerWatchTarget? _target;
  int _epoch = 0;
  DockerStreamLease? _stream;
  StreamSubscription<String>? _events;
  bool _opening = false;
  int _retries = 0;
  Timer? _retry;
  Timer? _batch;
  Timer? _statsTimer;
  int? _refreshing;
  int? _polling;
  int? _verifying;

  /// Whether a watch asked for the stacks while detached, so the next
  /// endpoint's verdicts are checked again.
  bool _stacksAsked = false;

  // Work due: whole lists ([_fresh] of them read from nothing) and
  // container ids to read again.
  final Set<DockerWatchList> _relist = {};
  final Set<DockerWatchList> _fresh = {};
  final Set<String> _changedIds = {};

  // Kept across detaches: the lists, the previous stats reads and where
  // the stream can resume.
  List<ContainerSummary>? _containers;
  List<ImageSummary>? _images;
  List<VolumeSummary>? _volumes;
  List<NetworkSummary>? _networks;
  final Map<String, ContainerStats> _previous = {};
  LogTimestamp? _lastEvent;
  DateTime? _lostAt;
  String? _socketPath;

  // The events timeline (DKE-03): the events this endpoint's streams
  // read, oldest first, and a gap wherever a stream was lost. It starts
  // with the first stream, and a new timeline entry is sent with the
  // next batch.
  final List<DockerTimelineEntry> _timeline = [];
  bool _streamed = false;
  bool _timelineDue = false;

  /// The last event the timeline took before a resumed stream: Docker's
  /// `since` is inclusive and whole seconds, so the stream replays it and
  /// any event of its second again; the timeline skips those.
  LogTimestamp? _replayedTo;

  bool get _wantsContainers =>
      _lists.contains(DockerWatchList.containers) ||
      _lists.contains(DockerWatchList.stacks);

  /// Takes [watches], every watch the server holds; [asked] are the
  /// lists one of them just added, which it gets at once: from what the
  /// engine holds, or read.
  void watch(
    Iterable<DockerWatch> watches, {
    Set<DockerWatchList> asked = const {},
  }) {
    _lists = {for (final w in watches) ...w.lists};
    _statsFor = {
      for (final w in watches)
        if (w.lists.contains(DockerWatchList.stats)) ...w.statsFor,
    };
    _previous.removeWhere((id, _) => !_statsFor.contains(id));
    if (!_wantsContainers) _containers = null;
    if (!_lists.contains(DockerWatchList.images)) _images = null;
    if (!_lists.contains(DockerWatchList.volumes)) _volumes = null;
    if (!_lists.contains(DockerWatchList.networks)) _networks = null;

    // A view that opens the stacks again sees the files checked again.
    if (asked.contains(DockerWatchList.stacks)) {
      _target?.stacks.forget();
      _stacksAsked = _target == null;
    }

    // Detached, a list is read when the next endpoint attaches, even if
    // the stream resumes there.
    final attached = _target != null;
    for (final list in asked) {
      final held = switch (list) {
        DockerWatchList.containers || DockerWatchList.stacks => _containers,
        DockerWatchList.images => _images,
        DockerWatchList.volumes => _volumes,
        DockerWatchList.networks => _networks,
        DockerWatchList.events => _timeline,
        DockerWatchList.stats => null,
      };
      if (attached && held != null) {
        _send(list, fresh: false);
      } else {
        for (final read in _fetched({list})) {
          _due(read, fresh: true);
        }
      }
    }
    if (!attached) return;
    if (!_opening) unawaited(_refresh());
    _scheduleStats();
  }

  /// Reads over [target] from now on: opens the events stream, then
  /// lists and polls stats.
  void attach(DockerWatchTarget target) {
    if (identical(target, _target)) return;
    if (_target != null) unawaited(detach());
    if (target.socketPath != _socketPath) {
      _containers = null;
      _images = null;
      _volumes = null;
      _networks = null;
      _previous.clear();
      _lastEvent = null;
      _lostAt = null;
      _changedIds.clear();
      _timeline.clear();
      _streamed = false;
    }
    _socketPath = target.socketPath;
    _target = target;
    if (_stacksAsked) target.stacks.forget();
    _stacksAsked = false;
    _retries = 0;
    unawaited(_open(target, _epoch));
    _poll();
  }

  /// Stops reading over the endpoint, which dropped. The lists and the
  /// resume point stay for the next [attach].
  Future<void> detach() async {
    if (_target == null) return;
    _target = null;
    _epoch++;
    _lostAt ??= _now();
    _opening = false;
    // _retry also paces the re-lists without a stream.
    for (final timer in [_retry, _batch, _statsTimer]) {
      timer?.cancel();
    }
    _retry = _batch = _statsTimer = null;
    final events = _events;
    final stream = _stream;
    _events = null;
    _stream = null;
    await Future.wait([?events?.cancel(), ?stream?.close()]);
  }

  /// Stops and forgets everything: the last watch went, or the session.
  Future<void> close() {
    _lists = const {};
    _statsFor = const {};
    _containers = null;
    _images = null;
    _volumes = null;
    _networks = null;
    _previous.clear();
    _relist.clear();
    _fresh.clear();
    _changedIds.clear();
    _timeline.clear();
    _streamed = false;
    _timelineDue = false;
    return detach();
  }

  /// Closes the events stream, which gives way to re-lists (low-session
  /// mode, M9); the stream's loss opens it again, or finds no channel.
  void yieldStream() => unawaited(_stream?.close());

  // -- events ---------------------------------------------------------

  Future<void> _open(DockerWatchTarget target, int epoch) async {
    final lease = target.openEvents();
    if (lease == null) {
      _pollLists(epoch);
      return;
    }

    final lostAt = _lostAt;
    final since =
        lostAt != null && _now().difference(lostAt) <= eventGapThreshold
        ? _lastEvent
        : null;
    // `since` replays the daemon's in-memory events, which a restarted
    // daemon has lost along with the containers that died meanwhile, so
    // a resumed stream re-lists too; only past the gap is the re-list a
    // fresh one. Past it the stats baseline is stale as well: a CPU %
    // over the outage would read as current.
    for (final list in _fetched(_lists)) {
      _due(list, fresh: since == null);
    }
    if (since == null) _previous.clear();

    _opening = true;
    _stream = lease;
    final client = lease.client;
    try {
      final response = await client.requestLines(
        'GET',
        '/events',
        query: {if (since != null) 'since': '${since.seconds}'},
        filters: {'type': _eventTypes},
      );
      if (epoch != _epoch) return;
      // A stream after a lost one leaves a gap in the timeline; with
      // `since` the engine replays what it still holds of it.
      if (_streamed && lostAt != null) {
        _addToTimeline(
          DockerTimelineGap(
            at: lostAt.toUtc(),
            until: _now().toUtc(),
            resumed: since != null,
          ),
        );
      }
      _streamed = true;
      _replayedTo = since;
      _send(DockerWatchList.events, fresh: false);
      _timelineDue = false;
      _lostAt = null;
      _retries = 0;
      final eventV2 = client.gates.usesEventV2;
      _events = response.body.listen(
        (line) => _onLine(line, eventV2: eventV2),
        onError: (Object _) => _lose(epoch),
        onDone: () => _lose(epoch),
        cancelOnError: true,
      );
    } on DockerException {
      if (epoch != _epoch) return;
      _lose(epoch);
    } finally {
      if (epoch == _epoch) _opening = false;
    }
    // The lists are read once the stream is open, so no change between
    // the two goes unseen; without a stream they are read anyway.
    if (epoch == _epoch) unawaited(_refresh());
  }

  /// The stream ended or failed to open: it opens again after a backoff
  /// over the same endpoint. A link or daemon that went also fails the
  /// pooled reads, which drop the endpoint.
  void _lose(int epoch) {
    if (epoch != _epoch) return;
    _lostAt ??= _now();
    _events = null;
    final stream = _stream;
    _stream = null;
    unawaited(stream?.close());

    final delay = _retryBase * math.pow(2, math.min(_retries, 5)).toInt();
    _retries++;
    _retry?.cancel();
    _retry = _startTimer(delay < _retryCap ? delay : _retryCap, () {
      _retry = null;
      if (_target case final target? when epoch == _epoch) {
        unawaited(_open(target, epoch));
      }
    });
  }

  /// Without a stream every watched list is read in full now and again
  /// after [kDockerListPoll], when the stream is tried again. The stream
  /// counts as lost, so one that opens later resumes as after a loss.
  void _pollLists(int epoch) {
    _lostAt ??= _now();
    for (final list in _fetched(_lists)) {
      _due(list, fresh: true);
    }
    unawaited(_refresh());
    _retry?.cancel();
    _retry = _startTimer(kDockerListPoll, () {
      _retry = null;
      if (_target case final target? when epoch == _epoch) {
        unawaited(_open(target, epoch));
      }
    });
  }

  void _onLine(String line, {required bool eventV2}) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      return;
    }
    final event = parseDockerEvent(decoded, expectEventV2: eventV2).value;
    final at = event.timestamp;
    if (at != null) _lastEvent = at;
    if (_quiet(event)) return;
    // A replayed event the timeline holds still feeds the reads below.
    final replayed = switch (_replayedTo) {
      final to? => at != null && at <= to,
      null => false,
    };
    if (!replayed) {
      _replayedTo = null;
      _addToTimeline(
        DockerTimelineEvent(
          at: (at?.toDateTime() ?? _now()).toUtc(),
          type: event.type,
          action: event.action,
          actorId: event.actorId,
          name: event.name ?? (event.type == 'image' ? event.actorId : null),
          image: event.type == 'container' ? event.image : null,
          exitCode: event.exitCode,
        ),
      );
      if (_lists.contains(DockerWatchList.events)) _timelineDue = true;
    }

    final plan = planEventRefresh(event: event, now: _now());
    for (final list in plan.lists) {
      switch (list) {
        case DockerList.containers when _wantsContainers:
          if (event.actorId case final id? when id.isNotEmpty) {
            _changedIds.add(id);
          } else {
            _due(DockerWatchList.containers, fresh: false);
          }
        case DockerList.images when _lists.contains(DockerWatchList.images):
          _due(DockerWatchList.images, fresh: false);
        case DockerList.volumes when _lists.contains(DockerWatchList.volumes):
          _due(DockerWatchList.volumes, fresh: false);
        case DockerList.networks when _lists.contains(DockerWatchList.networks):
          _due(DockerWatchList.networks, fresh: false);
        default:
          break;
      }
    }
    // A connect or disconnect changes that container's networks, and
    // Docker logs it as a network event only (DNW-01's counts read them).
    if (event.type == 'network' && _wantsContainers) {
      if (event.attributes['container'] case final id? when id.isNotEmpty) {
        _changedIds.add(id);
      }
    }
    _schedule();
  }

  /// Reads again what a finished action changed: the [containers] it
  /// addressed, or with [everyContainer] the whole list after a prune,
  /// the images after an image removal, the volumes after a volume's
  /// create or removal, and the networks after a removal. The
  /// engine can log a change's event before the list endpoint holds the
  /// change (Docker's containerPause logs `pause` first), so the read that
  /// event starts may still show the old state, while the action's reply
  /// only comes once the list holds it.
  void changed({
    Set<String> containers = const {},
    bool everyContainer = false,
    bool images = false,
    bool volumes = false,
    bool networks = false,
  }) {
    if (_target == null) return;
    if (_wantsContainers) {
      _changedIds.addAll(containers.where((id) => id.isNotEmpty));
      if (everyContainer) _due(DockerWatchList.containers, fresh: false);
    }
    if (images && _lists.contains(DockerWatchList.images)) {
      _due(DockerWatchList.images, fresh: false);
    }
    if (volumes && _lists.contains(DockerWatchList.volumes)) {
      _due(DockerWatchList.volumes, fresh: false);
    }
    if (networks && _lists.contains(DockerWatchList.networks)) {
      _due(DockerWatchList.networks, fresh: false);
    }
    _schedule();
  }

  /// Reads what is due after [kDockerEventBatch], so a burst reads once.
  void _schedule() {
    if (_relist.isEmpty && _changedIds.isEmpty && !_timelineDue) return;
    _batch ??= _startTimer(kDockerEventBatch, () {
      _batch = null;
      if (_timelineDue) {
        _timelineDue = false;
        _send(DockerWatchList.events, fresh: false);
      }
      unawaited(_refresh());
    });
  }

  void _addToTimeline(DockerTimelineEntry entry) {
    _timeline.add(entry);
    if (_timeline.length > kDockerEventsKept) {
      _timeline.removeRange(0, _timeline.length - kDockerEventsKept);
    }
  }

  static bool _quiet(DockerEvent event) =>
      event.type == 'container' &&
      (event.action.startsWith('exec_') ||
          _quietActions.contains(event.action));

  // -- lists ----------------------------------------------------------

  void _due(DockerWatchList list, {required bool fresh}) {
    _relist.add(list);
    if (fresh) _fresh.add(list);
  }

  /// The lists read for [lists]: stacks come from the containers, and
  /// stats are not a list read.
  static Set<DockerWatchList> _fetched(Set<DockerWatchList> lists) => {
    if (lists.contains(DockerWatchList.containers) ||
        lists.contains(DockerWatchList.stacks))
      DockerWatchList.containers,
    if (lists.contains(DockerWatchList.images)) DockerWatchList.images,
    if (lists.contains(DockerWatchList.volumes)) DockerWatchList.volumes,
    if (lists.contains(DockerWatchList.networks)) DockerWatchList.networks,
  };

  /// Reads what is due, until nothing is; one run at a time per
  /// endpoint.
  Future<void> _refresh() async {
    final target = _target;
    final epoch = _epoch;
    if (target == null || _refreshing == epoch) return;
    _refreshing = epoch;
    try {
      while (epoch == _epoch &&
          (_relist.isNotEmpty || _changedIds.isNotEmpty)) {
        final relist = {..._relist};
        final fresh = {..._fresh};
        final ids = {..._changedIds};
        _relist.clear();
        _fresh.clear();
        _changedIds.clear();
        if (!await _read(target, epoch, relist, fresh, ids)) {
          // Detached meanwhile: what was taken stays due.
          _relist.addAll(relist);
          _fresh.addAll(fresh);
          _changedIds.addAll(ids);
          return;
        }
      }
    } finally {
      if (_refreshing == epoch) _refreshing = null;
    }
  }

  /// Reads one batch; false when the endpoint went meanwhile.
  Future<bool> _read(
    DockerWatchTarget target,
    int epoch,
    Set<DockerWatchList> relist,
    Set<DockerWatchList> fresh,
    Set<String> ids,
  ) async {
    final cached = _containers;
    final whole =
        relist.contains(DockerWatchList.containers) ||
        (ids.isNotEmpty && (cached == null || ids.length > _targetedMax));
    if (_wantsContainers && (whole || ids.isNotEmpty)) {
      final read = await _list(
        target,
        epoch,
        (client) =>
            client.listContainers(filters: whole ? null : {'id': ids.toList()}),
      );
      if (epoch != _epoch) return false;
      switch (read) {
        case final List<ContainerSummary> list:
          _containers = whole
              ? withoutCommands(list)
              : _merge(cached!, list, ids);
          final isFresh = fresh.contains(DockerWatchList.containers);
          _send(DockerWatchList.containers, fresh: isFresh);
          _send(DockerWatchList.stacks, fresh: isFresh);
        case final DockerQueryFailed failure:
          _fail(DockerWatchList.containers, failure);
          _fail(DockerWatchList.stacks, failure);
        case null:
          return false;
      }
    }

    if (relist.contains(DockerWatchList.images) &&
        _lists.contains(DockerWatchList.images)) {
      final read = await _list(target, epoch, (c) => c.listImages());
      if (epoch != _epoch) return false;
      switch (read) {
        case final List<ImageSummary> list:
          _images = list;
          _send(
            DockerWatchList.images,
            fresh: fresh.contains(DockerWatchList.images),
          );
        case final DockerQueryFailed failure:
          _fail(DockerWatchList.images, failure);
        case null:
          return false;
      }
    }

    if (relist.contains(DockerWatchList.volumes) &&
        _lists.contains(DockerWatchList.volumes)) {
      final read = await _list(target, epoch, (c) => c.listVolumes());
      if (epoch != _epoch) return false;
      switch (read) {
        case final List<VolumeSummary> list:
          _volumes = list;
          _send(
            DockerWatchList.volumes,
            fresh: fresh.contains(DockerWatchList.volumes),
          );
        case final DockerQueryFailed failure:
          _fail(DockerWatchList.volumes, failure);
        case null:
          return false;
      }
    }

    if (relist.contains(DockerWatchList.networks) &&
        _lists.contains(DockerWatchList.networks)) {
      final read = await _list(target, epoch, (c) => c.listNetworks());
      if (epoch != _epoch) return false;
      switch (read) {
        case final List<NetworkSummary> list:
          _networks = list;
          _send(
            DockerWatchList.networks,
            fresh: fresh.contains(DockerWatchList.networks),
          );
        case final DockerQueryFailed failure:
          _fail(DockerWatchList.networks, failure);
        case null:
          return false;
      }
    }
    return true;
  }

  /// The list [read] returns, its failure, or null when the connection
  /// dropped, which drops the endpoint.
  Future<Object?> _list<T>(
    DockerWatchTarget target,
    int epoch,
    Future<DockerParseResult<List<T>>> Function(DockerClient client) read,
  ) async {
    try {
      return (await target.use(read)).value;
    } on DockerException catch (e) {
      final (:failure, :dropped) = dockerReadFailure(e);
      if (!dropped) return failure;
      if (epoch == _epoch) _dropped();
      return null;
    }
  }

  /// [cached] with the containers [ids] named replaced by [read]: one
  /// missing from it is gone, and one new to the list joins at its end.
  static List<ContainerSummary> _merge(
    List<ContainerSummary> cached,
    List<ContainerSummary> read,
    Set<String> ids,
  ) {
    final fresh = {for (final c in withoutCommands(read)) c.id: c};
    return [
      for (final c in cached)
        if (fresh.remove(c.id) case final updated?)
          updated
        else if (!ids.contains(c.id))
          c,
      ...fresh.values,
    ];
  }

  void _send(DockerWatchList list, {required bool fresh}) {
    if (!_lists.contains(list)) return;
    final DockerPayload payload;
    switch (list) {
      case DockerWatchList.containers:
        payload = DockerContainersPayload(_containers!);
      case DockerWatchList.stacks:
        final target = _target;
        if (target == null) return;
        final stacks = _stacks(target);
        payload = stacks;
        if (_verifying != _epoch &&
            stacks.verdicts.values.any((v) => v is StackVerifying)) {
          unawaited(_verify(target, _epoch));
        }
      case DockerWatchList.images:
        payload = DockerImagesPayload(_images!);
      case DockerWatchList.volumes:
        payload = DockerVolumesPayload(_volumes!);
      case DockerWatchList.networks:
        payload = DockerNetworksPayload(_networks!);
      case DockerWatchList.events:
        payload = DockerEventsPayload(_timeline);
      case DockerWatchList.stats:
        return;
    }
    _emitList(list, payload, fullRelist: fresh);
  }

  DockerStacksPayload _stacks(DockerWatchTarget target) {
    final grouping = groupComposeProjects(_containers!);
    return DockerStacksPayload(
      grouping,
      verdicts: target.stacks.known(grouping),
      composeCli: target.stacks.composeCli,
    );
  }

  /// Checks the projects the stacks list has without a verdict and sends
  /// it again, until a check finds every project of the list it read
  /// known; one run per endpoint. A check that waited for a channel runs
  /// again with the next list, not in this run (M4 plan M6).
  Future<void> _verify(DockerWatchTarget target, int epoch) async {
    _verifying = epoch;
    try {
      var first = true;
      while (epoch == _epoch && _lists.contains(DockerWatchList.stacks)) {
        final containers = _containers;
        if (containers == null) return;
        final grouping = groupComposeProjects(containers);
        final verdicts = target.stacks.known(grouping);
        final unchecked = verdicts.values.any(
          (v) => v is StackVerifying && (first || v.waiting == null),
        );
        if (!unchecked) return;
        first = false;

        await target.stacks.verify(grouping);
        if (epoch != _epoch || _containers == null) return;
        if (_lists.contains(DockerWatchList.stacks)) {
          _emitList(DockerWatchList.stacks, _stacks(target));
        }
      }
    } finally {
      if (_verifying == epoch) _verifying = null;
    }
  }

  void _fail(DockerWatchList list, DockerQueryFailed failure) {
    if (_lists.contains(list)) _emitList(list, failure);
  }

  void _emitList(
    DockerWatchList list,
    DockerPayload payload, {
    bool fullRelist = false,
  }) => _emit(
    DockerListChanged(
      serverId: serverId,
      list: list,
      payload: payload,
      at: _now(),
      fullRelist: fullRelist,
    ),
  );

  // -- stats ----------------------------------------------------------

  void _scheduleStats() {
    if (_target == null || _statsFor.isEmpty) return;
    if (_statsTimer != null || _polling == _epoch) return;
    _statsTimer = _startTimer(kDockerStatsInterval, () {
      _statsTimer = null;
      _poll();
    });
  }

  /// One stats round over [_statsFor], leaving out containers the list
  /// knows are not running.
  void _poll() {
    final target = _target;
    final epoch = _epoch;
    if (target == null || _polling == epoch) return;
    final known = {for (final c in _containers ?? const []) c.id: c.state};
    final queue = [
      for (final id in _statsFor)
        if (known[id] case null || 'running') id,
    ];
    if (queue.isEmpty) return _scheduleStats();

    _polling = epoch;
    unawaited(_round(target, epoch, queue));
  }

  Future<void> _round(
    DockerWatchTarget target,
    int epoch,
    List<String> queue,
  ) async {
    final rows = <ContainerListStats>[];
    var dropped = false;
    Future<void> worker() async {
      while (queue.isNotEmpty && !dropped && epoch == _epoch) {
        final id = queue.removeAt(0);
        try {
          final read = await target.use(
            (client) => client.containerStatsOneShot(id),
          );
          if (epoch != _epoch || !_statsFor.contains(id)) continue;
          final delta = computeStatsDelta(read.value, previous: _previous[id]);
          _previous[id] = read.value;
          rows.add(
            ContainerListStats(
              containerId: id,
              at: _now(),
              cpuPercent: delta.cpuPercent,
              memoryUsed: delta.memoryUsage,
              memoryLimit: delta.memoryLimit,
            ),
          );
        } on DockerException catch (e) {
          // A container that went or failed is left out of this round.
          _previous.remove(id);
          dropped = dockerReadFailure(e).dropped;
        }
      }
    }

    final width = math.min(
      target.rank == DockerRank.streamlocal && !target.lowSession
          ? kDockerStatsInFlight
          : 1,
      queue.length,
    );
    try {
      await Future.wait([for (var i = 0; i < width; i++) worker()]);
    } finally {
      // Anything but a DockerException escaping a worker is a bug; the
      // round still ends, so the next one is scheduled.
      if (epoch == _epoch) _polling = null;
    }
    if (epoch != _epoch) return;
    if (dropped) return _dropped();
    if (_lists.contains(DockerWatchList.stats)) {
      _emitList(DockerWatchList.stats, DockerStatsPayload(rows));
    }
    _scheduleStats();
  }
}
