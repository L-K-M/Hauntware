// Gate code stays under tool/ so it cannot become an application dependency.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../lib/license_gate.dart';

const String _canonicalUnlicense = '''
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or distribute this software, either in source code form or as a compiled binary, for any purpose, commercial or non-commercial, and by any means.

In jurisdictions that recognize copyright laws, the author or authors of this software dedicate any and all copyright interest in the software to the public domain. We make this dedication for the benefit of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of relinquishment in perpetuity of all present and future rights to this software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <http://unlicense.org/>
''';

void main() {
  late Directory sandbox;
  late _GitFixture spdx;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-license-gate-test-',
    );
    spdx = _GitFixture.create(p.join(sandbox.path, 'spdx'), {
      'text/Unlicense.txt': _canonicalUnlicense,
    });
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('passes without Séance dependencies', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      includeMarker: false,
    );

    final report = await _verify(project, spdx, LicenseGateMode.markerOnly);

    expect(report.declarationCount, 0);
    expect(report.lockedSourceCount, 0);
  });

  test('requires the marker when a declaration is added', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
      includeMarker: false,
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('missing the required'),
        ),
      ),
    );
  });

  test('fails closed when a declaration has no lock entry', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
      includeLockEntry: false,
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('is not resolved'),
        ),
      ),
    );
  });

  test('fails closed when the lock resolves a different path', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
      lockPath: 'seance/packages/seance_protocol',
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('is not resolved'),
        ),
      ),
    );
  });

  test('fails closed on an external git declaration', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.directory, 'pubspec.yaml', '''
name: fixture
dependencies:
  seance_core:
    git:
      url: https://example.invalid/seance.git
      ref: v0.8.0
      path: packages/seance_core
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('external git source'),
        ),
      ),
    );
  });

  test('fails closed on a git lock source', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.directory, 'pubspec.lock', '''
packages:
  seance_core:
    dependency: "direct main"
    description:
      path: packages/seance_core
      ref: v0.8.0
      resolved-ref: ${'f' * 40}
      url: https://example.invalid/seance.git
    source: git
    version: "0.8.0"
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('external git source'),
        ),
      ),
    );
  });

  test('fails closed when the declaration escapes the worktree', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
      manifestPath: '../../outside/seance_core',
      lockPath: '/nonexistent/seance_core',
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('outside the worktree'),
        ),
      ),
    );
  });

  test('fails closed when the declaration leaves the component', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
      manifestPath: 'other/seance_core',
      lockPath: 'other/seance_core',
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('outside the seance component'),
        ),
      ),
    );
  });

  test('treats any path into seance/ as a Séance source', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
      includeMarker: false,
    );
    _write(project.directory, 'pubspec.yaml', '''
name: fixture
dependencies:
  core:
    path: ../seance/packages/seance_core
''');
    _write(project.directory, 'pubspec.lock', '''
packages:
  core:
    dependency: "direct main"
    description:
      path: ../seance/packages/seance_core
      relative: true
    source: path
    version: "0.8.0"
''');
    _commitProjectChanges(project.worktree);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('missing the required'),
        ),
      ),
    );
  });

  test('fails closed when a lock path entry has no usable path', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.directory, 'pubspec.lock', '''
packages:
  seance_core:
    dependency: "direct main"
    description:
      path: ../seance/packages/seance_core
      relative: false
    source: path
    version: "0.8.0"
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('no usable path resolution'),
        ),
      ),
    );
  });

  test('fails closed when the resolving lock is untracked', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _git(project.worktree, const [
      'rm',
      '--cached',
      'poltergeist/pubspec.lock',
    ]);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('committed and clean'),
        ),
      ),
    );
  });

  test('fails closed when dependency resolution changes the lock', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    final lock = File(p.join(project.directory.path, 'pubspec.lock'));
    lock.writeAsStringSync('${lock.readAsStringSync()}# changed by pub get\n');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('committed and clean'),
        ),
      ),
    );
  });

  test('fails closed on malformed dependency YAML', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      includeMarker: false,
    );
    _write(project.directory, 'pubspec.yaml', 'dependencies: [\n');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('invalid YAML'),
        ),
      ),
    );
  });

  test('does not let a root lock cover a standalone package', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.directory, 'tool/bench/pubspec.yaml', '''
name: bench
dependencies:
  seance_core:
    path: ../../../seance/packages/seance_core
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('not covered by a pubspec.lock'),
        ),
      ),
    );
  });

  for (final fileName in const ['pubspec.yaml', 'pubspec.lock']) {
    test('rejects a symlinked $fileName', () async {
      final project = _ProjectFixture.create(
        p.join(sandbox.path, 'project'),
        seanceFiles: const {'LICENSE': _canonicalUnlicense},
      );
      final file = File(p.join(project.directory.path, fileName));
      final targetName = 'real-$fileName';
      file.renameSync(p.join(project.directory.path, targetName));
      Link(file.path).createSync(targetName);

      await expectLater(
        _verify(project, spdx, LicenseGateMode.markerOnly),
        throwsA(
          isA<LicenseGateException>().having(
            (error) => error.message,
            'message',
            contains('symbolic link'),
          ),
        ),
      );
    });
  }

  test('requires the marker for a lock-only Séance source', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      includeMarker: false,
    );
    _write(project.directory, 'pubspec.lock', '''
packages:
  seance_protocol:
    dependency: transitive
    description:
      path: ../seance/packages/seance_protocol
      relative: true
    source: path
    version: "0.8.0"
''');
    _commitProjectChanges(project.worktree);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('missing the required'),
        ),
      ),
    );
  });

  test('scans tracked manifests under generated directory names', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
      includeMarker: false,
    );
    _write(project.directory, 'build/pubspec.yaml', '''
name: nested
dependencies:
  seance_core:
    path: ../../seance/packages/seance_core
''');
    _write(project.directory, 'build/pubspec.lock', '''
packages:
  seance_core:
    dependency: "direct main"
    description:
      path: ../../seance/packages/seance_core
      relative: true
    source: path
    version: "0.8.0"
''');
    _commitProjectChanges(project.worktree);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('missing the required'),
        ),
      ),
    );
  });

  test('accepts every permitted SPDX license and file name', () async {
    const licenses = {
      'Unlicense': 'canonical unlicense terms',
      'MIT': 'canonical mit terms',
      'Apache-2.0': 'canonical apache terms',
      'BSD-2-Clause': 'canonical bsd two terms',
      'BSD-3-Clause': 'canonical bsd three terms',
      'ISC': 'canonical isc terms',
    };
    const licenseFiles = {
      'LICENSE': 'canonical unlicense terms',
      'LICENSE.txt': 'canonical mit terms',
      'LICENSE.md': 'canonical apache terms',
      'LICENCE': 'canonical bsd two terms',
      'UNLICENSE': 'canonical bsd three terms',
      'COPYING': 'canonical isc terms',
    };
    final allSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-all'), {
      for (final entry in licenses.entries)
        'text/${entry.key}.txt': entry.value,
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: licenseFiles,
    );

    final report = await _verify(
      project,
      allSpdx,
      LicenseGateMode.release,
      permittedLicenseIds: licenses.keys.toSet(),
    );

    expect(report.matchedLicenseIds, licenses.keys.toSet());
  });

  test('ignores copyright notices wherever they appear', () async {
    final customSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-custom'), {
      'text/Unlicense.txt': 'first term\nsecond term',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': '''
Copyright 2024 Before
first term
Copyright (c) 2025 Middle
second term
Copyright © 2026 After
''',
      },
    );

    final report = await _verify(
      project,
      customSpdx,
      LicenseGateMode.release,
      permittedCopyrightHolders: {'Before', 'Middle', 'After'},
    );

    expect(report.matchedLicenseIds, {'Unlicense'});
  });

  test('does not erase substantive copyright restrictions', () async {
    final customSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-custom'), {
      'text/Unlicense.txt': 'first term\nsecond term',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': '''
first term
Copyright © 2026 Example disallows redistribution.
second term
''',
      },
    );

    await expectLater(
      _verify(project, customSpdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('non-permitted LICENSE'),
        ),
      ),
    );
  });

  test('does not mistake a limited grant for a holder name', () async {
    final customSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-custom'), {
      'text/Unlicense.txt': 'first term\nsecond term',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': '''
first term
Copyright © 2026 Example grants use only for evaluation.
second term
''',
      },
    );

    await expectLater(
      _verify(project, customSpdx, LicenseGateMode.release),
      throwsA(isA<LicenseGateException>()),
    );
  });

  for (final restriction in const [
    'ACME PERSONAL USE ONLY',
    'Acme Proprietary',
    'Acme No Sharing',
    'Acme Not Free',
  ]) {
    test('does not erase notice-shaped restriction: $restriction', () async {
      final customSpdx = _GitFixture.create(
        p.join(sandbox.path, 'spdx-custom'),
        {'text/Unlicense.txt': 'first term\nsecond term'},
      );
      final project = _ProjectFixture.create(
        p.join(sandbox.path, 'project'),
        seanceFiles: {
          'LICENSE':
              '''
first term
Copyright 2026 $restriction
second term
''',
        },
      );

      await expectLater(
        _verify(project, customSpdx, LicenseGateMode.release),
        throwsA(isA<LicenseGateException>()),
      );
    });
  }

  test('matches an Apache placeholder to an actual notice', () async {
    final customSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-custom'), {
      'text/Apache-2.0.txt': '''
first term
Copyright [yyyy] [name of copyright owner]
second term
''',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': '''
first term
Copyright 2026 Example
second term
''',
      },
    );

    final report = await _verify(
      project,
      customSpdx,
      LicenseGateMode.release,
      permittedLicenseIds: {'Apache-2.0'},
      permittedCopyrightHolders: {'Example'},
    );

    expect(report.matchedLicenseIds, {'Apache-2.0'});
  });

  test('accepts the canonical Unlicense from the component tree', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );

    final report = await _verify(project, spdx, LicenseGateMode.release);

    expect(report.lockedSourceCount, 1);
    expect(report.matchedLicenseIds, {'Unlicense'});
  });

  test('keeps upstream holders on vendored licenses', () async {
    final mitSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-mit'), {
      'text/Unlicense.txt': _canonicalUnlicense,
      'text/MIT.txt': 'mit terms',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': _canonicalUnlicense,
        'third_party/flutter_pty/LICENSE':
            'Copyright 2024 Upstream Author\nmit terms',
      },
    );

    final report = await _verify(
      project,
      mitSpdx,
      LicenseGateMode.release,
      permittedLicenseIds: {'Unlicense', 'MIT'},
    );

    expect(report.matchedLicenseIds, {'Unlicense', 'MIT'});
  });

  test('matches vendored licenses with a different title line', () async {
    // Vendored files carry their own heading ("The MIT License (MIT)")
    // while the SPDX corpus prints "MIT License"; the license body is
    // what must match.
    const body = 'Permission is hereby granted to deal in the Software.';
    final mitSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-mit'), {
      'text/Unlicense.txt': _canonicalUnlicense,
      'text/MIT.txt':
          'MIT License\n\nCopyright (c) <year> <copyright holders>\n\n$body',
    });
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': _canonicalUnlicense,
        'third_party/flutter_pty/LICENSE':
            'The MIT License (MIT)\n\nCopyright (c) 2022 xuty\n\n$body',
      },
    );

    final report = await _verify(
      project,
      mitSpdx,
      LicenseGateMode.release,
      permittedLicenseIds: {'Unlicense', 'MIT'},
    );

    expect(report.matchedLicenseIds, {'Unlicense', 'MIT'});
  });

  test('rejects a restricted title line over an MIT body', () async {
    // The title alias list is exact: a restricted or foreign heading
    // must stay part of the body comparison instead of being stripped.
    const body = 'Permission is hereby granted to deal in the Software.';
    final mitSpdx = _GitFixture.create(p.join(sandbox.path, 'spdx-mit'), {
      'text/Unlicense.txt': _canonicalUnlicense,
      'text/MIT.txt':
          'MIT License\n\nCopyright (c) <year> <copyright holders>\n\n$body',
    });
    for (final title in const [
      'MIT License - Non-Commercial Only',
      'Acme Proprietary License',
    ]) {
      final project = _ProjectFixture.create(
        p.join(sandbox.path, 'project-$title'),
        seanceFiles: {
          'LICENSE': _canonicalUnlicense,
          'third_party/flutter_pty/LICENSE':
              '$title\n\nCopyright (c) 2022 xuty\n\n$body',
        },
      );

      await expectLater(
        _verify(
          project,
          mitSpdx,
          LicenseGateMode.release,
          permittedLicenseIds: {'Unlicense', 'MIT'},
        ),
        throwsA(
          isA<LicenseGateException>().having(
            (error) => error.message,
            'message',
            contains('non-permitted third_party/flutter_pty/LICENSE'),
          ),
        ),
        reason: title,
      );
    }
  });

  test('rejects a restrictive vendored license', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': _canonicalUnlicense,
        'third_party/widget/LICENSE': 'GNU GENERAL PUBLIC LICENSE Version 3',
      },
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('non-permitted third_party/widget/LICENSE'),
        ),
      ),
    );
  });

  test('ignores license-looking names outside vendored directories', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': _canonicalUnlicense,
        'docs/sample/LICENSE': 'not a real license at all',
      },
    );

    final report = await _verify(project, spdx, LicenseGateMode.release);

    expect(report.matchedLicenseIds, {'Unlicense'});
  });

  test('rejects uncommitted changes inside the component', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, 'seance/LICENSE', 'now uncommitted\n');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('uncommitted changes'),
        ),
      ),
    );
  });

  test('rejects a missing license in the component', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'README.md': 'No license yet.'},
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('no recognized license'),
        ),
      ),
    );
  });

  test('rejects restrictive content under a recognized name', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'COPYING': 'GNU GENERAL PUBLIC LICENSE Version 3'},
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('non-permitted COPYING'),
        ),
      ),
    );
  });

  test('checks the committed component tree, not the working tree', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    // An uncommitted restrictive COPYING is ignored by the scan, but the
    // dirty component itself still fails closed.
    _write(
      project.worktree,
      'seance/COPYING',
      'GNU GENERAL PUBLIC LICENSE Version 3',
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('uncommitted changes'),
        ),
      ),
    );
  });

  test('rejects a second restrictive license candidate', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': _canonicalUnlicense,
        'COPYING': 'GNU GENERAL PUBLIC LICENSE Version 3',
      },
    );

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('non-permitted COPYING'),
        ),
      ),
    );
  });

  test('rejects a restrictive source among multiple locks', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {
        'LICENSE': _canonicalUnlicense,
        'packages/seance_protocol/pubspec.yaml':
            'name: seance_protocol\nversion: 0.8.0\n',
        'third_party/bad/LICENSE': 'Copyright holders prohibit redistribution.',
      },
      lockPath: 'seance/packages/seance_core',
    );
    final lock = File(p.join(project.directory.path, 'pubspec.lock'));
    lock.writeAsStringSync('''
${lock.readAsStringSync()}
  seance_protocol:
    dependency: transitive
    description:
      path: ../seance/packages/seance_protocol
      relative: true
    source: path
    version: "0.8.0"
''');
    _commitProjectChanges(project.worktree);

    await expectLater(
      _verify(project, spdx, LicenseGateMode.release),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('non-permitted'),
        ),
      ),
    );
  });

  test('rejects a gate that runs before dependency resolution', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  gate:
    steps:
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: dart pub get
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('before dependency resolution'),
        ),
      ),
    );
  });

  test('rejects a publisher that bypasses the gate job', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  gate:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
  build:
    steps:
      - run: echo build
  publish:
    needs: build
    steps:
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('bypasses the license gate'),
        ),
      ),
    );
  });

  test('accepts the monorepo draft-attach/publish-point graph', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    // Mirrors the root release.yml shape: build legs attach to the
    // hidden draft in parallel with the job carrying the full gate,
    // while the draft flip and the image push sit behind needs chains
    // that include the gate job.
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  test:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart --marker-only
  server:
    needs: test
    steps:
      - uses: softprops/action-gh-release@v3
        with:
          draft: true
  client:
    needs: test
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - uses: softprops/action-gh-release@v3
        with:
          draft: true
  docker:
    needs:
      - test
      - server
      - client
    steps:
      - uses: docker/build-push-action@v7
        with:
          push: true
  sums:
    needs:
      - server
      - client
      - docker
    steps:
      - run: gh release edit "\$TAG" --draft=false
''');

    final report = await _verify(project, spdx, LicenseGateMode.markerOnly);
    expect(report.lockedSourceCount, greaterThan(0));
  });

  test('rejects an ungated draft-flip publish point', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  gate:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
  attach:
    needs: gate
    steps:
      - uses: softprops/action-gh-release@v3
        with:
          draft: true
  sums:
    steps:
      - run: gh release edit "\$TAG" --draft=false
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('bypasses the license gate'),
        ),
      ),
    );
  });

  test('rejects a draft-flip flag hidden on a continued line', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  gate:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
  attach:
    needs: gate
    steps:
      - uses: softprops/action-gh-release@v3
        with:
          draft: true
  sums:
    steps:
      - run: |
          gh release edit "\$TAG" \\
            --draft=false
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('bypasses the license gate'),
        ),
      ),
    );
  });

  test('rejects an ungated container-image push', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  gate:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
  attach:
    needs: gate
    steps:
      - uses: softprops/action-gh-release@v3
        with:
          draft: true
  build:
    steps:
      - run: echo build
  docker:
    needs: build
    steps:
      - uses: docker/build-push-action@v7
        with:
          push: true
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('bypasses the license gate'),
        ),
      ),
    );
  });

  test('accepts a direct publish leg that needs the gate job', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  gate:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
  publish:
    needs: gate
    steps:
      - uses: softprops/action-gh-release@v3
''');

    final report = await _verify(project, spdx, LicenseGateMode.markerOnly);
    expect(report.lockedSourceCount, greaterThan(0));
  });

  test('rejects a disabled gate step', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - if: false
        run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('rejects a soft-failing gate step', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - continue-on-error: true
        run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('rejects a commented marker paired with an echo', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      # run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: echo dart run tool/license_gate/bin/check.dart
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('rejects a same-job gate after publishing', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - uses: softprops/action-gh-release@v2
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(isA<LicenseGateException>()),
    );
  });

  test('allows a post-gate flutter build against the committed lock', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: flutter build apk
      - uses: softprops/action-gh-release@v2
''');

    final report = await _verify(project, spdx, LicenseGateMode.markerOnly);
    // The workflow this test verifies carries a real post-gate
    // `flutter build` step; the gate must accept it.
    expect(report.lockedSourceCount, greaterThan(0));
  });

  test('rejects pub add after the gate', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: flutter pub add some_dep
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('after the license gate'),
        ),
      ),
    );
  });

  test('rejects pub in backticks and subshells', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: echo `flutter pub get` \$(dart pub upgrade)
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('after the license gate'),
        ),
      ),
    );
  });

  test('rejects pub chained after another command', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: echo prep && flutter pub get; flutter pub upgrade
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('after the license gate'),
        ),
      ),
    );
  });

  test('rejects dependency resolution after the gate', () async {
    final project = _ProjectFixture.create(
      p.join(sandbox.path, 'project'),
      seanceFiles: const {'LICENSE': _canonicalUnlicense},
    );
    _write(project.worktree, '.github/workflows/release.yml', '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - run: dart pub upgrade
      - uses: softprops/action-gh-release@v2
''');

    await expectLater(
      _verify(project, spdx, LicenseGateMode.markerOnly),
      throwsA(
        isA<LicenseGateException>().having(
          (error) => error.message,
          'message',
          contains('after the license gate'),
        ),
      ),
    );
  });
}

Future<LicenseGateReport> _verify(
  _ProjectFixture project,
  _GitFixture spdx,
  LicenseGateMode mode, {
  Set<String> permittedLicenseIds = const {'Unlicense'},
  Set<String> permittedCopyrightHolders = const {'L-K-M'},
}) => verifySeanceLicenseGate(
  repositoryRoot: project.directory,
  mode: mode,
  settings: LicenseGateSettings(
    spdxRepository: spdx.directory.path,
    spdxRevision: spdx.revision,
    permittedLicenseIds: permittedLicenseIds,
    permittedCopyrightHolders: permittedCopyrightHolders,
  ),
);

/// A monorepo-shaped fixture: a Git worktree whose root holds the `seance/`
/// component, the `.github` release pipeline, and the `poltergeist/` scan
/// root the gate runs against.
final class _ProjectFixture {
  /// The directory passed as `repositoryRoot` — `poltergeist/` inside the
  /// worktree, matching the release job's working directory.
  final Directory directory;

  /// The Git worktree toplevel.
  final Directory worktree;

  const _ProjectFixture._(this.directory, this.worktree);

  static _ProjectFixture create(
    String path, {
    Map<String, String>? seanceFiles,
    bool includeMarker = true,
    bool includeLockEntry = true,
    String manifestPath = '../seance/packages/seance_core',
    String lockPath = 'seance/packages/seance_core',
  }) {
    final worktree = Directory(path)..createSync(recursive: true);
    _write(
      worktree,
      '.github/workflows/release.yml',
      includeMarker
          ? '''
jobs:
  publish:
    steps:
      - run: dart pub get
      - run: dart run tool/license_gate/bin/check.dart # $seanceLicenseGateMarker
      - uses: softprops/action-gh-release@v2
'''
          : 'name: Release\n',
    );
    final project = Directory(p.join(worktree.path, 'poltergeist'));

    if (seanceFiles == null) {
      _write(project, 'pubspec.yaml', 'name: fixture\n');
      _write(project, 'pubspec.lock', 'packages: {}\n');
      _commitProject(worktree);
      return _ProjectFixture._(project, worktree);
    }

    _write(
      worktree,
      'seance/packages/seance_core/pubspec.yaml',
      'name: seance_core\nversion: 0.8.0\n',
    );
    for (final entry in seanceFiles.entries) {
      _write(worktree, p.join('seance', entry.key), entry.value);
    }

    _write(project, 'pubspec.yaml', '''
name: fixture
dependencies:
  seance_core:
    path: $manifestPath
''');
    _write(
      project,
      'pubspec.lock',
      includeLockEntry
          ? '''
packages:
  seance_core:
    dependency: "direct main"
    description:
      path: ${p.isAbsolute(lockPath) ? lockPath : '../$lockPath'}
      relative: ${p.isAbsolute(lockPath) ? 'false' : 'true'}
    source: path
    version: "0.8.0"
'''
          : 'packages: {}\n',
    );
    _commitProject(worktree);
    return _ProjectFixture._(project, worktree);
  }
}

final class _GitFixture {
  final Directory directory;
  String revision;

  _GitFixture._(this.directory, this.revision);

  static _GitFixture create(String path, Map<String, String> files) {
    final directory = Directory(path)..createSync(recursive: true);
    _git(directory, const ['init', '--quiet']);
    _git(directory, const ['config', 'user.name', 'Fixture']);
    _git(directory, const ['config', 'user.email', 'fixture@example.invalid']);
    final fixture = _GitFixture._(directory, '');
    fixture.commit(files);
    return fixture;
  }

  void commit(Map<String, String> files) {
    for (final entry in files.entries) {
      _write(directory, entry.key, entry.value);
    }
    _git(directory, const ['add', '.']);
    _git(directory, const ['commit', '--quiet', '-m', 'Fixture']);
    revision = _git(directory, const ['rev-parse', 'HEAD']).trim();
  }
}

void _write(Directory root, String relativePath, String contents) {
  final file = File(p.join(root.path, relativePath));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(contents);
}

void _commitProject(Directory directory) {
  _git(directory, const ['init', '--quiet']);
  _git(directory, const ['config', 'user.name', 'Fixture']);
  _git(directory, const ['config', 'user.email', 'fixture@example.invalid']);
  _git(directory, const ['add', '.']);
  _git(directory, const ['commit', '--quiet', '-m', 'Fixture']);
}

void _commitProjectChanges(Directory directory) {
  _git(directory, const ['add', '.']);
  _git(directory, const ['commit', '--quiet', '-m', 'Change fixture']);
}

String _git(Directory directory, List<String> arguments) {
  final result = Process.runSync(
    'git',
    arguments,
    workingDirectory: directory.path,
  );
  if (result.exitCode == 0) return result.stdout as String;

  throw StateError('git ${arguments.join(' ')}: ${result.stderr}');
}
