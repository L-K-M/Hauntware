// The real-shell matrix is present where it is required (CI), so a runner
// image that drops a shell fails the job instead of quietly skipping that
// shell's cases. See shell_matrix.dart.
import 'dart:io';

import 'package:test/test.dart';

import 'shell_matrix.dart';

void main() {
  test('names each shell and tool this machine lacks', () {
    expect(
      missingFromShellMatrix(
        shellInstalled: (name) => name != 'mksh',
        toolInstalled: (name) => name != 'getfacl',
      ),
      ['mksh', 'getfacl'],
    );
    expect(
      missingFromShellMatrix(
        shellInstalled: (_) => true,
        toolInstalled: (_) => true,
      ),
      isEmpty,
    );
  });

  final required = Platform.environment[requireShellMatrix] == '1';

  test(
    'every shell and tool of the real-shell suites is installed',
    () {
      expect(
        missingFromShellMatrix(),
        isEmpty,
        reason:
            'the real-shell suites would skip these; install '
            '${shellMatrixPackages.join(' ')}',
      );
    },
    skip: required
        ? null
        : 'set $requireShellMatrix=1 to require the matrix (CI does)',
  );
}
