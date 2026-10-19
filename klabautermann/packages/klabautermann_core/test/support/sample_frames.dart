// HWS/1 replies for sample-pipeline tests, framed as a sampler prints
// them and assembled by the library's own reader, so a test feeds the
// pipeline what SamplerSession delivers (03 §6.2).
import 'dart:convert';

import 'package:klabautermann_core/src/sampling/sampler_session.dart';
import 'package:klabautermann_host/klabautermann_host.dart';

const _nonce = '0123456789abcdef0123456789abcdef';

/// One section of a reply: the collector or probe area, its status and
/// payload.
typedef TestSection = (String name, SectionStatus status, String payload);

/// An `ok` section of [collector] with [payload].
TestSection ok(String collector, String payload) =>
    (collector, SectionStatus.ok, payload);

/// The reply numbered [seq] with [sections], whose `B` marker carries
/// [uptime] (empty when null), as [SamplerSession] hands it over.
SamplerReplied reply(int seq, double? uptime, List<TestSection> sections) {
  List<int> marker(String body) => utf8.encode('\x1e$_nonce $body\n');
  final bytes = [
    ...marker('SELF 4242 4241'),
    ...marker('READY HWS/1 $kCollectorSetVersion'),
    ...marker('B $seq ${uptime?.toStringAsFixed(2) ?? ''}'),
    for (final (name, status, payload) in sections) ...[
      ...marker('S $name ${status.name} ${utf8.encode(payload).length}'),
      ...utf8.encode(payload),
      0x0a,
    ],
    ...marker('E $seq'),
  ];
  final events = HwsTickAssembler(nonce: _nonce).push(bytes);
  return SamplerReplied(events.whereType<HwsTick>().single);
}
