// The shells and tools the real-shell suites (tag `shell`) build their
// matrix from. Those suites give a shell or tool that is not installed no
// tests, which suits a developer's machine and hides a lost shell in CI:
// skips are not counted. The CI job that runs them installs
// [shellMatrixPackages] and sets [requireShellMatrix], and
// shell_matrix_test.dart then fails on whatever is still missing.
import 'dart:io';

/// The environment variable that turns a missing shell or tool from a skip
/// into a failure. CI sets it to `1`; local runs leave it unset.
const requireShellMatrix = 'KLABAUTERMANN_REQUIRE_SHELL_MATRIX';

/// The Ubuntu packages that provide [shellMatrixShells] and
/// [shellMatrixTools] beyond what a minimal image carries.
const shellMatrixPackages = [
  'mksh',
  'busybox-static',
  'acl',
  'attr',
  'cron',
  'openssl',
  'gzip',
  'xz-utils',
];

/// The shells the suites run each script in. BusyBox stands for its `ash`
/// applet and for the BusyBox tool set.
const shellMatrixShells = ['dash', 'bash', 'mksh', 'busybox'];

/// The tools whose absence skips a test or lets a stand-in go unchecked
/// against the real one.
const shellMatrixTools = [
  'openssl',
  'getfacl',
  'getfattr',
  'crontab',
  'gzip',
  'zcat',
  'xz',
  'xzcat',
  'tail',
];

/// The directories the suites look for a shell in. Some read PATH too; the
/// strictest (ops_shell_test.dart) reads only these, so a shell elsewhere
/// would still lose that suite's cases.
const _shellDirectories = ['/bin', '/usr/bin'];

bool _shellInstalled(String name) =>
    _shellDirectories.any((dir) => File('$dir/$name').existsSync());

bool _toolInstalled(String name) =>
    Process.runSync('sh', ['-c', 'command -v "\$1"', 'sh', name]).exitCode == 0;

/// The entries of [shellMatrixShells] and [shellMatrixTools] this machine
/// lacks, in that order.
List<String> missingFromShellMatrix({
  bool Function(String name) shellInstalled = _shellInstalled,
  bool Function(String name) toolInstalled = _toolInstalled,
}) => [
  for (final shell in shellMatrixShells)
    if (!shellInstalled(shell)) shell,
  for (final tool in shellMatrixTools)
    if (!toolInstalled(tool)) tool,
];
