import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/keep_alive_strings.dart';

void main() {
  // The state machine the old app-private service implemented moved to the
  // ghost_keepalive package (its background_keep_alive_test.dart); these
  // pins hold Séance's half of the contract: the notification this app
  // shows is unchanged by the move, channel id included — its settings are
  // stored user data from before the plugin existed.
  const strings = SeanceKeepAliveStrings();

  test('the channel id and notification strings keep their wording', () {
    expect(strings.channelId, 'seance.keepalive');
    expect(strings.channelName, 'Session keep-alive');
    expect(strings.channelDescription,
        'Shown while connections are kept alive in the background.');
    expect(strings.notificationTitle, 'Séance');
    expect(strings.smallIconResourceName, 'ic_stat_keep_alive');
  });

  test('release shrinking retains the dynamically named notification icon', () {
    final resources = File('android/app/src/main/res/raw/keep_keepalive.xml');
    expect(resources.existsSync(), isTrue);
    expect(resources.readAsStringSync(),
        contains('tools:keep="@drawable/${strings.smallIconResourceName}"'));
  });

  test('the notification text pluralizes sessions', () {
    expect(strings.notificationText(1),
        'Keeping 1 session alive in the background.');
    expect(strings.notificationText(3),
        'Keeping 3 sessions alive in the background.');
  });
}
