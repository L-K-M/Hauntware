/// Parsers for BOOT-02's boot ends and BOOT-03's kernels (03 §7.11), as
/// [HostCommands.bootEnds] and [HostCommands.kernels] print them.
library;

import 'package:meta/meta.dart';

import '../commands/commands.dart' show HostCommands, kKernelsMarker;

/// How a boot before the current one ended (BOOT-02).
enum BootEnd {
  /// Its journal ends with journald stopping or a shutdown target.
  clean,

  /// Its journal ends without either: a crash, a power loss or a hard
  /// reset.
  unclean,

  /// The system journal is not readable for it.
  unknown,
}

final _bootEndLine = RegExp(r'^([0-9a-f]{32}) (clean|unclean|unknown)$');

/// The ends [HostCommands.bootEnds] printed, by boot ID; lines it does
/// not recognise are skipped.
Map<String, BootEnd> parseBootEnds(String raw) => {
  for (final line in raw.split('\n'))
    if (_bootEndLine.firstMatch(line.trim()) case final match?)
      match[1]!: BootEnd.values.byName(match[2]!),
};

/// Whether the running kernel is the newest installed (BOOT-03).
enum KernelState {
  /// The running kernel is the newest whose modules are installed.
  current,

  /// A newer kernel is installed; a reboot loads it.
  newerInstalled,

  /// The running kernel's modules are gone, as after an upgrade that
  /// removed them; a reboot loads the installed one.
  runningRemoved,

  /// No module directory was found, as in a container.
  unknown,
}

/// The running and installed kernels (BOOT-03).
@immutable
final class KernelCheck {
  KernelCheck({
    required this.running,
    required List<String> installed,
    required this.state,
  }) : installed = List.unmodifiable(installed);

  /// `uname -r`.
  final String running;

  /// The installed kernels' releases, oldest first by version.
  final List<String> installed;

  final KernelState state;

  /// The newest installed release, or null with none found.
  String? get newest => installed.isEmpty ? null : installed.last;
}

/// The kernels in [raw], or null when it is not the read's output.
KernelCheck? parseKernels(String raw) {
  final lines = [for (final line in raw.split('\n')) line.trim()];
  final markerAt = lines.indexOf(kKernelsMarker);
  if (markerAt != 1 || lines.first.isEmpty) return null;
  final running = lines.first;
  final installed = [
    for (final line in lines.skip(markerAt + 1))
      if (line.isNotEmpty && !line.contains('/')) line,
  ]..sort(compareVersions);
  final KernelState state;
  if (installed.isEmpty) {
    state = KernelState.unknown;
  } else if (!installed.contains(running)) {
    state = KernelState.runningRemoved;
  } else if (compareVersions(installed.last, running) > 0) {
    state = KernelState.newerInstalled;
  } else {
    state = KernelState.current;
  }
  return KernelCheck(running: running, installed: installed, state: state);
}

final _versionPart = RegExp(r'\d+|\D+');

/// Orders kernel releases as `sort -V` does: digit runs by value, other
/// runs as text, so `6.1.0-9` comes before `6.1.0-13`.
int compareVersions(String a, String b) {
  final left = _versionPart.allMatches(a).map((m) => m[0]!).toList();
  final right = _versionPart.allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final x = int.tryParse(left[i]);
    final y = int.tryParse(right[i]);
    final order = x != null && y != null
        ? x.compareTo(y)
        : left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  return left.length.compareTo(right.length);
}
