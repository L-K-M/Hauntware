import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _ownerName = 'Fixture Owner';
const _ownerEmail = 'owner@example.test';
const _authorEmail = 'author.only@example.test';
const _committerEmail = 'committer.only@example.test';
const _trailerEmail = 'trailer+only@example.test';
const _strandedEmail = 'stranded@example.test';
const _unknownEmail = 'unknown@example.test';
const _unrelatedEmail = 'unrelated@example.test';
const _replacementEmail = 'replacement@example.test';
const _bmpSortName = '';
const _nonBmpSortName = '𐀀';
const _component = 'seance';

void main() {
  late Directory sandbox;
  late _Fixture fixture;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('seance-audit-test-');
    fixture = await _Fixture.create(sandbox.path);
  });

  tearDown(() async {
    await sandbox.delete(recursive: true);
  });

  test(
    'audits recorded history and tree without local config rewrites',
    () async {
      final findings = await _audit(fixture, ['--print-findings']);

      expect(findings.exitCode, 0, reason: findings.stderr as String);
      final output = findings.stdout as String;

      expect(output, contains('$_ownerName <$_ownerEmail>'));
      expect(output, isNot(contains('laundered@example.test')));
      expect(output, isNot(contains(_unrelatedEmail)));
      expect(output, isNot(contains(_replacementEmail)));
      expect(output, contains('docs/café.txt'));
      expect(output, contains('NOTICE.md'));
      expect(output, contains('packages/seance_core/lib/core.dart'));
      expect(output, contains(fixture.componentTree));
      expect(
        output.indexOf(_bmpSortName),
        lessThan(output.indexOf(_nonBmpSortName)),
      );
      expect(output, contains('$_strandedEmail\t${fixture.strandedCommit}'));
      expect(output, contains('$_unknownEmail\t${fixture.strandedCommit}'));
      expect(
        output,
        contains('Mentored-by: Bare Name\t${fixture.strandedCommit}'),
      );
      expect(
        output,
        isNot(contains('$_trailerEmail\t${fixture.strandedCommit}\t')),
      );
    },
  );

  test('unions author, committer, and trailer pinpoint hits', () async {
    final findings = await _audit(fixture, ['--print-findings']);

    expect(findings.exitCode, 0, reason: findings.stderr as String);
    final output = findings.stdout as String;

    expect(output, contains('$_authorEmail\t${fixture.authorCommit}'));
    expect(output, contains('$_committerEmail\t${fixture.committerCommit}'));
    expect(output, contains('$_trailerEmail\t${fixture.trailerCommit}'));
  });

  test('records the imported lineage tip in the record', () async {
    final record = await _audit(fixture, ['--print-record']);

    expect(record.exitCode, 0, reason: record.stderr as String);
    final output = record.stdout as String;
    expect(output, contains('Lineage: `${fixture.standaloneTip}`'));
    expect(output, contains('Component: `seance/` tree'));
    expect(output, contains('(path dependency)'));
  });

  test('fails when any recorded audit section changes', () async {
    final generated = await _audit(fixture, ['--print-record']);
    expect(generated.exitCode, 0, reason: generated.stderr as String);

    final ports = File(p.join(fixture.root.path, 'docs', 'PORTS.md'));
    final record = generated.stdout as String;
    await ports.parent.create(recursive: true);
    await ports.writeAsString('# Ports\n\n$record');

    final passing = await _audit(fixture);
    expect(passing.exitCode, 0, reason: passing.stderr as String);

    for (final section in [
      'Identity',
      'Companion',
      'Companion orphans',
      'Pinpoints',
      'License scan',
      'Vendored paths',
      'Gitlinks',
      'Tree',
    ]) {
      final expression = RegExp('($section:.*sha256:)([0-9a-f])');
      final tampered = record.replaceFirstMapped(
        expression,
        (match) => '${match[1]}${match[2] == '0' ? '1' : '0'}',
      );
      expect(tampered, isNot(record), reason: 'missing $section digest');
      await ports.writeAsString('# Ports\n\n$tampered');

      final failing = await _audit(fixture);
      expect(failing.exitCode, isNot(0), reason: '$section was accepted');
      expect(failing.stderr, contains('record does not match'));
    }
  });

  test('rejects a shallow worktree', () async {
    final shallow = Directory(p.join(sandbox.path, 'shallow'));
    await _run('git', [
      'clone',
      '--depth=1',
      fixture.worktree.uri.toString(),
      shallow.path,
    ]);

    final result = await _audit(fixture, [
      '--root',
      p.join(shallow.path, 'poltergeist'),
      '--print-record',
    ]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('non-shallow'));
  });

  test('fails when manifest and lock Séance paths differ', () async {
    final manifest = File(
      p.join(fixture.root.path, 'tool', 'bench', 'pubspec.yaml'),
    );
    await manifest.writeAsString(
      (await manifest.readAsString()).replaceFirst(
        'seance/packages/seance_core',
        'seance/packages/seance_protocol',
      ),
    );

    final drift = await _audit(fixture, ['--print-record']);
    expect(drift.exitCode, isNot(0));
    expect(drift.stderr, contains('manifest and lock'));
  });

  test('rejects an external git Séance declaration', () async {
    final manifest = File(
      p.join(fixture.root.path, 'tool', 'bench', 'pubspec.yaml'),
    );
    await manifest.writeAsString('''name: fixture
dependencies:
  seance_core:
    git:
      url: "${fixture.worktree.uri}"
      ref: HEAD
      path: packages/seance_core
''');

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('external git source'));
  });

  test('rejects a Séance declaration without a path source', () async {
    final manifest = File(
      p.join(fixture.root.path, 'tool', 'bench', 'pubspec.yaml'),
    );
    await manifest.writeAsString('''name: fixture
dependencies:
  seance_core: ^1.1.0
''');

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('without a path source'));
  });

  test('rejects a Séance path outside the worktree', () async {
    final manifest = File(
      p.join(fixture.root.path, 'tool', 'bench', 'pubspec.yaml'),
    );
    await manifest.writeAsString('''name: fixture
dependencies:
  seance_core:
    path: ../../../../seance/packages/seance_core
''');

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('outside the worktree'));
  });

  test('rejects a Séance path outside the component', () async {
    final manifest = File(
      p.join(fixture.root.path, 'tool', 'bench', 'pubspec.yaml'),
    );
    await manifest.writeAsString('''name: fixture
dependencies:
  seance_core:
    path: ../bench_lib
''');
    await Directory(
      p.join(fixture.root.path, 'tool', 'bench_lib'),
    ).create(recursive: true);

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('outside the $_component component'));
  });

  test('rejects unaudited gitlinks', () async {
    await fixture.addGitlink();

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('gitlinks requiring a separate audit'));
  });

  test('does not let an unrelated lock cover the manifest', () async {
    final benchLock = File(
      p.join(fixture.root.path, 'tool', 'bench', 'pubspec.lock'),
    );
    final decoy = File(p.join(fixture.root.path, 'pubspec.lock'));
    await decoy.writeAsString(
      (await benchLock.readAsString()).replaceAll('../../../', '../'),
    );
    await benchLock.delete();

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('has no resolving lock'));
  });

  test('rejects uncommitted changes inside the component', () async {
    await File(
      p.join(fixture.worktree.path, 'seance', 'dirty.txt'),
    ).writeAsString('uncommitted\n');

    final result = await _audit(fixture, ['--print-record']);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('uncommitted changes'));
  });
}

Future<ProcessResult> _audit(
  _Fixture fixture, [
  List<String> extraArguments = const [],
]) {
  final script = p.join(
    Directory.current.path,
    'scripts',
    'audit-seance-pin.sh',
  );
  final arguments = <String>['--root', fixture.root.path, ...extraArguments];

  return Process.run(
    script,
    arguments,
    environment: {'DART_EXECUTABLE': Platform.resolvedExecutable},
  );
}

Future<ProcessResult> _run(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
  );
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed:\n${result.stderr}',
    );
  }

  return result;
}

/// A monorepo-shaped worktree: `seance/` arrives through a subtree merge
/// whose extra parent is the standalone-era tip, while the consuming
/// `poltergeist/tool/bench` package declares local path dependencies.
final class _Fixture {
  final Directory worktree;
  final Directory root;
  final String standaloneTip;
  final String componentTree;
  final String authorCommit;
  final String committerCommit;
  final String trailerCommit;
  final String strandedCommit;

  const _Fixture({
    required this.worktree,
    required this.root,
    required this.standaloneTip,
    required this.componentTree,
    required this.authorCommit,
    required this.committerCommit,
    required this.trailerCommit,
    required this.strandedCommit,
  });

  static Future<_Fixture> create(String sandboxPath) async {
    final worktree = Directory(p.join(sandboxPath, 'worktree'))
      ..createSync(recursive: true);

    await _run('git', ['init', '-b', 'main'], workingDirectory: worktree.path);
    await _write(worktree, 'README.md', 'worktree\n');
    await _commit(worktree, 'Base');
    final base = await _head(worktree);

    // Standalone era: the component's own history at un-prefixed paths.
    await _run('git', [
      'checkout',
      '--orphan',
      'seance-standalone',
    ], workingDirectory: worktree.path);
    await _run('git', ['rm', '-rf', '.'], workingDirectory: worktree.path);

    await _write(
      worktree,
      '.mailmap',
      'Laundered <laundered@example.test> <$_ownerEmail>\n',
    );
    await _write(
      worktree,
      'LICENSE',
      'This work is dedicated to the public domain.\n',
    );
    await _write(worktree, 'NOTICE.md', 'Licence inventory.\n');
    await _write(worktree, 'docs/café.txt', 'fixture\n');
    await _write(
      worktree,
      'packages/seance_core/pubspec.yaml',
      'name: seance_core\n',
    );
    await _write(
      worktree,
      'packages/seance_core/lib/core.dart',
      'const core = 1;\n',
    );
    await _write(
      worktree,
      'packages/seance_protocol/pubspec.yaml',
      'name: seance_protocol\n',
    );
    await _write(
      worktree,
      'packages/seance_protocol/lib/protocol.dart',
      'const protocol = 1;\n',
    );
    await _write(
      worktree,
      'third_party/vendored/LICENSE',
      'Vendored licence.\n',
    );
    await _commit(worktree, 'Initial fixture');

    await _write(worktree, 'bmp-sort.txt', 'bmp\n');
    await _commit(
      worktree,
      'BMP sort fixture',
      authorName: _bmpSortName,
      authorEmail: 'bmp@example.test',
    );

    await _write(worktree, 'non-bmp-sort.txt', 'non-bmp\n');
    await _commit(
      worktree,
      'Non-BMP sort fixture',
      authorName: _nonBmpSortName,
      authorEmail: 'non-bmp@example.test',
    );

    await _write(worktree, 'author.txt', 'author\n');
    final authorCommit = await _commit(
      worktree,
      'Author-only change',
      authorName: 'Author Only',
      authorEmail: _authorEmail,
    );

    await _write(worktree, 'committer.txt', 'committer\n');
    final committerCommit = await _commit(
      worktree,
      'Committer-only change',
      committerName: 'Committer Only',
      committerEmail: _committerEmail,
    );

    await _write(worktree, 'trailer.txt', 'trailer\n');
    final trailerCommit = await _commit(
      worktree,
      'Trailer-only change\n\nCo-authored-by: Trailer Only <$_trailerEmail>',
    );

    await _write(worktree, 'stranded.txt', 'stranded\n');
    final strandedCommit = await _commit(
      worktree,
      'Stranded attribution\n\n'
      'Co-Authored-By: Trailer Only <$_trailerEmail>\n'
      'Reported-by: Stranded Person <$_strandedEmail>\n'
      'Original-Author: Unknown Person <$_unknownEmail>\n'
      'Mentored-by: Bare Name\n\n'
      'This paragraph strands the attribution.',
    );
    final tip = await _head(worktree);

    await _run('git', [
      'checkout',
      '-b',
      'unrelated',
    ], workingDirectory: worktree.path);
    await _write(worktree, 'unrelated.txt', 'unrelated\n');
    await _commit(
      worktree,
      'Unrelated branch',
      authorName: 'Unrelated',
      authorEmail: _unrelatedEmail,
    );

    // A replacement object must never reach the evidence: the audit pins
    // --no-replace-objects on every Git read.
    final tipTree = (await _run('git', [
      'rev-parse',
      '$tip^{tree}',
    ], workingDirectory: worktree.path)).stdout.toString().trim();
    final replacement = (await _run(
      'git',
      ['commit-tree', tipTree, '-m', 'Replacement commit'],
      workingDirectory: worktree.path,
      environment: _identityEnvironment(
        authorName: 'Replacement',
        authorEmail: _replacementEmail,
        committerName: 'Replacement',
        committerEmail: _replacementEmail,
      ),
    )).stdout.toString().trim();
    await _run('git', [
      'replace',
      tip,
      replacement,
    ], workingDirectory: worktree.path);

    // Import merge: main carries the standalone tree under `seance/` with
    // the standalone tip as the second parent — the imported lineage.
    await _run('git', ['checkout', 'main'], workingDirectory: worktree.path);
    await _run('git', [
      'read-tree',
      '--empty',
    ], workingDirectory: worktree.path);
    await _run('git', ['read-tree', base], workingDirectory: worktree.path);
    await _run('git', [
      'read-tree',
      '--prefix=seance/',
      tip,
    ], workingDirectory: worktree.path);
    final mergeTree = (await _run('git', [
      'write-tree',
    ], workingDirectory: worktree.path)).stdout.toString().trim();
    final imported = (await _run(
      'git',
      [
        'commit-tree',
        mergeTree,
        '-p',
        base,
        '-p',
        tip,
        '-m',
        'Import Séance history',
      ],
      workingDirectory: worktree.path,
      environment: _identityEnvironment(
        authorName: _ownerName,
        authorEmail: _ownerEmail,
        committerName: _ownerName,
        committerEmail: _ownerEmail,
      ),
    )).stdout.toString().trim();
    await _run('git', [
      'update-ref',
      'refs/heads/main',
      imported,
    ], workingDirectory: worktree.path);
    await _run('git', ['reset', '--hard'], workingDirectory: worktree.path);

    // Post-import era: a commit inside the prefixed component plus the
    // consuming package's local path declaration and lock.
    await _write(
      worktree,
      'seance/packages/seance_core/lib/post_import.dart',
      'const postImport = 1;\n',
    );
    await _write(
      worktree,
      'poltergeist/tool/bench/pubspec.yaml',
      '''name: fixture
dependencies:
  seance_core:
    path: ../../../seance/packages/seance_core
''',
    );
    await _write(worktree, 'poltergeist/tool/bench/pubspec.lock', '''packages:
  seance_core:
    dependency: "direct main"
    description:
      path: "../../../seance/packages/seance_core"
      relative: true
    source: path
    version: "1.1.0"
  seance_protocol:
    dependency: transitive
    description:
      path: "../../../seance/packages/seance_protocol"
      relative: true
    source: path
    version: "1.1.0"
''');
    await _commit(
      worktree,
      'Wire local Séance sources',
      authorName: _ownerName,
      authorEmail: _ownerEmail,
    );

    final componentTree = (await _run('git', [
      'rev-parse',
      'HEAD:seance',
    ], workingDirectory: worktree.path)).stdout.toString().trim();

    return _Fixture(
      worktree: worktree,
      root: Directory(p.join(worktree.path, 'poltergeist')),
      standaloneTip: tip,
      componentTree: componentTree,
      authorCommit: authorCommit,
      committerCommit: committerCommit,
      trailerCommit: trailerCommit,
      strandedCommit: strandedCommit,
    );
  }

  Future<void> addGitlink() async {
    await _run('git', [
      'update-index',
      '--add',
      '--cacheinfo',
      '160000,$standaloneTip,$_component/external/module',
    ], workingDirectory: worktree.path);
    await _run(
      'git',
      ['commit', '-m', 'Add gitlink'],
      workingDirectory: worktree.path,
      environment: _identityEnvironment(
        authorName: _ownerName,
        authorEmail: _ownerEmail,
        committerName: _ownerName,
        committerEmail: _ownerEmail,
      ),
    );

    // A satisfied gitlink keeps the component clean so the audit reaches
    // the tree scan instead of the dirty-worktree guard.
    final module = Directory(
      p.join(worktree.path, _component, 'external', 'module'),
    );
    await _run('git', ['init', module.path]);
    await _run('git', [
      '-C',
      module.path,
      'fetch',
      worktree.path,
      'refs/heads/seance-standalone',
    ]);
    await _run('git', [
      '-C',
      module.path,
      'checkout',
      '--quiet',
      '--detach',
      'FETCH_HEAD',
    ]);
  }
}

Future<void> _write(
  Directory root,
  String relativePath,
  String contents,
) async {
  final file = File(p.join(root.path, relativePath));
  await file.parent.create(recursive: true);
  await file.writeAsString(contents);
}

Future<String> _commit(
  Directory repository,
  String message, {
  String authorName = _ownerName,
  String authorEmail = _ownerEmail,
  String committerName = _ownerName,
  String committerEmail = _ownerEmail,
}) async {
  await _run('git', ['add', '.'], workingDirectory: repository.path);
  await _run(
    'git',
    ['commit', '-m', message],
    workingDirectory: repository.path,
    environment: _identityEnvironment(
      authorName: authorName,
      authorEmail: authorEmail,
      committerName: committerName,
      committerEmail: committerEmail,
    ),
  );

  return _head(repository);
}

Map<String, String> _identityEnvironment({
  required String authorName,
  required String authorEmail,
  required String committerName,
  required String committerEmail,
}) => {
  'GIT_AUTHOR_NAME': authorName,
  'GIT_AUTHOR_EMAIL': authorEmail,
  'GIT_COMMITTER_NAME': committerName,
  'GIT_COMMITTER_EMAIL': committerEmail,
};

Future<String> _head(Directory repository) async {
  final result = await _run('git', [
    'rev-parse',
    'HEAD',
  ], workingDirectory: repository.path);

  return result.stdout.toString().trim();
}
