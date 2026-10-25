// On-device history (HIS-01, 03 §7.20): each server's readings rolled up
// into 1-minute buckets for 48 hours and 10-minute buckets for 30 days,
// with the gaps the engine saw, in fixed-size binary rings under
// `history/<server>/` that a bucket rewrites in place. Raw samples never
// touch disk, nothing here syncs, and a server's rings go when it leaves
// the fleet (SYN-08).
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../alerts/alert_evaluator.dart' show AlertMetric, alertValues;
import '../capabilities/capability_cache.dart' show CachePurge;
import '../engine/protocol.dart' show GapCause, SampleResult;
import '../fleet/server_file_stem.dart';
import '../settings/instance_lock.dart' show SupportDirectoryAccess;

/// The directory under the support directory that holds the rings.
const String historyDirectoryName = 'history';

/// A rollup tier: its bucket width and how many buckets its ring holds.
enum HistoryTier {
  /// 1-minute buckets for 48 hours.
  minute(Duration(minutes: 1), 48 * 60),

  /// 10-minute buckets for 30 days.
  tenMinutes(Duration(minutes: 10), 30 * 24 * 6);

  const HistoryTier(this.bucket, this.slots);

  final Duration bucket;
  final int slots;

  /// How far back the ring reaches.
  Duration get span => bucket * slots;

  /// The start of the bucket that holds [at].
  DateTime bucketOf(DateTime at) {
    final width = bucket.inMilliseconds;
    final ms = at.toUtc().millisecondsSinceEpoch;
    return DateTime.fromMillisecondsSinceEpoch(ms - ms % width, isUtc: true);
  }
}

/// Where a bucket's readings came from (03 §7.20).
enum HistoryProvenance {
  /// Readings the app's sampler took while connected.
  liveSampler,

  /// Rolled up on this device from finer buckets of the same session.
  sessionRollup,
}

/// One metric's readings within a bucket.
@immutable
final class HistoryStat {
  const HistoryStat({
    required this.min,
    required this.max,
    required this.mean,
    required this.count,
  });

  final double min, max, mean;

  /// How many readings the bucket holds.
  final int count;

  /// [this] and [other] as one bucket's readings.
  HistoryStat merge(HistoryStat other) {
    final total = count + other.count;
    return HistoryStat(
      min: other.min < min ? other.min : min,
      max: other.max > max ? other.max : max,
      mean: total == 0 ? 0 : (mean * count + other.mean * other.count) / total,
      count: total,
    );
  }
}

/// One rolled-up bucket of a server's readings.
@immutable
final class HistoryBucket {
  const HistoryBucket({
    required this.start,
    required this.provenance,
    required this.values,
  });

  /// The bucket's start, by the engine's clock in UTC; its width is the
  /// tier's.
  final DateTime start;

  final HistoryProvenance provenance;

  /// The metrics the bucket's readings carried; one they never carried is
  /// absent, never zero (03 §10.4).
  final Map<AlertMetric, HistoryStat> values;
}

/// A span the engine knew had no readings, and why (03 §9.5 item 5). A
/// span with neither buckets nor a gap is time the app was closed or did
/// not sample the server.
@immutable
final class HistoryGap {
  const HistoryGap({
    required this.from,
    required this.until,
    required this.cause,
  });

  final DateTime from, until;
  final GapCause cause;
}

/// A server's history in one tier: its buckets, oldest first, and the
/// gaps within their span.
@immutable
final class HistoryRange {
  const HistoryRange({required this.buckets, required this.gaps});

  final List<HistoryBucket> buckets;
  final List<HistoryGap> gaps;
}

/// The bytes of one ring: a file, or memory where the process does not
/// hold the support directory alone.
abstract interface class _RingBytes {
  Future<Uint8List> read(int offset, int length);
  Future<void> write(int offset, Uint8List bytes);
  Future<void> close();
}

final class _MemoryRing implements _RingBytes {
  _MemoryRing(int length) : _bytes = Uint8List(length);

  final Uint8List _bytes;

  /// A copy, as a file ring's read is: a write queued while the caller
  /// decodes never shows through.
  @override
  Future<Uint8List> read(int offset, int length) async =>
      _bytes.sublist(offset, offset + length);

  @override
  Future<void> write(int offset, Uint8List bytes) async =>
      _bytes.setRange(offset, offset + bytes.length, bytes);

  @override
  Future<void> close() async {}
}

final class _FileRing implements _RingBytes {
  _FileRing(this._file);

  final RandomAccessFile _file;

  @override
  Future<Uint8List> read(int offset, int length) async {
    await _file.setPosition(offset);
    final bytes = await _file.read(length);
    // A ring shorter than its layout reads as empty slots past its end.
    if (bytes.length == length) return bytes;
    return Uint8List(length)..setRange(0, bytes.length, bytes);
  }

  @override
  Future<void> write(int offset, Uint8List bytes) async {
    await _file.setPosition(offset);
    await _file.writeFrom(bytes);
  }

  @override
  Future<void> close() => _file.close();
}

/// The ring layout: a header naming the format, then fixed-size slots.
/// A bucket slot is its start in seconds (0 when empty), its provenance,
/// and per [AlertMetric] in declaration order the reading count and the
/// min, max and mean as 32-bit floats. A gap slot is its start and end in
/// seconds and its cause; the gap ring's header holds the next slot. A
/// tier's header names the tier and the metric count, so a build with
/// other metrics starts the ring over rather than misread it.
const _magic = 0x4b485231; // "KHR1"
const _headerBytes = 16;
const _metricBytes = 16;
final _bucketSlotBytes = 8 + 4 + _metricBytes * AlertMetric.values.length;
const _gapSlotBytes = 8 + 8 + 4;
const _gapSlots = 256;

int _ringBytes(HistoryTier tier) =>
    _headerBytes + tier.slots * _bucketSlotBytes;
const _gapRingBytes = _headerBytes + _gapSlots * _gapSlotBytes;

/// One server's open rings.
final class _ServerRings {
  _ServerRings(this.tiers, this.gaps);

  final Map<HistoryTier, _RingBytes> tiers;
  final _RingBytes gaps;
}

/// A bucket being filled.
final class _Accumulator {
  _Accumulator(this.start, this.provenance);

  final DateTime start;
  final HistoryProvenance provenance;
  final Map<AlertMetric, HistoryStat> values = {};

  void add(AlertMetric metric, HistoryStat stat) =>
      values.update(metric, (held) => held.merge(stat), ifAbsent: () => stat);

  HistoryBucket get bucket => HistoryBucket(
    start: start,
    provenance: provenance,
    values: Map.unmodifiable(values),
  );
}

/// The history the engine records and answers from. It rolls each
/// server's readings into the current 1-minute bucket, writes the bucket
/// once a reading of a later minute arrives, and folds written minutes
/// into the current 10-minute bucket the same way. Reads include the
/// buckets still filling. It writes files only with exclusive access to
/// the support directory, one file operation at a time in call order;
/// otherwise it keeps the rings in memory for the run.
final class HistoryStore {
  HistoryStore._(this._directory, this._access, this._purge);

  /// The store under [supportDirectory]. With exclusive access and
  /// [CachePurge.removedServers] it first deletes the rings of servers
  /// outside [fleet]. Never throws.
  static Future<HistoryStore> open(
    Directory supportDirectory, {
    required SupportDirectoryAccess access,
    required Set<String> fleet,
    required CachePurge purge,
  }) async {
    final store = HistoryStore._(
      Directory(
        '${supportDirectory.path}${Platform.pathSeparator}'
        '$historyDirectoryName',
      ),
      access,
      purge,
    );
    if (store._writesFiles && purge == CachePurge.removedServers) {
      await store._sweep(fleet);
    }
    return store;
  }

  /// A store that keeps every ring in memory, for tests.
  @visibleForTesting
  factory HistoryStore.inMemory() => HistoryStore._(
    Directory.systemTemp,
    SupportDirectoryAccess.unguarded,
    CachePurge.never,
  );

  final Directory _directory;
  final SupportDirectoryAccess _access;
  final CachePurge _purge;

  final Map<String, Future<_ServerRings?>> _rings = {};
  final Map<String, _Accumulator> _minute = {};
  final Map<String, _Accumulator> _tenMinutes = {};
  Future<void> _tail = Future.value();

  /// Bumped per server by [forget], so a write queued before it is
  /// dropped instead of opening the server's rings again.
  final Map<String, int> _generations = {};

  bool get _writesFiles => _access == SupportDirectoryAccess.exclusive;

  /// Rolls [result]'s readings for [serverId], taken [at], into its
  /// current bucket.
  void observe(String serverId, SampleResult result, DateTime at) {
    final values = alertValues(result);
    if (values.isEmpty) return;

    final start = HistoryTier.minute.bucketOf(at);
    final held = _minute[serverId];
    if (held != null && held.start != start) {
      // A reading from before the held minute, as across a clock change,
      // starts nothing new and is dropped.
      if (start.isBefore(held.start)) return;
      _closeMinute(serverId, held);
    }
    final bucket = _minute.putIfAbsent(
      serverId,
      () => _Accumulator(start, HistoryProvenance.liveSampler),
    );
    for (final MapEntry(key: metric, :value) in values.entries) {
      bucket.add(
        metric,
        HistoryStat(min: value, max: value, mean: value, count: 1),
      );
    }
  }

  /// Records a span [serverId] had no readings, as the engine's [Gap]
  /// reports it.
  void gap(String serverId, DateTime from, DateTime until, GapCause cause) =>
      _queue(serverId, (rings) async {
        final header = ByteData.sublistView(
          await rings.gaps.read(0, _headerBytes),
        );
        final next = header.getUint32(4) % _gapSlots;
        final slot = ByteData(_gapSlotBytes)
          ..setInt64(0, _seconds(from))
          ..setInt64(8, _seconds(until))
          ..setUint8(16, cause.index);
        await rings.gaps.write(
          _headerBytes + next * _gapSlotBytes,
          slot.buffer.asUint8List(),
        );
        await rings.gaps.write(0, _gapHeader(next + 1));
      });

  /// Writes the buckets still filling, as when the engine stops: each
  /// minute closes into its 10-minute bucket first, so that one holds
  /// every reading too.
  Future<void> flush() {
    for (final MapEntry(key: serverId, value: minute)
        in _minute.entries.toList()) {
      _closeMinute(serverId, minute);
    }
    for (final MapEntry(key: serverId, value: ten) in _tenMinutes.entries) {
      _write(serverId, HistoryTier.tenMinutes, ten.bucket);
    }
    return _tail;
  }

  /// [serverId]'s buckets and gaps in [tier], oldest first: those within
  /// the tier's span before [now], the filling bucket included.
  Future<HistoryRange> read(
    String serverId,
    HistoryTier tier, {
    required DateTime now,
  }) async {
    await _tail;
    final rings = await _ringsOf(serverId);
    final from = now.toUtc().subtract(tier.span);
    final buckets = <DateTime, HistoryBucket>{};
    final gaps = <HistoryGap>[];
    if (rings != null) {
      final bytes = await rings.tiers[tier]!.read(0, _ringBytes(tier));
      final data = ByteData.sublistView(bytes);
      for (var slot = 0; slot < tier.slots; slot++) {
        final bucket = _decodeBucket(
          data,
          _headerBytes + slot * _bucketSlotBytes,
        );
        if (bucket == null || bucket.start.isBefore(from)) continue;
        buckets[bucket.start] = bucket;
      }
      final gapData = ByteData.sublistView(
        await rings.gaps.read(0, _gapRingBytes),
      );
      for (var slot = 0; slot < _gapSlots; slot++) {
        final offset = _headerBytes + slot * _gapSlotBytes;
        final start = gapData.getInt64(offset);
        if (start == 0) continue;
        final until = _fromSeconds(gapData.getInt64(offset + 8));
        final cause = gapData.getUint8(offset + 16);
        if (until.isBefore(from) || cause >= GapCause.values.length) continue;
        gaps.add(
          HistoryGap(
            from: _fromSeconds(start),
            until: until,
            cause: GapCause.values[cause],
          ),
        );
      }
    }
    final filling = switch (tier) {
      HistoryTier.minute => _minute[serverId],
      HistoryTier.tenMinutes => _tenMinutes[serverId],
    };
    if (filling != null) buckets[filling.start] = filling.bucket;
    final ordered = buckets.values.toList()
      ..sort((a, b) => a.start.compareTo(b.start));
    gaps.sort((a, b) => a.from.compareTo(b.from));
    return HistoryRange(
      buckets: List.unmodifiable(ordered),
      gaps: List.unmodifiable(gaps),
    );
  }

  /// Forgets [serverIds], which left the fleet or moved to another
  /// endpoint: their filling buckets, and their rings unless the purge is
  /// withheld.
  Future<void> forget(Set<String> serverIds) {
    for (final serverId in serverIds) {
      _minute.remove(serverId);
      _tenMinutes.remove(serverId);
      _generations[serverId] = (_generations[serverId] ?? 0) + 1;
      final rings = _rings.remove(serverId);
      _tail = _tail.then((_) async {
        try {
          final open = await rings;
          if (open != null) {
            for (final ring in [...open.tiers.values, open.gaps]) {
              await ring.close();
            }
          }
          if (_writesFiles && _purge == CachePurge.removedServers) {
            final directory = _serverDirectory(serverId);
            if (directory != null && await directory.exists()) {
              await directory.delete(recursive: true);
            }
          }
        } on FileSystemException {
          // A ring left behind is purged at the next open.
        }
      });
    }
    return _tail;
  }

  void _closeMinute(String serverId, _Accumulator minute) {
    _write(serverId, HistoryTier.minute, minute.bucket);

    final start = HistoryTier.tenMinutes.bucketOf(minute.start);
    final held = _tenMinutes[serverId];
    if (held != null && held.start != start) {
      _write(serverId, HistoryTier.tenMinutes, held.bucket);
      _tenMinutes.remove(serverId);
    }
    final ten = _tenMinutes.putIfAbsent(
      serverId,
      () => _Accumulator(start, HistoryProvenance.sessionRollup),
    );
    minute.values.forEach(ten.add);
    _minute.remove(serverId);
  }

  void _write(String serverId, HistoryTier tier, HistoryBucket bucket) =>
      _queue(serverId, (rings) {
        final slot =
            (_seconds(bucket.start) ~/ tier.bucket.inSeconds) % tier.slots;
        return rings.tiers[tier]!.write(
          _headerBytes + slot * _bucketSlotBytes,
          _encodeBucket(bucket),
        );
      });

  void _queue(String serverId, Future<void> Function(_ServerRings) body) {
    final generation = _generations[serverId] ?? 0;
    _tail = _tail.then((_) async {
      // A server forgotten since this write was queued keeps no rings.
      if ((_generations[serverId] ?? 0) != generation) return;
      try {
        final rings = await _ringsOf(serverId);
        if (rings != null) await body(rings);
      } on FileSystemException {
        // A write the disk refused costs that bucket, not the run.
      }
    });
  }

  Future<_ServerRings?> _ringsOf(String serverId) =>
      _rings.putIfAbsent(serverId, () => _openRings(serverId));

  Future<_ServerRings?> _openRings(String serverId) async {
    if (!_writesFiles) {
      return _ServerRings({
        for (final tier in HistoryTier.values)
          tier: _MemoryRing(_ringBytes(tier)),
      }, _MemoryRing(_gapRingBytes));
    }
    final directory = _serverDirectory(serverId);
    if (directory == null) return null;
    try {
      await directory.create(recursive: true);
      final tiers = <HistoryTier, _RingBytes>{};
      for (final tier in HistoryTier.values) {
        tiers[tier] = await _openRing(
          File('${directory.path}${Platform.pathSeparator}${tier.name}.ring'),
          _ringBytes(tier),
          () => _tierHeader(tier),
        );
      }
      final gaps = await _openRing(
        File('${directory.path}${Platform.pathSeparator}gaps.ring'),
        _gapRingBytes,
        () => _gapHeader(0),
      );
      return _ServerRings(tiers, gaps);
    } on FileSystemException {
      return null;
    }
  }

  /// Opens [file] for in-place writes, starting it over with [header]
  /// when it is not a ring of this layout.
  static Future<_RingBytes> _openRing(
    File file,
    int length,
    Uint8List Function() header,
  ) async {
    final opened = await file.open(mode: FileMode.append);
    final ring = _FileRing(opened);
    final expected = header();
    final found = await ring.read(0, _headerBytes);
    final ours =
        await opened.length() == length &&
        ByteData.sublistView(found).getUint32(0) == _magic &&
        found[8] == expected[8] &&
        found[9] == expected[9] &&
        ByteData.sublistView(found).getUint32(12) ==
            ByteData.sublistView(expected).getUint32(12);
    if (!ours) {
      await opened.truncate(0);
      await opened.truncate(length);
      await ring.write(0, expected);
    }
    return ring;
  }

  Directory? _serverDirectory(String serverId) =>
      switch (serverFileStem(serverId)) {
        final stem? => Directory(
          '${_directory.path}${Platform.pathSeparator}$stem',
        ),
        null => null,
      };

  Future<void> _sweep(Set<String> fleet) async {
    final keep = {for (final id in fleet) ?serverFileStem(id)};
    try {
      if (!await _directory.exists()) return;
      await for (final entry in _directory.list()) {
        final name = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
        if (!keep.contains(name)) await entry.delete(recursive: true);
      }
    } on FileSystemException {
      // Left for the next open.
    }
  }

  static Uint8List _tierHeader(HistoryTier tier) {
    final header = ByteData(_headerBytes)
      ..setUint32(0, _magic)
      ..setUint8(8, tier.index)
      ..setUint8(9, AlertMetric.values.length)
      ..setUint32(12, tier.slots);
    return header.buffer.asUint8List();
  }

  /// The gap ring's header with [next] as the slot the next gap takes.
  static Uint8List _gapHeader(int next) {
    final header = ByteData(_headerBytes)
      ..setUint32(0, _magic)
      ..setUint32(4, next % _gapSlots)
      ..setUint8(8, 0xff)
      ..setUint32(12, _gapSlots);
    return header.buffer.asUint8List();
  }

  static Uint8List _encodeBucket(HistoryBucket bucket) {
    final data = ByteData(_bucketSlotBytes)
      ..setInt64(0, _seconds(bucket.start))
      ..setUint8(8, bucket.provenance.index + 1);
    for (final metric in AlertMetric.values) {
      final offset = 12 + metric.index * _metricBytes;
      final stat = bucket.values[metric];
      if (stat == null) continue;
      data
        ..setUint32(offset, stat.count)
        ..setFloat32(offset + 4, stat.min)
        ..setFloat32(offset + 8, stat.max)
        ..setFloat32(offset + 12, stat.mean);
    }
    return data.buffer.asUint8List();
  }

  static HistoryBucket? _decodeBucket(ByteData data, int offset) {
    final start = data.getInt64(offset);
    final provenance = data.getUint8(offset + 8);
    if (start == 0 ||
        provenance == 0 ||
        provenance > HistoryProvenance.values.length) {
      return null;
    }
    final values = <AlertMetric, HistoryStat>{};
    for (final metric in AlertMetric.values) {
      final at = offset + 12 + metric.index * _metricBytes;
      final count = data.getUint32(at);
      if (count == 0) continue;
      values[metric] = HistoryStat(
        count: count,
        min: data.getFloat32(at + 4),
        max: data.getFloat32(at + 8),
        mean: data.getFloat32(at + 12),
      );
    }
    return HistoryBucket(
      start: _fromSeconds(start),
      provenance: HistoryProvenance.values[provenance - 1],
      values: Map.unmodifiable(values),
    );
  }

  static int _seconds(DateTime at) =>
      at.toUtc().millisecondsSinceEpoch ~/ Duration.millisecondsPerSecond;

  static DateTime _fromSeconds(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(
        seconds * Duration.millisecondsPerSecond,
        isUtc: true,
      );
}
