import 'package:flutter/foundation.dart' show TargetPlatform;
import 'package:ghost_ui/ghost_ui.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../l10n/app_localizations.dart';

/// The activity panel's transfer formatting (02 §5.3/§6): rates, ETAs,
/// route text, and the throttle popover's custom-rate parser. String
/// literals here are technical (units, separators, route grammar) —
/// reviewed per file in the localization contract; authored copy lives
/// in the ARB. The rate/ETA rendering and the parse grammar moved to
/// `package:ghost_ui` (`ghost_rate_format.dart`); this file keeps the
/// app's names and its parse ceiling.

/// The throttle popover's ceiling for a custom rate (02 §6's "bounded
/// input"): 10 GB/s is far past any link the app will see; larger
/// entries are rejected inline, never silently clamped. The cap is app
/// policy — it crosses into `ghostParseByteRate` as a parameter.
const maxTransferRateBytesPerSecond = 10 * 1000 * 1000 * 1000;

/// A smoothed rate as "2.3 MB/s" — the row, footer, and status chip's
/// speed text. The `/s` suffix is machine grammar, not copy.
String formatTransferRate(
  double bytesPerSecond, {
  required TargetPlatform platform,
}) => ghostFormatByteRate(bytesPerSecond, platform: platform);

/// One configured limit as the chip/popover shows it: the pane size
/// format plus the rate suffix; null (unlimited) renders the header
/// button's ∞ glyph — callers substitute the localized label there.
String formatTransferLimit(
  int bytesPerSecond, {
  required TargetPlatform platform,
}) => ghostFormatByteRate(bytesPerSecond, platform: platform);

/// ETA text (02 §5.3): compact, one-decimal-free, capped at days —
/// "45s", "4m 20s", "1h 3m", "2d 5h".
String formatTransferEta(Duration eta) => ghostFormatCompactEta(eta);

/// The custom-rate field's grammar (02 §6): a number optionally followed
/// by a byte unit (B, KB, MB, GB, TB — decimal like the size formatter)
/// and an optional `/s`. A bare number means bytes per second. Returns
/// bytes/sec, or null on anything the grammar does not cover or that
/// exceeds [maxTransferRateBytesPerSecond] — the popover renders that as
/// an inline error and never clamps.
int? parseTransferRate(String input) =>
    ghostParseByteRate(input, maxBytesPerSecond: maxTransferRateBytesPerSecond);

/// The leaf name of a source/destination path — task titles and item
/// rows. Handles both separators (a Windows local path on any host) and
/// a trailing separator (a root like `/`).
String pathBasename(String path) {
  var trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith('\\'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final slash = trimmed.lastIndexOf('/');
  final backslash = trimmed.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  if (cut < 0) return trimmed;
  return trimmed.substring(cut + 1);
}

/// The parent portion of [path], or null at a root. Display-side
/// arithmetic only — routing decisions keep the task's own paths.
String? pathDirname(String path) {
  var trimmed = path;
  while (trimmed.length > 1 &&
      (trimmed.endsWith('/') || trimmed.endsWith('\\'))) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  final slash = trimmed.lastIndexOf('/');
  final backslash = trimmed.lastIndexOf('\\');
  final cut = slash > backslash ? slash : backslash;
  if (cut <= 0) return cut == 0 ? trimmed.substring(0, 1) : null;
  return trimmed.substring(0, cut);
}

/// The longest shared parent directory across [paths] — the multi-root
/// route line's source side (a task's roots share a gesture, not
/// necessarily a directory).
String commonParentPath(List<String> paths) {
  if (paths.isEmpty) return '';
  // Seed with the first path itself — when it parents the rest it IS
  // the shared root, and seeding one level up would lose it.
  var candidate = paths.first;
  for (final path in paths.skip(1)) {
    // Ascend the candidate until it is an ancestor directory of this
    // path (prefix comparison on a separator boundary). The root is
    // an ancestor of every absolute path — '/a/' never starts with
    // '//', so it needs the explicit case.
    while (candidate.isNotEmpty &&
        !(candidate == '/' || '$path/'.startsWith('$candidate/')) &&
        path != candidate) {
      final parent = pathDirname(candidate);
      if (parent == null || parent == candidate) {
        candidate = '';
        break;
      }
      candidate = parent;
    }
  }
  return candidate;
}

/// A task's endpoint label for the `source → destination` line: the
/// localized "This computer" for a local side, the server's name via
/// [serverLabel] otherwise — the raw id only when nothing resolves it
/// (a server deleted since the task ran), the honest last resort.
String transferEndpointLabel(
  FsLocation location, {
  required String localLabel,
  String? Function(String serverId)? serverLabel,
}) =>
    switch (location) {
      LocalFsLocation() => localLabel,
      ServerFsLocation(:final serverId) =>
        serverLabel?.call(serverId) ?? serverId,
    };

/// The task's one-line title: the single root's name, or a counted
/// summary for multi-root and delete tasks.
String transferTaskTitle(TransferTask task, AppLocalizations l10n) {
  if (task.rootPaths.length == 1) {
    return pathBasename(task.rootPaths.first);
  }
  if (task.operation == TransferOperation.delete) {
    return l10n.activityTaskTitleDelete(task.rootPaths.length);
  }
  return l10n.activityTaskTitleMulti(
    task.rootPaths.length,
    pathBasename(task.destinationDir),
  );
}

/// The `source → destination` route text (02 §6's row grammar): each
/// endpoint's display path prefixed by its endpoint name. A multi-root
/// source collapses to the shared parent; a delete's destination is the
/// common parent (or remote trash run dir) the spec records.
String formatTransferRoute(
  TransferTask task, {
  required String localLabel,
  String? Function(String serverId)? serverLabel,
}) {
  final sourcePath = task.rootPaths.length == 1
      ? task.rootPaths.first
      : commonParentPath(task.rootPaths);
  final source =
      '${transferEndpointLabel(task.source, localLabel: localLabel, serverLabel: serverLabel)}:'
      ' $sourcePath';
  final destination =
      '${transferEndpointLabel(task.destination, localLabel: localLabel, serverLabel: serverLabel)}:'
      ' ${task.destinationDir}';
  return '$source → $destination';
}
