import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/ui/system_view.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

final _l10n = AppLocalizationsEn();

HostProfile _profile(String virt, String container, [List<String>? lxcfs]) =>
    HostProfile(virtualization: virt, container: container, lxcfsMounts: lxcfs);

void main() {
  group('withholdsHostFigure (SYS-04, D50)', () {
    const uptime = SystemWideProcFile.uptime;

    test('withholds every system-wide file in a container without lxcfs', () {
      final profile = _profile('lxc', 'lxc', const []);
      for (final file in SystemWideProcFile.values) {
        expect(withholdsHostFigure(profile, file), isTrue, reason: file.path);
      }
    });

    test('shows what lxcfs serves as the container\'s own, not stat', () {
      final profile = _profile('lxc', 'lxc', const ['/proc/uptime']);
      expect(withholdsHostFigure(profile, uptime), isFalse);
      expect(withholdsHostFigure(profile, SystemWideProcFile.stat), isTrue);
    });

    test('keeps figures outside containers and while the question is '
        'open', () {
      final vm = _profile('kvm', 'none', const []);
      expect(withholdsHostFigure(vm, uptime), isFalse);
      expect(withholdsHostFigure(null, uptime), isFalse);
      expect(withholdsHostFigure(HostProfile(), uptime), isFalse);
    });
  });

  group('virtualizationText (SYS-01)', () {
    String? text(HostProfile? profile) => virtualizationText(_l10n, profile);

    test('names a container ahead of its machine', () {
      expect(text(_profile('lxc', 'lxc')), 'Container (lxc)');
      expect(inContainer(_profile('lxc', 'lxc')), isTrue);
    });

    test('takes an lxcfs mount for a container where the tool said none', () {
      final profile = _profile('none', 'none', const ['/proc/meminfo']);
      expect(text(profile), 'Container');
      expect(inContainer(profile), isTrue);
    });

    test('names a virtual machine and bare metal', () {
      expect(text(_profile('kvm', 'none')), 'Virtual machine (kvm)');
      expect(text(_profile('none', 'none')), 'None detected');
      expect(inContainer(_profile('kvm', 'none')), isFalse);
    });

    test('stays unknown without a probe answer or the tool', () {
      expect(text(null), isNull);
      expect(text(HostProfile()), isNull);
      expect(inContainer(null), isFalse);
    });
  });

  test('networkTotals sums every interface and keeps unknown apart from '
      'no interface (NET-01)', () {
    expect(
      networkTotals({
        'eth0': const NetRate(rxBytesPerSecond: 1000, txBytesPerSecond: 10),
        'eth1': const NetRate(rxBytesPerSecond: 24, txBytesPerSecond: 5),
      }),
      (rx: 1024.0, tx: 15.0),
    );
    expect(networkTotals(null), isNull);
    expect(networkTotals(const {}), (rx: 0.0, tx: 0.0));
  });

  test('uptimeText words the two largest parts, rounding down '
      '(BOOT-01)', () {
    String text(int days, int hours, int minutes, [int seconds = 0]) =>
        uptimeText(
          _l10n,
          Duration(
            days: days,
            hours: hours,
            minutes: minutes,
            seconds: seconds,
          ),
        );

    expect(text(12, 3, 59), '12 days, 3 hours');
    expect(text(1, 0, 0), '1 day, 0 hours');
    expect(text(0, 1, 1), '1 hour, 1 minute');
    expect(text(0, 23, 59, 59), '23 hours, 59 minutes');
    expect(text(0, 0, 7, 59), '7 minutes');
    expect(text(0, 0, 0, 30), 'Less than a minute');
  });

  test('shownMounts hides pseudo filesystems by type unless asked', () {
    final fs = FsSnapshot(const [
      FsMount(device: '/dev/sda1', type: 'ext4', mountPoint: '/'),
      FsMount(device: 'tmpfs', type: 'tmpfs', mountPoint: '/run'),
      // A device name that looks pseudo on a real filesystem stays.
      FsMount(device: 'tmpfs', type: 'xfs', mountPoint: '/data'),
      FsMount(device: 'overlay', type: 'overlay', mountPoint: '/var/lib/x'),
    ]);

    expect(
      [for (final m in shownMounts(fs, showPseudo: false)) m.mountPoint],
      ['/', '/data'],
    );
    expect(shownMounts(fs, showPseudo: true), hasLength(4));
  });

  test('CN-17 words the clock skew; within two seconds is in step', () {
    expect(clockSkewText(_l10n, null), isNull);
    expect(
      clockSkewText(_l10n, const Duration(milliseconds: -1900)),
      'In step with this device',
    );
    expect(
      clockSkewText(_l10n, const Duration(seconds: 3)),
      '3 seconds ahead of this device',
    );
    expect(
      clockSkewText(_l10n, const Duration(minutes: -5, seconds: -10)),
      '5 minutes behind this device',
    );
    expect(
      clockSkewText(_l10n, const Duration(hours: 3)),
      '3 hours ahead of this device',
    );
  });

  test('SYS-02 words the time sync, unknown where timedatectl did not say', () {
    expect(timeSyncText(_l10n, null), isNull);
    expect(timeSyncText(_l10n, HostProfile()), isNull);
    expect(
      timeSyncText(_l10n, HostProfile(ntpEnabled: true, ntpSynchronized: true)),
      'Synchronized',
    );
    expect(
      timeSyncText(
        _l10n,
        HostProfile(ntpEnabled: true, ntpSynchronized: false),
      ),
      'Not synchronized',
    );
    expect(
      timeSyncText(
        _l10n,
        HostProfile(ntpEnabled: false, ntpSynchronized: false),
      ),
      'Off',
    );
    // A clock the kernel still calls synchronized reads so even with
    // timedated's NTP unit off: another daemon may keep it, and the flag
    // lapses within hours once nothing does.
    expect(
      timeSyncText(
        _l10n,
        HostProfile(ntpEnabled: false, ntpSynchronized: true),
      ),
      'Synchronized',
    );
  });
}
