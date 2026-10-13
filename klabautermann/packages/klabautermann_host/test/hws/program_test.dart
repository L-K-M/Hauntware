// HWS/1 program assembly tests (03 §6.2, §6.3): the nonce line, the two
// sampler kinds, the READY marker and the no-user-text rule.
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

void main() {
  group('generateNonce', () {
    test('renders 128 bits as 32 hex digits', () {
      final nonce = generateNonce(Random.secure());
      expect(nonce, matches(RegExp(r'^[0-9a-f]{32}$')));
    });

    test('is a pure function of the supplied random source', () {
      expect(generateNonce(Random(7)), generateNonce(Random(7)));
      expect(generateNonce(Random(7)), isNot(generateNonce(Random(8))));
    });
  });

  group('collectors', () {
    test('every wire name matches the grammar', () {
      for (final c in Collector.values) {
        expect(c.wireName, matches(collectorWireNamePattern), reason: c.name);
      }
    });

    test('byName round-trips and rejects unknown names', () {
      for (final c in Collector.values) {
        expect(Collector.byName(c.wireName), c);
      }
      expect(Collector.byName('nope'), isNull);
    });

    test('the fragments cover every collector', () {
      expect(collectorFragments.keys, containsAll(Collector.values));
    });
  });

  group('buildSamplerProgram', () {
    const nonce = '0123456789abcdef0123456789abcdef';

    test('puts the nonce line first and nowhere else', () {
      final program = buildSamplerProgram(kind: SamplerKind.fast, nonce: nonce);
      final lines = program.split('\n');
      expect(lines.first, 'N=$nonce');
      expect(
        lines.where((l) => l.contains(nonce)),
        hasLength(1),
        reason: 'the nonce is written once',
      );
    });

    test('defines hw_t and hw_o on both samplers', () {
      for (final kind in SamplerKind.values) {
        final program = buildSamplerProgram(kind: kind, nonce: nonce);
        expect(program, contains('hw_t()'));
        expect(program, contains('hw_o()'));
        expect(program, contains('</dev/null'));
      }
    });

    test('the fast program carries only builtin collectors', () {
      final program = buildSamplerProgram(kind: SamplerKind.fast, nonce: nonce);
      expect(program, contains('c_overview()'));
      expect(program, contains('c_core()'));
      for (final c in [
        'fs',
        'identity',
        'probe',
        'procs',
        'units',
        'timers',
        'cron',
      ]) {
        expect(program, isNot(contains('c_$c()')), reason: c);
      }
    });

    test('the slow program carries only forking collectors', () {
      final program = buildSamplerProgram(kind: SamplerKind.slow, nonce: nonce);
      for (final c in [
        'fs',
        'identity',
        'probe',
        'procs',
        'units',
        'timers',
        'cron',
      ]) {
        expect(program, contains('c_$c()'), reason: c);
      }
      expect(program, isNot(contains('c_overview()')));
      expect(program, isNot(contains('c_core()')));
    });

    test('the READY marker is the program last line', () {
      for (final kind in SamplerKind.values) {
        final program = buildSamplerProgram(kind: kind, nonce: nonce);
        final trimmed = program.trimRight();
        expect(
          trimmed,
          endsWith(
            'printf \'\\036%s READY HWS/1 $kCollectorSetVersion\\n\' "\$N"',
          ),
        );
        expect(program, contains('READY HWS/1 $kCollectorSetVersion'));
      }
    });

    test('a bad nonce is refused before assembly', () {
      for (final bad in ['', 'xyz', '0123', 'a' * 31, 'a' * 33]) {
        expect(
          () => buildSamplerProgram(kind: SamplerKind.fast, nonce: bad),
          throwsArgumentError,
          reason: bad,
        );
      }
    });
  });

  test('the probe tool list carries the documented tools', () {
    expect(
      kProbeTools,
      containsAll(<String>['journalctl', 'timeout', 'docker']),
    );
    expect(kProbeTools, hasLength(26));
  });
}
