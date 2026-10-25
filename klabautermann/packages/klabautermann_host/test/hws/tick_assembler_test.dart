// Tick assembler tests (03 §6.2): SELF, READY and its collector-set
// version, complete replies, replies lost to framing errors, and the out-of-order
// markers that end a session.
import 'dart:convert';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const nonce = '0123456789abcdef0123456789abcdef';

List<int> _marker(String body) => utf8.encode('\x1e$nonce $body\n');

List<int> _section(String collector, String payload) {
  final p = utf8.encode(payload);
  return [
    ...utf8.encode('\x1e$nonce S $collector ok ${p.length}\n'),
    ...p,
    0x0a,
  ];
}

final _self = _marker('SELF 4242 4241');

final _ready = [..._self, ..._marker('READY HWS/1 $kCollectorSetVersion')];

List<int> _reply(int seq) => [
  ..._marker('B $seq 12.50'),
  ..._section('overview', '== loadavg ==\n0.10 0.20 0.30 1/100 4242'),
  ..._section('core', '== uptime ==\n12.50 3.00'),
  ..._marker('E $seq'),
];

String _describe(HwsTickEvent e) => switch (e) {
  HwsSessionReady(:final version) => 'ready $version',
  HwsTick(:final seq, :final uptimeSeconds, :final sections) =>
    'tick $seq $uptimeSeconds ${sections.map((s) => s.collector).join(',')}',
  HwsTickLost(:final seq) => 'lost $seq',
  HwsSessionFailed(:final fault) => 'failed ${fault.name}',
};

List<String> _assemble(List<int> bytes) =>
    HwsTickAssembler(nonce: nonce).push(bytes).map(_describe).toList();

void main() {
  test('reports READY, then each complete reply', () {
    final events = HwsTickAssembler(
      nonce: nonce,
    ).push([...utf8.encode('banner\n'), ..._ready, ..._reply(1), ..._reply(2)]);
    expect(events.map(_describe), [
      'ready $kCollectorSetVersion',
      'tick 1 12.5 overview,core',
      'tick 2 12.5 overview,core',
    ]);

    final ready = events.first as HwsSessionReady;
    expect((ready.pid, ready.parentPid), (4242, 4241));

    final tick = events[1] as HwsTick;
    expect(utf8.decode(tick.section('core')!.payload), contains('3.00'));
    expect(tick.section('fs'), isNull);
    expect(() => tick.sections.clear(), throwsUnsupportedError);
  });

  test('assembles the same replies at every split point', () {
    final bytes = [..._ready, ..._reply(1)];
    final expected = _assemble(bytes);
    for (var split = 1; split < bytes.length; split++) {
      final assembler = HwsTickAssembler(nonce: nonce);
      final events = [
        ...assembler.push(bytes.sublist(0, split)),
        ...assembler.push(bytes.sublist(split)),
      ];
      expect(events.map(_describe), expected, reason: 'split at $split');
    }
  });

  test('an empty uptime and an empty reply still complete', () {
    expect(_assemble([..._ready, ..._marker('B 4 '), ..._marker('E 4')]), [
      'ready $kCollectorSetVersion',
      'tick 4 null ',
    ]);
  });

  group('section cap', () {
    List<int> replyWith(int sections) => [
      ..._ready,
      ..._marker('B 1 1.00'),
      for (var i = 0; i < sections; i++) ..._section('core', 'x'),
      ..._marker('E 1'),
    ];

    test('a reply at the cap completes', () {
      expect(
        _assemble(replyWith(kMaxReplySections)).last,
        startsWith('tick 1'),
      );
    });

    test('a reply over the cap ends the session', () {
      final assembler = HwsTickAssembler(nonce: nonce);
      expect(assembler.push(replyWith(kMaxReplySections + 1)).map(_describe), [
        'ready $kCollectorSetVersion',
        'failed tooManySections',
      ]);
      expect(assembler.push(_reply(2)), isEmpty);
    });

    test('the largest reply the program emits stays within the cap', () {
      // Every collector but the probe emits one section; the probe emits
      // one per area function it calls.
      final program = buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce);
      final areas = RegExp(
        r'^  _probe_[a-z]+$',
        multiLine: true,
      ).allMatches(program).length;
      expect(areas, greaterThan(0));
      expect(
        areas + Collector.values.length - 1,
        lessThanOrEqualTo(kMaxReplySections),
      );
    });
  });

  group('session failures', () {
    test('a READY with another collector-set version', () {
      final assembler = HwsTickAssembler(nonce: nonce);
      expect(
        assembler
            .push([..._marker('READY HWS/1 0'), ..._reply(1)])
            .map(_describe),
        ['failed versionMismatch'],
      );
      expect(assembler.push(_reply(2)), isEmpty);
    });

    test('a version 7 program, which prints no SELF', () {
      // The READY version check (03 §6.3) runs before the SELF check, so
      // an older program reads as the mismatch it is.
      expect(_assemble([..._marker('READY HWS/1 7'), ..._reply(1)]), [
        'failed versionMismatch',
      ]);
      expect(kCollectorSetVersion, '11');
    });

    test('a second SELF before READY', () {
      expect(
        _assemble([
          ..._self,
          ..._marker('SELF 1 2'),
          ..._marker('READY HWS/1 $kCollectorSetVersion'),
        ]),
        ['failed outOfOrder'],
      );
    });

    test('a READY of this version without SELF', () {
      expect(
        _assemble([
          ..._marker('READY HWS/1 $kCollectorSetVersion'),
          ..._reply(1),
        ]),
        ['failed outOfOrder'],
      );
    });

    for (final bad in [
      'SELF',
      'SELF 1',
      'SELF 0 1',
      'SELF x 1',
      'SELF 1 2 3',
    ]) {
      test('a malformed SELF: "$bad"', () {
        expect(_assemble([..._marker(bad), ..._ready]), ['failed noReady']);
      });
    }

    test('a parent PID of 0 is valid', () {
      final events = HwsTickAssembler(nonce: nonce).push([
        ..._marker('SELF 7 0'),
        ..._marker('READY HWS/1 $kCollectorSetVersion'),
      ]);
      final ready = events.single as HwsSessionReady;
      expect((ready.pid, ready.parentPid), (7, 0));
    });

    test('no READY within the preamble cap', () {
      final events = _assemble([
        ...List.filled(kMaxPreambleBytes + 1, 0x78),
        ..._ready,
        ..._reply(1),
      ]);
      expect(events, ['failed noReady']);
    });

    test('a malformed READY', () {
      expect(_assemble([..._marker('READY HWS/1'), ..._reply(1)]), [
        'failed noReady',
      ]);
    });

    final outOfOrder = <String, List<int>>{
      'a second READY': [..._ready, ..._ready],
      'a second SELF before READY': [..._self, ..._ready],
      'a SELF after READY': [..._ready, ..._self],
      'a section outside a reply': [
        ..._ready,
        ..._section('core', 'x'),
        ..._marker('E 1'),
      ],
      'an end outside a reply': [..._ready, ..._marker('E 1')],
      'a begin inside a reply': [
        ..._ready,
        ..._marker('B 1 1.00'),
        ..._marker('B 2 1.00'),
      ],
      'an end for another sequence number': [
        ..._ready,
        ..._marker('B 1 1.00'),
        ..._marker('E 2'),
      ],
    };
    for (final MapEntry(key: name, value: bytes) in outOfOrder.entries) {
      test('$name ends the session', () {
        final assembler = HwsTickAssembler(nonce: nonce);
        final events = assembler.push(bytes).map(_describe).toList();
        expect(events.last, 'failed outOfOrder');
        expect(assembler.push(_reply(3)), isEmpty);
      });
    }
  });

  group('lost replies', () {
    test('a framing error inside a reply loses that reply only', () {
      final events = _assemble([
        ..._ready,
        ..._marker('B 1 1.00'),
        ...utf8.encode('\x1e$nonce S overview ok 3\nabcX'),
        ..._marker('E 1'),
        ..._reply(2),
      ]);
      expect(events, [
        'ready $kCollectorSetVersion',
        'lost 1',
        'tick 2 12.5 overview,core',
      ]);
    });

    test('a framing error between replies loses the next one', () {
      // The resynchronizing scan skips reply 2's begin marker, so reply 2
      // is lost when its end marker arrives.
      final events = _assemble([
        ..._ready,
        ..._reply(1),
        ...utf8.encode('stray output\n'),
        ..._reply(2),
        ..._reply(3),
      ]);
      expect(events, [
        'ready $kCollectorSetVersion',
        'tick 1 12.5 overview,core',
        'lost 2',
        'tick 3 12.5 overview,core',
      ]);
    });

    test('a resynchronizing end for a later reply loses both', () {
      final events = _assemble([
        ..._ready,
        ..._marker('B 1 1.00'),
        ..._marker('X'), // unknown kind: framing error, resync
        ..._marker('E x'), // malformed: resync continues past reply 1
        ..._marker('B 2 1.00'),
        ..._marker('E 2'),
      ]);
      expect(events, ['ready $kCollectorSetVersion', 'lost 1', 'lost 2']);
    });

    test('the lost reply carries the framing reason for diagnostics', () {
      final events = HwsTickAssembler(nonce: nonce).push([
        ..._ready,
        ..._marker('B 1 1.00'),
        ..._marker('X'),
        ..._marker('E 1'),
      ]);
      expect((events.last as HwsTickLost).detail, 'unknown marker kind');
    });
  });
}
