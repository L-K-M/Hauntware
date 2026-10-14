// Panel capability declaration tests (03 §6.1, §10.4; LOG-03, LOG-22):
// a panel works when one of its alternatives is fully met, is unknown
// while an answer is outstanding, and is missing only on a known lack.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

import 'support.dart';

const _ok = AccessStatus.ok;
const _missing = AccessStatus.missing;
const _unknown = AccessStatus.unknown;

Map<HostPanel, AccessStatus> _statuses(HostProfile p) => {
  for (final a in evaluatePanels(p, evaluateAccess(p))) a.panel: a.status,
};

PanelAvailability _panel(HostPanel panel, HostProfile p) =>
    evaluatePanel(panel, p, evaluateAccess(p));

/// Every panel starts out working; each table entry overrides some.
Map<HostPanel, AccessStatus> _allOk(Map<HostPanel, AccessStatus> changes) => {
  for (final panel in HostPanel.values) panel: changes[panel] ?? _ok,
};

final _tables = <String, Map<HostPanel, AccessStatus>>{
  // The kernel log has no journal access and no probed dmesg yet; the
  // fixtures predate the tail entry, so the file tail is unknown too.
  'debian-12': _allOk({
    HostPanel.kernelLog: _unknown,
    HostPanel.fileTail: _unknown,
  }),
  'ubuntu-2404': _allOk({HostPanel.fileTail: _unknown}),
  'rhel-8': _allOk({HostPanel.fileTail: _unknown}),
  // OpenRC, no journal: the systemd panels are missing, and the kernel
  // log waits for the dmesg answer.
  'alpine-322': _allOk({
    HostPanel.services: _missing,
    HostPanel.unitLogs: _missing,
    HostPanel.journal: _missing,
    HostPanel.kernelLog: _unknown,
    HostPanel.fileTail: _unknown,
  }),
};

void main() {
  test('every panel declares its needs', () {
    expect(kPanelNeeds.keys, unorderedEquals(HostPanel.values));
    for (final MapEntry(key: panel, value: alternatives)
        in kPanelNeeds.entries) {
      expect(alternatives, isNotEmpty, reason: panel.name);
    }
    expect(kPanelNeeds[HostPanel.kernelLog], [
      [Capability.journalctl, Capability.journalAccess],
      [Capability.dmesg],
    ]);
    expect(kPanelNeeds[HostPanel.fileTail], [
      [Capability.tail],
    ]);
  });

  group('platform tables', () {
    for (final platform in fixturePlatforms) {
      test(platform, () {
        expect(_statuses(fixtureProfile(platform)), _tables[platform]);
      });
    }
  });

  test('a profile without answers shows nothing as missing', () {
    final statuses = _statuses(HostProfile());
    for (final MapEntry(key: panel, value: status) in statuses.entries) {
      final needsNothing = kPanelNeeds[panel]!.any((a) => a.isEmpty);
      expect(status, needsNothing ? _ok : _unknown, reason: panel.name);
    }
  });

  group('kernel log (LOG-03)', () {
    test('prefers journalctl -k with journal access', () {
      final a = _panel(HostPanel.kernelLog, host(groups: const ['adm']));
      expect(a.status, _ok);
      expect(a.route, [Capability.journalctl, Capability.journalAccess]);
      expect(a.blocking, isEmpty);
    });

    test('falls back to dmesg without journal access', () {
      final a = _panel(HostPanel.kernelLog, host());
      expect(a.status, _ok);
      expect(a.route, [Capability.dmesg]);
    });

    test('names the journal fix when neither route works', () {
      final a = _panel(
        HostPanel.kernelLog,
        host(tools: const {'journalctl': '/usr/bin/journalctl', 'dmesg': null}),
      );
      expect(a.status, _missing);
      expect(a.blocking, [Capability.journalAccess]);
      expect(a.fix!.commandLine, [
        'sudo',
        'usermod',
        '-aG',
        'systemd-journal',
        'ops',
      ]);
    });
  });

  group('file tail (LOG-22)', () {
    test('works with tail', () {
      expect(_panel(HostPanel.fileTail, host()).status, _ok);
    });

    test('is missing without tail and unknown before the probe says', () {
      final without = _panel(
        HostPanel.fileTail,
        host(tools: const {'tail': null}),
      );
      expect(without.status, _missing);
      expect(without.blocking, [Capability.tail]);
      expect(without.fix, isNull);
      final unprobed = _panel(HostPanel.fileTail, host(tools: const {}));
      expect(unprobed.status, _unknown);
      expect(unprobed.blocking, [Capability.tail]);
    });
  });

  test('jobs need cron or systemd timers', () {
    final cronOnly = host(
      systemdDir: false,
      tools: const {'crontab': '/usr/bin/crontab'},
    );
    expect(_panel(HostPanel.jobs, cronOnly).route, [Capability.crontab]);
    final neither = host(systemdDir: false, tools: const {'crontab': null});
    expect(_panel(HostPanel.jobs, neither).status, _missing);
  });
}
