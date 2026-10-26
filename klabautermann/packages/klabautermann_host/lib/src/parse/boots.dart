/// Parsers for BOOT-02's boot ends and BOOT-03's kernels (03 §7.11), as
/// [HostCommands.bootEnds] and [HostCommands.kernels] print them.
library;

import 'dart:math' as math;

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
enum KernelCheckState {
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

  final KernelCheckState state;

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
      if (_release.hasMatch(line)) line,
  ]..sort(compareVersions);
  final KernelCheckState state;
  if (installed.isEmpty) {
    state = KernelCheckState.unknown;
  } else if (!installed.contains(running)) {
    state = KernelCheckState.runningRemoved;
  } else if (compareVersions(installed.last, running) > 0) {
    state = KernelCheckState.newerInstalled;
  } else {
    state = KernelCheckState.current;
  }
  return KernelCheck(running: running, installed: installed, state: state);
}

/// A kernel release as `/lib/modules` names one: it starts with a digit,
/// so a stray line of other output is not taken for a kernel.
final _release = RegExp(r'^[0-9][A-Za-z0-9._+~-]*$');

final _versionPart = RegExp(r'\d+|\D+');
final _digits = RegExp(r'^\d+$');

/// Orders kernel releases as `sort -V` does: digit runs by value, other
/// runs as text, so `6.1.0-9` comes before `6.1.0-13`, and a `~` before
/// anything, even the end, so `6.1.0-13~rc1` comes before `6.1.0-13`.
int compareVersions(String a, String b) {
  final left = _versionPart.allMatches(a).map((m) => m[0]!).toList();
  final right = _versionPart.allMatches(b).map((m) => m[0]!).toList();
  for (var i = 0; i < left.length && i < right.length; i++) {
    final order = _digits.hasMatch(left[i]) && _digits.hasMatch(right[i])
        ? BigInt.parse(left[i]).compareTo(BigInt.parse(right[i]))
        : _compareText(left[i], right[i]);
    if (order != 0) return order;
  }
  if (left.length == right.length) return 0;

  // The longer one goes first only when what it adds starts with `~`.
  final longer = left.length > right.length ? left : right;
  final shorterFirst = longer[math.min(left.length, right.length)].startsWith(
    '~',
  );
  final leftLonger = identical(longer, left);
  return (leftLonger != shorterFirst) ? 1 : -1;
}

/// dpkg's order for text: `~` before the end, the end before letters,
/// letters before other characters.
int _compareText(String a, String b) {
  int weight(String text, int i) {
    if (i >= text.length) return 0;
    final unit = text.codeUnitAt(i);
    if (unit == 0x7E) return -1;
    final letter = (unit | 0x20) >= 0x61 && (unit | 0x20) <= 0x7A;
    return letter ? unit : unit + 0x100;
  }

  for (var i = 0; i < a.length || i < b.length; i++) {
    final order = weight(a, i).compareTo(weight(b, i));
    if (order != 0) return order;
  }
  return 0;
}
