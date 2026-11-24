// DKR-9: driver options cross masked (03 §8.9), as labels and env do.
import 'package:klabautermann_core/src/docker/inspect_masking.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

const _mask = MaskedValue.maskToken;

void main() {
  test("an inspected container's log driver options cross masked, the "
      'rest of its host configuration as it is', () {
    final details = maskContainerInspect(
      const ContainerInspect(
        id: 'c1',
        hostConfig: ContainerHostConfig(
          networkMode: 'bridge',
          restartPolicy: ContainerRestartPolicy(name: 'always'),
          logConfig: LogConfig(
            type: 'splunk',
            config: {
              'splunk-token': 'hunter2',
              'splunk-url': 'https://splunk:8088',
              'loki-url': 'https://me:hunter2@loki/api',
              'max-size': '10m',
            },
          ),
          privileged: true,
          readonlyRootfs: true,
          binds: ['/a:/b'],
          memory: 1,
          nanoCpus: 2,
          pidMode: 'host',
          autoRemove: true,
          capAdd: ['NET_ADMIN'],
        ),
      ),
    );

    final host = details.hostConfig!;
    expect(host.logConfig!.type, 'splunk');
    expect(host.logConfig!.config, {
      'splunk-token': _mask,
      'splunk-url': 'https://splunk:8088',
      'loki-url': 'https://me:$_mask@loki/api',
      'max-size': '10m',
    });
    expect(host.networkMode, 'bridge');
    expect(host.restartPolicy!.name, 'always');
    expect(host.privileged, isTrue);
    expect(host.readonlyRootfs, isTrue);
    expect(host.binds, ['/a:/b']);
    expect(host.memory, 1);
    expect(host.nanoCpus, 2);
    expect(host.pidMode, 'host');
    expect(host.autoRemove, isTrue);
    expect(host.capAdd, ['NET_ADMIN']);

    expect(
      maskContainerInspect(const ContainerInspect(id: 'c2')).hostConfig,
      isNull,
    );
  });

  test("a volume's driver options are masked: a secret key, a secret "
      'sub-key of a mount option list, URL credentials', () {
    final plain = VolumeSummary(
      name: 'plain',
      labels: maskedLabels({'a': 'b'}),
    );
    final masked = maskVolumeOptions([
      plain,
      const VolumeSummary(
        name: 'share',
        driver: 'local',
        mountpoint: '/m',
        scope: 'local',
        options: {
          'type': 'cifs',
          'device': '//nas/share',
          'o': 'addr=nas,username=me,password=hun,ter2,vers=3.0',
          'token': 'abc',
          'url': 'nfs://me:hunter2@nas/x',
        },
      ),
    ]);

    expect(masked[0], same(plain));
    expect(masked[1].name, 'share');
    expect(masked[1].driver, 'local');
    expect(masked[1].mountpoint, '/m');
    expect(masked[1].scope, 'local');
    expect(masked[1].options, {
      'type': 'cifs',
      'device': '//nas/share',
      'o': 'addr=nas,username=me,password=$_mask',
      'token': _mask,
      'url': 'nfs://me:$_mask@nas/x',
    });
    expect('${masked[1].options}', isNot(contains('ter2')));
  });
}
