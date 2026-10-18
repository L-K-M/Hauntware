// Fixture rendering of the capture tool (03 §6.5): the files
// klabautermann_host's fixture test reads, SOURCE.md, the review that
// blocks a write, the platform id, the literals and the overwrite guard.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

import '../../tool/src/fixture_capture.dart';
import '../../tool/src/local_sampler.dart';
import '../../tool/src/redaction.dart';

HwsSection _section(String name, String payload, [SectionStatus? status]) =>
    HwsSection(
      name,
      status ?? SectionStatus.ok,
      Uint8List.fromList(utf8.encode(payload)),
    );

Capture _capture({
  String distro = 'ID=ubuntu\nVERSION_ID="24.04"',
  String cron = 'cron at 10.0.0.7',
  String? identity,
  String uid = '1000',
  String shell = 'dash',
}) => Capture(
  SamplerLaunch.stdinShell(shell),
  {
    for (final c in kFixtureCollectors)
      c: _section(c.wireName, switch (c) {
        Collector.cron => cron,
        Collector.identity when identity != null => identity,
        _ => '== x ==\n${c.wireName} at 10.0.0.7',
      }, c == Collector.units ? SectionStatus.error : null),
  },
  [
    _section('probe_kernel', 'Linux 6.1.0 x86_64'),
    _section('probe_distro', distro),
    _section('probe_identity', 'uid=$uid\nuser=anke\ngroups=anke sudo'),
    _section('probe_session', 'hw_timeout=absent\nssh_connection='),
  ],
);

HostProfile _profile(String distro) => _capture(distro: distro).profile;

String _text(FixtureFiles f, String name) => utf8.decode(f.files[name]!);

FixtureFiles _files(Map<String, List<int>> files) =>
    FixtureFiles(files, const {}, const []);

void main() {
  final redactor = Redactor(const RedactionLiterals());
  final at = DateTime.utc(2026, 10, 14);

  test('the fixture collectors are the tick collectors but probe and ops', () {
    expect(kFixtureCollectors.map((c) => c.wireName), [
      'overview',
      'core',
      'fs',
      'identity',
      'procs',
      'units',
      'timers',
      'cron',
    ]);
  });

  test('renders every fixture file, redacted, with a final newline', () {
    final f = renderFixtureFiles(_capture(), redactor, capturedAt: at);
    expect(f.files.keys, {
      for (final c in kFixtureCollectors) '${c.wireName}.txt',
      'probe.sections',
      'SOURCE.md',
    });
    expect(_text(f, 'procs.txt'), '== x ==\nprocs at 192.0.2.1\n');
    // cron's line is no job: it keeps its first word.
    expect(f.counts, {'IPv4 address': 7, 'cron text': 1});
    expect(f.residue, isEmpty);
  });

  test('probe.sections holds one ### block per area, marker stripped', () {
    final f = renderFixtureFiles(_capture(), redactor, capturedAt: at);
    expect(
      _text(f, 'probe.sections'),
      '### kernel ok\nLinux 6.1.0 x86_64\n'
      '### distro ok\nID=ubuntu\nVERSION_ID="24.04"\n'
      '### identity ok\nuid=1000\nuser=anke\ngroups=anke sudo\n'
      '### session ok\nssh_connection=\n',
    );
  });

  test('a probe line that reads as a block header is refused', () {
    expect(
      () => renderFixtureFiles(
        _capture(distro: 'ID=x\n### kernel ok'),
        redactor,
        capturedAt: at,
      ),
      throwsA(isA<CaptureFailure>()),
    );
  });

  test('SOURCE.md records the launch, statuses and redaction', () {
    final source = _text(
      renderFixtureFiles(_capture(), redactor, capturedAt: at),
      'SOURCE.md',
    );
    expect(source, contains('Captured on 2026-10-14'));
    expect(source, contains('`dash -s`'));
    expect(source, contains('| `units` | error |'));
    expect(source, contains('| `overview` | ok |'));
    expect(
      source,
      contains('Probe areas: kernel ok, distro ok, identity ok, session ok.'),
    );
    expect(
      source,
      contains('Redaction (03 §6.5): IPv4 address 7, cron text 1.'),
    );
  });

  test('a line the review flags is reported, with file and line', () {
    final f = renderFixtureFiles(
      _capture(identity: '== x ==\nbackup # its private key'),
      Redactor(const RedactionLiterals(userNames: ['anke'])),
      capturedAt: at,
    );
    expect(f.residue.map((r) => '$r'), [
      'identity.txt:2: mentions a private key',
    ]);
    expect(_text(f, 'probe.sections'), contains('user=user\ngroups=user sudo'));
  });

  test('a fixture that parses differently from its capture is refused', () {
    // A user named rc turns `rc=0` into `user=0`: no crontab, no job.
    final f = renderFixtureFiles(
      _capture(
        cron:
            '== crontab_meta ==\nrc=0\n== crontab ==\n0 1 * * * /usr/bin/x\n'
            '== etc_crontab ==\n== cron_d ==\n== cron_dirs ==',
      ),
      Redactor(const RedactionLiterals(userNames: ['rc'])),
      capturedAt: at,
    );
    expect(f.residue.map((r) => '$r'), [
      'cron.txt: parses differently: result.jobs: 1 entries, then 0',
      'jobs: mergeJobs over cron.txt and timers.txt parses differently: '
          '[]: 1 entries, then 0',
    ]);
    expect(
      parseShapeChange(Collector.cron, 'rc=0', 'rc=0 # x'),
      isNull,
      reason: 'text may differ',
    );
  });

  test('every committed fixture renders without residue', () {
    final root = [
      '../klabautermann_host/test/fixtures',
      'packages/klabautermann_host/test/fixtures',
    ].firstWhere((p) => Directory(p).existsSync());
    final platforms = Directory(root).listSync().whereType<Directory>();
    expect(platforms, hasLength(greaterThanOrEqualTo(6)));
    for (final dir in platforms) {
      String read(String name) => File('${dir.path}/$name').readAsStringSync();
      final probe = <HwsSection>[];
      for (final block in read(
        'probe.sections',
      ).split(RegExp('^### ', multiLine: true)).skip(1)) {
        final nl = block.indexOf('\n');
        final [area, status] = block.substring(0, nl).split(' ');
        probe.add(
          _section(
            '$kProbeSectionPrefix$area',
            block.substring(nl + 1).replaceFirst(RegExp(r'\n$'), ''),
            SectionStatus.values.byName(status),
          ),
        );
      }
      final capture = Capture(SamplerLaunch.stdinShell('sh'), {
        for (final c in kFixtureCollectors)
          c: _section(
            c.wireName,
            read('${c.wireName}.txt').replaceFirst(RegExp(r'\n$'), ''),
          ),
      }, probe);
      final profile = capture.profile;
      final f = renderFixtureFiles(
        capture,
        Redactor(
          captureLiterals(
            profile,
            hostNames: capture.hostNames,
            home: '/home/${profile.user}',
            passwd: '',
            keep: capture.formatWords,
          ),
        ),
        capturedAt: at,
      );
      expect(f.residue.map((r) => '$r'), isEmpty, reason: dir.path);
    }
  });

  test('SOURCE.md and probe.sections are redacted and reviewed too', () {
    final f = renderFixtureFiles(
      _capture(
        shell: '/home/anke/bin/dash',
        distro: 'ID=ubuntu\nVERSION_ID=1\nPRETTY_NAME="Load the private key"',
      ),
      Redactor(const RedactionLiterals(homeDirs: ['/home/anke'])),
      capturedAt: at,
    );
    expect(_text(f, 'SOURCE.md'), contains('`/home/user/bin/dash -s`'));
    expect(f.residue.map((r) => '${r.file} ${r.reason}'), [
      'probe.sections mentions a private key',
      'SOURCE.md mentions a private key',
    ]);
  });

  test('platform id from os-release, as the fixture directories name it', () {
    for (final (distro, id) in [
      ('ID=ubuntu\nVERSION_ID="24.04"', 'ubuntu-2404'),
      ('ID=debian\nVERSION_ID="12"', 'debian-12'),
      ('ID="rhel"\nID_LIKE="fedora"\nVERSION_ID="8.10"', 'rhel-8'),
      ('ID="rocky"\nID_LIKE="rhel centos fedora"\nVERSION_ID="9.4"', 'rocky-9'),
      ('ID=alpine\nVERSION_ID=3.22.1', 'alpine-322'),
      ('ID=arch', null),
      ('ID=../x\nVERSION_ID=1', null),
    ]) {
      expect(platformIdFor(_profile(distro)), id, reason: distro);
    }
    expect(isPlatformId('debian-12-lxc'), isTrue);
    expect(isPlatformId('../x'), isFalse);
  });

  test('literals: host names, personal accounts, no generic names', () {
    final literals = captureLiterals(
      _profile('ID=ubuntu\nVERSION_ID="24.04"'),
      hostNames: ['web1.corp.example.org', 'localhost', 'ubuntu'],
      home: '/home/anke',
      passwd:
          'root:x:0:0:root:/root:/bin/bash\n'
          'ubuntu:x:1001:1001::/home/ubuntu:/bin/sh\n'
          'bob:x:1002:1002:Bob,,,:/srv/bob:/bin/bash\n'
          'carol:x:70000:70000::/home/carol:/bin/bash\n'
          'snap_daemon:x:584788:584788::/nonexistent:/usr/bin/false\n'
          'nobody:x:65534:65534::/nonexistent:/usr/sbin/nologin\n'
          'nfsnobody:x:4294967294:4294967294::/var/lib/nfs:/sbin/nologin\n'
          'broken line\n',
      extra: ['nas07'],
    );
    expect(literals.hostNames, ['web1.corp.example.org', 'web1']);
    // Above UID_MAX too, as for the capturing user; no account whose
    // home is Debian's /nonexistent for system accounts.
    expect(literals.userNames, ['anke', 'bob', 'carol']);
    expect(literals.homeDirs, ['/home/anke', '/srv/bob', '/home/carol']);
    expect(literals.extra, ['nas07']);
  });

  test('literals: no word the probe or hostnamectl prints', () {
    // A host or user named like a probe key, its kernel, virtualization,
    // a probed tool, its time zone or chassis would rewrite those fields
    // (the third verification's docker, kvm, linux, berlin, vm and rc).
    final capture = Capture(
      SamplerLaunch.stdinShell('dash'),
      {
        Collector.identity: _section(
          'identity',
          '== hostnamectl ==\n{"Chassis":"vm"}',
        ),
      },
      [
        _section('probe_kernel', 'Linux 6.1.0-25-web1 x86_64'),
        _section('probe_distro', 'ID=debian\nVERSION_ID=12'),
        _section('probe_init', 'pid1_comm=systemd'),
        _section(
          'probe_virt',
          'virt_rc=0\nvirt=kvm\ncontainer_rc=0\ncontainer=lxc',
        ),
        _section('probe_tools', 'docker=/usr/bin/docker\npodman='),
        _section('probe_clock', 'Timezone=America/New_York'),
      ],
    );
    final literals = captureLiterals(
      capture.profile,
      hostNames: [
        'docker',
        'kvm',
        'lxc',
        'linux',
        'x86_64',
        'podman',
        'york',
        'systemd',
        'vm',
        'container',
        'web1',
      ],
      home: '/',
      passwd: 'rc:x:1000:1000::/home/rc:/bin/sh\n',
      keep: capture.formatWords,
    );
    // The kernel release is free text, which can hold the host's name.
    expect(literals.hostNames, ['web1']);
    expect(literals.userNames, isEmpty);
  });

  test('literals: no host name that is an address', () {
    // Its labels would match numbers anywhere (`*/10` for 10.0.0.5);
    // the address rules replace the address itself.
    final literals = captureLiterals(
      _profile('ID=ubuntu\nVERSION_ID="24.04"'),
      hostNames: ['10.0.0.5', 'fd00::5', 'web1.lan'],
      home: '/',
      passwd: '',
    );
    expect(literals.hostNames, ['web1.lan', 'web1']);
    expect(literals.domains, isEmpty);
  });

  test('literals: personal accounts from login.defs UID_MIN', () {
    final literals = captureLiterals(
      _capture(uid: '500').profile,
      hostNames: const [],
      home: '/home/anke',
      passwd:
          'jsmith:x:600:600::/home/jsmith:/bin/bash\n'
          'sys:x:499:499::/var/sys:/bin/false\n',
      loginDefs: '# UID_MIN 2000\nUID_MIN\t\t\t  500\nUID_MAX 60000\n',
    );
    expect(literals.userNames, ['anke', 'jsmith']);
  });

  test('literals: the domains of the host names and the search list', () {
    final literals = captureLiterals(
      _profile('ID=ubuntu\nVERSION_ID="24.04"'),
      hostNames: ['web-01.corp.acme.io', 'web-01', 'web-01.lan'],
      home: '/',
      passwd: '',
      searchDomains: ['corp.acme.io', 'lan', 'eu-central-1.compute.internal.'],
    );
    expect(literals.hostNames, ['web-01.corp.acme.io', 'web-01', 'web-01.lan']);
    // Two labels or more: a lone `lan` would match the word anywhere.
    expect(literals.domains, [
      'corp.acme.io',
      'acme.io',
      'eu-central-1.compute.internal',
      'compute.internal',
    ]);
  });

  test('the domains of a resolv.conf', () {
    expect(
      resolvDomains(
        '# search commented.example\n'
        'nameserver 10.0.0.2\n'
        'search corp.acme.io  eu-central-1.compute.internal\n'
        'domain corp.acme.io\n'
        'options edns0',
      ),
      ['corp.acme.io', 'eu-central-1.compute.internal', 'corp.acme.io'],
    );
  });

  test('the capturing user at any uid but a system one', () {
    // sssd's idmap range, systemd-homed, a system account, nobody.
    for (final (uid, users) in [
      ('1876001104', ['anke']),
      ('60100', ['anke']),
      ('999', <String>[]),
      ('65534', <String>[]),
    ]) {
      final literals = captureLiterals(
        _capture(uid: uid).profile,
        hostNames: const [],
        home: '/home/anke',
        passwd: '',
      );
      expect(literals.userNames, users, reason: uid);
      expect(literals.homeDirs, [if (users.isNotEmpty) '/home/anke']);
    }
    // A HOME of /root names no account.
    expect(
      captureLiterals(
        _capture().profile,
        hostNames: const [],
        home: '/root',
        passwd: '',
      ).homeDirs,
      isEmpty,
    );
  });

  test('host names from hostnamectl in the identity section', () {
    expect(
      _capture(
        identity:
            '== hostnamectl ==\n'
            '{"Hostname":"web1","StaticHostname":"web1.corp.example.org",'
            '"PrettyHostname":"Web 1","DefaultHostname":"localhost"}',
      ).hostNames,
      ['web1', 'web1.corp.example.org'],
    );
    expect(_capture().hostNames, isEmpty);
  });

  test('an existing platform directory needs replace, which empties it', () {
    final root = Directory.systemTemp.createTempSync('klab-fixtures-');
    addTearDown(() => root.deleteSync(recursive: true));
    final dir = Directory('${root.path}/p');
    expect(
      writeFixtureDir(
        dir,
        _files({
          'a.txt': [0x61],
          'old.txt': [0x6f],
          'a.golden.json': [0x7b, 0x7d],
        }),
        replace: false,
      ),
      isEmpty,
    );
    expect(
      () => writeFixtureDir(
        dir,
        _files({
          'a.txt': [0x62],
        }),
        replace: false,
      ),
      throwsA(isA<CaptureFailure>()),
    );
    expect(
      writeFixtureDir(
        dir,
        _files({
          'a.txt': [0x62],
        }),
        replace: true,
      ),
      ['old.txt'],
    );
    expect(dir.listSync().map((e) => e.uri.pathSegments.last), ['a.txt']);
    expect(File('${dir.path}/a.txt').readAsStringSync(), 'b');
  });

  test('residue writes nothing, not even with replace', () {
    final root = Directory.systemTemp.createTempSync('klab-fixtures-');
    addTearDown(() => root.deleteSync(recursive: true));
    final flagged = renderFixtureFiles(
      _capture(identity: 'Description=Load the private key'),
      redactor,
      capturedAt: at,
    );
    expect(flagged.residue, isNotEmpty);

    final fresh = Directory('${root.path}/fresh');
    expect(
      () => writeFixtureDir(fresh, flagged, replace: false),
      throwsA(isA<CaptureFailure>()),
    );
    expect(fresh.existsSync(), isFalse);

    final kept = Directory('${root.path}/kept')..createSync();
    File('${kept.path}/core.txt').writeAsStringSync('old');
    expect(
      () => writeFixtureDir(kept, flagged, replace: true),
      throwsA(isA<CaptureFailure>()),
    );
    expect(File('${kept.path}/core.txt').readAsStringSync(), 'old');
  });
}
