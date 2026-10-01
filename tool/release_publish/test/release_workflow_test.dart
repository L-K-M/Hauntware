import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  final workflow = File('.github/workflows/release.yml').readAsStringSync();

  test('workflow is valid YAML', () {
    expect(loadYaml(workflow), isA<YamlMap>());
  });

  test('matrix transports assets without publishing releases', () {
    expect(workflow, contains('actions/upload-artifact@v4'));
    expect(workflow, contains('actions/download-artifact@v4'));
    expect(workflow, isNot(contains('softprops/action-gh-release')));
  });

  test('one publisher owns release write permission', () {
    expect(workflow, contains('publish:'));
    expect(workflow, contains('contents: write'));
    expect(workflow, contains('tool/release_publish/bin/publish_draft.dart'));
    expect(workflow, contains('needs: [test, client]'));
  });

  test('dispatch verifies an existing tag and never creates one', () {
    expect(workflow, contains('verify-source'));
    expect(workflow, contains(r'ref: ${{ inputs.tag || github.ref_name }}'));
    expect(workflow, isNot(contains('target_commitish')));
    expect(workflow, isNot(contains('created here if it')));
  });

  test('all runs share one normalized tag concurrency key', () {
    expect(
      workflow,
      contains(r'group: release-${{ inputs.tag || github.ref_name }}'),
    );
    expect(workflow, contains('cancel-in-progress: false'));
  });

  test('Android release package is verified before transport', () {
    expect(workflow, contains('scripts/assert-android-release.sh'));
    expect(workflow, contains(r'expected_version="${RELEASE_TAG#v}"'));
  });

  test('iOS packages the unsigned archive as a Payload IPA', () {
    expect(workflow, contains('build: ipa --release --no-codesign'));
    expect(workflow, isNot(contains('build: ios --release --no-codesign')));
    expect(
      workflow,
      contains(
        'ios_archive="app/poltergeist_app/build/ios/archive/'
        'Runner.xcarchive"',
      ),
    );
    expect(
      workflow,
      contains(r'ios_app="$ios_archive/Products/Applications/Runner.app"'),
    );
    expect(workflow, contains(r'test -d "$ios_app"'));
    expect(workflow, contains(r'cp -R "$ios_app" Payload/'));
    expect(workflow, contains('zip -qry poltergeist-ios-unsigned.ipa Payload'));
    expect(
      workflow,
      isNot(contains('app/poltergeist_app/build/ios/iphoneos/Runner.app')),
    );
  });

  test('dependency resolution preserves the exact tagged source', () {
    expect(_occurrences(workflow, 'dart pub get --enforce-lockfile'), 5);
    expect(_occurrences(workflow, 'flutter pub get --enforce-lockfile'), 1);
    expect(
      _occurrences(
        workflow,
        'name: Verify dependency resolution preserves tagged source',
      ),
      3,
    );
    expect(_occurrences(workflow, 'git diff --exit-code'), 3);
    expect(_occurrences(workflow, 'git diff --cached --exit-code'), 3);
  });
}

int _occurrences(String source, String value) {
  return RegExp(RegExp.escape(value)).allMatches(source).length;
}
