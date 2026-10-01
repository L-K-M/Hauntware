import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late File apk;
  late File aapt;
  late File apksigner;
  late String certificate;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync(
      'poltergeist-android-assertion-test-',
    );
    apk = File(p.join(sandbox.path, 'poltergeist.apk'))
      ..writeAsBytesSync(const [1]);
    certificate = File(
      'app/poltergeist_app/android/ci-signing-certificate.sha256',
    ).readAsStringSync().trim();
    aapt = _writeExecutable(
      sandbox,
      'aapt',
      "printf \"package: name='com.lkm.poltergeist_app' "
          "versionCode='10099' versionName='0.1.0' "
          "compileSdkVersionCodename='16'\\n\"\n",
    );
    apksigner = _writeExecutable(sandbox, 'apksigner', '''cat <<'OUTPUT'
Verifies
Verified using v2 scheme (APK Signature Scheme v2): true
Number of signers: 1
Signer #1 certificate SHA-256 digest: $certificate
OUTPUT
''');
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('accepts the exact package, version, and signing identity', () async {
    final result = await _runAssertion(apk, aapt, apksigner);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('Android release verified'));
  });

  test('accepts tool executable paths containing spaces', () async {
    final toolDirectory = Directory(p.join(sandbox.path, 'tools with spaces'))
      ..createSync();
    final spacedAapt = _writeExecutable(
      toolDirectory,
      'aapt',
      "printf \"package: name='com.lkm.poltergeist_app' "
          "versionCode='10099' versionName='0.1.0'\\n\"\n",
    );
    final spacedApksigner = _writeExecutable(
      toolDirectory,
      'apksigner',
      '''cat <<'OUTPUT'
Verified using v2 scheme (APK Signature Scheme v2): true
Number of signers: 1
Signer #1 certificate SHA-256 digest: $certificate
OUTPUT
''',
    );
    final spacedDart = _writeExecutable(
      toolDirectory,
      'dart',
      "printf '0.1.0+10099\\n'\n",
    );

    final result = await _runAssertion(
      apk,
      spacedAapt,
      spacedApksigner,
      dartExecutable: spacedDart,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('Android release verified'));
  });

  test('accepts build-tools 37 certificate output', () async {
    apksigner.writeAsStringSync('''#!/usr/bin/env bash
cat <<'OUTPUT'
Verifies
Verified using v2 scheme (APK Signature Scheme v2): true
Number of signers: 1
V2 Signer: certificate SHA-256 digest: $certificate
OUTPUT
''');

    final result = await _runAssertion(apk, aapt, apksigner);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('Android release verified'));
  });

  test('rejects a flat Android version code', () async {
    aapt.writeAsStringSync(
      "#!/usr/bin/env bash\nprintf \"package: "
      "name='com.lkm.poltergeist_app' versionCode='1' "
      "versionName='0.1.0'\\n\"\n",
    );

    final result = await _runAssertion(apk, aapt, apksigner);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('versionCode'));
  });

  test('rejects a different signing certificate', () async {
    apksigner.writeAsStringSync('''#!/usr/bin/env bash
cat <<'OUTPUT'
Verifies
Verified using v2 scheme (APK Signature Scheme v2): true
Number of signers: 1
Signer #1 certificate SHA-256 digest: ${'0' * 64}
OUTPUT
''');

    final result = await _runAssertion(apk, aapt, apksigner);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('certificate'));
  });

  test('rejects multiple signers or a missing v2 signature', () async {
    apksigner.writeAsStringSync('''#!/usr/bin/env bash
cat <<'OUTPUT'
Verifies
Verified using v2 scheme (APK Signature Scheme v2): false
Number of signers: 2
Signer #1 certificate SHA-256 digest: $certificate
Signer #2 certificate SHA-256 digest: $certificate
OUTPUT
''');

    final result = await _runAssertion(apk, aapt, apksigner);

    expect(result.exitCode, isNot(0));
    expect(result.stderr, anyOf(contains('v2'), contains('signer')));
  });

  test('CI verifies every Android release build', () {
    final workflow = File('.github/workflows/ci.yml').readAsStringSync();

    expect(
      workflow,
      allOf(
        contains("if: matrix.target == 'android'"),
        contains('scripts/assert-android-release.sh'),
        contains('build/app/outputs/flutter-apk/app-release.apk'),
      ),
    );
  });
}

File _writeExecutable(Directory root, String name, String body) {
  final file = File(p.join(root.path, name))
    ..writeAsStringSync('#!/usr/bin/env bash\n$body');
  final chmod = Process.runSync('chmod', ['+x', file.path]);
  expect(chmod.exitCode, 0, reason: chmod.stderr as String);

  return file;
}

Future<ProcessResult> _runAssertion(
  File apk,
  File aapt,
  File apksigner, {
  File? dartExecutable,
}) {
  return Process.run(
    'bash',
    ['scripts/assert-android-release.sh', apk.path, '0.1.0'],
    workingDirectory: Directory.current.path,
    environment: {
      ...Platform.environment,
      'AAPT_BIN': aapt.path,
      'APKSIGNER_BIN': apksigner.path,
      'DART_BIN': dartExecutable?.path ?? Platform.resolvedExecutable,
    },
  );
}
