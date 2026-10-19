import 'package:meta/meta.dart';

/// A validated compose invocation: the argv list the caller hands to a
/// command runner (03 §7.16 STK-06, §5.4). Values are validated here;
/// shell quoting is `klabautermann_core`'s `quoteShellWord` job (03 §8.8)
/// and is deliberately not applied in this package.
@immutable
final class ComposeInvocation {
  const ComposeInvocation(this.argv);

  final List<String> argv;

  /// A space-joined rendering for logs and previews. Not a shell command:
  /// the arguments are not quoted.
  String get display => argv.join(' ');
}

/// `^[a-z0-9][a-z0-9_-]*$`: Compose v2 project and service names. Compose
/// lowercases project names, so uppercase is rejected rather than folded.
final RegExp composeNamePattern = RegExp(r'^[a-z0-9][a-z0-9_-]*$');

/// Validates a compose project name (03 §7.16 STK-06). Throws
/// [ArgumentError] on anything the CLI would reject.
String validateComposeProjectName(String name) {
  if (!composeNamePattern.hasMatch(name)) {
    throw ArgumentError.value(
      name,
      'project',
      'not a valid compose project name',
    );
  }
  return name;
}

/// Validates a compose service name. Compose allows dots in service names
/// (`db.replica`), so the grammar is slightly wider than a project name.
String validateComposeServiceName(String name) {
  if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9._-]*$').hasMatch(name)) {
    throw ArgumentError.value(
      name,
      'service',
      'not a valid compose service name',
    );
  }
  return name;
}

/// Validates an absolute host path with no NUL or line break (03 §8.8).
String validateAbsolutePath(String path) {
  if (!path.startsWith('/') ||
      path.contains('\u0000') ||
      path.contains('\n') ||
      path.contains('\r')) {
    throw ArgumentError.value(path, 'path', 'not an absolute safe path');
  }
  return path;
}

/// Validates the engine socket path and renders the CLI `--host` value
/// (03 §5.4).
String validateSocketPath(String socketPath) {
  validateAbsolutePath(socketPath);
  return 'unix://$socketPath';
}

List<String> _sharedPrefix({
  required String binary,
  required String socketPath,
  required String project,
  String? projectDirectory,
  List<String> configFiles = const [],
  String? envFile,
  List<String> envFiles = const [],
  List<String> profiles = const [],
}) {
  final argv = <String>[
    binary,
    '--host',
    validateSocketPath(socketPath),
    'compose',
    '-p',
    validateComposeProjectName(project),
  ];
  if (projectDirectory != null) {
    argv
      ..add('--project-directory')
      ..add(validateAbsolutePath(projectDirectory));
  }
  for (final f in configFiles) {
    argv
      ..add('-f')
      ..add(validateAbsolutePath(f));
  }
  for (final e in [?envFile, ...envFiles]) {
    argv
      ..add('--env-file')
      ..add(validateAbsolutePath(e));
  }
  for (final profile in profiles) {
    argv
      ..add('--profile')
      ..add(_validateProfile(profile));
  }
  return argv;
}

/// A compose profile name, or `*` for every profile (03 §7.16 STK-06).
String _validateProfile(String profile) {
  if (profile != '*' &&
      !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]*$').hasMatch(profile)) {
    throw ArgumentError.value(profile, 'profile', 'not a compose profile');
  }
  return profile;
}

/// `docker --host unix://<socket> compose ... ps --format json`
/// (03 §7.16 STK-01).
ComposeInvocation composePs({
  String binary = 'docker',
  required String socketPath,
  required String project,
  String? projectDirectory,
  List<String> configFiles = const [],
  String? envFile,
  bool all = false,
  bool json = true,
}) {
  final argv = _sharedPrefix(
    binary: binary,
    socketPath: socketPath,
    project: project,
    projectDirectory: projectDirectory,
    configFiles: configFiles,
    envFile: envFile,
  )..add('ps');
  if (all) argv.add('--all');
  if (json) {
    argv
      ..add('--format')
      ..add('json');
  }
  return ComposeInvocation(argv);
}

/// `... compose ... config` for source verification and viewing
/// (03 §7.16 STK-01, STK-04, STK-06). Exactly one of [quiet], [hash],
/// [services] or [formatJson] is expected; the interpolated plain output
/// is never captured by the app (it can contain secrets). [envFiles]
/// repeats `--env-file` for a project that recorded several; [profiles]
/// enables profiles, `*` all of them.
ComposeInvocation composeConfig({
  String binary = 'docker',
  required String socketPath,
  required String project,
  String? projectDirectory,
  List<String> configFiles = const [],
  String? envFile,
  List<String> envFiles = const [],
  bool quiet = false,
  String? hash,
  bool services = false,
  List<String> profiles = const [],
  bool formatJson = false,
}) {
  final argv = _sharedPrefix(
    binary: binary,
    socketPath: socketPath,
    project: project,
    projectDirectory: projectDirectory,
    configFiles: configFiles,
    envFile: envFile,
    envFiles: envFiles,
    profiles: profiles,
  )..add('config');
  if (quiet) argv.add('-q');
  if (services) argv.add('--services');
  if (hash != null) {
    argv
      ..add('--hash')
      ..add(hash);
  }
  if (formatJson) {
    argv
      ..add('--format')
      ..add('json');
  }
  return ComposeInvocation(argv);
}

/// `... compose ... up -d` (03 §7.16 STK-06, STK-23). `--remove-orphans`
/// is only added on explicit request; `-v` is never added.
ComposeInvocation composeUp({
  String binary = 'docker',
  required String socketPath,
  required String project,
  String? projectDirectory,
  List<String> configFiles = const [],
  String? envFile,
  List<String> envFiles = const [],
  List<String> services = const [],
  bool detach = true,
  bool removeOrphans = false,
  bool plainProgress = true,
  bool noAnsi = true,
}) {
  final argv = _sharedPrefix(
    binary: binary,
    socketPath: socketPath,
    project: project,
    projectDirectory: projectDirectory,
    configFiles: configFiles,
    envFile: envFile,
    envFiles: envFiles,
  );
  _composeOutputFlags(argv, plainProgress: plainProgress, noAnsi: noAnsi);
  argv.add('up');
  if (detach) argv.add('-d');
  if (removeOrphans) argv.add('--remove-orphans');
  argv.addAll(services.map(validateComposeServiceName));
  return ComposeInvocation(argv);
}

/// `... compose ... down` (03 §7.16 STK-23). `-v` is never added.
ComposeInvocation composeDown({
  String binary = 'docker',
  required String socketPath,
  required String project,
  String? projectDirectory,
  List<String> configFiles = const [],
  String? envFile,
  bool removeOrphans = false,
}) {
  final argv = _sharedPrefix(
    binary: binary,
    socketPath: socketPath,
    project: project,
    projectDirectory: projectDirectory,
    configFiles: configFiles,
    envFile: envFile,
  )..add('down');
  if (removeOrphans) argv.add('--remove-orphans');
  return ComposeInvocation(argv);
}

/// `... compose ... pull` (03 §7.16 STK-06).
ComposeInvocation composePull({
  String binary = 'docker',
  required String socketPath,
  required String project,
  String? projectDirectory,
  List<String> configFiles = const [],
  String? envFile,
  List<String> envFiles = const [],
  List<String> services = const [],
  bool plainProgress = true,
  bool noAnsi = true,
}) {
  final argv = _sharedPrefix(
    binary: binary,
    socketPath: socketPath,
    project: project,
    projectDirectory: projectDirectory,
    configFiles: configFiles,
    envFile: envFile,
    envFiles: envFiles,
  );
  _composeOutputFlags(argv, plainProgress: plainProgress, noAnsi: noAnsi);
  argv.add('pull');
  argv.addAll(services.map(validateComposeServiceName));
  return ComposeInvocation(argv);
}

/// `... compose ... restart` (03 §7.16 STK-23).
ComposeInvocation composeRestart({
  String binary = 'docker',
  required String socketPath,
  required String project,
  String? projectDirectory,
  List<String> configFiles = const [],
  String? envFile,
  List<String> services = const [],
}) {
  final argv = _sharedPrefix(
    binary: binary,
    socketPath: socketPath,
    project: project,
    projectDirectory: projectDirectory,
    configFiles: configFiles,
    envFile: envFile,
  )..add('restart');
  argv.addAll(services.map(validateComposeServiceName));
  return ComposeInvocation(argv);
}

/// `docker compose version` (03 §7.16 STK-05), used for CLI detection.
ComposeInvocation composeVersion({
  String binary = 'docker',
  required String socketPath,
  bool json = true,
}) {
  final argv = <String>[
    binary,
    '--host',
    validateSocketPath(socketPath),
    'compose',
    'version',
  ];
  if (json) {
    argv
      ..add('--format')
      ..add('json');
  }
  return ComposeInvocation(argv);
}

/// 03 §7.16 STK-06: `--progress plain --ansi never` are compose global
/// flags, so they precede the subcommand.
void _composeOutputFlags(
  List<String> argv, {
  required bool plainProgress,
  required bool noAnsi,
}) {
  if (plainProgress) {
    argv
      ..add('--progress')
      ..add('plain');
  }
  if (noAnsi) {
    argv
      ..add('--ansi')
      ..add('never');
  }
}
