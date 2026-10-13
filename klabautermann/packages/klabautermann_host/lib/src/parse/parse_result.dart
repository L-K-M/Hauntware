/// Shared result and context types for the collector payload parsers
/// (03 §3.3, §6.5).
///
/// Parsers are pure, tolerant of truncation, extra fields and non-UTF-8
/// bytes, and never throw on host input: they return a value plus warnings.
library;

import 'package:meta/meta.dart';

/// What one collector parser produced (03 §3.3): a value plus warnings.
/// An empty [warnings] list means the payload parsed cleanly.
@immutable
final class ParseResult<T> {
  const ParseResult(this.value, [this.warnings = const []]);

  /// The parsed snapshot or profile; always present, possibly partial.
  final T value;

  /// Human-readable notes about tolerated anomalies, in encounter order.
  final List<String> warnings;
}

/// Per-host parsing context (03 §3.3). Carries the facts later parsers
/// need that the raw payload does not hold; part 1 only needs the host
/// counter width, which feeds the rate maths of 03 §6.4 (CN-04).
@immutable
final class ParseContext {
  const ParseContext({this.counterWidth = CounterWidth.bits64});

  /// Width of the kernel's `/proc` counters (`unsigned long` on most
  /// hosts): 32 on 32-bit kernels, 64 elsewhere. Unknown stays 64, where
  /// a decrease is treated as a reset rather than a wrap.
  final CounterWidth counterWidth;

  /// The default context: 64-bit counters.
  static const standard = ParseContext();
}

/// The width of a monotonically increasing `/proc` counter (03 §6.4,
/// CN-04). The width decides what a decreasing reading means: a 32-bit
/// counter wraps (gigabit links roll `/proc/net/dev` over in under a
/// minute), while a 64-bit one cannot wrap, so a decrease is a reset.
enum CounterWidth {
  /// 32-bit counter; a decrease is a wrap, continued modulo 2^32.
  bits32,

  /// 64-bit counter; a decrease is a reset and yields no delta.
  bits64,
}
