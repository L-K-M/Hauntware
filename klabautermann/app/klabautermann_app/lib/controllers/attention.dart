import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../ui/docker/containers_view.dart' show containerNameOf;
import '../ui/overview_panel.dart' show DiskMeasure, diskAlarms;
import '../ui/charts/charts.dart' show ChartSeverity;
import 'alert_center.dart' show ActiveAlert;

/// TRI-03's kinds of problem, in the order the queue lists them.
enum AttentionKind {
  /// The engine does not dial until the user decides something (D46).
  blocked,

  /// The last attempt failed, or the engine waits before dialling again.
  unreachable,

  /// An in-app alert is raised (ALR-01).
  alert,

  failedUnit,

  /// A mount's space at the fleet rows' critical level.
  diskFull,

  /// A mount's inodes at the fleet rows' critical level.
  inodesFull,

  unhealthyContainer,
}

/// One problem in the queue: [kind] on [serverId], about [subject] (a
/// unit, a mount point, a container or an alert's rule id) where the kind
/// names one, with a mount's use in [percent] and a raised [alert].
@immutable
final class AttentionItem {
  const AttentionItem({
    required this.serverId,
    required this.kind,
    this.subject,
    this.percent,
    this.alert,
  });

  final String serverId;
  final AttentionKind kind;
  final String? subject;
  final int? percent;
  final ActiveAlert? alert;

  /// What an acknowledgement is filed under on its server: the kind and
  /// subject, which outlast the figures a reading changes.
  String get key => '${kind.name}:${subject ?? ''}';

  @override
  bool operator ==(Object other) =>
      other is AttentionItem &&
      other.serverId == serverId &&
      other.kind == kind &&
      other.subject == subject &&
      other.percent == percent;

  @override
  int get hashCode => Object.hash(serverId, kind, subject, percent);
}

/// What the queue reads of one server: its link, its raised alerts and,
/// where this run holds them, its last mount listing, unit list and
/// container list. A null reading was never taken this run.
@immutable
final class AttentionSource {
  const AttentionSource({
    required this.serverId,
    this.link,
    this.alerts = const [],
    this.fs,
    this.failedUnits,
    this.containers,
  });

  final String serverId;
  final LinkStatus? link;
  final List<ActiveAlert> alerts;
  final FsSnapshot? fs;
  final List<SystemdUnit>? failedUnits;
  final List<ContainerSummary>? containers;
}

/// The queue's problems, and per server the kinds it could see: a kind
/// it saw without a problem has cleared, while one it could not see may
/// still stand.
typedef AttentionScan = ({
  List<AttentionItem> items,
  Map<String, Set<AttentionKind>> observed,
});

/// TRI-03's problems across [sources], from cached results only: per
/// server its link, then its alerts, units, mounts (the fullest first) and
/// containers.
AttentionScan scanAttention(Iterable<AttentionSource> sources) {
  final items = <AttentionItem>[];
  final observed = <String, Set<AttentionKind>>{};
  for (final source in sources) {
    final id = source.serverId;
    final seen = observed[id] = {
      // An idle link has not tried yet, one connecting or waiting for the
      // user has not settled, and one closed without a failure (by its
      // owner, or lost before the redial) says nothing about reaching
      // the server: a stored blocked or unreachable acknowledgement
      // stands until the link settles, so a relaunch or a retry between
      // backoffs does not reopen it.
      if (source.link
          case LinkReady() ||
              LinkDegraded() ||
              LinkBlocked() ||
              LinkBackoff() ||
              LinkClosed(failure: _?)) ...[
        AttentionKind.blocked,
        AttentionKind.unreachable,
      ],
      AttentionKind.alert,
    };

    switch (source.link) {
      case LinkBlocked():
        items.add(AttentionItem(serverId: id, kind: AttentionKind.blocked));
      case LinkBackoff() || LinkClosed(failure: _?):
        items.add(AttentionItem(serverId: id, kind: AttentionKind.unreachable));
      case _:
        break;
    }

    for (final alert in source.alerts) {
      items.add(
        AttentionItem(
          serverId: id,
          kind: AttentionKind.alert,
          subject: alert.ruleId,
          alert: alert,
        ),
      );
    }

    if (source.failedUnits case final units?) {
      seen.add(AttentionKind.failedUnit);
      for (final unit in units) {
        items.add(
          AttentionItem(
            serverId: id,
            kind: AttentionKind.failedUnit,
            subject: unit.unit,
          ),
        );
      }
    }

    if (source.fs case final fs?) {
      seen.addAll(const [AttentionKind.diskFull, AttentionKind.inodesFull]);
      for (final alarm in diskAlarms(fs)) {
        if (alarm.severity != ChartSeverity.critical) continue;
        items.add(
          AttentionItem(
            serverId: id,
            kind: alarm.measure == DiskMeasure.space
                ? AttentionKind.diskFull
                : AttentionKind.inodesFull,
            subject: alarm.mountPoint,
            percent: alarm.percent,
          ),
        );
      }
    }

    if (source.containers case final containers?) {
      seen.add(AttentionKind.unhealthyContainer);
      for (final container in containers) {
        if (container.health != HealthStatus.unhealthy) continue;
        items.add(
          AttentionItem(
            serverId: id,
            kind: AttentionKind.unhealthyContainer,
            subject: containerNameOf(container),
          ),
        );
      }
    }
  }
  return (items: items, observed: observed);
}

/// The longest note an acknowledgement keeps.
const int kAttentionNoteMax = 500;

/// One acknowledgement: when, and the user's note, possibly empty.
@immutable
final class AttentionAck {
  const AttentionAck({required this.at, this.note = ''});

  final DateTime at;
  final String note;
}

/// Writes the acknowledgements to `settings.json`.
typedef SaveAttention = Future<void> Function(Map<String, Object?> json);

// The fields of one acknowledgement in `settings.json`.
const String _atField = 'at';
const String _noteField = 'note';

/// TRI-03's acknowledgements, device-local (02 TRI-03): by server, under
/// each problem's [AttentionItem.key]. An acknowledgement hides its
/// problem until the problem clears, which [prune] notices, so the same
/// problem coming back asks for attention again. Without [save], as in
/// most tests, they last this run.
final class AttentionAcks extends ChangeNotifier {
  AttentionAcks({
    Map<String, Object?>? stored,
    this._save,
    this._now = DateTime.now,
  }) : _acks = _decode(stored);

  final SaveAttention? _save;
  final DateTime Function() _now;
  final Map<String, Map<String, AttentionAck>> _acks;

  /// [item]'s acknowledgement, or null while it asks for attention.
  AttentionAck? ackFor(AttentionItem item) => _acks[item.serverId]?[item.key];

  /// Acknowledges [item] with [note], trimmed and cut to
  /// [kAttentionNoteMax] code points.
  Future<void> acknowledge(AttentionItem item, {String note = ''}) {
    final trimmed = note.trim();
    _acks.putIfAbsent(item.serverId, () => {})[item.key] = AttentionAck(
      at: _now().toUtc(),
      // Cut by code points, so no surrogate pair is split.
      note: String.fromCharCodes(trimmed.runes.take(kAttentionNoteMax)),
    );
    return _changed();
  }

  /// Takes [item]'s acknowledgement back, so it asks for attention again.
  Future<void> reopen(AttentionItem item) {
    final server = _acks[item.serverId];
    if (server?.remove(item.key) == null) return Future.value();
    if (server!.isEmpty) _acks.remove(item.serverId);
    return _changed();
  }

  /// Drops the acknowledgements of problems [scan] saw clear, and those
  /// of servers it no longer lists; true when one was dropped. A kind the
  /// scan could not see keeps its acknowledgements.
  bool prune(AttentionScan scan) {
    final standing = {for (final item in scan.items) (item.serverId, item.key)};
    var dropped = false;
    for (final serverId in [..._acks.keys]) {
      final seen = scan.observed[serverId];
      final server = _acks[serverId]!;
      if (seen == null) {
        _acks.remove(serverId);
        dropped = true;
        continue;
      }
      server.removeWhere((key, _) {
        final kind = AttentionKind.values.asNameMap()[key.split(':').first];
        final clear =
            kind == null ||
            (seen.contains(kind) && !standing.contains((serverId, key)));
        dropped |= clear;
        return clear;
      });
      if (server.isEmpty) _acks.remove(serverId);
    }
    if (dropped) _changed();
    return dropped;
  }

  Future<void> _changed() {
    notifyListeners();
    return _save?.call(_encode()) ?? Future.value();
  }

  Map<String, Object?> _encode() => {
    for (final MapEntry(key: serverId, value: server) in _acks.entries)
      serverId: {
        for (final MapEntry(:key, value: ack) in server.entries)
          key: {
            _atField: ack.at.toIso8601String(),
            if (ack.note.isNotEmpty) _noteField: ack.note,
          },
      },
  };

  /// [stored] leniently: an entry that does not read as an
  /// acknowledgement is skipped rather than failing the rest.
  static Map<String, Map<String, AttentionAck>> _decode(
    Map<String, Object?>? stored,
  ) => {
    for (final MapEntry(key: serverId, :value) in (stored ?? const {}).entries)
      if (value case final Map<String, Object?> server)
        if ({
              for (final MapEntry(:key, :value) in server.entries)
                if (value case {_atField: final String at})
                  if (DateTime.tryParse(at) case final parsed?)
                    key: AttentionAck(
                      at: parsed.toUtc(),
                      note: switch (value[_noteField]) {
                        final String note => note,
                        _ => '',
                      },
                    ),
            }
            case final acks when acks.isNotEmpty)
          serverId: acks,
  };
}
