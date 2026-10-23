// Crontab lines other managers own (JOB-09, 03 §8.7): Dokku's account,
// a cron.d file named for a manager, and a block a comment naming one
// opens, which runs to the next blank line.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  test('a comment naming a manager opens its block, to the next blank '
      'line', () {
    final owners = crontabOwners([
      '0 1 * * * /usr/local/bin/mine',
      '# Coolify: scheduled backups',
      '0 2 * * * docker exec coolify-db backup',
      '',
      '# runtipi updates',
      '0 3 * * * /opt/runtipi/update',
      '# and DOKKU next',
      '0 4 * * * dokku ps:report',
      '',
      '0 5 * * * /usr/local/bin/mine --late',
    ]);

    expect(owners, [
      null,
      CrontabManager.coolify,
      CrontabManager.coolify,
      null,
      CrontabManager.runtipi,
      CrontabManager.runtipi,
      CrontabManager.dokku,
      CrontabManager.dokku,
      null,
      null,
    ]);
  });

  test("a paused line is the app's own, whatever its held command "
      'names', () {
    expect(
      crontabOwners([
        '${kCrontabPauseMarker}2026-10-21T03:00:00Z 0 3 * * * dokku logs app',
        '0 4 * * * /usr/local/bin/mine',
      ]),
      [null, null],
    );
  });

  test("the dokku account's crontab and a manager's cron.d file are "
      'wholly its', () {
    expect(
      crontabOwners(['0 1 * * * a', '', '0 2 * * * b'], user: 'dokku'),
      everyElement(CrontabManager.dokku),
    );
    expect(crontabOwners(['0 1 * * * root a'], cronDFile: 'dokploy-backups'), [
      CrontabManager.dokploy,
    ]);
    expect(crontabOwners(['0 1 * * * root a'], cronDFile: 'dokkuish'), [
      null,
    ], reason: 'a name inside a longer word is not the manager');
    expect(crontabOwners(['# my cookbook', '0 1 * * * a']), [null, null]);
  });
}
