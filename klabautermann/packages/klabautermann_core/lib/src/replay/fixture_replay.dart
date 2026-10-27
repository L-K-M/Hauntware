/// The pure pieces of the fixture replays (03 §11.4): the engine budget
/// harness (spike S5 part 1, `tool/engine_budget.dart`) and the replay
/// engine the app's frame-timing test runs on (part 2). They hold the
/// fixture counters a replayed host advances, the HWS/1 frames it prints,
/// when each host reads, and the follow's input and batches. Nothing here
/// owns a clock, a file or an isolate.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';

import '../engine/protocol.dart';
import '../logs/journal_record.dart';

/// One section of a replayed reply: the collector or `probe_<area>`, its
/// status and payload.
typedef ReplaySection = ({String name, SectionStatus status, String payload});

/// The nonce of every replayed session.
const replayNonce = '0123456789abcdef0123456789abcdef';

/// Each counter's rise per second, by block and row shape, as the
/// sample-pipeline fixture test advances them per reading: the aggregate
/// CPU and each core by 100 jiffies (one CPU-second at `USER_HZ` 100),
/// each interface by 2,000 bytes in and 1,000 out, each disk by 8
/// sectors read and 16 written.
const _cpuRates = [30, 0, 10, 50, 10];
const _coreSumRates = [25, 75];
const _coreRawRates = [10, 0, 5, 60, 15, 5, 3, 2];
const _netdevRates = [2000, 1000];
const _diskRates = [1, 8, 1, 16];

/// [payload], a fast collector's fixture, [seconds] later: every counter
/// risen at its rate and the uptime and idle time by [seconds], with the
/// rest of each line, its spacing included, as it was.
String advanceCounters(String payload, double seconds) {
  var block = '';
  final out = <String>[];
  for (final line in payload.split('\n')) {
    final header = RegExp(r'^== ([a-z0-9_-]+) ==$').firstMatch(line);
    if (header != null) {
      block = header[1]!;
      out.add(line);
      continue;
    }

    final words = line.trim().split(RegExp(r'\s+'));
    final rates = switch ((block, words.first, words.length)) {
      ('stat', 'cpu', _) => _cpuRates,
      ('stat', final name, 3) when name.startsWith('cpu') => _coreSumRates,
      ('stat', final name, 9) when name.startsWith('cpu') => _coreRawRates,
      ('netdev', _, 3) => _netdevRates,
      ('diskstats', _, 5) => _diskRates,
      _ => null,
    };
    if (rates != null) {
      out.add(
        _mapWords(line, (i, word) {
          if (i == 0 || i > rates.length) return word;
          return '${int.parse(word) + (rates[i - 1] * seconds).round()}';
        }),
      );
    } else if (block == 'uptime' && words.length == 2) {
      out.add(
        _mapWords(
          line,
          (_, word) => (double.parse(word) + seconds).toStringAsFixed(2),
        ),
      );
    } else {
      out.add(line);
    }
  }
  return out.join('\n');
}

/// [line] with each whitespace-separated word replaced by [map]'s value
/// for its index and text.
String _mapWords(String line, String Function(int i, String word) map) {
  var i = 0;
  return line.replaceAllMapped(RegExp(r'\S+'), (m) => map(i++, m[0]!));
}

/// The host uptime a fast fixture's `uptime` block holds, or null
/// without one.
double? fixtureUptime(String payload) {
  final match = RegExp(
    r'^== uptime ==\n(\S+)',
    multiLine: true,
  ).firstMatch(payload);
  return match == null ? null : double.tryParse(match[1]!);
}

/// The sections of a fixture's `probe.sections` file, where each
/// `### <area> <status>` line opens one area.
List<ReplaySection> parseProbeSections(String text) => [
  for (final chunk in text.split(RegExp(r'^### ', multiLine: true)))
    if (chunk.isNotEmpty) _probeSection(chunk),
];

ReplaySection _probeSection(String chunk) {
  final newline = chunk.indexOf('\n');
  final head = chunk.substring(0, newline).split(' ');
  var body = chunk.substring(newline + 1);
  while (body.endsWith('\n')) {
    body = body.substring(0, body.length - 1);
  }
  return (
    name: 'probe_${head[0]}',
    status: SectionStatus.values.byName(head[1]),
    payload: body,
  );
}

/// The SELF and READY markers a replayed session starts with (03 §6.2,
/// §6.3). A replayed host has no processes, so SELF names PID 2 and its
/// parent PID 1.
Uint8List readyFrame() => (_marker(
  'SELF 2 1',
)..add(_marker('READY HWS/1 $kCollectorSetVersion').toBytes())).toBytes();

/// Reply [seq] with [sections], framed as the sampler prints it (03
/// §6.2): its `B` marker carries [uptime], or nothing when it is null.
Uint8List replyFrame(int seq, double? uptime, List<ReplaySection> sections) {
  final out = _marker('B $seq ${uptime?.toStringAsFixed(2) ?? ''}');
  for (final section in sections) {
    final payload = utf8.encode(section.payload);
    out
      ..add(
        _marker('S ${section.name} ${section.status.name} ${payload.length}')
            .toBytes(),
      )
      ..add(payload)
      ..addByte(0x0a);
  }
  return (out..add(_marker('E $seq').toBytes())).toBytes();
}

BytesBuilder _marker(String body) =>
    BytesBuilder(copy: false)..add(utf8.encode('\x1e$replayNonce $body\n'));

/// When each replayed host's fast sampler reads (03 §6.4). Hosts below
/// [openHosts] are servers the user opened: they read `core` every
/// [coreEvery], whose reply also serves their `overview` row. The rest
/// read `overview` every [overviewEvery]. Within each group the first
/// reads are spread evenly over the interval, as hosts connected at
/// different moments would be, so the fleet's ticks do not all land at
/// once.
final class ReplaySchedule {
  ReplaySchedule({
    required this.hosts,
    required this.overviewEvery,
    required this.openHosts,
    required this.coreEvery,
  }) : assert(openHosts >= 0 && openHosts <= hosts),
       _nextSlot = List.filled(hosts, 0);

  final int hosts, openHosts;
  final Duration overviewEvery, coreEvery;
  final List<int> _nextSlot;

  /// Reads that came due more than once between two [due] calls, of
  /// which only the latest ran.
  int get skipped => _skipped;
  int _skipped = 0;

  bool _isOpen(int host) => host < openHosts;

  Collector collectorOf(int host) =>
      _isOpen(host) ? Collector.core : Collector.overview;

  Set<SampleStream> streamsOf(int host) => _isOpen(host)
      ? const {SampleStream.overview, SampleStream.core}
      : const {SampleStream.overview};

  Duration _interval(int host) => _isOpen(host) ? coreEvery : overviewEvery;

  /// When [host]'s read number [slot] starts, from the replay's start.
  Duration slotTime(int host, int slot) {
    final (rank, size) = _isOpen(host)
        ? (host, openHosts)
        : (host - openHosts, hosts - openHosts);
    final interval = _interval(host).inMicroseconds;
    return Duration(microseconds: interval * rank ~/ size + interval * slot);
  }

  /// How many of [host]'s reads start before [end].
  int slotsWithin(int host, Duration end) {
    final first = slotTime(host, 0);
    if (end <= first) return 0;

    final interval = _interval(host).inMicroseconds;
    return ((end - first).inMicroseconds + interval - 1) ~/ interval;
  }

  /// The reads due at [now], by host: each host's latest slot that has
  /// started and not yet run. Slots passed over count as [skipped], as a
  /// sampler skips a tick while it is busy (03 §6.2).
  List<({int host, int slot})> due(Duration now) {
    final out = <({int host, int slot})>[];
    for (var host = 0; host < hosts; host++) {
      final passed = slotsWithin(host, now + const Duration(microseconds: 1));
      final next = _nextSlot[host];
      if (passed <= next) continue;

      _skipped += passed - next - 1;
      _nextSlot[host] = passed;
      out.add((host: host, slot: passed - 1));
    }
    return out;
  }
}

/// When a stream due at [due] every [period] reads next after reading at
/// [now]: one period on, or, when [now] is a period or more late, the
/// first slot of that grid after [now], the slots passed over skipped as
/// a busy sampler skips its ticks (03 §6.2).
Duration nextGridRead(Duration due, Duration period, Duration now) {
  final passed = (now - due).inMicroseconds ~/ period.inMicroseconds;
  return due + period * (passed + 1);
}

/// A follow's input: [rows], `journalctl -o json` lines, cycled to make
/// up one second of [linesPerSecond] (at least one pass over [rows]),
/// each ended by a newline, and handed out in order from where the last
/// [feed] stopped, wrapping around.
final class JournalFeed {
  JournalFeed(List<String> rows, int linesPerSecond) {
    if (rows.isEmpty) throw ArgumentError.value(rows, 'rows', 'is empty');

    final count = math.max(rows.length, linesPerSecond);
    final out = BytesBuilder(copy: false);
    _lineStarts = [0];
    for (var i = 0; i < count; i++) {
      out
        ..add(utf8.encode(rows[i % rows.length]))
        ..addByte(0x0a);
      _lineStarts.add(out.length);
    }
    _bytes = out.toBytes();
  }

  late final Uint8List _bytes;

  /// Where each line starts in [_bytes], with its end last.
  late final List<int> _lineStarts;
  int _next = 0;

  /// Hands [follow] the next [lines] lines and returns their bytes.
  int feed(FollowReplay follow, int lines) {
    final cycle = _lineStarts.length - 1;
    var bytes = 0;
    while (lines > 0) {
      final take = math.min(lines, cycle - _next);
      final from = _lineStarts[_next], to = _lineStarts[_next + take];
      follow.add(Uint8List.sublistView(_bytes, from, to));
      bytes += to - from;
      _next = (_next + take) % cycle;
      lines -= take;
    }
    return bytes;
  }
}

/// The batches a follow sends at most (03 §10.1 [E]).
const kMaxLogBatchesPerSecond = 20;

const _batchInterval = Duration(
  microseconds: Duration.microsecondsPerSecond ~/ kMaxLogBatchesPerSecond,
);

/// A stand-in for the follower K26 builds (03 §7.6, §10.1): it takes
/// `journalctl -f -o json` output in the chunks a channel delivers,
/// decodes and splits it into lines, parses each into a [JournalRecord]
/// and hands out [LogBatch]es on a 50 ms beat, never more than
/// [kMaxLogBatchesPerSecond] in any second. At most [maxPending] records
/// wait for a batch; older ones are dropped and counted in the next
/// batch's [LogBatch.dropped], so memory stays bounded when the engine
/// falls behind.
final class FollowReplay {
  FollowReplay({required this.streamId, required this.maxPending})
    : assert(maxPending > 0) {
    _input = const Utf8Decoder(allowMalformed: true).startChunkedConversion(
      const LineSplitter().startChunkedConversion(_Lines(_line)),
    );
  }

  final String streamId;
  final int maxPending;

  late final ByteConversionSink _input;
  final _pending = ListQueue<LogRecord>();
  int _droppedSinceBatch = 0;
  Duration? _lastBatch;

  /// When the latest [kMaxLogBatchesPerSecond] batches went, oldest first.
  final _sentAt = ListQueue<Duration>(kMaxLogBatchesPerSecond);

  /// Lines parsed into records.
  int get linesParsed => _linesParsed;
  int _linesParsed = 0;

  /// Lines that were not a JSON object.
  int get malformed => _malformed;
  int _malformed = 0;

  /// Records dropped since the follow started.
  int get dropped => _dropped;
  int _dropped = 0;

  /// Records waiting for the next batch, and the most that ever waited.
  int get pending => _pending.length;
  int get maxPendingSeen => _maxPendingSeen;
  int _maxPendingSeen = 0;

  /// Takes the next chunk of the follow's output.
  void add(List<int> chunk) => _input.add(chunk);

  void _line(String line) {
    if (line.trim().isEmpty) return;

    final entry = parseJournalLine(line);
    if (entry == null) {
      _malformed++;
      return;
    }
    _linesParsed++;
    _pending.add(journalRecordFrom(entry));
    if (_pending.length > maxPending) {
      _pending.removeFirst();
      _droppedSinceBatch++;
      _dropped++;
    }
    if (_pending.length > _maxPendingSeen) _maxPendingSeen = _pending.length;
  }

  /// The next batch at [now], from the follow's start: null until 50 ms
  /// after the last one was due, while that would make more than
  /// [kMaxLogBatchesPerSecond] in a second, or while nothing is waiting
  /// or dropped.
  LogBatch? flush(Duration now) {
    final last = _lastBatch;
    if (last != null && now - last < _batchInterval) return null;
    // A batch sent late on the beat can go less than 50 ms before the
    // next, so the beat alone allows a 21st within a second.
    if (_sentAt.length == kMaxLogBatchesPerSecond &&
        now - _sentAt.first < const Duration(seconds: 1)) {
      return null;
    }
    if (_pending.isEmpty && _droppedSinceBatch == 0) return null;

    final batch = LogBatch(
      streamId: streamId,
      records: _pending,
      dropped: _droppedSinceBatch,
    );
    _pending.clear();
    _droppedSinceBatch = 0;
    if (_sentAt.length == kMaxLogBatchesPerSecond) _sentAt.removeFirst();
    _sentAt.add(now);
    // A 50 ms beat rather than one that drifts by the caller's step;
    // after a longer pause it starts again from [now].
    _lastBatch = last != null && now - last < _batchInterval * 2
        ? last + _batchInterval
        : now;
    return batch;
  }
}

final class _Lines implements Sink<String> {
  _Lines(this._onLine);

  final void Function(String line) _onLine;

  @override
  void add(String line) => _onLine(line);

  @override
  void close() {}
}
