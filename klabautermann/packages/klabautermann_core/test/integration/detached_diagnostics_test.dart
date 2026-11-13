import 'dart:convert';

import 'package:seance_core/seance_core.dart' show RemoteCommandResult;
import 'package:test/test.dart';

import 'support/link_meter.dart';

void main() {
  test('records only detached launcher and directory command kinds', () {
    expect(detachedCommandKind('sh klabautermann-launch secret'), 'setsid');
    expect(detachedCommandKind('sh XDG_STATE_HOME secret'), 'directory');
    expect(detachedCommandKind('unrelated secret'), isNull);
  });

  test('result summaries describe shape without keeping output', () {
    final directory = detachedRunSummary(
      'directory',
      const RemoteCommandResult(
        stdout: '/home/secret/ops\n',
        stderr: 'private error',
        exitCode: 0,
      ),
    );
    expect(directory['stdoutAbsolute'], isTrue);
    expect(directory['stderrEmpty'], isFalse);
    expect(jsonEncode(directory), isNot(contains('secret')));
    expect(jsonEncode(directory), isNot(contains('private error')));

    final launch = detachedRunSummary(
      'setsid',
      const RemoteCommandResult(stdout: '4242\n'),
    );
    expect(launch['exitCode'], isNull);
    expect(launch['stdoutIsPid'], isTrue);
    expect(jsonEncode(launch), isNot(contains('4242')));
    expect(
      detachedRunSummary(
        'setsid',
        const RemoteCommandResult(stdout: '0'),
      )['stdoutIsPid'],
      isFalse,
    );
  });
}
