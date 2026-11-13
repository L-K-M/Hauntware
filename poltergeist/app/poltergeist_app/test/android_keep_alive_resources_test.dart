import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/transfer_keep_alive.dart';

void main() {
  test('release shrinking retains the dynamically named notification icon', () {
    const strings = PoltergeistKeepAliveStrings();
    final resources = File('android/app/src/main/res/raw/keep_keepalive.xml');

    expect(resources.existsSync(), isTrue);
    expect(
      resources.readAsStringSync(),
      contains('tools:keep="@drawable/${strings.smallIconResourceName}"'),
    );
  });
}
