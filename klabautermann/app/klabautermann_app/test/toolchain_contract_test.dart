import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _flutterVersion = '3.47.2';
const _productAgentsPath = '../../AGENTS.md';
const _rootAgentsPath = '../../../AGENTS.md';
const _workflowPaths = {
  '../../../.github/workflows/ci.yml',
  '../../../.github/workflows/release.yml',
};

void main() {
  test('documents the pinned Flutter release', () {
    expect(
      File(_rootAgentsPath).readAsStringSync(),
      contains('Use Flutter $_flutterVersion'),
    );
    expect(
      File(_productAgentsPath).readAsStringSync(),
      contains('Flutter $_flutterVersion'),
    );
  });

  test('keeps one Flutter pin per workflow', () {
    for (final path in _workflowPaths) {
      final workflow = File(path).readAsStringSync();

      expect(
        RegExp(
          RegExp.escape("FLUTTER_VERSION: '$_flutterVersion'"),
        ).allMatches(workflow),
        hasLength(1),
        reason: path,
      );
      expect(workflow, isNot(contains("flutter-version: '$_flutterVersion'")));
      expect(
        workflow,
        contains(r'flutter-version: ${{ env.FLUTTER_VERSION }}'),
      );
    }
  });
}
