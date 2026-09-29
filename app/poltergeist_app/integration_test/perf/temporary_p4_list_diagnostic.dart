// DIAGNOSTIC BRANCH ONLY. Do not use these results as gate evidence.
import 'dart:async';
import 'dart:developer' show Timeline;
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

final listDiagnostic = ListDiagnostic();
const listDiagnosticMode = String.fromEnvironment(
  'P4_LIST_DIAGNOSTIC_MODE',
  defaultValue: 'normal',
);

class ListDiagnostic {
  int requested = 0;
  int completed = 0;
  int inFlight = 0;
  int maxInFlight = 0;
  Completer<void>? _gate;
  final _events = <String>[];
  String get snapshot =>
      'mode=$listDiagnosticMode requested=$requested completed=$completed pending=${requested - completed} engineInFlight=$inFlight maxInFlight=$maxInFlight';

  void hold() {
    if (_gate != null) throw StateError('already held');
    _gate = Completer<void>();
    mark('HOLD');
  }

  void release() {
    final gate = _gate;
    _gate = null;
    mark('RELEASE');
    gate?.complete();
  }

  void mark(String marker) =>
      _events.add('P4-LIST $marker t=${Timeline.now} $snapshot');

  Future<List<RemoteFileEntry>> list(
    int channel,
    String path,
    Future<List<RemoteFileEntry>> Function() dispatch,
  ) async {
    final id = ++requested;
    final requestedAt = Timeline.now;
    final gate = _gate;
    mark('REQUEST id=$id channel=$channel gated=${gate != null}');
    if (gate != null) await gate.future;
    final dispatchedAt = Timeline.now;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
    mark('START id=$id channel=$channel');
    var count = -1;
    try {
      final entries = await dispatch();
      count = entries.length;
      return entries;
    } finally {
      inFlight--;
      completed++;
      final now = Timeline.now;
      mark(
        'END id=$id channel=$channel entries=$count totalUs=${now - requestedAt} listCallUs=${now - dispatchedAt}',
      );
    }
  }

  Future<void> waitIdle() async {
    final deadline = DateTime.now().add(const Duration(seconds: 120));
    while (requested != completed) {
      if (DateTime.now().isAfter(deadline)) throw TimeoutException(snapshot);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  void dump() {
    for (final event in _events) {
      // ignore: avoid_print
      print(event);
    }
    _events.clear();
  }
}

final class DiagnosticAppEngine implements AppEngine {
  DiagnosticAppEngine(this._client);

  final AppEngine _client;

  @override
  Stream<EnginePromptEvent> get prompts => _client.prompts;

  @override
  Stream<PromptDismissedEvent> get promptDismissals => _client.promptDismissals;

  @override
  void replyPrompt(String promptId, EnginePromptKind kind, PromptReply reply) =>
      _client.replyPrompt(promptId, kind, reply);

  @override
  Stream<HostKeyPinnedEvent> get hostKeyPins => _client.hostKeyPins;

  @override
  Stream<IncidentStoreEvent> get incidentChanges => _client.incidentChanges;

  @override
  Stream<ServerStatus> watchServer(String serverId) =>
      _client.watchServer(serverId);

  @override
  Stream<RecoveryFailedEvent> get recoveryFailures => _client.recoveryFailures;

  @override
  Stream<ConnectionLogEvent> get connectionLog => _client.connectionLog;

  @override
  Stream<ProbeStatusesEvent> get probeStatuses => _client.probeStatuses;

  @override
  Future<void> setProbeTargets(List<ServerConfig> targets) =>
      _client.setProbeTargets(targets);

  @override
  Future<void> setProbeActivity(ProbeActivity activity) =>
      _client.setProbeActivity(activity);

  @override
  Future<AppBrowseChannel> openBrowseChannel({
    required String serverId,
    required String paneTabId,
    required ServerConfig config,
  }) async => DiagnosticBrowseChannel(
    await _client.openBrowseChannel(
      serverId: serverId,
      paneTabId: paneTabId,
      config: config,
    ),
  );

  @override
  Future<AppBrowseChannel> openLocalChannel({required String rootPath}) async =>
      DiagnosticBrowseChannel(
        await _client.openLocalChannel(rootPath: rootPath),
      );

  @override
  Future<void> disconnectServer(String serverId) =>
      _client.disconnectServer(serverId);

  @override
  Future<void> removeBookmark(String serverId) =>
      _client.removeBookmark(serverId);

  @override
  Future<void> shutdown() => _client.shutdown();

  @override
  ConnectionManager transferConnections(ServerConfigSource configs) =>
      _client.transferConnections(configs);

  @override
  late final LocalTrashBackend localTrash = _client.localTrash;
}

final class DiagnosticBrowseChannel implements AppBrowseChannel {
  DiagnosticBrowseChannel(this._channel) : id = ++_nextChannel;

  static int _nextChannel = 0;
  final int id;

  final AppBrowseChannel _channel;

  @override
  String get homePath => _channel.homePath;

  @override
  Stream<DirectoryWatchEvent> get directoryChanges => _channel.directoryChanges;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) =>
      listDiagnostic.list(id, path, () => _channel.listDirectory(path));

  @override
  Future<void> watchDirectory(String path) => _channel.watchDirectory(path);

  @override
  Future<void> unwatchDirectory() => _channel.unwatchDirectory();

  @override
  Future<void> rename(String oldPath, String newPath) =>
      _channel.rename(oldPath, newPath);

  @override
  Future<void> setPermissions(String path, int permissions) {
    assert(
      permissions >= 0 && permissions <= 0xFFF,
      'permissions must be a twelve-bit mode (0x000-0xFFF)',
    );
    return _channel.setPermissions(path, permissions);
  }

  @override
  Future<void> openInDefaultApp(String path) => _channel.openInDefaultApp(path);

  @override
  Future<void> createDirectory(String path) => _channel.createDirectory(path);

  @override
  Future<RemoteFileEntry> createEmptyFile(String path) =>
      _channel.createEmptyFile(path);

  @override
  Future<RemoteFileEntry> stat(String path) => _channel.stat(path);

  @override
  Future<void> close() => _channel.close();
}
