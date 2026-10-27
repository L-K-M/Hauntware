// STK-07's edits (03 §7.16; M5 plan M25b): a verified stack's file goes
// through SAF-12's pipeline as any file does, and its candidate is
// checked with `compose config -q` in the file's place before the
// rename, so a file compose cannot read never replaces one it can.
import 'package:klabautermann_docker/klabautermann_docker.dart';

import '../engine/protocol.dart';

/// A verified project an edit of one of its files reads and plans
/// against, and the socket and `docker` program (CN-16) its compose
/// commands name; or why there is none.
typedef StackEditSource = ({
  ComposeProject? project,
  String? socketPath,
  String? dockerProgram,
  StackFileFailure? failure,
});

/// Looks [path] of [project] up on the server's Docker endpoint: the
/// engine passes one to an edit's read and plan.
typedef StackEditLookup =
    Future<StackEditSource> Function(String project, String path);

/// `compose config -q` over [project]'s files with [temp] in [path]'s
/// place: a config file or a recorded environment file is replaced in
/// its list; the working directory's `.env` is passed as the one
/// `--env-file` when the project records none, and otherwise compose
/// does not read it, so the check runs over the files as they are.
/// Throws [ArgumentError] for a name or path compose's builder refuses.
List<String> stackCandidateCheck({
  required ComposeProject project,
  required String socketPath,
  required String dockerProgram,
  required String path,
  required String temp,
}) {
  String swap(String file) => file == path ? temp : file;
  final configFiles = project.configFiles.map(swap).toList();
  final recorded = project.environmentFiles;
  final envFiles = recorded.contains(path)
      ? recorded.map(swap).toList()
      : recorded.isEmpty && !project.configFiles.contains(path)
      ? [temp]
      : recorded;
  return composeConfig(
    binary: dockerProgram,
    socketPath: socketPath,
    project: project.name,
    projectDirectory: project.workingDir,
    configFiles: configFiles,
    envFiles: envFiles,
    quiet: true,
  ).argv;
}

/// What an edit read or plan answers when [failure] means there is no
/// stack file to edit.
EditReadFailure stackReadFailure(StackFileFailure failure) => switch (failure) {
  StackFileFailure.notVerified => EditReadFailure.stackUnverified,
  StackFileFailure.unknownStack ||
  StackFileFailure.notFound => EditReadFailure.notFound,
  StackFileFailure.notStackFile ||
  StackFileFailure.notRegularFile => EditReadFailure.invalidTarget,
  StackFileFailure.permissionDenied => EditReadFailure.adminRequired,
  StackFileFailure.readFailed => EditReadFailure.failed,
};
