// Release tooling stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../release_support/lib/release_artifacts.dart';
import '../lib/release_finalize_adapters.dart';
import '../lib/release_finalizer.dart';
import '../lib/release_process.dart';

const _repository = 'L-K-M/Poltergeist';
const _tag = 'v0.1.0';
const _commit = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _tagObject = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _fingerprint = '0123456789ABCDEF0123456789ABCDEF01234567';
const _identity = '71';

void main() {
  group('GitGpgReleaseSignatureService', () {
    test('verifies the exact remote tag object, commit, and signer', () async {
      final runner = _FakeProcessRunner([
        _textResult('tag\n'),
        _textResult('$_tagObject\n'),
        _textResult('$_commit\n'),
        _textResult('', standardError: _validSignatureStatus(_fingerprint)),
        _jsonResult({
          'object': {'type': 'tag', 'sha': _tagObject},
        }),
        _jsonResult({
          'tag': _tag,
          'object': {'type': 'commit', 'sha': _commit},
        }),
      ]);
      final service = GitGpgReleaseSignatureService.withRunner(
        repository: _repository,
        repositoryRoot: Directory.current,
        runner: runner,
      );

      await service.verifyTag(
        tag: _tag,
        expectedFingerprint: _fingerprint.toLowerCase(),
      );

      expect(runner.calls.map((call) => call.executable), [
        'git',
        'git',
        'git',
        'git',
        'gh',
        'gh',
      ]);
      expect(runner.calls[3].arguments, containsAll(['verify-tag', '--raw']));
      expect(
        runner.calls[4].arguments,
        contains('repos/$_repository/git/ref/tags/$_tag'),
      );
    });

    test('rejects a signer outside the expected primary key', () async {
      const otherFingerprint = '89ABCDEF0123456789ABCDEF0123456789ABCDEF';
      final runner = _FakeProcessRunner([
        _textResult('tag\n'),
        _textResult('$_tagObject\n'),
        _textResult('$_commit\n'),
        _textResult('', standardError: _validSignatureStatus(otherFingerprint)),
      ]);
      final service = GitGpgReleaseSignatureService.withRunner(
        repository: _repository,
        repositoryRoot: Directory.current,
        runner: runner,
      );

      await expectLater(
        service.verifyTag(tag: _tag, expectedFingerprint: _fingerprint),
        throwsA(
          isA<ReleaseFinalizeException>().having(
            (error) => error.message,
            'message',
            contains(otherFingerprint),
          ),
        ),
      );
      expect(runner.calls, hasLength(4));
    });

    test('creates an armored detached signature without overwrite', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-sign-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final sums = File(p.join(sandbox.path, 'SHA256SUMS'))
        ..writeAsStringSync('digest  asset\n');
      final runner = _FakeProcessRunner(
        [_textResult('')],
        callbacks: [
          (call) {
            File(p.join(sandbox.path, 'SHA256SUMS.asc')).writeAsStringSync(
              '-----BEGIN PGP SIGNATURE-----\nsigned\n'
              '-----END PGP SIGNATURE-----\n',
            );
          },
        ],
      );
      final service = GitGpgReleaseSignatureService.withRunner(
        repository: _repository,
        repositoryRoot: Directory.current,
        runner: runner,
      );

      final signature = await service.signChecksums(
        checksums: sums,
        expectedFingerprint: _fingerprint,
      );

      expect(p.basename(signature.path), 'SHA256SUMS.asc');
      expect(runner.calls.single.arguments, contains('--detach-sign'));
      expect(runner.calls.single.arguments, isNot(contains('--yes')));
      expect(runner.calls.single.arguments, contains(_fingerprint));
    });

    test('verifies a detached signature against the expected key', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-verify-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final sums = File(p.join(sandbox.path, 'SHA256SUMS'))
        ..writeAsStringSync('digest  asset\n');
      final signature = File(p.join(sandbox.path, 'SHA256SUMS.asc'))
        ..writeAsStringSync(
          '-----BEGIN PGP SIGNATURE-----\nsigned\n'
          '-----END PGP SIGNATURE-----\n',
        );
      final runner = _FakeProcessRunner([
        _textResult(_validSignatureStatus(_fingerprint)),
      ]);
      final service = GitGpgReleaseSignatureService.withRunner(
        repository: _repository,
        repositoryRoot: Directory.current,
        runner: runner,
      );

      await service.verifyChecksumSignature(
        checksums: sums,
        signature: signature,
        expectedFingerprint: _fingerprint,
      );

      expect(runner.calls.single.executable, 'gpg');
      expect(
        runner.calls.single.arguments,
        containsAll(['--status-fd=1', '--verify']),
      );
    });

    test('treats an ERRSIG verification failure as inconclusive', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-errsig-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final sums = File(p.join(sandbox.path, 'SHA256SUMS'))
        ..writeAsStringSync('digest  asset\n');
      final signature = File(p.join(sandbox.path, 'SHA256SUMS.asc'))
        ..writeAsStringSync(
          '-----BEGIN PGP SIGNATURE-----\nsigned\n'
          '-----END PGP SIGNATURE-----\n',
        );
      final runner = _FakeProcessRunner([
        const ReleaseProcessResult(
          exitCode: 2,
          standardOutput: '[GNUPG:] ERRSIG 0123456789ABCDEF 1 10 00 0 9\n',
        ),
      ]);
      final service = GitGpgReleaseSignatureService.withRunner(
        repository: _repository,
        repositoryRoot: Directory.current,
        runner: runner,
      );

      await expectLater(
        service.verifyChecksumSignature(
          checksums: sums,
          signature: signature,
          expectedFingerprint: _fingerprint,
        ),
        throwsA(
          isA<ReleaseFinalizeException>().having(
            (error) => error.kind,
            'kind',
            ReleaseFinalizeFailureKind.inconclusive,
          ),
        ),
      );
    });
  });

  group('GhReleaseRepository', () {
    test(
      'downloads one exact unsigned draft and checks every digest',
      () async {
        final sandbox = Directory.systemTemp.createTempSync(
          'poltergeist-release-download-test-',
        );
        addTearDown(() => sandbox.deleteSync(recursive: true));
        final payloads = _payloadContents();
        final runner = _FakeProcessRunner([
          _releaseResult(payloads),
          for (final name in _downloadNames(payloads))
            _binaryResult(
              name == 'SHA256SUMS'
                  ? utf8.encode(_checksumText(payloads))
                  : payloads[name]!,
            ),
        ]);
        final signatures = _FakeSignatureService();
        final repository = GhReleaseRepository.withRunner(
          repository: _repository,
          signatures: signatures,
          expectedFingerprint: _fingerprint,
          runner: runner,
        );
        final destination = Directory(p.join(sandbox.path, 'candidate'));

        final candidate = await repository.downloadUnsignedDraft(
          tag: _tag,
          expectedSourceCommit: _commit,
          destination: destination,
        );

        expect(candidate.checksums.readAsStringSync(), _checksumText(payloads));
        expect(destination.listSync(), hasLength(8));
        expect(runner.fileCalls, hasLength(8));
        expect(signatures.verifyCalls, isEmpty);
      },
    );

    test('rejects a pre-existing signature before downloading', () async {
      final payloads = _payloadContents();
      final runner = _FakeProcessRunner([
        _releaseResult(payloads, signature: _SignatureAsset.present),
      ]);
      final repository = GhReleaseRepository.withRunner(
        repository: _repository,
        signatures: _FakeSignatureService(),
        expectedFingerprint: _fingerprint,
        runner: runner,
      );

      await expectLater(
        repository.downloadUnsignedDraft(
          tag: _tag,
          expectedSourceCommit: _commit,
          destination: Directory.systemTemp.createTempSync(
            'poltergeist-release-existing-signature-test-',
          ),
        ),
        throwsA(
          isA<ReleaseFinalizeException>().having(
            (error) => error.message,
            'message',
            contains('SHA256SUMS.asc'),
          ),
        ),
      );
      expect(runner.fileCalls, isEmpty);
    });

    test('rejects a malformed extra asset set', () async {
      final payloads = _payloadContents();
      final runner = _FakeProcessRunner([
        _releaseResult(payloads, extraAsset: 'surprise.zip'),
      ]);
      final repository = GhReleaseRepository.withRunner(
        repository: _repository,
        signatures: _FakeSignatureService(),
        expectedFingerprint: _fingerprint,
        runner: runner,
      );

      await expectLater(
        repository.downloadUnsignedDraft(
          tag: _tag,
          expectedSourceCommit: _commit,
          destination: Directory.systemTemp.createTempSync(
            'poltergeist-release-extra-test-',
          ),
        ),
        throwsA(
          isA<ReleaseFinalizeException>().having(
            (error) => error.message,
            'message',
            contains('surprise.zip'),
          ),
        ),
      );
    });

    test('rejects a draft bound to an earlier signed-tag commit', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-stale-source-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final payloads = _payloadContents();
      final runner = _FakeProcessRunner([
        _releaseResult(payloads),
        for (final name in _downloadNames(payloads))
          _binaryResult(
            name == 'SHA256SUMS'
                ? utf8.encode(_checksumText(payloads))
                : payloads[name]!,
          ),
      ]);
      final repository = GhReleaseRepository.withRunner(
        repository: _repository,
        signatures: _FakeSignatureService(),
        expectedFingerprint: _fingerprint,
        runner: runner,
      );

      await expectLater(
        repository.downloadUnsignedDraft(
          tag: _tag,
          expectedSourceCommit: 'cccccccccccccccccccccccccccccccccccccccc',
          destination: Directory(p.join(sandbox.path, 'candidate')),
        ),
        throwsA(
          isA<ReleaseFinalizeException>().having(
            (error) => error.kind,
            'kind',
            ReleaseFinalizeFailureKind.policyMismatch,
          ),
        ),
      );
    });

    test('uploads through the full asset endpoint without clobber', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-upload-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final signature = File(p.join(sandbox.path, 'SHA256SUMS.asc'))
        ..writeAsStringSync(
          '-----BEGIN PGP SIGNATURE-----\nsigned\n'
          '-----END PGP SIGNATURE-----\n',
        );
      final payloads = _payloadContents();
      final runner = _FakeProcessRunner([
        _releaseResult(payloads),
        for (final name in _downloadNames(payloads))
          _binaryResult(
            name == 'SHA256SUMS'
                ? utf8.encode(_checksumText(payloads))
                : payloads[name]!,
          ),
        _pinnedReleaseResult(payloads),
        _jsonResult({'id': 99, 'name': 'SHA256SUMS.asc'}),
      ]);
      final repository = GhReleaseRepository.withRunner(
        repository: _repository,
        signatures: _FakeSignatureService(),
        expectedFingerprint: _fingerprint,
        runner: runner,
      );

      final candidate = await repository.downloadUnsignedDraft(
        tag: _tag,
        expectedSourceCommit: _commit,
        destination: Directory(p.join(sandbox.path, 'candidate')),
      );
      await repository.uploadSignature(
        candidate: candidate,
        signature: signature,
      );

      final upload = runner.calls.last;
      expect(upload.arguments, contains('--input'));
      expect(upload.arguments, contains(signature.path));
      expect(upload.arguments.join(' '), isNot(contains('clobber')));
      expect(upload.arguments, isNot(contains('--hostname')));
      expect(
        upload.arguments.last,
        'https://uploads.github.com/repos/$_repository/releases/71/'
        'assets?name=SHA256SUMS.asc',
      );
    });

    test('classifies an uncertain upload response as inconclusive', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-upload-response-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final signature = File(p.join(sandbox.path, 'SHA256SUMS.asc'))
        ..writeAsStringSync(
          '-----BEGIN PGP SIGNATURE-----\nsigned\n'
          '-----END PGP SIGNATURE-----\n',
        );
      final payloads = _payloadContents();
      final runner = _FakeProcessRunner([
        _releaseResult(payloads),
        for (final name in _downloadNames(payloads))
          _binaryResult(
            name == 'SHA256SUMS'
                ? utf8.encode(_checksumText(payloads))
                : payloads[name]!,
          ),
        _pinnedReleaseResult(payloads),
        const ReleaseProcessResult(exitCode: 1, standardError: 'response lost'),
      ]);
      final repository = GhReleaseRepository.withRunner(
        repository: _repository,
        signatures: _FakeSignatureService(),
        expectedFingerprint: _fingerprint,
        runner: runner,
      );
      final candidate = await repository.downloadUnsignedDraft(
        tag: _tag,
        expectedSourceCommit: _commit,
        destination: Directory(p.join(sandbox.path, 'candidate')),
      );

      await expectLater(
        repository.uploadSignature(candidate: candidate, signature: signature),
        throwsA(
          isA<ReleaseFinalizeException>()
              .having(
                (error) => error.kind,
                'kind',
                ReleaseFinalizeFailureKind.inconclusive,
              )
              .having(
                (error) => error.message,
                'message',
                contains('response lost'),
              ),
        ),
      );
      expect(
        runner.calls.last.arguments.last,
        contains('/releases/71/assets?name=SHA256SUMS.asc'),
      );
    });

    test(
      'refuses to upload to a replacement release with the same tag',
      () async {
        final sandbox = Directory.systemTemp.createTempSync(
          'poltergeist-release-replacement-test-',
        );
        addTearDown(() => sandbox.deleteSync(recursive: true));
        final signature = File(p.join(sandbox.path, 'SHA256SUMS.asc'))
          ..writeAsStringSync(
            '-----BEGIN PGP SIGNATURE-----\nsigned\n'
            '-----END PGP SIGNATURE-----\n',
          );
        final payloads = _payloadContents();
        final runner = _FakeProcessRunner([
          _releaseResult(payloads, releaseId: 71),
          for (final name in _downloadNames(payloads))
            _binaryResult(
              name == 'SHA256SUMS'
                  ? utf8.encode(_checksumText(payloads))
                  : payloads[name]!,
            ),
          _pinnedReleaseResult(payloads, releaseId: 72),
        ]);
        final repository = GhReleaseRepository.withRunner(
          repository: _repository,
          signatures: _FakeSignatureService(),
          expectedFingerprint: _fingerprint,
          runner: runner,
        );
        final candidate = await repository.downloadUnsignedDraft(
          tag: _tag,
          expectedSourceCommit: _commit,
          destination: Directory(p.join(sandbox.path, 'candidate')),
        );

        await expectLater(
          repository.uploadSignature(
            candidate: candidate,
            signature: signature,
          ),
          throwsA(
            isA<ReleaseFinalizeException>().having(
              (error) => error.message,
              'message',
              contains('release identity'),
            ),
          ),
        );
        expect(
          runner.calls.where((call) => call.arguments.contains('POST')),
          isEmpty,
        );
      },
    );

    test(
      'treats stale draft visibility after publish as inconclusive',
      () async {
        final payloads = _payloadContents();
        final runner = _FakeProcessRunner([
          _releaseResult(payloads),
          for (final name in _downloadNames(payloads))
            _binaryResult(
              name == 'SHA256SUMS'
                  ? utf8.encode(_checksumText(payloads))
                  : payloads[name]!,
            ),
          _pinnedReleaseResult(payloads),
          _textResult(''),
          _pinnedReleaseResult(payloads, signature: _SignatureAsset.present),
        ]);
        final repository = GhReleaseRepository.withRunner(
          repository: _repository,
          signatures: _FakeSignatureService(),
          expectedFingerprint: _fingerprint,
          runner: runner,
        );

        final candidate = await repository.downloadUnsignedDraft(
          tag: _tag,
          expectedSourceCommit: _commit,
          destination: Directory.systemTemp.createTempSync(
            'poltergeist-release-stale-visibility-test-',
          ),
        );
        addTearDown(() => candidate.directory.deleteSync(recursive: true));
        await repository.publish(candidate);
        final verification = await repository.verify(
          candidate: candidate,
          visibility: ReleaseVisibilityExpectation.published,
          signaturePolicy: ReleaseSignaturePolicy.required,
        );

        expect(verification.status, ReleaseVerificationStatus.inconclusive);
      },
    );

    test('fresh verification checks assets, notes, and signature', () async {
      final payloads = _payloadContents();
      final runner = _FakeProcessRunner([
        _releaseResult(payloads),
        for (final name in _downloadNames(payloads))
          _binaryResult(
            name == 'SHA256SUMS'
                ? utf8.encode(_checksumText(payloads))
                : payloads[name]!,
          ),
        _pinnedReleaseResult(payloads, signature: _SignatureAsset.present),
        for (final name in _downloadNames(
          payloads,
          signature: _SignatureAsset.present,
        ))
          _binaryResult(switch (name) {
            'SHA256SUMS' => utf8.encode(_checksumText(payloads)),
            'SHA256SUMS.asc' => utf8.encode(
              '-----BEGIN PGP SIGNATURE-----\nsigned\n'
              '-----END PGP SIGNATURE-----\n',
            ),
            _ => payloads[name]!,
          }),
      ]);
      final signatures = _FakeSignatureService();
      final repository = GhReleaseRepository.withRunner(
        repository: _repository,
        signatures: signatures,
        expectedFingerprint: _fingerprint,
        runner: runner,
      );
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-fresh-verify-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final candidate = await repository.downloadUnsignedDraft(
        tag: _tag,
        expectedSourceCommit: _commit,
        destination: Directory(p.join(sandbox.path, 'candidate')),
      );

      final verification = await repository.verify(
        candidate: candidate,
        visibility: ReleaseVisibilityExpectation.draft,
        signaturePolicy: ReleaseSignaturePolicy.required,
      );

      expect(verification.status, ReleaseVerificationStatus.valid);
      expect(signatures.verifyCalls, hasLength(1));
      expect(signatures.verifyCalls.single, _fingerprint);
      expect(signatures.tagVerifyCalls, [_tag]);
    });

    test('treats a short asset download as inconclusive', () async {
      final payloads = _payloadContents();
      final signedNames = _downloadNames(
        payloads,
        signature: _SignatureAsset.present,
      );
      final runner = _FakeProcessRunner([
        _releaseResult(payloads),
        for (final name in _downloadNames(payloads))
          _binaryResult(
            name == 'SHA256SUMS'
                ? utf8.encode(_checksumText(payloads))
                : payloads[name]!,
          ),
        _pinnedReleaseResult(payloads, signature: _SignatureAsset.present),
        for (var index = 0; index < signedNames.length; index++)
          _binaryResult(
            index == 0
                ? const []
                : switch (signedNames[index]) {
                    'SHA256SUMS' => utf8.encode(_checksumText(payloads)),
                    'SHA256SUMS.asc' => utf8.encode(
                      '-----BEGIN PGP SIGNATURE-----\nsigned\n'
                      '-----END PGP SIGNATURE-----\n',
                    ),
                    final name => payloads[name]!,
                  },
          ),
      ]);
      final repository = GhReleaseRepository.withRunner(
        repository: _repository,
        signatures: _FakeSignatureService(),
        expectedFingerprint: _fingerprint,
        runner: runner,
      );
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-short-download-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final candidate = await repository.downloadUnsignedDraft(
        tag: _tag,
        expectedSourceCommit: _commit,
        destination: Directory(p.join(sandbox.path, 'candidate')),
      );

      final verification = await repository.verify(
        candidate: candidate,
        visibility: ReleaseVisibilityExpectation.draft,
        signaturePolicy: ReleaseSignaturePolicy.required,
      );

      expect(verification.status, ReleaseVerificationStatus.inconclusive);
    });
  });

  group('SizeComparingLocalReleaseAuditor', () {
    test('accepts a local artifact at the ten percent boundary', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-size-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final remote = File(p.join(sandbox.path, 'primary.tar.gz'))
        ..writeAsBytesSync(List.filled(110, 1));
      final checksums = File(p.join(sandbox.path, 'SHA256SUMS'))
        ..writeAsStringSync('sums');
      final driver = _FakePrimaryPlatformDriver(
        assetName: p.basename(remote.path),
        localSize: 100,
      );
      final auditor = SizeComparingLocalReleaseAuditor(
        repositoryRoot: Directory.current,
        driver: driver,
      );
      final candidate = ReleaseCandidate(
        identity: _identity,
        tag: _tag,
        sourceCommit: _commit,
        directory: sandbox,
        checksums: checksums,
      );

      await auditor.compareLocalBuild(candidate);
      await auditor.smokeDownloadedBuild(candidate);

      expect(driver.buildTags, [_tag]);
      expect(driver.smoked, [remote.path]);
    });

    test('rejects an artifact beyond the ten percent boundary', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-size-failure-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final remote = File(p.join(sandbox.path, 'primary.tar.gz'))
        ..writeAsBytesSync(List.filled(111, 1));
      final driver = _FakePrimaryPlatformDriver(
        assetName: p.basename(remote.path),
        localSize: 100,
      );
      final auditor = SizeComparingLocalReleaseAuditor(
        repositoryRoot: Directory.current,
        driver: driver,
      );

      await expectLater(
        auditor.compareLocalBuild(
          ReleaseCandidate(
            identity: _identity,
            tag: _tag,
            sourceCommit: _commit,
            directory: sandbox,
            checksums: File(p.join(sandbox.path, 'SHA256SUMS')),
          ),
        ),
        throwsA(
          isA<ReleaseFinalizeException>().having(
            (error) => error.message,
            'message',
            contains('10.00%'),
          ),
        ),
      );
    });
  });

  group('DesktopPrimaryPlatformReleaseDriver', () {
    test('builds and packages the exact tagged Linux checkout', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-linux-build-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final destination = Directory(p.join(sandbox.path, 'audit'));
      final runner = _FakeProcessRunner(
        [
          _textResult(''),
          _textResult(''),
          _textResult('$_commit\n'),
          _textResult(''),
          _textResult(''),
          _textResult(''),
          _textResult(''),
          _textResult(''),
          _textResult(''),
        ],
        callbacks: [
          (call) => Directory(call.arguments.last).createSync(recursive: true),
          null,
          null,
          null,
          null,
          null,
          null,
          (call) {
            final app = call.workingDirectory!;
            Directory(
              p.join(app.path, 'build', 'linux', 'x64', 'release', 'bundle'),
            ).createSync(recursive: true);
          },
          (call) => File(call.arguments[1]).writeAsStringSync('archive'),
        ],
      );
      final driver = DesktopPrimaryPlatformReleaseDriver.withRunner(
        platform: PrimaryReleasePlatform.linuxX64,
        runner: runner,
      );

      final artifact = await driver.buildTaggedArtifact(
        repositoryRoot: sandbox,
        tag: _tag,
        sourceCommit: _commit,
        destination: destination,
      );

      expect(artifact.path, endsWith('poltergeist-linux-x64.tar.gz'));
      expect(artifact.lengthSync(), greaterThan(0));
      expect(
        runner.calls.first.arguments,
        containsAll(['clone', '--no-checkout', '--no-hardlinks']),
      );
      expect(
        runner.calls[1].arguments,
        containsAll(['checkout', '--detach', _commit]),
      );
      expect(
        runner.calls
            .where(
              (call) =>
                  call.arguments.length >= 2 &&
                  call.arguments[0] == 'pub' &&
                  call.arguments[1] == 'get',
            )
            .map((call) => call.arguments),
        everyElement(['pub', 'get', '--enforce-lockfile']),
      );
      expect(
        runner.calls.any(
          (call) =>
              call.executable == 'git' &&
              call.arguments.join(' ') ==
                  'status --porcelain=v1 --untracked-files=no',
        ),
        isTrue,
      );
      expect(
        runner.calls
            .where((call) => call.executable == 'flutter')
            .last
            .arguments,
        ['build', 'linux', '--release', '--no-pub'],
      );
    });

    test('rejects dependency resolution that changes tagged source', () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'poltergeist-release-dirty-build-test-',
      );
      addTearDown(() => sandbox.deleteSync(recursive: true));
      final runner = _FakeProcessRunner(
        [
          _textResult(''),
          _textResult(''),
          _textResult('$_commit\n'),
          _textResult(''),
          _textResult(''),
          _textResult(' M pubspec.lock\n'),
        ],
        callbacks: [
          (call) => Directory(call.arguments.last).createSync(recursive: true),
        ],
      );
      final driver = DesktopPrimaryPlatformReleaseDriver.withRunner(
        platform: PrimaryReleasePlatform.linuxX64,
        runner: runner,
      );

      await expectLater(
        driver.buildTaggedArtifact(
          repositoryRoot: sandbox,
          tag: _tag,
          sourceCommit: _commit,
          destination: Directory(p.join(sandbox.path, 'audit')),
        ),
        throwsA(
          isA<ReleaseFinalizeException>()
              .having(
                (error) => error.kind,
                'kind',
                ReleaseFinalizeFailureKind.policyMismatch,
              )
              .having(
                (error) => error.message,
                'message',
                contains('pubspec.lock'),
              ),
        ),
      );
      expect(
        runner.calls.any(
          (call) =>
              call.executable == 'flutter' &&
              call.arguments.firstOrNull == 'build',
        ),
        isFalse,
      );
    });

    test(
      'Linux smoke extracts and observes the downloaded executable',
      () async {
        final sandbox = Directory.systemTemp.createTempSync(
          'poltergeist-release-linux-smoke-test-',
        );
        addTearDown(() => sandbox.deleteSync(recursive: true));
        final artifact = File(
          p.join(sandbox.path, 'poltergeist-linux-x64.tar.gz'),
        )..writeAsStringSync('archive');
        final runner = _FakeProcessRunner(
          [_textResult('')],
          callbacks: [
            (call) {
              final destination = call.arguments.last;
              final executable = File(
                p.join(destination, 'poltergeist-linux-x64', 'poltergeist'),
              );
              executable.parent.createSync(recursive: true);
              executable.writeAsStringSync('binary');
            },
          ],
          launchResult: const ReleaseLaunchResult.remainedRunning(),
        );
        final driver = DesktopPrimaryPlatformReleaseDriver.withRunner(
          platform: PrimaryReleasePlatform.linuxX64,
          runner: runner,
        );

        await driver.smokeArtifact(
          artifact,
          Directory(p.join(sandbox.path, 'smoke')),
        );

        expect(runner.launchCalls.single.executable, endsWith('poltergeist'));
        expect(
          runner.launchCalls.single.observation,
          const Duration(seconds: 5),
        );
      },
    );

    test('maps and smokes each desktop archive shape', () async {
      final cases = <(PrimaryReleasePlatform, String, String)>[
        (
          PrimaryReleasePlatform.macosUniversal,
          'poltergeist-macos-universal.zip',
          p.join('Poltergeist.app', 'Contents', 'MacOS', 'Poltergeist'),
        ),
        (
          PrimaryReleasePlatform.windowsX64,
          'poltergeist-windows-x64.zip',
          p.join('poltergeist-windows-x64', 'poltergeist_app.exe'),
        ),
      ];
      for (final (platform, assetName, executablePath) in cases) {
        final sandbox = Directory.systemTemp.createTempSync(
          'poltergeist-release-desktop-smoke-test-',
        );
        addTearDown(() => sandbox.deleteSync(recursive: true));
        final artifact = File(p.join(sandbox.path, assetName))
          ..writeAsStringSync('archive');
        final runner = _FakeProcessRunner(
          [_textResult('')],
          callbacks: [
            (call) {
              final destination =
                  platform == PrimaryReleasePlatform.macosUniversal
                  ? call.arguments.last
                  : call.arguments
                        .singleWhere((argument) => argument.startsWith('-o'))
                        .substring(2);
              final executable = File(p.join(destination, executablePath));
              executable.parent.createSync(recursive: true);
              executable.writeAsStringSync('binary');
            },
          ],
        );
        final driver = DesktopPrimaryPlatformReleaseDriver.withRunner(
          platform: platform,
          runner: runner,
        );

        expect(driver.assetName, assetName);
        await driver.smokeArtifact(
          artifact,
          Directory(p.join(sandbox.path, 'smoke')),
        );
        expect(
          p.normalize(runner.launchCalls.single.executable),
          endsWith(p.normalize(executablePath)),
        );
      }
    });

    test('reports unsupported hosts explicitly', () {
      expect(
        () => DesktopPrimaryPlatformReleaseDriver.current(
          operatingSystem: 'android',
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('Linux, macOS, or Windows'),
          ),
        ),
      );
    });
  });
}

Map<String, List<int>> _payloadContents() {
  return {
    'poltergeist-android.apk': utf8.encode('android'),
    'poltergeist-ios-unsigned.ipa': utf8.encode('ios'),
    'poltergeist-linux-x64.AppImage': utf8.encode('appimage'),
    'poltergeist-linux-x64.tar.gz': utf8.encode('linux'),
    'poltergeist-macos-universal.zip': utf8.encode('macos'),
    'poltergeist-windows-x64.zip': utf8.encode('windows'),
    'poltergeist_0.1.0-1_amd64.deb': utf8.encode('deb'),
  };
}

List<String> _downloadNames(
  Map<String, List<int>> payloads, {
  _SignatureAsset signature = _SignatureAsset.absent,
}) {
  return <String>[
    ...payloads.keys,
    'SHA256SUMS',
    if (signature == _SignatureAsset.present) 'SHA256SUMS.asc',
  ]..sort();
}

String _checksumText(Map<String, List<int>> payloads) {
  final names = payloads.keys.toList()..sort();
  return '${names.map((name) => '${sha256.convert(payloads[name]!)}  $name').join('\n')}\n';
}

ReleaseProcessResult _releaseResult(
  Map<String, List<int>> payloads, {
  _SignatureAsset signature = _SignatureAsset.absent,
  String? extraAsset,
  int releaseId = 71,
}) {
  return _jsonResult([
    [
      _releaseObject(
        payloads,
        signature: signature,
        extraAsset: extraAsset,
        releaseId: releaseId,
      ),
    ],
  ]);
}

ReleaseProcessResult _pinnedReleaseResult(
  Map<String, List<int>> payloads, {
  _SignatureAsset signature = _SignatureAsset.absent,
  String? extraAsset,
  int releaseId = 71,
  bool draft = true,
}) {
  return _jsonResult(
    _releaseObject(
      payloads,
      signature: signature,
      extraAsset: extraAsset,
      releaseId: releaseId,
      draft: draft,
    ),
  );
}

Map<String, Object?> _releaseObject(
  Map<String, List<int>> payloads, {
  _SignatureAsset signature = _SignatureAsset.absent,
  String? extraAsset,
  int releaseId = 71,
  bool draft = true,
}) {
  final checksums = utf8.encode(_checksumText(payloads));
  var nextId = 100;
  final assets = <Map<String, Object?>>[
    for (final entry in payloads.entries)
      {'id': nextId++, 'name': entry.key, 'size': entry.value.length},
    {'id': nextId++, 'name': 'SHA256SUMS', 'size': checksums.length},
    if (signature == _SignatureAsset.present)
      {
        'id': nextId++,
        'name': 'SHA256SUMS.asc',
        'size': utf8
            .encode(
              '-----BEGIN PGP SIGNATURE-----\nsigned\n'
              '-----END PGP SIGNATURE-----\n',
            )
            .length,
      },
    if (extraAsset != null) {'id': nextId++, 'name': extraAsset, 'size': 1},
  ];
  final notes = ReleaseNotesDocument.create(
    tag: _tag,
    sourceCommit: _commit,
    checksums: _checksumText(payloads),
  ).encode();

  return {
    'id': releaseId,
    'tag_name': _tag,
    'draft': draft,
    'prerelease': true,
    'body': notes,
    'assets': assets,
  };
}

enum _SignatureAsset { absent, present }

ReleaseProcessResult _jsonResult(Object value) {
  return _textResult(jsonEncode(value));
}

ReleaseProcessResult _textResult(String output, {String standardError = ''}) {
  return ReleaseProcessResult(
    exitCode: 0,
    standardOutput: output,
    standardError: standardError,
  );
}

ReleaseProcessResult _binaryResult(List<int> output) {
  return ReleaseProcessResult(exitCode: 0, binaryOutput: output);
}

String _validSignatureStatus(String fingerprint) {
  return '[GNUPG:] VALIDSIG $fingerprint 2026-09-02 1788300000 0 4 0 1 10 '
      '00 $fingerprint\n';
}

final class _FakeProcessRunner implements ReleaseProcessRunner {
  final List<ReleaseProcessResult> _results;
  final ReleaseLaunchResult launchResult;
  final List<_ProcessCall> calls = [];
  final List<_ProcessCall> fileCalls = [];
  final List<_LaunchCall> launchCalls = [];
  final List<void Function(_ProcessCall call)?> _callbacks;
  var _callIndex = 0;

  _FakeProcessRunner(
    List<ReleaseProcessResult> results, {
    this.launchResult = const ReleaseLaunchResult.remainedRunning(),
    List<void Function(_ProcessCall call)?> callbacks = const [],
  }) : _results = [...results],
       _callbacks = [...callbacks];

  @override
  Future<ReleaseProcessResult> run(
    String executable,
    List<String> arguments, {
    Directory? workingDirectory,
  }) async {
    final call = _ProcessCall(executable, [...arguments], workingDirectory);
    calls.add(call);
    final result = _next();
    _consumeCallback(call);

    return result;
  }

  @override
  Future<ReleaseProcessResult> runToFile(
    String executable,
    List<String> arguments, {
    required File output,
    Directory? workingDirectory,
  }) async {
    final call = _ProcessCall(executable, [...arguments], workingDirectory);
    calls.add(call);
    fileCalls.add(call);
    final result = _next();
    _consumeCallback(call);
    output.parent.createSync(recursive: true);
    output.writeAsBytesSync(result.binaryOutput);

    return result;
  }

  @override
  Future<ReleaseLaunchResult> observeLaunch(
    String executable,
    List<String> arguments, {
    required Duration observation,
    Directory? workingDirectory,
  }) async {
    launchCalls.add(
      _LaunchCall(executable, [...arguments], workingDirectory, observation),
    );
    return launchResult;
  }

  ReleaseProcessResult _next() {
    if (_results.isEmpty) throw StateError('unexpected process call');

    return _results.removeAt(0);
  }

  void _consumeCallback(_ProcessCall call) {
    if (_callIndex < _callbacks.length) _callbacks[_callIndex]?.call(call);
    _callIndex++;
  }
}

class _ProcessCall {
  final String executable;
  final List<String> arguments;
  final Directory? workingDirectory;

  const _ProcessCall(this.executable, this.arguments, this.workingDirectory);
}

final class _LaunchCall extends _ProcessCall {
  final Duration observation;

  const _LaunchCall(
    super.executable,
    super.arguments,
    super.workingDirectory,
    this.observation,
  );
}

final class _FakeSignatureService implements ReleaseSignatureService {
  final List<String> verifyCalls = [];
  final List<String> tagVerifyCalls = [];

  @override
  Future<File> signChecksums({
    required File checksums,
    required String expectedFingerprint,
  }) {
    throw UnimplementedError();
  }

  @override
  Future<void> verifyChecksumSignature({
    required File checksums,
    required File signature,
    required String expectedFingerprint,
  }) async {
    verifyCalls.add(expectedFingerprint);
  }

  @override
  Future<VerifiedReleaseTag> verifyTag({
    required String tag,
    required String expectedFingerprint,
  }) async {
    tagVerifyCalls.add(tag);
    return const VerifiedReleaseTag(tag: _tag, commit: _commit);
  }
}

final class _FakePrimaryPlatformDriver implements PrimaryPlatformReleaseDriver {
  @override
  final String assetName;
  final int localSize;
  final List<String> buildTags = [];
  final List<String> smoked = [];

  _FakePrimaryPlatformDriver({
    required this.assetName,
    required this.localSize,
  });

  @override
  Future<File> buildTaggedArtifact({
    required Directory repositoryRoot,
    required String tag,
    required String sourceCommit,
    required Directory destination,
  }) async {
    buildTags.add(tag);
    destination.createSync(recursive: true);
    return File(p.join(destination.path, assetName))
      ..writeAsBytesSync(List.filled(localSize, 1));
  }

  @override
  Future<void> smokeArtifact(File artifact, Directory destination) async {
    smoked.add(artifact.path);
  }
}
