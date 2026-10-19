import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/access/access_panel.dart'
    show fixCommandText;
import 'package:klabautermann_app/ui/access/panel_gate.dart';
import 'package:klabautermann_app/ui/server_surfaces.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'profiles.dart';

/// 03 §10.4: a panel the access rules (K04) rule out shows why instead of
/// an empty body; one they cannot rule out yet shows itself.
void main() {
  group('decidePanelGate', () {
    test('shows every panel before the probe answers', () {
      for (final panel in ServerPanel.values) {
        expect(
          decidePanelGate(panel, null).kind,
          PanelGateKind.open,
          reason: panel.name,
        );
      }
    });

    test('leaves the Docker tab to its endpoint on any host', () {
      // GatedPanel follows the Docker endpoint instead (03 §5.9).
      for (final profile in [debianHost(), alpineContainer()]) {
        expect(
          decidePanelGate(ServerPanel.docker, profile).kind,
          PanelGateKind.open,
        );
      }
    });

    test('shows every panel on a systemd host with its tools', () {
      for (final panel in ServerPanel.values) {
        expect(
          decidePanelGate(panel, debianHost()).kind,
          PanelGateKind.open,
          reason: panel.name,
        );
      }
    });

    test('hides Services without systemd, naming systemd', () {
      final gate = decidePanelGate(ServerPanel.services, alpineContainer());
      expect(gate.kind, PanelGateKind.hidden);
      expect(gate.blocking, [Capability.systemd]);
    });

    test('keeps Jobs while crontab or systemd can list them', () {
      expect(
        decidePanelGate(ServerPanel.jobs, alpineContainer()).kind,
        PanelGateKind.open,
      );
      final gate = decidePanelGate(
        ServerPanel.jobs,
        alpineContainer(tools: {'crontab': null}),
      );
      expect(gate.kind, PanelGateKind.hidden);
      expect(gate.blocking, [Capability.crontab]);
    });

    test('hides Logs only when no log source can work', () {
      expect(
        decidePanelGate(ServerPanel.logs, alpineContainer()).kind,
        PanelGateKind.open,
        reason: 'tail still follows files',
      );
      final gate = decidePanelGate(
        ServerPanel.logs,
        alpineContainer(tools: {'tail': null}),
      );
      expect(gate.kind, PanelGateKind.hidden);
      // Journal access goes unsaid while journalctl itself is missing.
      expect(gate.blocking, [Capability.journalctl, Capability.tail]);
    });

    test('shows a panel whose capability the probe did not report', () {
      final unreported = HostProfile.fromJson({
        'systemdDir': false,
        'areaStatuses': {'identity': 'ok'},
      });
      expect(
        decidePanelGate(ServerPanel.jobs, unreported).kind,
        PanelGateKind.open,
      );
      expect(
        decidePanelGate(ServerPanel.logs, unreported).kind,
        PanelGateKind.open,
      );
    });
  });

  group('fixCommandText', () {
    test('puts the elevation in front of plain words', () {
      final fix = AccessFix(const [
        'usermod',
        '-aG',
        'systemd-journal',
        'alice',
      ], FixElevation.sudo);
      expect(fixCommandText(fix), 'sudo usermod -aG systemd-journal alice');
      expect(
        fixCommandText(AccessFix(fix.argv, FixElevation.doas)),
        'doas usermod -aG systemd-journal alice',
      );
      for (final bare in [FixElevation.none, FixElevation.rootShell]) {
        expect(
          fixCommandText(AccessFix(fix.argv, bare)),
          'usermod -aG systemd-journal alice',
        );
      }
    });

    test('quotes a word the shell would split or expand', () {
      final fix = AccessFix(const [
        'addgroup',
        r"a b'$c",
        'docker',
      ], FixElevation.none);
      expect(fixCommandText(fix), 'addgroup \'a b\'"\'"\'\$c\' docker');
    });
  });
}
