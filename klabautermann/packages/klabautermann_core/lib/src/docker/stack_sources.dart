/// Compose stack sources (03 §7.16 STK-01, STK-04, STK-05; M11): whether
/// the files a project's containers name are its source, and reading
/// them once they are.
///
/// ```text
///   project from the container list
///     ├─ no config files, unsafe names, no config-hash ─▶ unverified
///     ├─ test -f each config file (one exec) ─▶ missing
///     │    └─▶ source not on host (deployed by the marked manager)
///     ├─ compose CLI, looked for once: none, standalone only ─▶ unverified
///     └─ compose config --hash '*' (one exec) ─▶ every service it
///          prints matches its containers' label, and one does
///          ─▶ verified, else unverified
///   stack file of a verified project ─▶ SFTP stat, read at most 1 MiB
///     ├─ denied, admin mode on ─▶ the same read as root (M4 E16b)
///     └─▶ masked spans (03 §8.9)
/// ```
///
/// Nothing a file or `config` holds is kept: the hash run's output is
/// hashes, its error text is read only for the flag refusal and dropped,
/// and a file's text leaves in the one answer it was read for.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show HostCommands;
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ElevatedProcess,
        ElevationException,
        RemoteCommandException,
        RemoteCommandResult,
        RemoteFileErrorKind,
        RemoteFileException,
        RemoteFileSystem,
        RemoteFileType,
        RemoteTransferCancellation,
        quoteShellWord;

import '../admin/admin_mode.dart' show AdminSession;
import '../engine/protocol.dart';

/// Runs one remote command in a short-action slot (M9).
typedef StackCommandRunner =
    Future<RemoteCommandResult> Function(
      String command, {
      required Duration timeout,
      required int maxOutputBytes,
    });

/// How long a check's command may take [E]: `config` reads and
/// interpolates every file, and a Python Compose v1 starts slowly.
const _commandTimeout = Duration(seconds: 30);

/// The checks print short lines; `config --hash` one per service.
const _commandMaxOutputBytes = 64 * 1024;

/// The elevated read (STK-04 in admin mode): exit 4 for a missing path,
/// 3 for anything but a regular file (a link included, as SFTP's stat
/// without following refuses it), otherwise the size on one line and
/// then at most `$2` bytes.
const _elevatedReadScript =
    r'[ -e "$1" ] || [ -L "$1" ] || exit 4; '
    r'{ [ -f "$1" ] && [ ! -L "$1" ]; } || exit 3; '
    r'wc -c < "$1" || exit 5; exec head -c "$2" "$1"';

/// One line per file, the exit status of `test -f`.
const _testScript = r'for f in "$@"; do test -f "$f"; echo "$?"; done';

/// The plugin's `version` from the positional words, then the standalone
/// binary's; prints both statuses, then each one's first line.
const _cliScript =
    r'p=$("$@" 2>/dev/null); pc=$?; '
    r's=$(docker-compose version 2>/dev/null); sc=$?; '
    r'''printf '%s %s\n' "$pc" "$sc"; '''
    r'''printf '%s\n' "$p" | head -n 1; printf '%s\n' "$s" | head -n 1''';

/// `Docker Compose version v2.29.7` or `docker-compose version 1.29.2,
/// build 5becea4c`.
final _versionPattern = RegExp(
  r'version\s+v?([0-9]+\.[0-9]+[^\s,]*)',
  caseSensitive: false,
);

/// One endpoint's stack checks, owned by the Docker session: verdicts are
/// kept per project until its labels change or [forget], and the CLI is
/// looked for once.
final class StackSources {
  /// [run] runs a command on the server in a short-action slot, and
  /// [openFileSystem] opens its SFTP file system.
  StackSources({
    required this._socketPath,
    required this._run,
    required this._openFileSystem,
    this._admin,
  });

  final String _socketPath;
  final StackCommandRunner _run;
  final Future<RemoteFileSystem> Function() _openFileSystem;

  /// The server's admin session, through which a file SFTP may not read
  /// is read as root (STK-04); null while admin mode is off.
  final AdminSession? Function()? _admin;

  DockerComposeCli? _cli;
  Future<DockerComposeCli?>? _detecting;

  /// The verdict last found for each project, with the labels it was
  /// found for.
  final Map<String, ({String key, StackVerdict verdict})> _verdicts = {};
  final Map<String, Future<StackVerdict>> _checking = {};

  /// Bumped by [forget], so a check under way then keeps no verdict.
  int _generation = 0;

  /// The compose CLI, once found.
  DockerComposeCli? get composeCli => _cli;

  /// Each project's verdict as far as it is known without running
  /// anything: one checked for its current labels, one the labels alone
  /// decide, otherwise [StackVerifying].
  Map<String, StackVerdict> known(ComposeGrouping grouping) => {
    for (final project in grouping.projects)
      project.name: _known(project) ?? const StackVerifying(),
  };

  /// Forgets every verdict: a view opened the stacks again, and the
  /// files may have changed meanwhile.
  void forget() {
    _generation++;
    _verdicts.clear();
    _checking.clear();
  }

  /// Checks each project of [grouping] whose verdict is not known.
  Future<void> verify(ComposeGrouping grouping) => Future.wait([
    for (final project in grouping.projects)
      if (_known(project) == null) verdict(project),
  ]);

  /// [project]'s verdict, checked unless known.
  Future<StackVerdict> verdict(ComposeProject project) {
    if (_known(project) case final known?) return Future.value(known);
    final key = _keyOf(project);
    final generation = _generation;
    return _checking[key] ??= _check(project).then((verdict) {
      if (generation == _generation) {
        _checking.remove(key);
        _verdicts[project.name] = (key: key, verdict: verdict);
      }
      return verdict;
    });
  }

  StackVerdict? _known(ComposeProject project) {
    final kept = _verdicts[project.name];
    if (kept != null && kept.key == _keyOf(project)) return kept.verdict;
    return _fromLabels(project).verdict;
  }

  /// Reads [path] of [project] (STK-04): only a file of a verified
  /// project, over SFTP, at most [kStackFileMaxBytes], masked (M11).
  /// [client] lists the project's containers, so the verdict is the
  /// one for its labels now.
  Future<DockerPayload> readFile(
    DockerClient client,
    String project,
    String path,
  ) async {
    final list = await client.listContainers(
      filters: {
        'label': ['${ComposeLabelKeys.project}=$project'],
      },
    );
    final found = groupComposeProjects(list.value).project(project);
    if (found == null) {
      return const DockerStackFileFailed(StackFileFailure.unknownStack);
    }
    final kind = _fileKind(found, path);
    if (kind == null) {
      return const DockerStackFileFailed(StackFileFailure.notStackFile);
    }
    if (await verdict(found) is! StackVerified) {
      return const DockerStackFileFailed(StackFileFailure.notVerified);
    }
    return _read(project, path, kind);
  }

  // -- redeploy (STK-06) ----------------------------------------------

  /// The services [project]'s files name, every profile's with
  /// [allProfiles]: `config --services`, whose output is names only.
  /// Null when the run failed or printed something else, as a CLI
  /// without `--profile '*'` does.
  Future<Set<String>?> serviceNames(
    ComposeProject project, {
    bool allProfiles = false,
  }) async {
    final ComposeInvocation invocation;
    try {
      invocation = composeConfig(
        socketPath: _socketPath,
        project: project.name,
        projectDirectory: project.workingDir,
        configFiles: project.configFiles,
        envFiles: project.environmentFiles,
        profiles: [if (allProfiles) '*'],
        services: true,
      );
    } on ArgumentError {
      return null;
    }
    final result = await _command(invocation.argv);
    if (result == null || !result.succeeded || result.truncated) return null;
    return parseComposeServiceNames(result.stdout);
  }

  /// Each service's hash from [hashArgv], a `config --hash '*'` run a
  /// plan built; null when it failed or printed something else.
  Future<Map<String, String>?> serviceHashes(List<String> hashArgv) async {
    final result = await _command(hashArgv);
    if (result == null || !result.succeeded || result.truncated) return null;
    return parseComposeServiceHashes(result.stdout);
  }

  // -- verification ---------------------------------------------------

  Future<StackVerdict> _check(ComposeProject project) async {
    final (:verdict, :invocation, :expected) = _fromLabels(project);
    if (verdict != null) return verdict;

    final present = await _filesPresent(project.configFiles);
    if (present == null) {
      return const StackUnverified(StackUnverifiedReason.checkFailed);
    }
    if (present.contains(false)) {
      return StackSourceNotOnHost(
        deployedBy: project.ownership.primary?.manager,
      );
    }

    final cli = await _detect();
    if (cli == null) {
      return const StackUnverified(StackUnverifiedReason.checkFailed);
    }
    if (cli.pluginVersion == null) {
      return StackUnverified(
        cli.standaloneVersion == null
            ? StackUnverifiedReason.noComposeCli
            : StackUnverifiedReason.standaloneComposeOnly,
      );
    }

    return _compareHashes(invocation!, expected!);
  }

  /// What the labels alone tell: a verdict, or the `config --hash`
  /// invocation and each service's hashes to compare it with.
  _Labels _fromLabels(ComposeProject project) {
    _Labels unverified(StackUnverifiedReason reason) =>
        (verdict: StackUnverified(reason), invocation: null, expected: null);

    if (project.configFiles.isEmpty) {
      return unverified(StackUnverifiedReason.noSourceLabels);
    }
    final ComposeInvocation invocation;
    try {
      invocation = composeConfig(
        socketPath: _socketPath,
        project: project.name,
        projectDirectory: project.workingDir,
        configFiles: project.configFiles,
        envFiles: project.environmentFiles,
        hash: '*',
      );
    } on ArgumentError {
      return unverified(StackUnverifiedReason.unsafeLabels);
    }

    // One-off containers keep the hash of the run that made them, so the
    // services' own containers decide.
    final expected = <String, Set<String>>{};
    for (final service in project.services) {
      for (final container in service.containers) {
        final labels = ComposeLabels.fromContainerLabels(container.labels);
        if (labels == null || labels.isOneOff) continue;
        final hash = labels.configHash;
        if (hash == null) {
          return unverified(StackUnverifiedReason.noHashLabels);
        }
        expected.putIfAbsent(service.name, () => {}).add(hash);
      }
    }
    if (expected.isEmpty) {
      return unverified(StackUnverifiedReason.noHashLabels);
    }
    return (verdict: null, invocation: invocation, expected: expected);
  }

  /// Whether each of [files] is a regular file, from one exec; null when
  /// the exec failed or answered something else.
  Future<List<bool>?> _filesPresent(List<String> files) async {
    final result = await _command(['sh', '-c', _testScript, 'sh', ...files]);
    if (result == null || !result.succeeded) return null;
    final codes = const LineSplitter().convert(result.stdout.trim());
    if (codes.length != files.length) return null;
    return [for (final code in codes) code.trim() == '0'];
  }

  /// The CLIs, looked for once in one exec; null, and looked for again
  /// next time, when the exec failed.
  Future<DockerComposeCli?> _detect() {
    if (_cli case final cli?) return Future.value(cli);
    return _detecting ??= () async {
      final plugin = composeVersion(socketPath: _socketPath, json: false);
      final result = await _command([
        'sh',
        '-c',
        _cliScript,
        'sh',
        ...plugin.argv,
      ]);
      _detecting = null;
      if (result == null || !result.succeeded) return null;
      return _cli = _parseCli(result.stdout);
    }();
  }

  static DockerComposeCli? _parseCli(String stdout) {
    final lines = const LineSplitter().convert(stdout);
    if (lines.isEmpty) return null;
    final codes = lines.first.trim().split(' ');
    if (codes.length != 2) return null;
    String? version(int line, String code) {
      if (code != '0' || lines.length <= line) return null;
      return _versionPattern.firstMatch(lines[line])?[1];
    }

    return DockerComposeCli(
      pluginVersion: version(1, codes[0]),
      standaloneVersion: version(2, codes[1]),
    );
  }

  /// Runs `config --hash '*'` and compares each service's hash with its
  /// containers' labels. A service it does not print is one the files no
  /// longer name, or one only a profile enables: STK-06 lists it, and it
  /// says nothing about the files. Its error text is read only to tell a
  /// CLI without the flag form from a config that fails.
  Future<StackVerdict> _compareHashes(
    ComposeInvocation invocation,
    Map<String, Set<String>> expected,
  ) async {
    final result = await _command(invocation.argv);
    if (result == null || result.exitCode == null) {
      return const StackUnverified(StackUnverifiedReason.checkFailed);
    }
    if (!result.succeeded) {
      final refused =
          result.stderr.contains('unknown flag') ||
          result.stderr.contains('no such option');
      return StackUnverified(
        refused
            ? StackUnverifiedReason.cliCouldNotHash
            : StackUnverifiedReason.configFailed,
      );
    }

    final hashes = result.truncated
        ? null
        : parseComposeServiceHashes(result.stdout);
    if (hashes == null) {
      return const StackUnverified(StackUnverifiedReason.cliCouldNotHash);
    }
    var matched = false;
    for (final MapEntry(key: service, value: labels) in expected.entries) {
      final hash = hashes[service];
      if (hash == null) continue;
      if (labels.length != 1 || hash != labels.single) {
        return const StackUnverified(StackUnverifiedReason.hashMismatch);
      }
      matched = true;
    }
    return matched
        ? const StackVerified()
        : const StackUnverified(StackUnverifiedReason.hashMismatch);
  }

  /// Runs [argv] through 03 §8.8's quoting; null when the link failed.
  Future<RemoteCommandResult?> _command(List<String> argv) async {
    try {
      return await _run(
        HostCommands.commandLine(argv, quote: quoteShellWord),
        timeout: _commandTimeout,
        maxOutputBytes: _commandMaxOutputBytes,
      );
    } on RemoteCommandException {
      return null;
    } on ChannelOpenException {
      return null;
    }
  }

  /// What a project's verdict depends on besides the files: its name,
  /// paths and each container's hash.
  static String _keyOf(ComposeProject project) => [
    project.name,
    project.workingDir ?? '',
    ...project.configFiles,
    '',
    ...project.environmentFiles,
    '',
    for (final service in project.services)
      for (final container in service.containers)
        '${service.name} ${container.labels[ComposeLabelKeys.configHash]} '
            '${container.labels[ComposeLabelKeys.oneoff]}',
  ].join('\u0000');

  // -- files ----------------------------------------------------------

  /// How [path] of [project] is masked, or null when it is none of the
  /// project's files: a config file is compose, an environment file or
  /// the working directory's `.env` is environment.
  static StackFileKind? _fileKind(ComposeProject project, String path) {
    if (project.configFiles.contains(path)) return StackFileKind.compose;
    if (project.environmentFiles.contains(path)) {
      return StackFileKind.environment;
    }
    final directory = project.workingDir;
    if (directory == null) return null;
    final dotEnv = directory.endsWith('/')
        ? '$directory.env'
        : '$directory/.env';
    return path == dotEnv ? StackFileKind.environment : null;
  }

  Future<DockerPayload> _read(
    String project,
    String path,
    StackFileKind kind,
  ) async {
    final cancellation = RemoteTransferCancellation();
    final sink = _BoundedSink(kStackFileMaxBytes, cancellation);
    final int size;
    try {
      final files = await _openFileSystem();
      final entry = await files.stat(path, followLinks: false);
      if (entry.type != RemoteFileType.file) {
        return const DockerStackFileFailed(StackFileFailure.notRegularFile);
      }
      size = entry.size ?? 0;
      try {
        await files.download(
          path,
          sink,
          cancellation: cancellation,
          computeHash: false,
        );
      } on RemoteFileException {
        // Past the cap the read was cancelled, and what came is kept.
        if (!sink.full) rethrow;
      }
    } on RemoteFileException catch (e) {
      if (e.kind == RemoteFileErrorKind.permissionDenied) {
        if (_admin?.call() case final session?) {
          return _readElevated(project, path, kind, session);
        }
      }
      // `unsupported` also means SFTP itself is missing; the stat above
      // has told a non-regular file apart already.
      return DockerStackFileFailed(switch (e.kind) {
        RemoteFileErrorKind.notFound => StackFileFailure.notFound,
        RemoteFileErrorKind.permissionDenied =>
          StackFileFailure.permissionDenied,
        _ => StackFileFailure.readFailed,
      });
    } on ChannelOpenException {
      return const DockerStackFileFailed(StackFileFailure.readFailed);
    }

    return DockerStackFilePayload(
      project: project,
      path: path,
      text: maskStackFile(sink.text, kind),
      size: size,
      truncated: sink.full,
    );
  }
}

extension on StackSources {
  /// [path] read as root through [session], with the SFTP read's cap and
  /// masking: only a regular file, its first [kStackFileMaxBytes] bytes
  /// kept to the last complete line, its text neither cached nor logged.
  Future<DockerPayload> _readElevated(
    String project,
    String path,
    StackFileKind kind,
    AdminSession session,
  ) async {
    const failed = DockerStackFileFailed(StackFileFailure.readFailed);
    final ElevatedProcess process;
    try {
      process = await session.executor.start([
        'sh',
        '-c',
        _elevatedReadScript,
        'sh',
        path,
        '${kStackFileMaxBytes + 1}',
      ], password: session.password);
    } on ElevationException {
      return const DockerStackFileFailed(StackFileFailure.permissionDenied);
    } on RemoteCommandException {
      return failed;
    } on ChannelOpenException {
      return failed;
    }
    unawaited(process.stdin.close());

    // The size line, then the bytes; past the cap the process is let go.
    final head = BytesBuilder();
    int? size;
    final sink = _BoundedSink(kStackFileMaxBytes, RemoteTransferCancellation());
    await for (final chunk in process.stdout) {
      if (size == null) {
        head.add(chunk);
        final bytes = head.toBytes();
        final newline = bytes.indexOf(0x0A);
        if (newline < 0) continue;
        size = int.tryParse(ascii.decode(bytes.sublist(0, newline)).trim());
        if (size == null) break;
        sink.add(bytes.sublist(newline + 1));
      } else {
        sink.add(chunk);
      }
      if (sink.full) break;
    }
    if (sink.full) {
      unawaited(process.close());
    } else {
      final exit = await process.exit;
      if (await process.refusal != null) {
        return const DockerStackFileFailed(StackFileFailure.permissionDenied);
      }
      switch (exit.exitCode) {
        case 0 when size != null:
          break;
        case 4:
          return const DockerStackFileFailed(StackFileFailure.notFound);
        case 3:
          return const DockerStackFileFailed(StackFileFailure.notRegularFile);
        default:
          return failed;
      }
    }
    return DockerStackFilePayload(
      project: project,
      path: path,
      text: maskStackFile(sink.text, kind),
      size: size ?? 0,
      truncated: sink.full,
    );
  }
}

typedef _Labels = ({
  StackVerdict? verdict,
  ComposeInvocation? invocation,
  Map<String, Set<String>>? expected,
});

/// Takes up to [_cap] bytes; a write past it cancels the transfer.
final class _BoundedSink implements StreamSink<List<int>> {
  _BoundedSink(this._cap, this._cancellation);

  final int _cap;
  final RemoteTransferCancellation _cancellation;
  final _bytes = BytesBuilder();
  final _done = Completer<void>();

  /// Whether the file went past the cap.
  bool full = false;

  /// The bytes as text; past the cap only up to the last complete line,
  /// so no value is cut where its masking rule could no longer see it.
  String get text {
    var bytes = _bytes.toBytes();
    if (full) {
      final end = bytes.lastIndexOf(0x0A);
      bytes = Uint8List.sublistView(bytes, 0, end + 1);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  void add(List<int> data) {
    if (full) return;
    final room = _cap - _bytes.length;
    if (data.length <= room) return _bytes.add(data);
    _bytes.add(data.sublist(0, room));
    full = true;
    _cancellation.cancel();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> get done => _done.future;
}
