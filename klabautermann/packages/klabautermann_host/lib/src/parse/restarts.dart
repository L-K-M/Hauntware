/// The parser for PKG-04's restart check (03 §7.8): the services still
/// running libraries an update replaced, and whether a newer kernel waits
/// for a reboot, from `needrestart -b`, `needs-restarting -s` or
/// `zypper ps -sss`.
library;

import 'package:meta/meta.dart';

/// The tools the restart check runs, in the order it looks for them.
enum RestartTool { needrestart, needsRestarting, zypper }

/// Whether the running kernel is the newest installed, as needrestart's
/// `NEEDRESTART-KSTA` says.
enum KernelState {
  current,

  /// A newer kernel of the same ABI waits for a reboot.
  abiCompatibleUpgrade,

  /// A newer kernel version waits for a reboot.
  versionUpgrade,
}

/// What one restart check found.
@immutable
final class RestartCheck {
  RestartCheck({
    required this.tool,
    Iterable<String> services = const [],
    this.kernel,
  }) : services = List.unmodifiable(services);

  /// The tool that answered, or null when none is installed.
  final RestartTool? tool;

  /// The systemd units to restart, each once, in the tool's order.
  final List<String> services;

  /// The kernel's state, where the tool reports it (needrestart only).
  final KernelState? kernel;
}

/// A systemd unit name as the tools print them.
final _unit = RegExp(r'^[A-Za-z0-9:_.@\\-]+\.(service|socket|timer|target)$');

/// [raw], the check's output (`HostCommands.restartCheck`): a
/// `== tool <name>` line, then the tool's own output.
RestartCheck parseRestartCheck(String raw) {
  final lines = raw.split('\n');
  final header = lines.isEmpty ? '' : lines.first.trim();
  final tool = switch (header) {
    '== tool needrestart' => RestartTool.needrestart,
    '== tool needs-restarting' => RestartTool.needsRestarting,
    '== tool zypper' => RestartTool.zypper,
    _ => null,
  };
  if (tool == null) return RestartCheck(tool: null);

  final services = <String>{};
  KernelState? kernel;
  for (final line in lines.skip(1)) {
    final text = line.trim();
    if (tool == RestartTool.needrestart) {
      if (text.startsWith('NEEDRESTART-SVC:')) {
        final unit = text.substring('NEEDRESTART-SVC:'.length).trim();
        if (_unit.hasMatch(unit)) services.add(unit);
      } else if (text.startsWith('NEEDRESTART-KSTA:')) {
        kernel = switch (text.substring('NEEDRESTART-KSTA:'.length).trim()) {
          '1' => KernelState.current,
          '2' => KernelState.abiCompatibleUpgrade,
          '3' => KernelState.versionUpgrade,
          _ => null,
        };
      }
      continue;
    }
    // needs-restarting -s and zypper ps -sss print one unit per line;
    // zypper's names may lack the `.service` suffix.
    if (text.isEmpty) continue;
    final unit = text.contains('.') ? text : '$text.service';
    if (_unit.hasMatch(unit)) services.add(unit);
  }
  return RestartCheck(tool: tool, services: services, kernel: kernel);
}
