// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import 'package:test/test.dart';

import '../lib/release_finalize_cli.dart';
import '../lib/release_finalizer.dart';

const _repository = 'L-K-M/Poltergeist';
const _tag = 'v0.1.0';
const _fingerprint = '0123456789ABCDEF0123456789ABCDEF01234567';

void main() {
  test('requires an explicit 40-hex OpenPGP fingerprint', () async {
    final errors = <String>[];

    final missing = await runReleaseFinalizeCommand([
      '--repository',
      _repository,
      '--tag',
      _tag,
    ], writeError: errors.add);
    final malformed = await runReleaseFinalizeCommand([
      '--repository',
      _repository,
      '--tag',
      _tag,
      '--fingerprint',
      'short',
    ], writeError: errors.add);

    expect(missing, 64);
    expect(malformed, 64);
    expect(errors, everyElement(contains('--fingerprint')));
  });

  test('passes normalized arguments to the finalization action', () async {
    final sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-release-cli-test-',
    );
    addTearDown(() => sandbox.deleteSync(recursive: true));
    ReleaseFinalizeInvocation? invocation;
    final output = <String>[];

    final result = await runReleaseFinalizeCommand(
      [
        '--repository',
        _repository,
        '--tag',
        _tag,
        '--fingerprint',
        _fingerprint.toLowerCase(),
        '--repo-root',
        sandbox.path,
      ],
      action: (value) async {
        invocation = value;
        return const ReleaseFinalizationResult(
          ReleaseFinalizationStatus.published,
        );
      },
      writeOutput: output.add,
    );

    expect(result, 0);
    expect(invocation?.repository, _repository);
    expect(invocation?.tag, _tag);
    expect(invocation?.expectedFingerprint, _fingerprint);
    expect(invocation?.repositoryRoot.path, sandbox.absolute.path);
    expect(output.single, contains('published'));
  });

  test(
    'returns failure when verification leaves the release drafted',
    () async {
      final errors = <String>[];

      final result = await runReleaseFinalizeCommand(
        [
          '--repository',
          _repository,
          '--tag',
          _tag,
          '--fingerprint',
          _fingerprint,
        ],
        action: (_) async => const ReleaseFinalizationResult(
          ReleaseFinalizationStatus.draftMismatch,
          'bad digest',
        ),
        writeError: errors.add,
      );

      expect(result, 1);
      expect(errors.single, contains('bad digest'));
    },
  );
}
