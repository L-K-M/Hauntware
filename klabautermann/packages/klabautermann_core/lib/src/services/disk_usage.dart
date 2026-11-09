// DSK-07's folder read (03 §7.3): one `du` over a folder, as the login
// user over the link or, in admin mode, as root through the elevation
// executor, so the sizes take in what the login user may not read. Where
// ncdu or gdu is installed, one export of the whole filesystem streams
// into a [DiskUsageTree] instead, and every folder under it opens from
// that tree without another read.
import 'dart:async';
import 'dart:convert' show Utf8Decoder;

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ElevationException,
        RemoteCommandException,
        RemoteCommandResult,
        RemoteProcess,
        SshLink,
        quoteShellWord;

import '../admin/admin_mode.dart' show AdminSession;
import '../engine/protocol.dart';
import '../logs/host_queries.dart' show kHostQueryMaxOutputBytes;

/// How long one folder read may run: `du` walks every file under the
/// folder, which takes minutes on a large tree.
const kDiskUsageTimeout = Duration(minutes: 3);

/// Reads [path] on [serverId]: through [session] when given, else as the
/// login user over [link]. Answers rather than throws.
Future<DiskUsageReport> readDiskUsage(
  String serverId,
  String path, {
  required String requestId,
  required SshLink link,
  AdminSession? session,
  Duration timeout = kDiskUsageTimeout,
}) async {
  DiskUsageReport failed(DiskUsageReportFailure failure) => DiskUsageReport(
    serverId: serverId,
    requestId: requestId,
    path: path,
    failure: failure,
  );

  final List<String> argv;
  try {
    argv = HostCommands.diskUsage(path);
  } on HostCommandError {
    return failed(DiskUsageReportFailure.invalidPath);
  }

  final RemoteCommandResult result;
  try {
    result = switch (session) {
      final session? => await session.executor.run(
        argv,
        password: session.password,
        timeout: timeout,
      ),
      null => await link.run(
        HostCommands.commandLine(argv, quote: quoteShellWord),
        stdin: const [],
        timeout: timeout,
        maxOutputBytes: kHostQueryMaxOutputBytes,
      ),
    };
  } on ElevationException {
    return failed(DiskUsageReportFailure.elevationRefused);
  } on RemoteCommandException {
    return failed(DiskUsageReportFailure.transport);
  }

  final parse = parseDiskUsage(result.stdout, path);
  if (parse.listing case final listing?) {
    return DiskUsageReport(
      serverId: serverId,
      requestId: requestId,
      path: path,
      listing: listing,
    );
  }
  return failed(switch (parse.problem!) {
    DiskUsageProblem.notFound => DiskUsageReportFailure.notFound,
    DiskUsageProblem.denied => DiskUsageReportFailure.denied,
    DiskUsageProblem.unreadable => DiskUsageReportFailure.unreadable,
  });
}

/// The whole-tree export tool [profile] found, ncdu before gdu; null when
/// neither is installed or the profile is not known yet.
DiskUsageExportTool? diskUsageExportToolOf(HostProfile? profile) {
  if (profile == null) return null;
  for (final tool in DiskUsageExportTool.values) {
    if (profile.tools[tool.name] != null) return tool;
  }
  return null;
}

/// Exports the filesystem under [root] with [tool] and reads it as it
/// streams, through [session] when given, else as the login user over
/// [link]. Null when the export does not start, fails, runs past
/// [timeout] or holds more than the reader keeps: the explorer then reads
/// folder by folder with `du`. Never throws.
Future<DiskUsageTree?> readDiskUsageTree(
  String root, {
  required DiskUsageExportTool tool,
  required SshLink link,
  AdminSession? session,
  Duration timeout = kDiskUsageTimeout,
}) async {
  final List<String> argv;
  try {
    argv = HostCommands.diskUsageExport(root, tool);
  } on HostCommandError {
    return null;
  }

  final RemoteProcess process;
  try {
    process = switch (session) {
      final session? => await session.executor.start(
        argv,
        password: session.password,
      ),
      null => await link.start(
        HostCommands.commandLine(argv, quote: quoteShellWord),
      ),
    };
  } on ElevationException {
    return null;
  } on RemoteCommandException {
    return null;
  } on ChannelOpenException {
    return null;
  }

  final reader = DiskUsageExportReader(root);
  // What the tool says on stderr is not read; draining it keeps a long
  // complaint from stalling the channel.
  unawaited(process.stderr.drain<void>().catchError((Object _) {}));
  try {
    await process.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach(reader.add)
        .timeout(timeout);
    return reader.close();
  } on DiskUsageExportException {
    return null;
  } on TimeoutException {
    return null;
  } on RemoteCommandException {
    return null;
  } finally {
    unawaited(process.close().catchError((Object _) {}));
  }
}

/// Whether a read of [path] for an explorer started at [root] answers
/// from the whole-tree export: when the explorer named its mount point,
/// [path] is that mount point or under it, and the read is not Read again
/// on a folder below the mount point, which reads only that folder so a
/// small folder never waits on the whole tree.
bool diskUsageFromTree({
  required String path,
  required String? root,
  required bool fresh,
}) {
  if (root == null) return false;
  if (path == root) return true;
  return !fresh && path.startsWith(root == '/' ? '/' : '$root/');
}

/// How long an export answers the explorer before a folder that opens
/// reads the filesystem again [E]: the explorer reads a folder once until
/// Read again, so this only matters when it opens again later.
const kDiskUsageTreeLifetime = Duration(minutes: 5);

/// Each server's last whole-tree export (DSK-07): one per server, for
/// the mount and the reader (login user or root) it was read for, so a
/// second mount or reader replaces it and the engine keeps one tree per
/// server at most.
final class DiskUsageTrees {
  DiskUsageTrees({DateTime Function()? now}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final _trees = <String, _HeldTree>{};

  /// [serverId]'s tree of [root] read as root when [elevated]: the held
  /// one while it is the same, younger than [kDiskUsageTreeLifetime] and
  /// not [fresh], else a new one from [read], which reads that run share.
  Future<DiskUsageTree?> tree(
    String serverId,
    String root, {
    required bool elevated,
    required bool fresh,
    required Future<DiskUsageTree?> Function() read,
  }) {
    final held = _trees[serverId];
    final now = _now();
    if (!fresh &&
        held != null &&
        held.root == root &&
        held.elevated == elevated &&
        now.difference(held.started) < kDiskUsageTreeLifetime) {
      return held.tree;
    }
    final tree = read();
    final entry = _HeldTree(root, elevated, now, tree);
    _trees[serverId] = entry;
    // A failed export is not kept: the next folder tries again.
    unawaited(
      tree.then((read) {
        if (read == null && identical(_trees[serverId], entry)) {
          _trees.remove(serverId);
        }
      }),
    );
    return tree;
  }

  void forget(Iterable<String> serverIds) => serverIds.forEach(_trees.remove);
}

final class _HeldTree {
  const _HeldTree(this.root, this.elevated, this.started, this.tree);

  final String root;
  final bool elevated;
  final DateTime started;
  final Future<DiskUsageTree?> tree;
}
