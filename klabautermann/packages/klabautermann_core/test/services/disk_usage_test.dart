// DSK-07's folder read (03 §7.3): one `du` as the login user, or as root
// through the elevation executor in admin mode, whose output parses into
// the folder's listing, and a typed failure otherwise.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/services/disk_usage.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show kDiskUsageErrorsMarker;
import 'package:seance_core/seance_core.dart'
    show
        ElevatedExecutor,
        ElevationProbe,
        RemoteCommandException,
        RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';

/// Answers every command with [answer], or throws [failure], and records
/// each.
final class _Link extends TestLinkBase {
  _Link(this.answer);

  final RemoteCommandResult answer;
  final commands = <String>[];
  final timeouts = <Duration?>[];
  Object? failure;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    timeouts.add(timeout);
    if (failure case final error?) throw error;
    return answer;
  }
}

RemoteCommandResult _out(String stdout) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout);

void main() {
  const listing =
      'd\t12\t/srv\nd\t8\t/srv/data\nf\t4\t/srv/notes\n'
      '$kDiskUsageErrorsMarker\n\n';

  test('reads the folder as the login user, unelevated', () async {
    final link = _Link(_out(listing));
    final report = await readDiskUsage(
      _server,
      '/srv',
      requestId: 'r-1',
      link: link,
    );
    expect(report.failure, isNull);
    expect(report.path, '/srv');
    expect(report.listing!.totalBytes, 12 * 1024);
    expect(report.listing!.entries.map((entry) => entry.name), [
      'data',
      'notes',
    ]);
    expect(link.commands.single, contains('du -x -k -a -d 1'));
    expect(link.commands.single, isNot(contains('sudo')));
    expect(link.timeouts.single, kDiskUsageTimeout);
  });

  test('in admin mode the same read runs through the executor', () async {
    final link = _Link(_out(listing));
    final report = await readDiskUsage(
      _server,
      '/srv',
      requestId: 'r-1',
      link: link,
      session: AdminSession.test(
        ElevatedExecutor(link, const ElevationProbe(isRoot: true)),
        null,
      ),
    );
    expect(report.listing, isNotNull);
    expect(link.commands.single, contains('du -x -k -a -d 1'));
  });

  test('failures are typed', () async {
    Future<DiskUsageReportFailure?> failure(
      _Link link, [
      String path = '/srv',
    ]) async => (await readDiskUsage(
      _server,
      path,
      requestId: 'r',
      link: link,
    )).failure;

    expect(
      await failure(_Link(_out(listing)), 'srv'),
      DiskUsageReportFailure.invalidPath,
    );
    expect(
      await failure(
        _Link(_out(''))..failure = const RemoteCommandException('closed'),
      ),
      DiskUsageReportFailure.transport,
    );
    expect(
      await failure(
        _Link(
          _out(
            '$kDiskUsageErrorsMarker\n'
            "du: cannot access '/srv': No such file or directory\n",
          ),
        ),
      ),
      DiskUsageReportFailure.notFound,
    );
    expect(
      await failure(
        _Link(
          _out(
            '$kDiskUsageErrorsMarker\n'
            "du: cannot read directory '/srv': Permission denied\n",
          ),
        ),
      ),
      DiskUsageReportFailure.denied,
    );
    expect(
      await failure(_Link(_out('sh: du: not found\n'))),
      DiskUsageReportFailure.unreadable,
    );
  });
}
