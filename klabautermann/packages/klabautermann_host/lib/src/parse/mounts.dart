/// Parser for DSK-05's mounts and DSK-14's swap devices (03 §7.3), as
/// [HostCommands.mounts] prints them.
library;

import 'dart:convert';

import 'package:meta/meta.dart';

import '../commands/commands.dart'
    show
        HostCommands,
        kMountsFindmntMarker,
        kMountsProcMarker,
        kMountsSwapsMarker;

/// One mount: where, from what, as which filesystem and with which
/// options (DSK-05).
@immutable
final class MountEntry {
  MountEntry({
    required this.target,
    required this.source,
    required this.type,
    required List<String> options,
  }) : options = List.unmodifiable(options);

  final String target;
  final String source;
  final String type;

  /// The mount options in the kernel's order (`rw`, `relatime`, ...).
  final List<String> options;

  /// Whether it is mounted read-only.
  bool get readOnly => options.contains('ro');
}

/// What a swap device is (DSK-14).
enum SwapKind { partition, file, other }

/// One swap device from `/proc/swaps` (DSK-14).
@immutable
final class SwapDevice {
  const SwapDevice({
    required this.path,
    required this.kind,
    required this.sizeBytes,
    required this.usedBytes,
    required this.priority,
  });

  final String path;
  final SwapKind kind;
  final int sizeBytes;
  final int usedBytes;

  /// Higher is used first; the kernel numbers unset priorities from -2
  /// down.
  final int priority;
}

/// [HostCommands.mounts]'s mounts and swap devices.
@immutable
final class MountsRead {
  MountsRead({
    required List<MountEntry> mounts,
    required List<SwapDevice> swaps,
  }) : mounts = List.unmodifiable(mounts),
       swaps = List.unmodifiable(swaps);

  /// The mounts in mount order, so a later one over the same target is
  /// the one in effect.
  final List<MountEntry> mounts;
  final List<SwapDevice> swaps;

  /// The mount in effect at [target], or null.
  MountEntry? mountAt(String target) =>
      mounts.lastWhereOrNull((mount) => mount.target == target);
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}

/// The read in [raw], or null when it is not the read's output.
MountsRead? parseMounts(String raw) {
  final lines = raw.split('\n');
  final swapsAt = lines.indexOf(kMountsSwapsMarker);
  if (swapsAt < 1) return null;

  final mountLines = lines.sublist(1, swapsAt);
  final List<MountEntry>? mounts = switch (lines.first.trim()) {
    kMountsFindmntMarker => _findmnt(mountLines.join('\n')),
    kMountsProcMarker => _procMounts(mountLines),
    _ => null,
  };
  if (mounts == null) return null;
  return MountsRead(mounts: mounts, swaps: _swaps(lines.skip(swapsAt + 1)));
}

/// `findmnt -J -l`'s `filesystems` list; null when it is not that JSON.
List<MountEntry>? _findmnt(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return null;
  }
  if (decoded case {'filesystems': final List<Object?> filesystems}) {
    return [
      for (final entry in filesystems)
        if (entry case {
          'target': final String target,
          'source': final String? source,
          'fstype': final String? type,
          'options': final String? options,
        })
          MountEntry(
            target: target,
            source: source ?? '',
            type: type ?? '',
            options: _options(options ?? ''),
          ),
    ];
  }
  return null;
}

/// `/proc/self/mounts`: `source target type options dump pass`, with
/// spaces, tabs, newlines and backslashes octal-escaped.
List<MountEntry> _procMounts(List<String> lines) => [
  for (final line in lines)
    if (line.trim().split(' ') case [
      final source,
      final target,
      final type,
      final options,
      ...,
    ])
      MountEntry(
        target: _unescape(target),
        source: _unescape(source),
        type: type,
        options: _options(options),
      ),
];

/// `/proc/swaps`: a header, then `path type size used priority`, sizes
/// in KiB and the path octal-escaped as in `/proc/self/mounts`.
List<SwapDevice> _swaps(Iterable<String> lines) => [
  for (final line in lines)
    if (line.trim().split(RegExp(r'\s+')) case [
      final path,
      final kind,
      final size,
      final used,
      final priority,
    ])
      if ((int.tryParse(size), int.tryParse(used), int.tryParse(priority))
          case (final size?, final used?, final priority?))
        SwapDevice(
          path: _unescape(path),
          kind: switch (kind) {
            'partition' => SwapKind.partition,
            'file' => SwapKind.file,
            _ => SwapKind.other,
          },
          sizeBytes: size * 1024,
          usedBytes: used * 1024,
          priority: priority,
        ),
];

List<String> _options(String options) => [
  for (final option in options.split(','))
    if (option.isNotEmpty) option,
];

final _octal = RegExp(r'\\([0-7]{3})');

String _unescape(String field) => field.replaceAllMapped(
  _octal,
  (match) => String.fromCharCode(int.parse(match[1]!, radix: 8)),
);
