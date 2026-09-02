import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _agentsPath = '../../AGENTS.md';
const _flutterVersion = '3.47.2';

void main() {
  test('pins the documented Flutter checkout', () {
    final agents = File(_agentsPath).readAsStringSync();

    expect(
      agents,
      contains(
        'git clone --depth 1 --branch $_flutterVersion '
        'https://github.com/flutter/flutter.git /opt/flutter',
      ),
    );
    expect(agents, isNot(contains('git clone --depth 1 -b stable')));
  });
}
