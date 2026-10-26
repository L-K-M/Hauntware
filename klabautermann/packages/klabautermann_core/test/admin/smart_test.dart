// HW-04's drive health read (03 §7.11): the scan's drives are read
// through the elevation executor with `-n standby`, a probe without
// smartctl runs nothing, and each failure is typed.
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/admin/smart.dart';
import 'package:seance_core/seance_core.dart'
    show
        ElevatedExecutor,
        ElevationProbe,
        RemoteCommandException,
        RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';

/// Answers each command with the first of [answers] whose key it
/// contains, and records it.
final class _Link extends TestLinkBase {
  _Link(this.answers);

  final Map<String, RemoteCommandResult> answers;
  final commands = <String>[];
  Object? failure;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    if (failure case final error?) throw error;
    for (final MapEntry(:key, :value) in answers.entries) {
      if (command.contains(key)) return value;
    }
    return const RemoteCommandResult(exitCode: 1, stderr: 'unexpected');
  }
}

RemoteCommandResult _json(Object value, {int exitCode = 0}) =>
    RemoteCommandResult(exitCode: exitCode, stdout: jsonEncode(value));

Future<SmartReport> _read(_Link link, {HostProfile? profile}) => readSmart(
  _server,
  requestId: 'r-1',
  session: AdminSession.test(
    ElevatedExecutor(link, const ElevationProbe(isRoot: true)),
    null,
  ),
  profile: profile,
);

void main() {
  test('reads each scanned drive without waking a sleeping one', () async {
    final link = _Link({
      '--scan-open': _json({
        'devices': [
          {'name': '/dev/sda', 'type': 'sat'},
          {'name': '/dev/sdb', 'type': 'sat'},
          {'name': '/dev/nvme0', 'type': 'nvme'},
        ],
      }),
      '/dev/sda': _json({
        'model_name': 'Samsung SSD 860 EVO 500GB',
        'smart_status': {'passed': true},
        'temperature': {'current': 33},
      }),
      '/dev/sdb': _json({
        'smartctl': {
          'exit_status': 2,
          'messages': [
            {'string': 'Device is in STANDBY mode, exit(2)'},
          ],
        },
      }, exitCode: 2),
      '/dev/nvme0': _json({
        'smartctl': {'exit_status': 8},
        'model_name': 'WD Blue SN570 1TB',
        'smart_status': {'passed': false},
      }, exitCode: 8),
    });

    final report = await _read(link);
    expect(report.failure, isNull);
    expect(
      [for (final d in report.disks) (d.device, d.verdict)],
      [
        ('/dev/sda', SmartVerdict.passed),
        ('/dev/sdb', SmartVerdict.asleep),
        ('/dev/nvme0', SmartVerdict.failing),
      ],
    );
    expect(report.notRead, 0);
    final reads = link.commands.where((c) => c.contains('-n')).toList();
    expect(reads, hasLength(3));
    expect(reads.every((c) => c.contains('standby')), isTrue);
  });

  test('a probe without smartctl runs nothing; a missing tool, an old '
      'smartctl, a refused elevation and a lost link are told apart', () async {
    final none = _Link({});
    expect(
      (await _read(
        none,
        profile: HostProfile(tools: const {'smartctl': null}),
      )).failure,
      SmartReportFailure.missing,
    );
    expect(none.commands, isEmpty);

    expect(
      (await _read(
        _Link({
          '--scan-open': const RemoteCommandResult(
            exitCode: 127,
            stderr: 'sh: smartctl: not found',
          ),
        }),
      )).failure,
      SmartReportFailure.missing,
    );
    expect(
      (await _read(
        _Link({
          '--scan-open': const RemoteCommandResult(
            exitCode: 1,
            stdout: 'UNRECOGNIZED OPTION: j',
          ),
        }),
      )).failure,
      SmartReportFailure.unreadable,
    );
    final lost = _Link({})..failure = const RemoteCommandException('closed');
    expect((await _read(lost)).failure, SmartReportFailure.transport);
  });

  test('reads at most kSmartDrivesRead drives and counts the rest', () async {
    final link = _Link({
      '--scan-open': _json({
        'devices': [
          for (var i = 0; i < kSmartDrivesRead + 3; i++)
            {'name': '/dev/sd$i', 'type': 'sat'},
        ],
      }),
      '-n': _json({
        'smart_status': {'passed': true},
      }),
    });

    final report = await _read(link);
    expect(report.disks, hasLength(kSmartDrivesRead));
    expect(report.notRead, 3);
  });
}
