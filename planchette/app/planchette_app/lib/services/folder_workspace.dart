import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as paths;
import 'package:poltergeist_core/poltergeist_core.dart';

/// A window's browser. Listing commits are generation-checked, so a slow
/// request cannot replace a newer folder or revive a closed workspace.
final class FolderWorkspace extends ChangeNotifier {
  FolderWorkspace({RemoteFileSystem? localFileSystem})
    : _local = localFileSystem ?? LocalFileSystem();

  final RemoteFileSystem _local;
  PaneChannel? _channel;
  ServerConfig? _server;
  String? _root;
  String? _path;
  List<RemoteFileEntry> _entries = const [];
  bool _loading = false;
  bool _disposed = false;
  bool _showHidden = false;
  String? _error;
  int _generation = 0;
  StreamSubscription<ServerStatus>? _statusSubscription;
  ServerStatus? _status;

  String? get root => _root;
  String? get path => _path;
  ServerConfig? get server => _server;
  bool get isRemote => _server != null;
  bool get isOpen => _root != null;
  bool get loading => _loading;
  String? get error => _error;
  ServerStatus? get status => _status;
  bool get showHidden => _showHidden;
  List<RemoteFileEntry> get entries => _showHidden
      ? _entries
      : List.unmodifiable(
          _entries.where((entry) => !entry.name.startsWith('.')),
        );
  paths.Context get _paths => isRemote ? paths.posix : paths.context;
  bool get canGoUp => _path != null && _path != _root;
  String get label =>
      _server?.label ?? (_root == null ? '' : paths.basename(_root!));
  String get displayPath => isRemote
      ? '${_server!.username}@${_server!.host}:${_path ?? _root ?? ''}'
      : _path ?? '';

  Future<void> openLocal(String folder) => _bind(folder);

  /// The caller owns connection prompts and gives this window its own channel.
  Future<void> openRemote(
    ServerConfig server,
    PaneChannel channel,
    Stream<ServerStatus> status, {
    String? root,
  }) {
    var folder = root ?? channel.homePath;
    if (folder == '~') {
      folder = channel.homePath;
    } else if (folder.startsWith('~/')) {
      folder = paths.posix.join(channel.homePath, folder.substring(2));
    } else if (!paths.posix.isAbsolute(folder)) {
      folder = paths.posix.join(channel.homePath, folder);
    }
    return _bind(folder, server: server, channel: channel, status: status);
  }

  Future<void> _bind(
    String folder, {
    ServerConfig? server,
    PaneChannel? channel,
    Stream<ServerStatus>? status,
  }) async {
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _notify();
    try {
      final fs = channel?.fs ?? _local;
      final root = await fs.canonicalize(folder);
      final listed = sortFileEntries(await fs.listDirectory(root));
      if (_disposed || generation != _generation) {
        if (!identical(channel, _channel)) await channel?.close();
        return;
      }
      final previous = _channel;
      await _statusSubscription?.cancel();
      if (_disposed || generation != _generation) {
        if (!identical(channel, _channel)) await channel?.close();
        return;
      }
      _channel = channel;
      _server = server;
      _root = root;
      _path = root;
      _entries = List.unmodifiable(listed);
      _status = null;
      _statusSubscription = status?.listen((value) {
        if (_disposed || !identical(_channel, channel)) return;
        _status = value;
        _notify();
      });
      if (!identical(previous, channel)) await previous?.close();
    } on Object catch (error) {
      if (!identical(channel, _channel)) await channel?.close();
      if (!_disposed && generation == _generation) _error = '$error';
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<void> navigate(String folder) async {
    final root = _root;
    if (root == null || _disposed) return;
    final target = _paths.normalize(folder);
    if (!_paths.equals(root, target) && !_paths.isWithin(root, target)) {
      _error = 'Choose a folder inside this workspace.';
      _notify();
      return;
    }
    final generation = ++_generation;
    _loading = true;
    _error = null;
    _notify();
    RemoteFileSystem? fs;
    try {
      fs = _channel?.fs ?? _local;
      final listed = sortFileEntries(await fs.listDirectory(target));
      if (_disposed || generation != _generation) return;
      _path = target;
      _entries = List.unmodifiable(listed);
    } on Object catch (error) {
      if (_disposed || generation != _generation) return;
      _error = '$error';
      if (fs != null && error is RemoteFileException) {
        _channel?.reportFailure(fs, error);
      }
    } finally {
      if (!_disposed && generation == _generation) {
        _loading = false;
        _notify();
      }
    }
  }

  Future<void> refresh() async {
    final path = _path;
    if (path != null) await navigate(path);
  }

  Future<void> up() async {
    if (canGoUp) await navigate(_paths.dirname(_path!));
  }

  void toggleHidden() {
    _showHidden = !_showHidden;
    _notify();
  }

  Future<void> close() async {
    ++_generation;
    final channel = _channel;
    _channel = null;
    _server = null;
    _root = null;
    _path = null;
    _entries = const [];
    _error = null;
    _status = null;
    _loading = false;
    await _statusSubscription?.cancel();
    _statusSubscription = null;
    _notify();
    await channel?.close();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(
      close().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(exception: error, stack: stack),
        );
      }),
    );
    super.dispose();
  }
}
