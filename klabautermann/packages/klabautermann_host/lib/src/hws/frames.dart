/// The HWS/1 frame parser (03 §6.2 "Replies").
///
/// Replies are framed by the session nonce and length-prefixed:
/// `␣-nonce-B-seq-uptime` opens a tick (with `\036` as the leading
/// separator and spaces between fields), `S collector status bytes` opens
/// a section followed by a newline, exactly `bytes` payload bytes and a
/// newline, and `E seq` closes the tick. A forged marker inside a payload
/// is consumed as payload, so forgery fails even if a nonce leaks. Any
/// framing mismatch resynchronizes on the next `E` marker carrying this
/// parser's nonce. Before the first marker (`SELF`, then READY), output
/// that does not start a marker for this nonce is skipped up to
/// [kMaxPreambleBytes].
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'collector.dart';

/// Byte that opens every marker (ASCII record separator, 03 §6.2).
const kMarkerByte = 0x1e;

/// Upper bound on one section's declared payload (03 §6.5). A larger
/// `<bytes>` field is a framing error, so memory stays bounded.
const kMaxSectionBytes = 1 << 20;

/// Upper bound on a marker line. Markers carry a nonce, one letter and a
/// few small fields; a longer line is a framing error.
const kMaxMarkerBytes = 256;

/// Upper bound on the output skipped before the READY marker. The login
/// shell runs its startup files before it parses the start command, and
/// some print banners even when not interactive; more output than this
/// fails the start instead of being read indefinitely.
const kMaxPreambleBytes = 64 * 1024;

/// The status a section reports (03 §6.2).
enum SectionStatus {
  /// Collector ran and produced its payload.
  ok,

  /// The tool the collector needs is absent on the host.
  missing,

  /// The collector was refused (permission error), captured in the payload.
  denied,

  /// The `timeout` guard stopped the collector (slow sampler only).
  timeout,

  /// Anything else; the payload carries the captured stderr.
  error,
}

/// An event the frame parser emits (03 §6.2).
sealed class HwsEvent {
  const HwsEvent();
}

/// The program's READY marker: protocol tag plus collector-set version.
final class HwsReady extends HwsEvent {
  const HwsReady(this.version);

  /// The collector-set version of the running program (03 §6.3).
  final String version;
}

/// `SELF <pid> <ppid>`, printed just before READY: the sampler shell's
/// `$$` and `$PPID`, which the protected targets need (03 §8.6).
final class HwsSelf extends HwsEvent {
  const HwsSelf(this.pid, this.parentPid);

  /// The sampler shell's PID.
  final int pid;

  /// Its parent's PID: the sshd process serving the session, or 0 when
  /// the parent lies outside the shell's PID namespace.
  final int parentPid;
}

/// `B <seq> <uptime>`: a tick or on-demand reply begins.
final class HwsBegin extends HwsEvent {
  const HwsBegin(this.seq, this.uptimeSeconds);

  /// Request sequence number.
  final int seq;

  /// `/proc/uptime` field 1 on the host at tick start; the client derives
  /// rate intervals from the delta between two ticks' uptimes. Null when
  /// the host could not read `/proc/uptime` and printed an empty field.
  final double? uptimeSeconds;
}

/// `S <collector> <status> <bytes>` plus the payload that followed it.
final class HwsSection extends HwsEvent {
  const HwsSection(this.collector, this.status, this.payload);

  /// Section name: a collector wire name or a probe area
  /// (`probe_<area>`, 03 §6.1).
  final String collector;

  /// Whether the payload is real output, an error text or absent.
  final SectionStatus status;

  /// Exactly `<bytes>` bytes as emitted; may be empty (never null).
  final Uint8List payload;
}

/// `E <seq>`: a tick or on-demand reply is complete.
final class HwsEnd extends HwsEvent {
  const HwsEnd(this.seq);

  /// Request sequence number.
  final int seq;
}

/// A framing violation; the parser resynchronizes on the next `E` marker
/// for this nonce and emits it as [HwsEnd].
final class HwsFramingError extends HwsEvent {
  const HwsFramingError(this.reason);

  /// What failed to parse.
  final String reason;
}

enum _State { preReady, marker, payload, payloadNewline, resync }

final _noncePattern = RegExp(r'^[0-9a-f]{32}$');

/// `/proc/uptime` prints seconds with two decimals; `double.tryParse`
/// alone would also accept `NaN`, `Infinity` and exponents.
final _uptimePattern = RegExp(r'^[0-9]+(\.[0-9]+)?$');

/// Incremental parser for one session's reply stream. Accepts byte chunks
/// of any size; [push] returns the events the new bytes complete (possibly
/// none).
final class HwsFrameParser {
  HwsFrameParser({required String nonce}) : _nonceBytes = latin1.encode(nonce) {
    if (!_noncePattern.hasMatch(nonce)) {
      throw ArgumentError.value(nonce, 'nonce', 'must be 32 hex digits');
    }
    _prefix = Uint8List.fromList([kMarkerByte, ..._nonceBytes, 0x20]);
    _needle = Uint8List.fromList([..._prefix, 0x45, 0x20]); // 'E' ' '
  }

  final List<int> _nonceBytes;

  /// `\036<nonce> ` — the start of every marker for this nonce.
  late final Uint8List _prefix;

  /// `\036<nonce> E ` — the resynchronization needle (03 §6.2).
  late final Uint8List _needle;

  _State _state = _State.preReady;

  /// Bytes dropped before READY, bounded by [kMaxPreambleBytes].
  int _preambleBytes = 0;

  /// Unconsumed input; bounded by [kMaxMarkerBytes] while seeking markers
  /// and by the resync logic otherwise.
  final List<int> _buf = [];

  // Pending section under assembly.
  final List<int> _payload = [];
  String _pendingCollector = '';
  SectionStatus _pendingStatus = SectionStatus.error;
  int _payloadRemaining = 0;

  /// Feeds [bytes] and returns every event they complete.
  List<HwsEvent> push(List<int> bytes) {
    _buf.addAll(bytes);
    final events = <HwsEvent>[];
    var progress = true;
    while (progress) {
      progress = false;
      switch (_state) {
        case _State.preReady:
          progress = _preReadyStep(events);
        case _State.marker:
          progress = _markerStep(events);
        case _State.payload:
          progress = _payloadStep();
        case _State.payloadNewline:
          progress = _payloadNewlineStep(events);
        case _State.resync:
          progress = _resyncStep(events);
      }
    }
    return events;
  }

  // -- state handlers -------------------------------------------------

  /// Drops everything before the first marker for this nonce, which must
  /// be `SELF` or READY (03 §6.2); the session layer checks their order.
  /// The login shell's startup files may print partial lines, carriage
  /// returns or stray `\036` bytes, so the scan is byte-wise rather than
  /// line-wise.
  bool _preReadyStep(List<HwsEvent> events) {
    final at = _prefixCandidate();
    final noise = at < 0 ? _buf.length : at;
    if (noise > 0) {
      _take(noise);
      _preambleBytes += noise;
    }
    if (_preambleBytes > kMaxPreambleBytes) {
      _fail(events, 'no READY marker within $kMaxPreambleBytes bytes');
      return true;
    }
    if (_buf.length < _prefix.length) return false; // none yet, or partial

    final nl = _buf.indexOf(0x0a, _prefix.length);
    if (nl > kMaxMarkerBytes || (nl < 0 && _buf.length > kMaxMarkerBytes)) {
      _fail(events, 'marker line exceeds $kMaxMarkerBytes bytes');
      return true;
    }
    if (nl < 0) return false;

    final line = _take(nl + 1);
    final body = latin1.decode(line.sublist(_prefix.length, nl));
    const readyKind = 'READY ';
    const selfKind = 'SELF ';
    if (body.startsWith(selfKind)) {
      _state = _State.marker;
      _parseSelf(body.substring(selfKind.length), events);
      return true;
    }
    if (!body.startsWith(readyKind)) {
      _fail(events, 'marker before READY');
      return true;
    }
    _state = _State.marker;
    _parseReady(body.substring(readyKind.length), events);
    return true;
  }

  bool _markerStep(List<HwsEvent> events) {
    final nl = _buf.indexOf(0x0a);
    if (nl < 0) {
      if (_buf.length > kMaxMarkerBytes) {
        _fail(events, 'marker line exceeds $kMaxMarkerBytes bytes');
        return true;
      }
      return false;
    }
    if (nl > kMaxMarkerBytes) {
      _fail(events, 'marker line exceeds $kMaxMarkerBytes bytes');
      return true;
    }
    // The newline terminates the marker line; consume it too or it would
    // be read as a payload byte.
    final line = _take(nl + 1);
    _parseMarkerLine(line.sublist(0, nl), events);
    return true;
  }

  bool _payloadStep() {
    if (_buf.isEmpty) return false;
    final n = min(_payloadRemaining, _buf.length);
    _payload.addAll(_take(n));
    _payloadRemaining -= n;
    if (_payloadRemaining == 0) {
      _state = _State.payloadNewline;
    }
    return true;
  }

  bool _payloadNewlineStep(List<HwsEvent> events) {
    if (_buf.isEmpty) return false;
    // The section is only valid once its newline terminator is confirmed
    // (03 §6.2): a wrong terminator is a framing error, so the section is
    // never emitted for a payload the wire did not delimit.
    if (_buf[0] != 0x0a) {
      _fail(events, 'section payload not followed by a newline');
      return true;
    }
    _take(1);
    events.add(
      HwsSection(
        _pendingCollector,
        _pendingStatus,
        Uint8List.fromList(_payload),
      ),
    );
    _payload.clear();
    _state = _State.marker;
    return true;
  }

  /// Scans for `\036<nonce> E <seq>\n`, drops everything else, and emits
  /// the end marker once found (03 §6.2 resynchronization).
  bool _resyncStep(List<HwsEvent> events) {
    while (true) {
      final i = _buf.indexOf(kMarkerByte);
      if (i < 0) {
        _buf.clear();
        return false;
      }
      if (i > 0) _take(i);
      final cmp = min(_buf.length, _needle.length);
      var match = true;
      for (var j = 0; j < cmp; j++) {
        if (_buf[j] != _needle[j]) {
          match = false;
          break;
        }
      }
      if (!match) {
        _take(1); // this \036 starts no marker for our nonce
        continue;
      }
      if (_buf.length < _needle.length) return false; // partial needle
      final nl = _buf.indexOf(0x0a, _needle.length);
      if (nl < 0) {
        if (_buf.length > kMaxMarkerBytes) {
          _take(1); // no terminator in sight: not a real marker
          continue;
        }
        return false;
      }
      final seq = _parseUint(_buf.sublist(_needle.length, nl));
      _take(nl + 1);
      if (seq == null) continue; // malformed E marker; keep resyncing
      _state = _State.marker;
      events.add(HwsEnd(seq));
      return true;
    }
  }

  // -- marker parsing -------------------------------------------------

  void _parseMarkerLine(List<int> line, List<HwsEvent> events) {
    if (line.length < 35 || line[0] != kMarkerByte || line[33] != 0x20) {
      _fail(events, 'malformed marker line');
      return;
    }
    for (var j = 0; j < 32; j++) {
      if (line[j + 1] != _nonceBytes[j]) {
        _fail(events, 'marker carries a wrong nonce');
        return;
      }
    }
    final body = latin1.decode(line.sublist(34));
    final sp1 = body.indexOf(' ');
    final kind = sp1 < 0 ? body : body.substring(0, sp1);
    final rest = sp1 < 0 ? '' : body.substring(sp1 + 1);
    switch (kind) {
      case 'READY':
        _parseReady(rest, events);
      case 'SELF':
        _parseSelf(rest, events);
      case 'B':
        _parseBegin(rest, events);
      case 'S':
        _parseSection(rest, events);
      case 'E':
        _parseEnd(rest, events);
      default:
        _fail(events, 'unknown marker kind');
    }
  }

  void _parseReady(String rest, List<HwsEvent> events) {
    // `READY HWS/1 <collector-set version>` (03 §6.3).
    final parts = rest.split(' ');
    if (parts.length != 2 || parts[0] != 'HWS/1' || parts[1].isEmpty) {
      _fail(events, 'malformed READY marker');
      return;
    }
    events.add(HwsReady(parts[1]));
  }

  void _parseSelf(String rest, List<HwsEvent> events) {
    // `SELF <pid> <ppid>`; the shell's own PID is never 0.
    final parts = rest.split(' ');
    final pid = parts.length == 2 ? _parseUintStr(parts[0]) : null;
    final parentPid = parts.length == 2 ? _parseUintStr(parts[1]) : null;
    if (pid == null || pid == 0 || parentPid == null) {
      _fail(events, 'malformed SELF marker');
      return;
    }
    events.add(HwsSelf(pid, parentPid));
  }

  void _parseBegin(String rest, List<HwsEvent> events) {
    // `B <seq> <uptime>`; an empty uptime is valid (see [HwsBegin]).
    final parts = rest.split(' ');
    final seq = parts.length == 2 ? _parseUintStr(parts[0]) : null;
    final uptimeText = parts.length == 2 ? parts[1] : '';
    final uptimeValid =
        uptimeText.isEmpty || _uptimePattern.hasMatch(uptimeText);
    if (seq == null || !uptimeValid) {
      _fail(events, 'malformed B marker');
      return;
    }
    final uptime = uptimeText.isEmpty ? null : double.parse(uptimeText);
    events.add(HwsBegin(seq, uptime));
  }

  void _parseSection(String rest, List<HwsEvent> events) {
    final parts = rest.split(' ');
    if (parts.length != 3) {
      _fail(events, 'malformed S marker');
      return;
    }
    if (!collectorWireNamePattern.hasMatch(parts[0])) {
      _fail(events, 'section name violates the wire grammar');
      return;
    }
    final status = switch (parts[1]) {
      'ok' => SectionStatus.ok,
      'missing' => SectionStatus.missing,
      'denied' => SectionStatus.denied,
      'timeout' => SectionStatus.timeout,
      'error' => SectionStatus.error,
      _ => null,
    };
    if (status == null) {
      _fail(events, 'unknown section status');
      return;
    }
    final bytes = _parseUintStr(parts[2]);
    if (bytes == null || bytes > kMaxSectionBytes) {
      _fail(events, 'section byte count missing or over the cap');
      return;
    }
    _pendingCollector = parts[0];
    _pendingStatus = status;
    _payloadRemaining = bytes;
    _payload.clear();
    _state = bytes == 0 ? _State.payloadNewline : _State.payload;
  }

  void _parseEnd(String rest, List<HwsEvent> events) {
    final seq = _parseUintStr(rest);
    if (seq == null) {
      _fail(events, 'malformed E marker');
      return;
    }
    events.add(HwsEnd(seq));
  }

  // -- helpers --------------------------------------------------------

  void _fail(List<HwsEvent> events, String reason) {
    events.add(HwsFramingError(reason));
    _state = _State.resync;
  }

  /// Index of the first `\036` that starts [_prefix], fully or cut off by
  /// the end of the buffer; -1 when there is none.
  int _prefixCandidate() {
    for (var i = _buf.indexOf(kMarkerByte); i >= 0;) {
      final n = min(_prefix.length, _buf.length - i);
      var j = 0;
      while (j < n && _buf[i + j] == _prefix[j]) {
        j++;
      }
      if (j == n) return i;
      i = _buf.indexOf(kMarkerByte, i + 1);
    }
    return -1;
  }

  List<int> _take(int n) {
    final head = _buf.sublist(0, n);
    _buf.removeRange(0, n);
    return head;
  }

  int? _parseUint(List<int> digits) {
    if (digits.isEmpty || digits.length > 18) return null;
    var v = 0;
    for (final b in digits) {
      if (b < 0x30 || b > 0x39) return null;
      v = v * 10 + (b - 0x30);
    }
    return v;
  }

  int? _parseUintStr(String s) =>
      s.isEmpty ? null : _parseUint(latin1.encode(s));
}

/// Strips control characters other than newline and tab for display
/// (03 §6.2). C0, DEL and the C1 range go; printable text, tab and
/// newlines stay.
String stripControlChars(String text) {
  final b = StringBuffer();
  for (final r in text.runes) {
    final keep =
        r == 0x0a ||
        r == 0x09 ||
        (r > 0x1f && r != 0x7f && (r < 0x80 || r > 0x9f));
    if (keep) b.writeCharCode(r);
  }
  return b.toString();
}
