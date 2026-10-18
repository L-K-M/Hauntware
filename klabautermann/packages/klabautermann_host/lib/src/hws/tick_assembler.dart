/// Assembles HWS/1 frame events into replies (03 §6.2).
///
/// [HwsFrameParser] checks bytes; this layer checks the session: `SELF`
/// and then READY come first, READY carries this client's collector-set
/// version, and each
/// reply is a `B`, its sections and the `E` with the same sequence
/// number. A framing error loses the reply it interrupted, if any, and
/// the reply whose end marker the parser resynchronizes on (one loss when
/// they are the same). A well-framed marker out of order cannot come from
/// the constant program, so it ends the session and the engine restarts
/// the sampler.
library;

import 'frames.dart';
import 'program.dart' show kCollectorSetVersion;

/// Upper bound on the sections in one reply. A tick emits one section per
/// requested collector and the probe one per area, so the program's
/// largest reply (every collector once) holds 22 today. Past the cap the
/// session fails, which keeps one reply's memory within this many
/// [kMaxSectionBytes].
const kMaxReplySections = 32;

/// Why a session cannot continue (03 §6.2). The sampler must be
/// restarted; the assembler ignores everything after it reports one.
enum HwsSessionFault {
  /// No READY marker within [kMaxPreambleBytes] of output, or a malformed
  /// one: the login shell printed too much, or the program never started.
  noReady,

  /// READY carried a collector-set version other than
  /// [kCollectorSetVersion] (03 §6.3).
  versionMismatch,

  /// A READY of this version without `SELF` before it, a second `SELF`
  /// or READY, a section or end outside a reply, a begin inside one, or
  /// an end whose sequence number differs from its begin.
  outOfOrder,

  /// A reply held more than [kMaxReplySections] sections.
  tooManySections,
}

/// What [HwsTickAssembler] reports.
sealed class HwsTickEvent {
  const HwsTickEvent();
}

/// READY carried this client's collector-set version; requests may now be
/// written (03 §6.2).
final class HwsSessionReady extends HwsTickEvent {
  const HwsSessionReady(
    this.version, {
    required this.pid,
    required this.parentPid,
  });

  /// The collector-set version the program printed.
  final String version;

  /// The sampler shell's PID from the `SELF` marker, a protected target
  /// (03 §8.6).
  final int pid;

  /// The sampler shell's parent PID from the `SELF` marker: the sshd
  /// process serving the session, or 0 outside its PID namespace.
  final int parentPid;
}

/// One complete reply to a tick or on-demand request.
final class HwsTick extends HwsTickEvent {
  HwsTick(this.seq, this.uptimeSeconds, List<HwsSection> sections)
    : sections = List.unmodifiable(sections);

  /// Request sequence number from the `B` and `E` markers.
  final int seq;

  /// Host uptime at reply start; null when the host could not read it
  /// (see [HwsBegin.uptimeSeconds]).
  final double? uptimeSeconds;

  /// The sections in wire order.
  final List<HwsSection> sections;

  /// The first section named [collector], or null when the reply has none.
  HwsSection? section(String collector) {
    for (final s in sections) {
      if (s.collector == collector) return s;
    }
    return null;
  }
}

/// A reply lost to a framing error. Resynchronization reached its `E`
/// marker or a later reply's, so the request is finished, but its data is
/// gone and the client shows a gap (03 §6.2).
final class HwsTickLost extends HwsTickEvent {
  const HwsTickLost(this.seq, this.detail);

  /// Sequence number of the lost reply.
  final int seq;

  /// The parser's framing reason, for diagnostics; never shown as text.
  final String detail;
}

/// The session cannot continue; see [HwsSessionFault].
final class HwsSessionFailed extends HwsTickEvent {
  const HwsSessionFailed(this.fault, this.detail);

  /// Why the session ended.
  final HwsSessionFault fault;

  /// What was read, for diagnostics; never shown as text.
  final String detail;
}

enum _Phase { awaitingReady, idle, inReply, resync, failed }

/// Incremental reply assembler for one sampler session. Feed it the
/// session's stdout bytes in chunks of any size; [push] returns the
/// events they complete.
final class HwsTickAssembler {
  HwsTickAssembler({required String nonce})
    : _parser = HwsFrameParser(nonce: nonce);

  final HwsFrameParser _parser;
  _Phase _phase = _Phase.awaitingReady;

  /// The `SELF` marker, which comes just before READY.
  HwsSelf? _self;

  // The reply under assembly. [_openSeq] stays set through a resync, so
  // the reply the framing error interrupted is reported lost too.
  int? _openSeq;
  double? _openUptime;
  final List<HwsSection> _sections = [];
  String _lostDetail = '';

  /// Feeds [bytes] and returns every event they complete.
  List<HwsTickEvent> push(List<int> bytes) {
    if (_phase == _Phase.failed) return const [];
    final out = <HwsTickEvent>[];
    for (final e in _parser.push(bytes)) {
      _onEvent(e, out);
      if (_phase == _Phase.failed) break;
    }
    return out;
  }

  void _onEvent(HwsEvent e, List<HwsTickEvent> out) {
    switch ((_phase, e)) {
      case (_Phase.awaitingReady, final HwsSelf self) when _self == null:
        _self = self;

      // The version is checked first: a program of another version may
      // print no `SELF` at all, and the mismatch is the better diagnosis.
      case (_Phase.awaitingReady, HwsReady(:final version)):
        if (version != kCollectorSetVersion) {
          _fail(
            out,
            HwsSessionFault.versionMismatch,
            'READY $version, expected $kCollectorSetVersion',
          );
          return;
        }
        final self = _self;
        if (self == null) {
          _fail(out, HwsSessionFault.outOfOrder, 'READY without SELF');
          return;
        }
        _phase = _Phase.idle;
        out.add(
          HwsSessionReady(version, pid: self.pid, parentPid: self.parentPid),
        );

      case (_Phase.awaitingReady, HwsFramingError(:final reason)):
        _fail(out, HwsSessionFault.noReady, reason);

      case (_Phase.idle, HwsBegin(:final seq, :final uptimeSeconds)):
        _openSeq = seq;
        _openUptime = uptimeSeconds;
        _phase = _Phase.inReply;

      case (_Phase.inReply, final HwsSection section):
        if (_sections.length == kMaxReplySections) {
          _fail(
            out,
            HwsSessionFault.tooManySections,
            'reply $_openSeq exceeds $kMaxReplySections sections',
          );
          return;
        }
        _sections.add(section);

      case (_Phase.inReply, HwsEnd(:final seq)) when seq == _openSeq:
        out.add(HwsTick(seq, _openUptime, _sections));
        _closeReply();

      case (_Phase.idle || _Phase.inReply, HwsFramingError(:final reason)):
        _lostDetail = reason;
        _phase = _Phase.resync;

      case (_Phase.resync, HwsEnd(:final seq)):
        final open = _openSeq;
        if (open != null && open != seq) {
          out.add(HwsTickLost(open, _lostDetail));
        }
        out.add(HwsTickLost(seq, _lostDetail));
        _closeReply();

      case _:
        _fail(
          out,
          HwsSessionFault.outOfOrder,
          '${_label(e)} while ${_phase.name} (open reply: $_openSeq)',
        );
    }
  }

  void _closeReply() {
    _openSeq = null;
    _openUptime = null;
    _sections.clear();
    _lostDetail = '';
    _phase = _Phase.idle;
  }

  void _fail(List<HwsTickEvent> out, HwsSessionFault fault, String detail) {
    _phase = _Phase.failed;
    _sections.clear();
    out.add(HwsSessionFailed(fault, detail));
  }

  static String _label(HwsEvent e) => switch (e) {
    HwsReady(:final version) => 'READY $version',
    HwsSelf(:final pid, :final parentPid) => 'SELF $pid $parentPid',
    HwsBegin(:final seq) => 'B $seq',
    HwsSection(:final collector) => 'S $collector',
    HwsEnd(:final seq) => 'E $seq',
    HwsFramingError(:final reason) => 'framing error: $reason',
  };
}
