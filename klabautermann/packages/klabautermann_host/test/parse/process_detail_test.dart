// PRC-04 and PRC-05's process read: the status counters, limits, open
// descriptors and environment, sections the user may not read, and the
// unit and container a process's cgroups name.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _read = '''
== cwd
/srv/app
== status
VmSwap:	      12 kB
Threads:	9
voluntary_ctxt_switches:	120
nonvoluntary_ctxt_switches:	4
== cgroup
0::/system.slice/nginx.service
== limits
Limit                     Soft Limit           Hard Limit           Units
Max processes             64280                64280                processes
Max open files            1024                 unlimited            files
== fds
37
== environ
PATH=/usr/bin
API_TOKEN=s3cret
== status
''';

void main() {
  test('reads each section; the environment runs to the end, so a marker '
      'inside it stays a value', () {
    final detail = parseProcessDetail(_read)!;
    expect(detail.cwd, '/srv/app');
    expect(detail.threads, 9);
    expect(detail.swapKb, 12);
    expect((detail.voluntarySwitches, detail.involuntarySwitches), (120, 4));
    expect(detail.attribution.unit, 'nginx.service');
    expect(detail.openFilesLimit?.soft, 1024);
    expect(detail.openFilesLimit?.hard, isNull);
    expect(detail.processesLimit?.hard, 64280);
    expect(detail.openFiles, 37);
    expect(detail.environment, [
      'PATH=/usr/bin',
      'API_TOKEN=s3cret',
      '== status',
    ]);
  });

  test("a value's newlines, printed as \\x01, come back in its one entry", () {
    final head = _read.substring(0, _read.indexOf('== environ'));
    final detail = parseProcessDetail(
      '$head== environ\nKEY=a\x01YWJj==\x01b\nPATH=/bin\n',
    )!;
    expect(detail.environment, ['KEY=a\nYWJj==\nb', 'PATH=/bin']);
  });

  test('sections the user may not read are denied, not empty', () {
    final detail = parseProcessDetail('''
== cwd
$kProcessDetailDenied
== status
Threads:	1
== cgroup
0::/
== limits
== fds
$kProcessDetailDenied
== environ
$kProcessDetailDenied
''')!;
    expect((detail.cwd, detail.cwdDenied), (null, true));
    expect((detail.openFiles, detail.openFilesDenied), (null, true));
    expect((detail.environment, detail.environmentDenied), (null, true));
    expect(detail.openFilesLimit, isNull);
    expect(parseProcessDetail('sh: 1: readlink: not found\n'), isNull);
  });

  group('attribution (PRC-05)', () {
    ProcessAttribution of(List<String> lines) => attributionFromCgroup(lines);
    final id = 'a' * 64;

    test('a systemd unit, the innermost one under a user manager', () {
      expect(of(['0::/system.slice/sshd.service']).unit, 'sshd.service');
      expect(
        of([
          '0::/user.slice/user-1000.slice/user@1000.service/app.slice/'
              'app-firefox.scope',
        ]).unit,
        'app-firefox.scope',
      );
      expect(of(['0::/init.scope']).unit, 'init.scope');
    });

    test('a container under systemd or cgroupfs, by runtime', () {
      final docker = of(['0::/system.slice/docker-$id.scope']);
      expect(
        (docker.containerId, docker.runtime),
        (id, ContainerRuntime.docker),
      );
      expect(docker.unit, isNull);
      expect(
        of(['0::/machine.slice/libpod-$id.scope/container']).runtime,
        ContainerRuntime.podman,
      );
      final cgroupfs = of(['12:memory:/docker/$id', '0::/docker/$id']);
      expect(cgroupfs.containerId, id);
      final kube = of(['0::/kubepods/burstable/pod1234/$id']);
      expect((kube.containerId, kube.runtime), (id, null));
    });

    test('cgroup v1 reads the name=systemd hierarchy, and nothing names '
        'nothing', () {
      expect(
        of(['1:name=systemd:/system.slice/cron.service', '0::/']).unit,
        'cron.service',
      );
      final none = of(['0::/']);
      expect((none.unit, none.containerId), (null, null));
    });
  });
}
