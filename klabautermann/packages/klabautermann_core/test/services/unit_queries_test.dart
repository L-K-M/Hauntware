// The v1 unit reads (03 §7.5; M5 plan M22): a unit's file with its
// secrets masked, its resources, the sockets in either table shape, the
// user manager's commands, and why a read found nothing.
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/services/unit_queries.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteCommandException, RemoteCommandResult;
import 'package:test/test.dart';

import '../support/scripted_link.dart';

const _server = 'srv-1';

/// Answers every command with [answer], and records it.
final class _Link extends TestLinkBase {
  _Link(this.answer);

  RemoteCommandResult answer;
  Object? failure;
  final commands = <String>[];

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    if (failure case final error?) throw error;
    return answer;
  }
}

RemoteCommandResult _out(String stdout) =>
    RemoteCommandResult(exitCode: 0, stdout: stdout);

RemoteCommandResult _err(String stderr) =>
    RemoteCommandResult(exitCode: 1, stderr: stderr);

final _profile = HostProfile(
  uid: 1000,
  user: 'deploy',
  systemdVersion: 255,
  xdgRuntimeDir: '/run/user/1000',
);

Future<UnitPayload> _query(
  _Link link,
  UnitQuerySpec query, {
  HostProfile? profile,
}) async {
  final result = await runUnitQuery(
    _server,
    'r-1',
    query,
    link: link,
    profile: profile ?? _profile,
  );
  expect((result.serverId, result.requestId), (_server, 'r-1'));
  return result.payload;
}

String _shown(List<MaskedValue> text) => text.map((v) => v.display).join();

String _revealed(List<MaskedValue> text) =>
    text.map((v) => v.reveal() ?? v.display).join();

void main() {
  test("a unit's file masks Environment= values and Exec secrets, and "
      'reveals them as read', () async {
    const file =
        '# /etc/systemd/system/app.service\n'
        '[Service]\n'
        'Environment=DB_PASSWORD=hunter2 MODE=prod\n'
        'ExecStart=/usr/bin/app --token=s3cret --port 8080\n'
        'ExecReload=/bin/kill -HUP \$MAINPID\n'
        'Restart=on-failure\n';
    final link = _Link(_out(file));

    final payload = await _query(link, const UnitFileQuery('app.service'));

    expect(
      link.commands.single,
      endsWith("'systemctl' 'cat' '--' 'app.service'"),
    );
    final text = (payload as UnitFilePayload).text;
    expect(
      _shown(text),
      '# /etc/systemd/system/app.service\n'
      '[Service]\n'
      'Environment=********\n'
      'ExecStart=/usr/bin/app --token=******** --port 8080\n'
      'ExecReload=/bin/kill -HUP \$MAINPID\n'
      'Restart=on-failure\n',
    );
    expect(_revealed(text), file);
  });

  test('a backslash continuation of a masked assignment is masked whole', () {
    const file =
        'ExecStart=/usr/bin/app \\\n'
        '    --db-password=hunter2\n'
        'Environment=A=1 \\\n'
        '    B=hunter2\n'
        'Restart=always\n';

    final text = maskUnitFile(file);

    expect(
      _shown(text),
      'ExecStart=/usr/bin/app \\\n'
      '********\n'
      'Environment=********\n'
      '********\n'
      'Restart=always\n',
    );
    expect(_revealed(text), file);
  });

  test("a user unit reads in the user's manager", () async {
    final link = _Link(_out('[Unit]\n'));

    await _query(
      link,
      const UnitFileQuery('syncthing.service', scope: UnitScope.user),
      profile: HostProfile(uid: 1000, user: 'deploy'),
    );

    expect(
      link.commands.single,
      contains("'env' 'XDG_RUNTIME_DIR=/run/user/1000' 'systemctl' '--user'"),
    );
  });

  test("a unit's resources read from systemctl show", () async {
    final link = _Link(
      _out(
        'MemoryCurrent=52428800\n'
        'CPUUsageNSec=1500000000\n'
        'TasksCurrent=7\n'
        'NRestarts=2\n'
        'MainPID=4300\n'
        'ActiveEnterTimestamp=Tue 2026-10-20 03:00:00 UTC\n',
      ),
    );

    final payload = await _query(link, const UnitResourcesQuery('app.service'));

    final resources = (payload as UnitResourcesPayload).resources;
    expect(resources.memoryBytes, 52428800);
    expect(resources.tasks, 7);
    expect(resources.restarts, 2);
    expect(resources.mainPid, 4300);
    expect(link.commands.single, contains('--property=MemoryCurrent'));
  });

  test(
    'the sockets read as JSON from systemd 246 and as text before',
    () async {
      final json = _Link(
        _out(
          '[{"listen":"/run/docker.sock","unit":"docker.socket",'
          '"activates":"docker.service"}]',
        ),
      );
      final sockets = await _query(json, const SocketsQuery());
      expect(json.commands.single, contains("'--output=json'"));
      expect(
        (sockets as UnitSocketsPayload).sockets.single.unit,
        'docker.socket',
      );

      final text = _Link(
        _out('/run/docker.sock docker.socket docker.service\n'),
      );
      await _query(
        text,
        const SocketsQuery(),
        profile: HostProfile(uid: 1000, systemdVersion: 245),
      );
      expect(text.commands.single, contains("'--no-legend'"));
    },
  );

  test('a failed read says why', () async {
    Future<UnitQueryFailed> failed(
      RemoteCommandResult answer, [
      UnitQuerySpec query = const UnitFileQuery('app.service'),
    ]) async => await _query(_Link(answer), query) as UnitQueryFailed;

    expect(
      (await failed(_err('No files found for app.service.\n'))).failure,
      UnitQueryFailure.notFound,
    );
    expect(
      (await failed(_err('Unit app.service could not be found.\n'))).failure,
      UnitQueryFailure.notFound,
    );
    expect(
      (await failed(
        _err('Failed to connect to bus: No medium found\n'),
        const SocketsQuery(scope: UnitScope.user),
      )).failure,
      UnitQueryFailure.managerUnavailable,
    );
    final other = await failed(_err('Something else broke\n'));
    expect(other.failure, UnitQueryFailure.failed);
    expect(other.detail, 'Something else broke');

    final invalid = _Link(_out(''));
    expect(
      (await _query(invalid, const UnitFileQuery('a b')) as UnitQueryFailed)
          .failure,
      UnitQueryFailure.invalidUnit,
    );
    expect(invalid.commands, isEmpty);

    final broken = _Link(_out(''))
      ..failure = const RemoteCommandException('channel closed');
    expect(
      (await _query(broken, const SocketsQuery()) as UnitQueryFailed).failure,
      UnitQueryFailure.noLink,
    );
  });
}
