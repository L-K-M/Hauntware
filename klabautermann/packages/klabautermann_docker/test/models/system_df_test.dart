import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import '../harness.dart';

Object? fixtureJson(String name) => jsonDecode(fixtureString(name));

void expectTotals(
  DiskUsageTotals? t, {
  required int total,
  required int active,
  required int? size,
  required int reclaimable,
}) {
  expect(t, isNotNull);
  expect(t!.totalCount, total, reason: 'totalCount');
  expect(t.activeCount, active, reason: 'activeCount');
  expect(t.totalSize, size, reason: 'totalSize');
  expect(t.reclaimable, reclaimable, reason: 'reclaimable');
}

void main() {
  group('legacy shape (below 1.52)', () {
    test('computes the totals from the lists as the daemon does', () {
      final r = parseSystemDf(
        fixtureJson('system-df-1.44.json'),
        shape: SystemDfShape.legacy,
      );
      expect(r.warnings, isEmpty);
      final df = r.value;
      // Unused images free Size less SharedSize; busybox's unknown
      // SharedSize keeps it out.
      expectTotals(
        df.images,
        total: 4,
        active: 1,
        size: 20000000,
        reclaimable: 4100000 + 6700000,
      );
      // Running and paused containers are active; exited and created
      // ones free their writable layer.
      expectTotals(
        df.containers,
        total: 4,
        active: 2,
        size: 33400,
        reclaimable: 30400,
      );
      // An unknown volume size (-1) counts as in use and adds nothing.
      expectTotals(
        df.volumes,
        total: 3,
        active: 2,
        size: 750000,
        reclaimable: 250000,
      );
      // Shared build cache records are never reclaimable.
      expectTotals(
        df.buildCache,
        total: 3,
        active: 1,
        size: 260000,
        reclaimable: 120000,
      );
      expect(df.reclaimable, 10800000 + 30400 + 250000 + 120000);
    });

    test('ignores the usage objects below the gate', () {
      final r = parseSystemDf(
        fixtureJson('system-df-1.53.json'),
        shape: SystemDfShape.legacy,
      );
      expect(r.warnings, isEmpty);
      expect(r.value.images, isNull);
      expect(r.value.containers, isNull);
      expect(r.value.volumes, isNull);
      expect(r.value.buildCache, isNull);
      expect(r.value.reclaimable, isNull);
    });

    test('an unknown container count is never reclaimable', () {
      final r = parseSystemDf({
        'LayersSize': 300,
        'Images': [
          {'Id': 'a', 'Size': 100, 'SharedSize': 0, 'Containers': -1},
          {'Id': 'b', 'Size': 200, 'SharedSize': 0},
        ],
      }, shape: SystemDfShape.legacy);
      expect(r.warnings, isEmpty);
      expectTotals(
        r.value.images,
        total: 2,
        active: 0,
        size: 300,
        reclaimable: 0,
      );
    });
  });

  group('1.52 and 1.53 shapes', () {
    test('1.52 reads the usage objects and they agree with the lists', () {
      final decoded = fixtureJson('system-df-1.52.json');
      final current = parseSystemDf(decoded, shape: SystemDfShape.v152);
      final legacy = parseSystemDf(decoded, shape: SystemDfShape.legacy);
      expect(current.warnings, isEmpty);
      expect(legacy.warnings, isEmpty);

      final df = current.value;
      expectTotals(
        df.images,
        total: 2,
        active: 1,
        size: 12300000,
        reclaimable: 4100000,
      );
      expectTotals(
        df.containers,
        total: 2,
        active: 1,
        size: 31000,
        reclaimable: 30000,
      );
      expectTotals(
        df.volumes,
        total: 1,
        active: 1,
        size: 500000,
        reclaimable: 0,
      );
      expectTotals(df.buildCache, total: 0, active: 0, size: 0, reclaimable: 0);
      expect(df.reclaimable, 4130000);
      expect(legacy.value.reclaimable, df.reclaimable);
    });

    test('1.53 reads the usage objects alone', () {
      final r = parseSystemDf(
        fixtureJson('system-df-1.53.json'),
        shape: SystemDfShape.v153,
      );
      expect(r.warnings, isEmpty);
      final df = r.value;
      expectTotals(
        df.images,
        total: 5,
        active: 3,
        size: 2147483648,
        reclaimable: 734003200,
      );
      expectTotals(
        df.buildCache,
        total: 12,
        active: 0,
        size: 268435456,
        reclaimable: 268435456,
      );
      expect(df.reclaimable, 734003200 + 52428800 + 104857600 + 268435456);
    });

    test('the usage object wins over a disagreeing legacy list', () {
      final r = parseSystemDf({
        'Containers': [
          {'Id': 'a', 'State': 'exited', 'SizeRw': 999},
        ],
        'ContainerUsage': {
          'ActiveCount': 0,
          'TotalCount': 1,
          'Reclaimable': 10,
          'TotalSize': 10,
        },
      }, shape: SystemDfShape.v152);
      expect(r.warnings, isEmpty);
      expect(r.value.containers!.reclaimable, 10);
    });

    test('a type with only a legacy list falls back with a warning', () {
      final r = parseSystemDf(
        fixtureJson('system-df-1.44.json'),
        shape: SystemDfShape.v153,
      );
      expect(r.value.volumes!.reclaimable, 250000);
      expect(r.warnings, hasLength(4));
      expect(r.warnings.first, contains('ImageUsage missing'));
    });

    test('a type filter leaves the other types unknown', () {
      final r = parseSystemDf({
        'ImageUsage': {
          'ActiveCount': 1,
          'TotalCount': 2,
          'Reclaimable': 5,
          'TotalSize': 9,
        },
      }, shape: SystemDfShape.v153);
      expect(r.warnings, isEmpty);
      expect(r.value.containers, isNull);
      expect(r.value.volumes, isNull);
      expect(r.value.buildCache, isNull);
      expect(r.value.reclaimable, 5);
    });
  });

  group('tolerance', () {
    test('never throws on malformed daemon input', () {
      for (final shape in SystemDfShape.values) {
        final r = parseSystemDf(null, shape: shape);
        expect(r.warnings, isNotEmpty);
        expect(r.value.reclaimable, isNull);
      }

      final badEntry = parseSystemDf({
        'Containers': [1, 'x'],
      }, shape: SystemDfShape.legacy);
      expect(badEntry.warnings, hasLength(2));
      expect(badEntry.value.containers!.totalCount, 0);

      final badUsage = parseSystemDf({
        'ImageUsage': {'Reclaimable': 'lots', 'TotalCount': 2},
      }, shape: SystemDfShape.v153);
      expect(badUsage.warnings.single, contains('Reclaimable'));
      expect(badUsage.value.images!.reclaimable, isNull);
      expect(badUsage.value.images!.totalCount, 2);
      expect(badUsage.value.reclaimable, isNull);
    });
  });
}
