import 'dart:io';

import 'package:poltergeist_m0_bench/fixture_data.dart';
import 'package:poltergeist_m0_bench/result_manifest.dart'
    show affordableThroughputCells, standardThroughputTrialSpecs;
import 'package:poltergeist_m0_bench/src/throughput_execution.dart'
    show inspectThroughputFile, throughputTrialOrder;
import 'package:poltergeist_m0_bench/throughput.dart';
import 'package:poltergeist_m0_bench/throughput_attempt.dart';
import 'package:test/test.dart';

void main() {
  group('ThroughputSlice', () {
    test('full includes every transfer', () {
      expect(_selectedTransfers(ThroughputSlice.full), hasLength(6));
    });

    test('standard shaped slice excludes both 1 GB directions', () {
      expect(_selectedTransfers(ThroughputSlice.withoutShapedOneGigabyte), [
        (ThroughputLeg.download, fixturePayload1MbBytes),
        (ThroughputLeg.upload, fixturePayload1MbBytes),
        (ThroughputLeg.download, fixturePayload100MbBytes),
        (ThroughputLeg.upload, fixturePayload100MbBytes),
      ]);
    });

    test('parses only named CLI values', () {
      expect(ThroughputSlice.parse('full'), ThroughputSlice.full);
      expect(
        ThroughputSlice.parse('without-shaped-1gb'),
        ThroughputSlice.withoutShapedOneGigabyte,
      );
      expect(
        () => ThroughputSlice.parse('only-1gb-upload'),
        throwsFormatException,
      );
      expect(() => ThroughputSlice.parse('uploads'), throwsFormatException);
    });
  });

  group('ThroughputSampleSpec', () {
    test('parses only exact shaped 1 GB replicate shards', () {
      final first = ThroughputSampleSpec.parse(
        'rtt100-1gb-download-dart-hash-on-r1',
      );
      final second = ThroughputSampleSpec.parse('rtt100-1gb-upload-openssh-r2');

      expect(first.direction, ThroughputLeg.download);
      expect(first.variant, ThroughputVariant.dartHashOn);
      expect(first.replicate, ThroughputReplicate.first);
      expect(first.cliValue, 'rtt100-1gb-download-dart-hash-on-r1');
      expect(second.direction, ThroughputLeg.upload);
      expect(second.variant, ThroughputVariant.openssh);
      expect(second.replicate, ThroughputReplicate.second);
      expect(
        () => ThroughputSampleSpec.parse('download-dart-hash-on-r1'),
        throwsFormatException,
      );
      expect(
        () =>
            ThroughputSampleSpec.parse('rtt100-100mb-download-dart-hash-on-r1'),
        throwsFormatException,
      );
    });
  });

  group('ThroughputSampleDeadline', () {
    final startedAt = DateTime.utc(2026, 9, 1, 12);

    test('caps a transfer at 240 minutes while retaining the reserve', () {
      const startedAtMonotonic = Duration(hours: 1);
      var monotonicNow = startedAtMonotonic + const Duration(minutes: 1);
      final deadline = ThroughputSampleDeadline(
        startedAt,
        startedAtMonotonic: startedAtMonotonic,
        monotonicNow: () => monotonicNow,
      );

      expect(deadline.transferLimit(), const Duration(minutes: 240));
      monotonicNow = startedAtMonotonic + const Duration(minutes: 60);
      expect(deadline.transferLimit(), const Duration(minutes: 225));
    });

    test('refuses to start without the fixed reserve', () {
      const startedAtMonotonic = Duration(hours: 1);
      final deadline = ThroughputSampleDeadline(
        startedAt,
        startedAtMonotonic: startedAtMonotonic,
        monotonicNow: () => startedAtMonotonic + const Duration(minutes: 285),
      );

      expect(deadline.transferLimit, throwsStateError);
    });

    test('uses the exported monotonic anchor and preserves final reserve', () {
      const startedAtMonotonic = Duration(hours: 1);
      var monotonicNow = startedAtMonotonic + const Duration(minutes: 284);
      final deadline = ThroughputSampleDeadline(
        startedAt,
        startedAtMonotonic: startedAtMonotonic,
        monotonicNow: () => monotonicNow,
      );

      expect(deadline.remaining, const Duration(minutes: 31));
      deadline.ensureReserve();
      monotonicNow =
          startedAtMonotonic + const Duration(minutes: 285, microseconds: 1);
      expect(deadline.ensureReserve, throwsStateError);
    });
  });

  test('runs trials in the result manifest\'s ABCCBA order', () async {
    // The aggregator validates live evidence against this manifest; the
    // runner's order must match it before any shard runs.
    final cell = affordableThroughputCells.first;
    final manifest = standardThroughputTrialSpecs
        .where((trial) => trial.cellId == cell.id)
        .toList();
    expect(throughputTrialOrder.map((variant) => variant.cliValue), [
      for (final trial in manifest) trial.variant.label,
    ]);

    // The runner numbers each variant's replicates by occurrence.
    final seen = <ThroughputVariant, int>{};
    final replicates = [
      for (final variant in throughputTrialOrder)
        seen[variant] = (seen[variant] ?? 0) + 1,
    ];
    expect(replicates, [for (final trial in manifest) trial.replicate]);
    expect(replicates, [1, 1, 1, 2, 2, 2]);
  });

  test('independently verifies a local transfer destination', () async {
    final directory = await Directory.systemTemp.createTemp(
      'poltergeist-integrity-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/payload.bin');
    await file.writeAsString('abc');

    final integrity = await inspectThroughputFile(
      file,
      expectedBytes: 3,
      expectedDigest:
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    );

    expect(integrity.status, ThroughputIntegrityStatus.verified);
    expect(integrity.actualBytes, 3);
    expect(integrity.actualSha256, integrity.expectedSha256);
  });
}

List<(ThroughputLeg, int)> _selectedTransfers(ThroughputSlice slice) {
  const payloadBytes = [
    fixturePayload1MbBytes,
    fixturePayload100MbBytes,
    fixturePayload1GbBytes,
  ];

  return [
    for (final bytes in payloadBytes)
      for (final leg in ThroughputLeg.values)
        if (slice.includes(leg, bytes)) (leg, bytes),
  ];
}
