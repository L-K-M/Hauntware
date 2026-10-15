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
      hostNames: ['vm', 'web1.corp.example.org', 'web1'],
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

    test('a home directory goes before the user name', () {
      expect(
        _redact('/srv/anke-home/bin', literals: literals),
        '/home/user/bin',
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
        _redact('10.1.2.3 127.0.0.1 0.0.0.0 1.2.3 256.1.1.1 5.15.0.1-x'),
        '192.0.2.1 127.0.0.1 0.0.0.0 1.2.3 256.1.1.1 192.0.2.1-x',
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
        'fixture-nas:/home/anke     fuse.sshfs 1 1 0 100% /mnt/box\n'
        '192.0.2.1:/export        nfs 1 1 0 100% /mnt/x\n'
        '/dev/sda1               ext4 1 1 0 100% /',
      );
      // Elsewhere `<word>:/` is no mount source.
      const cpe = '"OperatingSystemCPEName":"cpe:/o:canonical:ubuntu_linux"';
      expect(_redact(cpe), cpe);
    });

    test('counts replacements per rule and keeps other bytes', () {
      final payload = [...latin1.encode('a 10.0.0.1 10.0.0.2 '), 0xff, 0x0a];
      final r = Redactor(const RedactionLiterals()).redact('fs', payload);
      expect(r.counts, {'IPv4 address': 2});
      expect(r.bytes, [...latin1.encode('a 192.0.2.1 192.0.2.1 '), 0xff, 0x0a]);
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
      ).redact('cron', utf8.encode(cron));
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

    test('a private-key header without its end becomes a placeholder', () {
      expect(
        _redact('$_pemBegin\nb3Blbg', collector: 'cron'),
        '[redacted]\nb3Blbg',
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
        'cron',
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
          'ExecStart=/usr/bin/agent --token abc123\n'
          'Description=Load the private key\n'
          'x QWxhZGRpbjpvcGVuIHNlc2FtZQ0123456789ABCDEFab\n'
          '/usr/lib/Abc0123456789012345678901234567890xyz.service\n'
          '--password=[redacted] /etc/cron.daily/passwd',
        ),
        [
          (1, 'passes a secret option'),
          (2, 'mentions a private key'),
          (3, 'holds a long base64 run'),
        ],
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
      expect(_redact(cron, collector: 'cron'), cron);
    });
  });
}
