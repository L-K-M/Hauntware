/// HWS/1 request encoding: the `hw_t` and `hw_o` command lines the client
/// writes to the sampler's stdin (03 §6.2).
///
/// Collector names come from [Collector] only, and `hw_o` arguments pass
/// the collector's validators and then the injected quoting function (the
/// app supplies Séance's `quoteShellWord`; 03 §8.8). An invalid request is
/// refused with [HwsRequestError] before any text is produced.
library;

import 'collector.dart';

/// Quotes one word for the remote shell. Injected because the
/// implementation (`quoteShellWord`) lives in `seance_core`, which this
/// package must not depend on (03 §3.4 `forbidden_dependencies`).
typedef ShellQuote = String Function(String word);

/// A request refused before encoding (03 §8.8): bad arity, an argument a
/// validator rejected, or a bad sequence number.
final class HwsRequestError implements Exception {
  const HwsRequestError(this.reason, {this.collector, this.argument});

  /// Why the request was refused.
  final String reason;

  /// The collector the request targeted, when relevant.
  final Collector? collector;

  /// The offending argument, when relevant.
  final String? argument;

  @override
  String toString() {
    final c = collector == null ? '' : ' for ${collector!.wireName}';
    final a = argument == null ? '' : ' (argument: $argument)';
    return 'HwsRequestError$c: $reason$a';
  }
}

/// `hw_t <seq> <collector>...` plus the newline that submits it (03 §6.2).
/// A collector that takes arguments is refused: a tick passes none, so it
/// is requested through [encodeOnDemandRequest] only.
String encodeTickRequest(int seq, List<Collector> collectors) {
  _checkSeq(seq);
  if (collectors.isEmpty) {
    throw const HwsRequestError('a tick requests at least one collector');
  }
  for (final c in collectors) {
    if (c.argValidators.isNotEmpty) {
      throw HwsRequestError('takes arguments, so only hw_o', collector: c);
    }
  }
  return 'hw_t $seq ${collectors.map((c) => c.wireName).join(' ')}\n';
}

/// `hw_o <seq> <collector> <arg>...` plus the newline (03 §6.2).
///
/// The argument count must equal [Collector.argValidators]' length and
/// every argument must pass its positional validator; a refused request
/// throws [HwsRequestError] before producing text. Valid arguments go
/// through [quote] before joining the line.
String encodeOnDemandRequest(
  int seq,
  Collector collector,
  List<String> args, {
  required ShellQuote quote,
}) {
  _checkSeq(seq);
  final validators = collector.argValidators;
  if (args.length != validators.length) {
    throw HwsRequestError(
      'expects ${validators.length} argument(s), got ${args.length}',
      collector: collector,
    );
  }
  final b = StringBuffer('hw_o $seq ${collector.wireName}');
  for (var i = 0; i < args.length; i++) {
    final reason = validators[i](args[i]);
    if (reason != null) {
      throw HwsRequestError(reason, collector: collector, argument: args[i]);
    }
    b
      ..write(' ')
      ..write(quote(args[i]));
  }
  b.write('\n');
  return b.toString();
}

void _checkSeq(int seq) {
  if (seq < 0) {
    throw HwsRequestError('seq must be non-negative, got $seq');
  }
}
