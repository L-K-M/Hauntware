import 'package:seance_core/seance_core.dart';

import 'admin_mode.dart';

/// [link] with every [start] through [session]'s elevation (M4 E16b,
/// LOG-22): the command line runs as root under `sh -c`, so a reader
/// built for the login shell reads a root-only file unchanged. Every
/// other call goes to [link] as it is.
final class ElevatedStartLink implements SshLink {
  ElevatedStartLink(this._link, this._session);

  final SshLink _link;
  final AdminSession _session;

  @override
  Future<RemoteProcess> start(String command, {PtyRequest? pty}) {
    if (pty != null) {
      throw ArgumentError.value(pty, 'pty', 'an elevated start has no PTY');
    }
    return _session.executor.start([
      'sh',
      '-c',
      command,
    ], password: _session.password);
  }

  @override
  ServerConfig get config => _link.config;

  @override
  SshLinkState get state => _link.state;

  @override
  Stream<SshLinkState> get states => _link.states;

  @override
  SshLinkSeen get seen => _link.seen;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) => _link.run(
    command,
    timeout: timeout,
    maxOutputBytes: maxOutputBytes,
    stdin: stdin,
  );

  @override
  Future<ByteDuplex> openUnixStream(String socketPath) =>
      _link.openUnixStream(socketPath);

  @override
  Future<ByteDuplex> openTcpStream(String host, int port) =>
      _link.openTcpStream(host, port);

  @override
  Future<RemoteFileSystem> openFileSystem() => _link.openFileSystem();

  /// Does nothing: the link is not this wrapper's to close.
  @override
  Future<void> close() async {}
}
