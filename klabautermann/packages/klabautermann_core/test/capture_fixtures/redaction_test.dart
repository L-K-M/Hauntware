// Redaction rules of the capture tool (03 §6.5): literals as whole
// words, identifier and secret patterns, the procs argv rules, byte
// preservation and the review that blocks a write.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

import '../../tool/src/redaction.dart';

// Split so that no file carries a private-key header.
const _pemBegin =
    '-----BEGIN OPENSSH'
    ' PRIVATE KEY-----';
const _pemEnd =
    '-----END OPENSSH'
    ' PRIVATE KEY-----';

String _redact(
  String text, {
  String collector = 'identity',
  RedactionLiterals literals = const RedactionLiterals(),
}) => latin1.decode(
  Redactor(literals).redact(collector, latin1.encode(text)).bytes,
);

void main() {
  group('literals', () {
    const literals = RedactionLiterals(
      hostNames: ['vm', 'web1', 'web1.corp.example.org'],
      userNames: ['anke'],
      homeDirs: ['/srv/anke-home'],
      extra: ['nas07'],
    );

    test('host names match whole words, case-insensitively', () {
      expect(
        _redact(
          'Hostname=WEB1.corp.example.org web1 vm vm.local web1-backup.timer',
          literals: literals,
        ),
        'Hostname=fixture-host fixture-host fixture-host fixture-host.local '
        'fixture-host-backup.timer',
      );
    });

    test('a short host name leaves words that contain it alone', () {
      const status = '1 VmRSS:\t 100 kB\nkvm-clock';
      expect(_redact(status, literals: literals), status);
    });

    test('user names in any case, inside unit names too', () {
      expect(
        _redact(
          'user=anke\nhome-anke.mount Session 3 of User Anke anker',
          literals: literals,
        ),
        'user=user\nhome-user.mount Session 3 of User user anker',
      );
    });

    test('a hyphenated name in its device-mapper and systemd forms', () {
      const hyphenated = RedactionLiterals(
        hostNames: ['web-01'],
        userNames: ['anke-m'],
      );
      const units =
          r'dev-mapper-web\x2d\x2d01\x2d\x2dvg\x2droot.device '
          r'dev-mapper-vg0\x2dweb\x2d\x2d01.device "home-anke\\x2dm.mount"';
      expect(
        _redact('/dev/mapper/web--01--vg-root\n$units', literals: hyphenated),
        '/dev/mapper/fixture-host--vg-root\n'
        r'dev-mapper-fixture-host\x2d\x2dvg\x2droot.device '
        r'dev-mapper-vg0\x2dfixture-host.device "home-user.mount"',
      );
      expect(Redactor(hyphenated).review(units), [
        (1, 'still names the host'),
        (1, 'still names a user'),
      ]);
    });

    test('a name after any systemd escape', () {
      const units =
          r'mnt-Backup\x20web1.mount media-x\x20anke.mount '
          r'"srv-x\\x40anke.mount"';
      expect(
        _redact(units, literals: literals),
        r'mnt-Backup\x20fixture-host.mount media-x\x20user.mount '
        r'"srv-x\\x40user.mount"',
      );
      expect(Redactor(literals).review(units), [
        (1, 'still names the host'),
        (1, 'still names a user'),
      ]);
    });

    test("the host's domain under any first label", () {
      const domain = RedactionLiterals(
        hostNames: ['web-01.corp.acme.io', 'web-01'],
        domains: ['corp.acme.io', 'acme.io'],
      );
      const units =
          'openvpn-client@vpn.corp.acme.io.service to VPN.Corp.Acme.IO\n'
          'backup.corp.acme.io:/bk/web-01/ vpn.acme.io notacme.io';
      expect(
        _redact(units, literals: domain, collector: 'units'),
        'openvpn-client@vpn.example.net.service to VPN.example.net\n'
        'backup.example.net:/bk/fixture-host/ vpn.example.net notacme.io',
      );
      expect(Redactor(domain).review(units), [
        (1, "still names the host's domain"),
        (2, "still names the host's domain"),
        (2, 'still names the host'),
      ]);
    });

    test('a home directory goes before the user name', () {
      expect(
        _redact('/srv/anke-home/bin /srv/anke-home2', literals: literals),
        '/home/user/bin /srv/user-home2',
      );
    });

    test('a --redact value goes wherever it occurs', () {
      expect(
        _redact('NAS07:/export backupnas07x', literals: literals),
        '[redacted]:/export backup[redacted]x',
      );
    });

    test('a placeholder that holds a literal never blocks the write', () {
      final redactor = Redactor(
        const RedactionLiterals(
          hostNames: ['host'],
          userNames: ['user', 'anke'],
          homeDirs: ['/home/user'],
        ),
      );
      final r = redactor.redact(
        'identity',
        latin1.encode('user=user home=/home/user host anke x/home/user/bin'),
      );
      expect(
        latin1.decode(r.bytes),
        'user=user home=/home/user fixture-host user x/home/user/bin',
      );
      // Only what changed counts.
      expect(r.counts, {'host name': 1, 'user name': 1});
      expect(redactor.review(latin1.decode(r.bytes)), isEmpty);
    });
  });

  group('identifiers', () {
    test('IPv4 keeps loopback and the unspecified address', () {
      expect(
        _redact(
          '10.1.2.3 127.0.0.1 0.0.0.0 1.2.3 256.1.1.1 5.15.0.1-x\n'
          '# push to 10.20.30.40. 1.2.3.4.5',
        ),
        '192.0.2.1 127.0.0.1 0.0.0.0 1.2.3 256.1.1.1 192.0.2.1-x\n'
        '# push to 192.0.2.1. 1.2.3.4.5',
      );
    });

    test('IPv6 keeps ::1 and leaves clock times and C++ names alone', () {
      expect(
        _redact(
          'fe80::1c2:3ff:fe4a:5b6c ::1 12:34:56 2001:0db8:0:0:0:0:2:1 '
          'std::vector ::ffff:10.0.0.1',
        ),
        '2001:db8::1 ::1 12:34:56 2001:db8::1 std::vector ::ffff:192.0.2.1',
      );
    });

    test('IPv6 before an unbracketed port and after a word', () {
      // systemd's Accept=yes instance names print local and peer addresses
      // as `<address>:<port>`.
      expect(
        _redact(
          'sshd@3-2a01:4f8:c17:1234::1:22-2a02:8070:abcd:1::5:51234.service\n'
          'x@4-12-2a01:4f8:c17:1234:1:2:3:4:22-2a02:807:a:1:2:3:4:5:51234.y\n'
          'host:2a01:4f8:c17:1234::1 code:2a01::5 deadbeef:2a01::5',
          collector: 'units',
        ),
        'sshd@3-2001:db8::1-2001:db8::1:51234.service\n'
        'x@4-12-2001:db8::1:22-2001:db8::1:51234.y\n'
        'host:2001:db8::1 code:2001:db8::1 deadbeef:2001:db8::1',
      );
      // Still no address: the tail of a longer colon run, a C++ name.
      const runs = 'a:b:c:d:e:f:1:2:3:4 std::abc a:b::c:12345678';
      expect(_redact(runs), runs);
    });

    test('MAC, UUID, hex ids and email addresses', () {
      expect(
        _redact(
          'aa:bb:cc:dd:ee:ff 6f1d2c3b-aaaa-4bbb-8ccc-0123456789ab '
          '0123456789abcdef0123456789abcdef root@web1.example.org',
        ),
        '00:00:5e:00:53:01 00000000-0000-0000-0000-000000000000 '
        '${'0' * 32} user@example.com',
      );
    });

    test('systemd template instances are no email addresses', () {
      const units =
          'getty@tty1.service user@1000.service modprobe@drm.service '
          'zfs-scrub@tank.timer';
      expect(_redact(units, collector: 'units'), units);
    });

    test('disk names and UUIDs in systemd-escaped unit names', () {
      const uuid = r'6f1d2c3b\x2daaaa\x2d4bbb\x2d8ccc\x2d0123456789ab';
      const zero = r'00000000\x2d0000\x2d0000\x2d0000\x2d000000000000';
      expect(
        _redact(
          'dev-disk-by\\x2did-ata\\x2dSSD_S3Z1NB0K123456X\\x2dpart1.device\n'
          'dev-disk-by\\x2did-wwn\\x2d0x5002538e40a1b2c3.device x\n'
          '"systemd-fsck@dev-disk-by\\\\x2duuid-0A1B\\\\x2d2C3D.service"\n'
          'File System Check on /dev/disk/by-uuid/0A1B-2C3D\n'
          'systemd-cryptsetup@luks\\x2d$uuid.service',
          collector: 'units',
        ),
        'dev-disk-by\\x2did-fixture\\x2ddisk.device\n'
        'dev-disk-by\\x2did-fixture\\x2ddisk.device x\n'
        '"systemd-fsck@dev-disk-by\\\\x2duuid-fixture\\\\x2ddisk.service"\n'
        'File System Check on /dev/disk/by-uuid/fixture-disk\n'
        'systemd-cryptsetup@luks\\x2d$zero.service',
      );
      expect(
        _redact('/dev/mapper/luks-6f1d2c3b-aaaa-4bbb-8ccc-0123456789ab /'),
        '/dev/mapper/luks-00000000-0000-0000-0000-000000000000 /',
      );
    });

    test('serials in every /dev by-* link and its device unit', () {
      // USB serial adapters, SAS addresses in by-path, a camera.
      expect(
        _redact(
          '/dev/serial/by-id/usb-FTDI_FT232R_USB_UART_A50285BI-if00-port0 x\n'
          '/dev/disk/by-path/pci-0000:02:00.0-sas-0x5000c5008e3c1a2d-lun-0\n'
          'dev-serial-by\\x2did-usb\\x2dSilicon_Labs_CP2102_0001A2B3C4'
          '\\x2dif00\\x2dport0.device\n'
          '"dev-disk-by\\\\x2dpath-pci\\\\x2d0000:02:00.0\\\\x2dsas'
          '\\\\x2d0x5000c5008e3c1a2d\\\\x2dlun\\\\x2d0.device"\n'
          'dev-v4l-by\\x2did-usb\\x2d046d_C920_ABCD1234\\x2dvideo.device',
          collector: 'units',
        ),
        '/dev/serial/by-id/fixture-device x\n'
        '/dev/disk/by-path/fixture-disk\n'
        'dev-serial-by\\x2did-fixture\\x2ddevice.device\n'
        '"dev-disk-by\\\\x2dpath-fixture\\\\x2ddisk.device"\n'
        'dev-v4l-by\\x2did-fixture\\x2ddevice.device',
      );
    });

    test('MACs in wwx names, with hyphens and in dotted form', () {
      expect(
        _redact(
          'wwx001e101f2a3b 1000 2000\n'
          'sys-subsystem-net-devices-wwx001e101f2a3b.device\n'
          '00-1E-10-1F-2A-3B 001e.101f.2a3b',
          collector: 'units',
        ),
        'wwx00005e005301 1000 2000\n'
        'sys-subsystem-net-devices-wwx00005e005301.device\n'
        '00-00-5e-00-53-01 0000.5e00.5301',
      );
    });

    test('MACs in interface names, disk ids and hostnamectl fields', () {
      expect(
        _redact(
          'enx0123456789ab wlxa0b1c2d3e4f5 eth0\n'
          '/dev/disk/by-id/ata-SSD_S3Z1NB0K123456X-part1 /\n'
          '{"HardwareSerial":"PF2ABCDE","ChassisAssetTag":"A-1",'
          '"PrettyHostname":"Anke\'s box","Location":"Rack 3",'
          '"HardwareModel":"X1"}',
        ),
        'enx00005e005301 wlx00005e005301 eth0\n'
        '/dev/disk/by-id/fixture-disk /\n'
        '{"HardwareSerial":"[redacted]","ChassisAssetTag":"[redacted]",'
        '"PrettyHostname":"[redacted]","Location":"[redacted]",'
        '"HardwareModel":"X1"}',
      );
    });

    test('machine-info fields hostnamectl repeats since systemd 256', () {
      expect(
        _redact(
          '{"MachineInformationData":["PRETTY_HOSTNAME=Anke\'s \\"Box\\"",'
          '"LOCATION=Rack 3, Berlin office","DEPLOYMENT=production",'
          '"TAGS=web:berlin"],"MachineTags":["web","berlin"]}',
        ),
        '{"MachineInformationData":["PRETTY_HOSTNAME=[redacted]",'
        '"LOCATION=[redacted]","DEPLOYMENT=production",'
        '"TAGS=[redacted]"],"MachineTags":["[redacted]"]}',
      );
      expect(_redact('"MachineTags":[ ]'), '"MachineTags":[ ]');
    });

    test('network mount sources in fs lose their server names', () {
      const fs =
          '== blocks ==\n'
          'nas07.lan:/volume1/backups\n'
          '                        nfs4 100 50 50 50% /mnt/backup\n'
          '//filer/share           cifs 100 50 50 50% /mnt/share\n'
          'anke@box:/home/anke     fuse.sshfs 1 1 0 100% /mnt/box\n'
          '10.0.0.9:/export        nfs 1 1 0 100% /mnt/x\n'
          '/dev/sda1               ext4 1 1 0 100% /';
      expect(
        _redact(fs, collector: 'fs'),
        '== blocks ==\n'
        'fixture-nas:/volume1/backups\n'
        '                        nfs4 100 50 50 50% /mnt/backup\n'
        '//fixture-nas/share           cifs 100 50 50 50% /mnt/share\n'
        'fixture-nas:/home/user     fuse.sshfs 1 1 0 100% /mnt/box\n'
        '192.0.2.1:/export        nfs 1 1 0 100% /mnt/x\n'
        '/dev/sda1               ext4 1 1 0 100% /',
      );
      // Elsewhere `<word>:/` is no mount source.
      const cpe = '"OperatingSystemCPEName":"cpe:/o:canonical:ubuntu_linux"';
      expect(_redact(cpe), cpe);
    });

    test('network mount sources in their other forms', () {
      // davfs and curlftpfs URLs, sshfs's `host:` with no or a relative
      // path, Ceph monitors with ports.
      const fs =
          '== blocks ==\n'
          'https://dav.corp.acme.io/remote.php/webdav/ fuse 1 1 0 1% /mnt/d\n'
          'https://anke@dav.corp.acme.io:8443/x fuse 1 1 0 1% /mnt/d2\n'
          'https://10.0.0.5/dav fuse 1 1 0 1% /mnt/d3\n'
          'nas.corp.acme.io:      fuse.sshfs 1 1 0 1% /mnt/nas\n'
          'nas.corp.acme.io:backups fuse.sshfs 1 1 0 1% /mnt/nas2\n'
          'mon1.corp.acme.io:6789:/ ceph 1 1 0 1% /mnt/ceph\n'
          'mon1.x.io:6789,mon2.x.io:6789:/ ceph 1 1 0 1% /mnt/c2\n'
          'curlftpfs#ftp://ftp.corp.acme.io/ fuse 1 1 0 1% /mnt/ftp\n'
          'tmpfs tmpfs 1 1 0 1% /run\n'
          'C:\\ 9p 1 1 0 1% /mnt/c';
      expect(
        _redact(fs, collector: 'fs'),
        '== blocks ==\n'
        'https://fixture-nas/remote.php/webdav/ fuse 1 1 0 1% /mnt/d\n'
        'https://fixture-nas:8443/x fuse 1 1 0 1% /mnt/d2\n'
        'https://192.0.2.1/dav fuse 1 1 0 1% /mnt/d3\n'
        'fixture-nas:      fuse.sshfs 1 1 0 1% /mnt/nas\n'
        'fixture-nas:backups fuse.sshfs 1 1 0 1% /mnt/nas2\n'
        'fixture-nas:/ ceph 1 1 0 1% /mnt/ceph\n'
        'fixture-nas:/ ceph 1 1 0 1% /mnt/c2\n'
        'curlftpfs#ftp://fixture-nas/ fuse 1 1 0 1% /mnt/ftp\n'
        'tmpfs tmpfs 1 1 0 1% /run\n'
        'C:\\ 9p 1 1 0 1% /mnt/c',
      );
    });

    test('counts replacements per rule and keeps other bytes', () {
      final payload = [...latin1.encode('a 10.0.0.1 10.0.0.2 '), 0xff, 0x0a];
      final r = Redactor(const RedactionLiterals()).redact('fs', payload);
      expect(r.counts, {'IPv4 address': 2});
      expect(r.bytes, [...latin1.encode('a 192.0.2.1 192.0.2.1 '), 0xff, 0x0a]);
    });
  });

  // These rules hold for every payload; in `cron` the job structure
  // (the cron group) removes command arguments first.
  group('other accounts', () {
    // Directory-service accounts and passwd accounts outside the literal
    // set (the second verification's erin, carol and dave).
    test('every home directory path, also another account\'s', () {
      expect(
        _redact(
          '/home/erin/bin/syncer /var/home/erin fixture-nas:/export/home/dave\n'
          '/home/erin@corp.example/x /home /home/user/x "/home/j\xc3\xbcrgen" '
          'PATH=/home/carol/bin:/usr/bin',
        ),
        '/home/user/bin/syncer /var/home/user fixture-nas:/export/home/user\n'
        '/home/user/x /home /home/user/x "/home/user" '
        'PATH=/home/user/bin:/usr/bin',
      );
    });

    test('home mount units in their systemd-escaped names', () {
      const units =
          'home-erin.mount home-erin-Music.mount var-home-erin.automount\n'
          '"home-j\\\\xc3\\\\xbcrgen.mount" home-a.mueller.mount '
          r'home-anke\x2dm.mount'
          '\n'
          'home.mount home-user.mount home-assistant.service '
          'systemd-homed.service';
      expect(
        _redact(units, collector: 'units'),
        'home-user.mount home-user-Music.mount var-home-user.automount\n'
        '"home-user.mount" home-user.mount home-user.mount\n'
        'home.mount home-user.mount home-assistant.service '
        'systemd-homed.service',
      );
    });

    test('session scopes name no account but root', () {
      expect(
        _redact(
          '{"unit":"session-5.scope","description":"Session 5 of User erin"}\n'
          'session-c1.scope loaded active running Session c1 of User gdm\n'
          '"Session 3 of User root"',
          collector: 'units',
        ),
        '{"unit":"session-5.scope","description":"Session 5 of User user"}\n'
        'session-c1.scope loaded active running Session c1 of User user\n'
        '"Session 3 of User root"',
      );
    });

    test('ps fallback rows name no account but root', () {
      const rows = '== rows ==\n4242 S 1 1 1 1 0 100 x\n== cmdline ==\n';
      expect(
        _redact(
          '$rows== ps ==\n'
          '    PID    PPID USER     STAT   RSS COMMAND\n'
          '   4242       1 erin     S      100 /home/erin/bin/syncer --x\n'
          '   4243       1 root     S      100 cron -f\n'
          '   4244       1 www-data S',
          collector: 'procs',
        ),
        '$rows== ps ==\n'
        '    PID    PPID USER     STAT   RSS COMMAND\n'
        '   4242       1 user     S      100 /home/user/bin/syncer [redacted]\n'
        '   4243       1 root     S      100 cron [redacted]\n'
        '   4244       1 user     S',
      );
      expect(
        _redact(
          '$rows== ps_w ==\n'
          '  PID USER       TIME COMMAND\n'
          '    1 dave       0:01 init',
          collector: 'procs',
        ),
        '$rows== ps_w ==\n'
        '  PID USER       TIME COMMAND\n'
        '    1 user       0:01 init',
      );
    });
  });

  group('secrets', () {
    const cron =
        '== crontab ==\n'
        'DB_PASSWORD=hunter2\n'
        '* * * * * curl -H "Authorization: Bearer abcdefghijklmnop0123" '
        'https://bot:s3cret@example.org/x\n'
        '$_pemBegin\n'
        'b3BlbnNzaC1rZXktdjEAAAAA\n'
        '$_pemEnd\n'
        '0 3 * * * /usr/bin/backup';

    test('secrets, URL credentials and private keys become placeholders', () {
      final r = Redactor(
        const RedactionLiterals(),
      ).redact('units', utf8.encode(cron));
      expect(
        latin1.decode(r.bytes),
        '== crontab ==\n'
        'DB_PASSWORD=[redacted]\n'
        '* * * * * curl -H "Authorization: [redacted]" '
        'https://[redacted]@example.org/x\n'
        '[redacted]\n'
        '0 3 * * * /usr/bin/backup',
      );
      expect(r.counts, {'secret': 3, 'URL credentials': 1});
    });

    test('URL credentials without a user name', () {
      expect(
        _redact(
          'redis-cli -u redis://:Hunter2@localhost:6379/0 ping\n'
          'x rediss://:Hunter2@10.0.0.5:6379',
          collector: 'units',
        ),
        'redis-cli -u redis://[redacted]@localhost:6379/0 ping\n'
        'x rediss://[redacted]@192.0.2.1:6379',
      );
    });

    test('crontab credential shapes SecretRedactor misses', () {
      const lines = [
        ('PGPASSWORD=Hunter2 pg_dump', 'PGPASSWORD=[redacted] pg_dump'),
        (
          'MYSQL_PWD="a b" BORG_PASSPHRASE=c',
          'MYSQL_PWD=[redacted] BORG_PASSPHRASE=[redacted]',
        ),
        (
          'mysqldump -u backup -pHunter2 shop',
          'mysqldump -u backup -p[redacted] shop',
        ),
        (
          "/usr/bin/mysql -uroot -p'S3 cr'",
          '/usr/bin/mysql -uroot -p[redacted]',
        ),
        (
          'curl -u admin:Hunter2 https://x.org',
          'curl -u [redacted] https://x.org',
        ),
        (
          'sshpass -p Hunter2 rsync -a x y:z',
          'sshpass -p [redacted] rsync -a x y:z',
        ),
        (
          '-H "Authorization: Basic YWRtaW46aHVudGVyMg=="',
          '-H "Authorization: Basic [redacted]"',
        ),
      ];
      final redactor = Redactor(const RedactionLiterals());
      final text = lines.map((l) => l.$1).join('\n');
      final r = redactor.redact('units', latin1.encode(text));
      final redacted = latin1.decode(r.bytes);
      expect(redacted, lines.map((l) => l.$2).join('\n'));
      expect(r.counts, {'secret': 8});
      expect(redactor.review(text), [
        for (var i = 1; i <= lines.length; i++) (i, 'looks like a secret'),
      ]);
      expect(redactor.review(redacted), isEmpty);
      // `-p` as a port, a path flag or a prompt, `-u` without a password.
      const plain =
          'mkdir -p /x; ssh -p 2222 h; mysqldump -p db | pigz -p4\n'
          'rsync -u h:/src /dst; sudo -u www-data x; mysql -uroot';
      expect(_redact(plain, collector: 'units'), plain);
    });

    test('secret-named options and the password options of clients', () {
      const lines = [
        (
          'gpg --batch --passphrase Hunter2 -c /x',
          'gpg --batch --passphrase [redacted] -c /x',
        ),
        (
          "wget --http-password 'a b' https://x/y",
          'wget --http-password [redacted] https://x/y',
        ),
        (
          'backup --auth-token abc123 -client-secret "Zz9',
          'backup --auth-token [redacted] -client-secret [redacted]',
        ),
        (
          'mongodump -u admin -p Hunter2 --out /x',
          'mongodump -u admin -p [redacted] --out /x',
        ),
        (
          'ldapsearch -x -w Hunter2 -b dc=x',
          'ldapsearch -x -w [redacted] -b dc=x',
        ),
        (
          'redis-cli -h db -a Hunter2 ping',
          'redis-cli -h db -a [redacted] ping',
        ),
        ('smbclient -U anke%Hunter2 //h/s', 'smbclient -U [redacted] //h/s'),
        (
          'curl -U p:Hunter2 --proxy-user p:Hunter2 x',
          'curl -U [redacted] --proxy-user [redacted] x',
        ),
        (
          'zip -P Hunter2 o.zip x; 7z a -pHunter2 o.7z',
          'zip -P [redacted] o.zip x; 7z a -p[redacted] o.7z',
        ),
      ];
      final redactor = Redactor(const RedactionLiterals());
      final text = lines.map((l) => l.$1).join('\n');
      final redacted = _redact(text, collector: 'units');
      expect(redacted, lines.map((l) => l.$2).join('\n'));
      expect(redactor.review(text), [
        for (var i = 1; i <= lines.length; i++) (i, 'looks like a secret'),
      ]);
      expect(redactor.review(redacted), isEmpty);
      // Prompts, the same letters in other programs, on the next line too.
      const plain =
          'ldapsearch -W -x; 7z x -p a.7z; ls -a /x; tar -P -cf x\n'
          '0 3 * * * mysqldump db\n0 4 * * * pigz -p4 x\n'
          'systemctl --no-ask-password stop x';
      expect(_redact(plain, collector: 'units'), plain);
    });

    test('a private-key header without its end becomes a placeholder', () {
      expect(
        _redact('$_pemBegin\nb3Blbg', collector: 'units'),
        '[redacted]\nb3Blbg',
      );
    });
  });

  group('cron', () {
    // The second verification's lines: crontab(5) environment syntax,
    // password options of clients no rule lists, positional secrets.
    const cron =
        '== crontab_meta ==\n'
        'rc=0\n'
        '== crontab ==\n'
        '# m h dom mon dow command\n'
        'MYSQL_PWD = Hunter2spaced\n'
        'DB_PASS= Hunter2nsb\n'
        'RESTIC_PASSWORD=correct horse battery staple\n'
        'DB_PW=Hunter2xyz\n'
        'CRON_TZ=Europe/Berlin\n'
        '*/5 * * * * docker login -u ci -p Hunter2xyz registry.example.net\n'
        "0 2 * * * lftp -u backup,Hunter2ftp -e 'mirror -R /srv /bk; quit' x\n"
        '0 1 * * * azcopy sync /srv "https://a.blob.core.windows.net/bk?sv=1'
        '&sig=Zx8sQ2kLm4%2FpRt7Yv1Wn9Bc3Df5Gh6Jk0Lq2Ws4Ed8%3D"\n'
        "@reboot echo 'Hunter2sudo' | sudo -S mount -a\n"
        '30 4 * * * PGPASSWORD=Hunter2 pg_dump db\r\n'
        '== etc_crontab ==\n'
        'SHELL=/bin/sh\n'
        '# mirror //admin:Hunter2xyz@mirror/x, pushes to...10.20.30.40\n'
        '#\n'
        '*/5 * * * * root ipmitool -H 10.0.0.9 -U admin -P Hunter2xyz power\n'
        '17 * * * * www-data sqlplus -s scott/Hunter2ora@orcl @/opt/r.sql\n'
        '@reboot erin /opt/bin/syncer --token x\n'
        '61 * * * * root curl -u admin:Hunter2xyz https://x\n'
        '== cron_d ==\n'
        'zz-hostile\tDB_PASS =Hunter2nsa\n'
        'zz-hostile\t0 1 * * * carol /opt/bin/sync.sh -p Hunter2xyz\n'
        'zz-hostile\tbackup\t0 1 * * * carol /opt/bin/sync.sh\n'
        'no-tab line\n'
        '== cron_dirs ==\n'
        'daily logrotate\n'
        'weekly\n'
        'hw_timeout=absent';

    test('jobs keep their schedule and first command word', () {
      expect(
        _redact(cron, collector: 'cron'),
        '== crontab_meta ==\n'
        'rc=0\n'
        '== crontab ==\n'
        '# [redacted]\n'
        'MYSQL_PWD = [redacted]\n'
        'DB_PASS= [redacted]\n'
        'RESTIC_PASSWORD=[redacted]\n'
        'DB_PW=[redacted]\n'
        'CRON_TZ=Europe/Berlin\n'
        '*/5 * * * * docker [redacted]\n'
        '0 2 * * * lftp [redacted]\n'
        '0 1 * * * azcopy [redacted]\n'
        '@reboot echo [redacted]\n'
        '30 4 * * * PGPASSWORD=[redacted] [redacted]\n'
        '== etc_crontab ==\n'
        'SHELL=[redacted]\n'
        '# [redacted]\n'
        '#\n'
        '*/5 * * * * root ipmitool [redacted]\n'
        '17 * * * * user sqlplus [redacted]\n'
        '@reboot user /opt/bin/syncer [redacted]\n'
        '61 [redacted]\n'
        '== cron_d ==\n'
        'zz-hostile\tDB_PASS =[redacted]\n'
        'zz-hostile\t0 1 * * * user /opt/bin/sync.sh [redacted]\n'
        'zz-hostile\tbackup [redacted]\n'
        'no-tab [redacted]\n'
        '== cron_dirs ==\n'
        'daily logrotate\n'
        'weekly\n'
        'hw_timeout=absent',
      );
    });

    test('the redacted payload parses to the same schedules', () {
      const ctx = ParseContext.standard;
      final before = parseCron(cron, ctx).value;
      final after = parseCron(_redact(cron, collector: 'cron'), ctx).value;
      List<Object?> schedules(CronSnapshot s) => [
        for (final j in s.jobs)
          if (j.expression != null) (j.source, j.schedule, j.cronTz),
      ];
      expect(schedules(after), schedules(before));
      expect(schedules(after), hasLength(9));
      expect(after.ownCrontabPresent, isTrue);
      expect(
        after.dirEntries.map((e) => e.name),
        before.dirEntries.map((e) => e.name),
      );
      expect(after.jobs.map((j) => j.user).nonNulls.toSet(), {'root', 'user'});
    });

    test("a failed crontab -l keeps its diagnostic, nothing else", () {
      const failed =
          'preamble x y\n'
          '== crontab_meta ==\n'
          'rc=1\n'
          'stray words\n'
          '== crontab ==\n'
          'no crontab for anke\n'
          '0 3 * * * /usr/bin/backup --all';
      final redacted = _redact(failed, collector: 'cron');
      expect(
        redacted,
        'preamble [redacted]\n'
        '== crontab_meta ==\n'
        'rc=1\n'
        'stray [redacted]\n'
        '== crontab ==\n'
        'no crontab for anke\n'
        '0 [redacted]',
      );
      expect(
        parseCron(redacted, ParseContext.standard).value.ownCrontabPresent,
        isFalse,
      );
    });
  });

  group('review', () {
    final redactor = Redactor(
      const RedactionLiterals(
        hostNames: ['web1'],
        userNames: ['anke'],
        homeDirs: ['/home/anke'],
      ),
    );

    test('a redacted payload passes', () {
      final redacted = redactor.redact(
        'units',
        utf8.encode(
          'DB_PASSWORD=hunter2 --password=x\n'
          '$_pemBegin\nAAAA\n$_pemEnd\n'
          'web1 /home/anke anke 10.0.0.1',
        ),
      );
      expect(redactor.review(latin1.decode(redacted.bytes)), isEmpty);
    });

    test('what the rules cannot judge blocks the write', () {
      expect(
        redactor.review(
          'Description=Load the private key\n'
          'x QWxhZGRpbjpvcGVuIHNlc2FtZQ0123456789ABCDEFab\n'
          '/usr/lib/Abc0123456789012345678901234567890xyz.service\n'
          '--password=[redacted] /etc/cron.daily/passwd',
        ),
        [(1, 'mentions a private key'), (2, 'holds a long base64 run')],
      );
    });

    test('a literal or secret the rules did not reach blocks too', () {
      expect(redactor.review('web1 is up\npassword=hunter2\nhome-ANKE'), [
        (1, 'still names the host'),
        (2, 'looks like a secret'),
        (3, 'still names a user'),
      ]);
    });
  });

  group('procs argv', () {
    const head =
        '== meta ==\n'
        'total=2\n'
        'selection=all\n'
        '== rows ==\n'
        '1 S 0 1 1 1 0 100 my prog\n'
        '30 S 1 1 1 1 1000 100 sshd\n'
        '== cmdline ==\n'
        'hw_timeout=absent\n';
    const payload =
        '$head'
        '==> 1/cmdline <==\n'
        '/usr/bin/python3\x1f-c\x1fprint("a\n'
        'b")\x1f\x1f--token\x1f\n'
        '==> 2/cmdline <==\n'
        '\n'
        '==> 30/cmdline <==\n'
        'sshd: anke@pts/0\x1f';

    test('keeps argv[0] up to its first space and redacts the rest', () {
      expect(
        _redact(payload, collector: 'procs'),
        '$head'
        '==> 1/cmdline <==\n'
        '/usr/bin/python3\x1f[redacted]\x1f[redacted]\n'
        '[redacted]\x1f\x1f[redacted]\x1f\n'
        '==> 2/cmdline <==\n'
        '\n'
        '==> 30/cmdline <==\n'
        'sshd: [redacted]\x1f',
      );
    });

    test('the redacted payload parses to the same processes', () {
      const ctx = ParseContext.standard;
      final before = parseProcs(payload, ctx);
      final after = parseProcs(_redact(payload, collector: 'procs'), ctx);
      expect(after.warnings, before.warnings);
      expect(after.value.processes.map((p) => p.pid), [1, 30]);
      expect(after.value.processes.first.argv, [
        '/usr/bin/python3',
        '[redacted]',
        '[redacted]\n[redacted]',
        '',
        '[redacted]',
      ]);
    });

    test('a block header inside an argument is argument text', () {
      expect(
        _redact(
          '$head==> 1/cmdline <==\nx\x1fa\n== rows ==\n9 S 1 1 1 1 0 1 key',
          collector: 'procs',
        ),
        '$head==> 1/cmdline <==\nx\x1f[redacted]\n[redacted]\n[redacted]',
      );
    });

    test('ps fallbacks keep the command word', () {
      const rows = '== rows ==\n623 S 1 1 1 1 0 7000 sshd\n== cmdline ==\n';
      expect(
        _redact(
          '$rows== ps ==\n'
          '    PID    PPID USER     STAT   RSS COMMAND\n'
          '    623       1 root     Ss    7000 sshd: anke [priv]',
          collector: 'procs',
        ),
        '$rows== ps ==\n'
        '    PID    PPID USER     STAT   RSS COMMAND\n'
        '    623       1 root     Ss    7000 sshd: [redacted]',
      );
      expect(
        _redact(
          '$rows== ps_w ==\nhw_timeout=absent\noops\n  1 root init --x',
          collector: 'procs',
        ),
        '$rows== ps_w ==\nhw_timeout=absent\noops\n  1 [redacted]',
      );
    });

    test('other collectors keep their argv-like text', () {
      const cron = '== crontab ==\n0 3 * * * /usr/bin/backup --all\x1fx';
      expect(_redact(cron, collector: 'units'), cron);
    });
  });
}
