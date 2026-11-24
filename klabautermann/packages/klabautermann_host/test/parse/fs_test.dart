// `fs` parser tests (03 §6.4, §7.3): `df -PT -B1` and `df -Pi` rows read
// from their fixed columns on the right, `df`'s complaints about mounts
// it could not read, and device names wrapped onto their own line.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _ctx = ParseContext.standard;

const _blocksHeader =
    'Filesystem     Type 1-blocks Used Available Capacity Mounted on';
const _inodesHeader = 'Filesystem Inodes IUsed IFree IUse% Mounted on';

String _payload(List<String> blocks, [List<String> inodes = const []]) => [
  '== blocks ==',
  _blocksHeader,
  ...blocks,
  '== inodes ==',
  _inodesHeader,
  ...inodes,
].join('\n');

void main() {
  test('a source with a space keeps its columns (HST-5)', () {
    final r = parseFs(
      _payload(
        [
          'gdrive:My Drive fuse.rclone 5000 2000 3000 40% /mnt/g',
          '//nas/Shared Docs cifs 900 300 600 34% /mnt/shared docs',
        ],
        [
          'gdrive:My Drive 100 40 60 40% /mnt/g',
          '//nas/Shared Docs 0 0 0 - /mnt/shared docs',
        ],
      ),
      _ctx,
    );

    expect(r.warnings, isEmpty);
    expect(r.value.mounts.map((m) => m.toJson()), [
      {
        'device': 'gdrive:My Drive',
        'type': 'fuse.rclone',
        'mountPoint': '/mnt/g',
        'sizeBytes': 5000,
        'usedBytes': 2000,
        'availBytes': 3000,
        'capacityPercent': 40,
        'inodesTotal': 100,
        'inodesUsed': 40,
        'inodesFree': 60,
        'inodeUsePercent': 40,
      },
      {
        'device': '//nas/Shared Docs',
        'type': 'cifs',
        'mountPoint': '/mnt/shared docs',
        'sizeBytes': 900,
        'usedBytes': 300,
        'availBytes': 600,
        'capacityPercent': 34,
        'inodesTotal': 0,
        'inodesUsed': 0,
        'inodesFree': 0,
        'inodeUsePercent': null,
      },
    ]);
  });

  test("df's complaint about a dead mount is reported beside the rows, "
      'never joined to one (HST-1)', () {
    const complaint = '/mnt/dead: Transport endpoint is not connected';
    final r = parseFs(
      _payload(
        [
          'df: $complaint',
          '/dev/sda1 ext4 1000000000 400000000 600000000 40% /',
          'tmpfs tmpfs 4096 0 4096 0% /run',
        ],
        ['df: $complaint', '/dev/sda1 65536 100 65436 1% /'],
      ),
      _ctx,
    );

    expect(r.value.errors, [complaint]);
    expect(r.warnings, ['df: $complaint']);
    final root = r.value.mounts.first;
    expect(root.device, '/dev/sda1');
    expect(root.type, 'ext4');
    expect(root.mountPoint, '/');
    expect(root.sizeBytes, 1000000000);
    expect(root.capacityPercent, 40);
    expect(root.inodesTotal, 65536);
    expect(r.value.mounts.map((m) => m.mountPoint), ['/', '/run']);
    expect(r.value.toJson()['errors'], [complaint]);
  });

  test('a complaint between rows costs neither neighbour', () {
    final r = parseFs(
      _payload([
        '/dev/sda1 ext4 1000 400 600 40% /',
        'df: /mnt/nfs: Stale file handle',
        'df: /mnt/smb: Host is down',
        '/dev/sdb1 xfs 2000 500 1500 25% /data',
      ]),
      _ctx,
    );

    expect(r.value.errors, [
      '/mnt/nfs: Stale file handle',
      '/mnt/smb: Host is down',
    ]);
    expect(r.value.mounts.map((m) => (m.device, m.mountPoint)), [
      ('/dev/sda1', '/'),
      ('/dev/sdb1', '/data'),
    ]);
  });

  test('a device wrapped onto its own line joins the next line only', () {
    final r = parseFs(
      _payload(
        [
          '/dev/mapper/a-very-long-volume-group-name-root',
          '               ext4 1000 400 600 40% /',
          '/dev/sdb1 xfs 2000 500 1500 25% /data',
        ],
        [
          '/dev/mapper/a-very-long-volume-group-name-root',
          '               100 40 60 40% /',
        ],
      ),
      _ctx,
    );

    expect(r.warnings, isEmpty);
    expect(r.value.errors, isEmpty);
    expect(r.value.toJson().containsKey('errors'), isFalse);
    expect(r.value.mounts.map((m) => (m.device, m.type, m.inodesTotal)), [
      ('/dev/mapper/a-very-long-volume-group-name-root', 'ext4', 100),
      ('/dev/sdb1', 'xfs', null),
    ]);
  });

  test('a line that is no row and no complaint is dropped with a warning, '
      'not joined to a whole row', () {
    final r = parseFs(
      _payload(['something unexpected', '/dev/sda1 ext4 1000 400 600 40% /']),
      _ctx,
    );

    expect(r.warnings, [contains('something unexpected')]);
    expect(r.value.mounts.single.device, '/dev/sda1');
  });
}
