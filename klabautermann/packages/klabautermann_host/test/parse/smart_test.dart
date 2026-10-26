import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

String _ata({
  bool passed = true,
  int exit = 0,
  int reallocated = 0,
  int pending = 0,
}) => jsonEncode({
  'smartctl': {'exit_status': exit},
  'device': {'name': '/dev/sda', 'type': 'sat'},
  'model_name': 'Samsung SSD 860 EVO 500GB',
  'smart_status': {'passed': passed},
  'ata_smart_attributes': {
    'table': [
      {
        'id': 5,
        'name': 'Reallocated_Sector_Ct',
        'raw': {'value': reallocated},
      },
      {
        'id': 9,
        'name': 'Power_On_Hours',
        'raw': {'value': 12345},
      },
      {
        'id': 197,
        'name': 'Current_Pending_Sector',
        'raw': {'value': pending},
      },
    ],
  },
  'power_on_time': {'hours': 12345},
  'temperature': {'current': 33},
});

String _nvme({int percentageUsed = 3, int criticalWarning = 0}) => jsonEncode({
  'smartctl': {'exit_status': 0},
  'device': {'name': '/dev/nvme0', 'type': 'nvme'},
  'model_name': 'WD Blue SN570 1TB',
  'smart_status': {'passed': true},
  'nvme_smart_health_information_log': {
    'critical_warning': criticalWarning,
    'temperature': 38,
    'percentage_used': percentageUsed,
    'power_on_hours': 1000,
  },
});

/// HW-04: smartctl's JSON.
void main() {
  test('the scan lists each drive with its device type', () {
    final scan = parseSmartScan(
      jsonEncode({
        'devices': [
          {'name': '/dev/sda', 'info_name': '/dev/sda [SAT]', 'type': 'sat'},
          {'name': '/dev/nvme0', 'type': 'nvme'},
          {'name': '/dev/bus/0', 'type': 'megaraid,1'},
          {'info_name': 'no name'},
        ],
      }),
    );
    expect(
      [for (final e in scan!) (e.device, e.type)],
      [
        ('/dev/sda', 'sat'),
        ('/dev/nvme0', 'nvme'),
        ('/dev/bus/0', 'megaraid,1'),
      ],
    );
    expect(parseSmartScan('smartctl: command not found'), isNull);
  });

  test('a healthy ATA drive passes with its model, temperature, hours and '
      'no bad sectors', () {
    final disk = parseSmartDisk(_ata(), device: '/dev/sda');
    expect(disk.verdict, SmartVerdict.passed);
    expect(disk.model, 'Samsung SSD 860 EVO 500GB');
    expect(disk.celsius, 33);
    expect(disk.powerOnHours, 12345);
    expect(disk.badSectors, 0);
    expect(disk.percentageUsed, isNull);
  });

  test('bad sectors, a prefailure attribute or failed self-tests warn; a '
      'failed assessment fails', () {
    expect(
      parseSmartDisk(_ata(reallocated: 8, pending: 2), device: 'x').verdict,
      SmartVerdict.warning,
    );
    expect(
      parseSmartDisk(_ata(reallocated: 8, pending: 2), device: 'x').badSectors,
      10,
    );
    expect(
      parseSmartDisk(_ata(exit: 16), device: 'x').verdict,
      SmartVerdict.warning,
    );
    expect(
      parseSmartDisk(_ata(exit: 128), device: 'x').verdict,
      SmartVerdict.warning,
    );
    // The error log alone (bit 6) is too common to warn on.
    expect(
      parseSmartDisk(_ata(exit: 64), device: 'x').verdict,
      SmartVerdict.passed,
    );
    expect(
      parseSmartDisk(_ata(passed: false, exit: 8), device: 'x').verdict,
      SmartVerdict.failing,
    );
  });

  test('an NVMe drive reports wear and its log\'s temperature and hours; '
      'a critical warning or used-up endurance warns', () {
    final disk = parseSmartDisk(_nvme(), device: '/dev/nvme0');
    expect(disk.verdict, SmartVerdict.passed);
    expect(disk.percentageUsed, 3);
    expect(disk.celsius, 38);
    expect(disk.powerOnHours, 1000);
    expect(disk.badSectors, isNull);

    expect(
      parseSmartDisk(_nvme(criticalWarning: 4), device: 'x').verdict,
      SmartVerdict.warning,
    );
    expect(
      parseSmartDisk(_nvme(percentageUsed: 104), device: 'x').verdict,
      SmartVerdict.warning,
    );
  });

  test('a spun-down drive is asleep; anything else unreadable is unknown', () {
    final asleep = jsonEncode({
      'smartctl': {
        'exit_status': 2,
        'messages': [
          {
            'string': 'Device is in STANDBY mode, exit(2)',
            'severity': 'information',
          },
        ],
      },
      'device': {'name': '/dev/sdb', 'type': 'sat'},
    });
    expect(
      parseSmartDisk(asleep, device: '/dev/sdb').verdict,
      SmartVerdict.asleep,
    );

    final openFailed = jsonEncode({
      'smartctl': {
        'exit_status': 2,
        'messages': [
          {'string': 'Smartctl open device: /dev/sdc failed: No such device'},
        ],
      },
    });
    expect(
      parseSmartDisk(openFailed, device: 'x').verdict,
      SmartVerdict.unknown,
    );
    expect(
      parseSmartDisk('garbage', device: 'x').verdict,
      SmartVerdict.unknown,
    );
  });

  test('the read command takes only a device node and a smartctl type', () {
    expect(HostCommands.smartRead('/dev/sda', 'sat'), [
      'smartctl',
      '-n',
      'standby',
      '-a',
      '-j',
      '-d',
      'sat',
      '/dev/sda',
    ]);
    expect(
      HostCommands.smartRead('/dev/bus/0', 'sat+megaraid,1').last,
      '/dev/bus/0',
    );
    for (final (device, type) in [
      ('/etc/shadow', 'sat'),
      ('/dev/../etc/shadow', 'sat'),
      ('/dev/sda', '--all'),
      ('/dev/sda;rm', 'sat'),
      ('/dev/sda', 'sat x'),
    ]) {
      expect(
        () => HostCommands.smartRead(device, type),
        throwsA(isA<HostCommandError>()),
        reason: '$device $type',
      );
    }
  });
}
