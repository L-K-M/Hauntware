// DSK-05 and DSK-14's parser: findmnt's JSON or /proc/self/mounts, then
// /proc/swaps.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _swaps =
    '''
$kMountsSwapsMarker
Filename				Type		Size		Used		Priority
/dev/sda3                               partition	4194300		1024		-2
/swap\\040file                           file		1048572		0		10
''';

void main() {
  test('findmnt: each mount with its options, the last over a target in '
      'effect', () {
    final read = parseMounts('''
$kMountsFindmntMarker
{
   "filesystems": [
      {"target":"/", "source":"/dev/sda1", "fstype":"ext4", "options":"rw,relatime"},
      {"target":"/boot/efi", "source":"/dev/sda2", "fstype":"vfat", "options":"ro,fmask=0077"},
      {"target":"/mnt", "source":null, "fstype":"tmpfs", "options":"rw"},
      {"target":"/mnt", "source":"server:/export", "fstype":"nfs4", "options":"rw,vers=4.2"}
   ]
}
$_swaps''')!;
    expect(read.mounts, hasLength(4));
    final root = read.mountAt('/')!;
    expect(
      (root.source, root.type, root.readOnly),
      ('/dev/sda1', 'ext4', false),
    );
    expect(root.options, ['rw', 'relatime']);
    expect(read.mountAt('/boot/efi')!.readOnly, isTrue);
    expect(read.mountAt('/mnt')!.type, 'nfs4');
    expect(read.mounts[2].source, '');
    expect(read.mountAt('/srv'), isNull);
  });

  test('/proc/self/mounts: escaped paths read back, as findmnt-less hosts '
      'print them', () {
    final read = parseMounts('''
$kMountsProcMarker
/dev/root / ext4 rw,relatime 0 0
proc /proc proc rw,nosuid,nodev,noexec,relatime 0 0
/dev/sdb1 /media/my\\040disk vfat ro,relatime 0 0
$_swaps''')!;
    expect(
      [for (final m in read.mounts) m.target],
      ['/', '/proc', '/media/my disk'],
    );
    expect(read.mountAt('/media/my disk')!.readOnly, isTrue);
  });

  test('swaps: partitions and files with sizes in bytes and priorities', () {
    final read = parseMounts('$kMountsProcMarker\n$_swaps')!;
    expect(
      [
        for (final s in read.swaps)
          (s.path, s.kind, s.sizeBytes, s.usedBytes, s.priority),
      ],
      [
        ('/dev/sda3', SwapKind.partition, 4194300 * 1024, 1024 * 1024, -2),
        ('/swap file', SwapKind.file, 1048572 * 1024, 0, 10),
      ],
    );
    expect(
      parseMounts('$kMountsProcMarker\n$kMountsSwapsMarker\n')!.swaps,
      isEmpty,
    );
  });

  test('output that is not the read is not taken for one', () {
    expect(parseMounts(''), isNull);
    expect(
      parseMounts('$kMountsProcMarker\n/dev/root / ext4 rw 0 0\n'),
      isNull,
    );
    expect(parseMounts('== other\n$kMountsSwapsMarker\n'), isNull);
    expect(
      parseMounts('$kMountsFindmntMarker\nnot json\n$kMountsSwapsMarker\n'),
      isNull,
    );
  });
}
