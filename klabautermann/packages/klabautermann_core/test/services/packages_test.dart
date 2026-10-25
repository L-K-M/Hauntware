// The package check (03 §7.8, PKG-01 to PKG-03): one command as the login
// user, its answer kept per server for an hour, concurrent reads sharing
// one run, and nothing kept when the link failed or the server left.
import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/services/packages.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';

final class _Link extends TestLinkBase {
  Object? failure;
  final commands = <({String command, Duration? timeout})>[];

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add((command: command, timeout: timeout));
    if (failure case final error?) throw error;
    return const RemoteCommandResult(
      exitCode: 0,
      stdout:
          '== manager pacman\n== updates\nlinux 1 -> 2\n== rc 0\n'
          '== reboot unknown\n',
    );
  }
}

void main() {
  final t0 = DateTime.utc(2026, 10, 25, 12);

  test('the check runs once, bounded, as the login user and answers what '
      'it found', () async {
    final link = _Link();
    final report = await readPackages(
      _server,
      requestId: 'r-1',
      link: link,
      now: () => t0,
    );

    expect(link.commands.single.command, contains('== manager apt'));
    expect(link.commands.single.command, isNot(contains('sudo')));
    expect(link.commands.single.timeout, isNotNull);
    expect((report.serverId, report.requestId), (_server, 'r-1'));
    expect(report.checkedAt, t0);
    expect(report.check!.updates.single.name, 'linux');
  });

  test('a failed link answers as such', () async {
    final link = _Link()..failure = const RemoteCommandException('closed');
    final report = await readPackages(
      _server,
      requestId: 'r-1',
      link: link,
      now: () => t0,
    );
    expect(report.failure, PackagesReportFailure.transport);
    expect(report.check, isNull);
  });

  group('PackageReports', () {
    late DateTime now;
    late PackageReports reports;
    late int checks;

    setUp(() {
      now = t0;
      reports = PackageReports(now: () => now);
      checks = 0;
    });

    Future<PackagesReport> check() async {
      checks++;
      return PackagesReport(
        serverId: _server,
        requestId: 'run-$checks',
        check: PackageCheck(manager: PackageManager.apk),
        checkedAt: now,
      );
    }

    Future<PackagesReport> read(String requestId, {bool fresh = false}) =>
        reports.read(_server, requestId: requestId, fresh: fresh, check: check);

    test('an answer stands for an hour unless a fresh check is asked '
        'for, and each read gets its own request id', () async {
      await read('a');
      now = t0.add(const Duration(minutes: 59));
      final kept = await read('b');
      expect(checks, 1);
      expect((kept.requestId, kept.checkedAt), ('b', t0));

      await read('c', fresh: true);
      expect(checks, 2);

      now = now.add(const Duration(minutes: 61));
      await read('d');
      expect(checks, 3);
    });

    test('reads while a check runs share it', () async {
      final gate = Completer<void>();
      Future<PackagesReport> slow() async {
        await gate.future;
        return check();
      }

      final first = reports.read(
        _server,
        requestId: 'a',
        fresh: false,
        check: slow,
      );
      final second = reports.read(
        _server,
        requestId: 'b',
        fresh: true,
        check: slow,
      );
      gate.complete();
      final answers = await Future.wait([first, second]);
      expect(checks, 1);
      expect([for (final a in answers) a.requestId], ['a', 'b']);
    });

    test('a failed check and one that ran while the server left are '
        'answered but not kept', () async {
      await reports.read(
        _server,
        requestId: 'a',
        fresh: false,
        check: () async => const PackagesReport(
          serverId: _server,
          requestId: 'x',
          failure: PackagesReportFailure.transport,
        ),
      );
      await read('b');
      expect(checks, 1);

      final gate = Completer<void>();
      final running = reports.read(
        _server,
        requestId: 'c',
        fresh: true,
        check: () async {
          await gate.future;
          return check();
        },
      );
      reports.forget({_server});
      gate.complete();
      expect((await running).check, isNotNull);

      await read('d');
      expect(checks, 3);
    });
  });
}
