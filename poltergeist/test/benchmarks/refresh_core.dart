// D12 baseline refresh: pure pooling core (README "Baseline refresh
// procedure", 08 §6).
//
// Pools the per-repetition rows of downloaded `bench-results` artifacts
// into a new tier-B baseline. Every artifact goes through the checker's
// own parser, so a refresh never pools rows the checker would reject,
// and medians use the checker's [median]. No IO: refresh.dart reads the
// artifacts and writes the committed files.
//
//   <run-id>/bench-results.json ──┐
//   target fingerprint ───────────┼─► poolRefresh ─► RefreshPool ─┬─► updateBaselineJson
//   budgets.json, tier-B baseline ┘                               └─► updateBudgetsJson
library;

import 'dart:convert';

import 'check_core.dart';

/// The procedure's minimum number of pooled runs (README step 1).
const minimumRefreshRuns = 3;

/// The merged results file inside every `bench-results` artifact.
const benchResultsFileName = 'bench-results.json';

/// Decimal places of a committed baseline median.
const _medianDecimals = 3;

const _jsonIndent = '  ';

/// Fingerprint axes a refresh compares and may override. scenarioConfig
/// is absent: it is per scenario and comes from the pooled rows.
enum FingerprintAxis {
  runnerImage,
  arch,
  dartVersion,
  flutterVersion,
  mode,
  cpuModel;

  /// Axes every tier of one job shares, so the tier-A calibration moves
  /// with them (tier A's runtime axes belong to its own SDK).
  static const machineAxes = {runnerImage, arch, cpuModel};

  String? of(BenchFingerprint fingerprint) => switch (this) {
    runnerImage => fingerprint.runnerImage,
    arch => fingerprint.arch,
    dartVersion => fingerprint.dartVersion,
    flutterVersion => fingerprint.flutterVersion,
    mode => fingerprint.mode,
    cpuModel => fingerprint.cpuModel,
  };
}

/// [fingerprint] with [overrides] applied, e.g. the committed baseline
/// fingerprint with `runnerImage` moved to the rotated image.
BenchFingerprint overrideAxes(
  BenchFingerprint fingerprint,
  Map<FingerprintAxis, String> overrides,
) {
  String? value(FingerprintAxis axis) =>
      overrides[axis] ?? axis.of(fingerprint);

  return BenchFingerprint(
    runnerImage: value(FingerprintAxis.runnerImage)!,
    arch: value(FingerprintAxis.arch)!,
    dartVersion: value(FingerprintAxis.dartVersion)!,
    flutterVersion: value(FingerprintAxis.flutterVersion),
    mode: value(FingerprintAxis.mode)!,
    cpuModel: value(FingerprintAxis.cpuModel)!,
    scenarioConfig: fingerprint.scenarioConfig,
  );
}

/// Pooled median of one scenario's `ok` rows across the used runs.
typedef PooledMedian = ({double median, String unit, int count});

/// What a refresh would commit, plus the evidence its README entry cites.
class RefreshPool {
  /// Runs whose tier-B rows match the target fingerprint in full, in
  /// ascending run-id order.
  final List<int> usedRuns;

  /// Every other run with the reason it stayed out of the pool.
  final Map<int, String> excludedRuns;

  /// New tier-B baseline entries in catalog order. A scenario without
  /// `ok` rows has no entry: never a fabricated median.
  final Map<String, BaselineEntry> entries;

  /// Tier-B scenarios with no `ok` rows, with their errored-row count.
  final Map<String, int> scenariosWithoutEntry;

  /// Tier-A pooled medians of the used runs; refreshes report them to
  /// show the unchanged budgets still pass.
  final Map<String, PooledMedian> tierAMedians;

  /// Findings a human must weigh before committing.
  final List<String> warnings;

  const RefreshPool({
    required this.usedRuns,
    required this.excludedRuns,
    required this.entries,
    required this.scenariosWithoutEntry,
    required this.tierAMedians,
    required this.warnings,
  });
}

/// Pools [artifacts] (run id → `bench-results.json` text, null when the
/// run's artifact holds no readable results file) against [target], the
/// tier-B fingerprint the refreshed baseline records.
///
/// Throws [CheckDataException] when pooled runs disagree on a scenario's
/// config: a run measured under another config belongs to a different
/// baseline, so the refresh must not average across them.
RefreshPool poolRefresh({
  required BudgetCatalog catalog,
  required TierBBaseline current,
  required BenchFingerprint target,
  required Map<int, String?> artifacts,
}) {
  final usedRuns = <int>[];
  final excludedRuns = <int, String>{};
  final values = <String, List<double>>{};
  final configs = <String, (String?, int)>{};
  final erroredRows = <String, int>{};
  final warnings = <String>{};

  for (final runId in artifacts.keys.toList()..sort()) {
    final text = artifacts[runId];
    if (text == null) {
      excludedRuns[runId] = 'no readable $benchResultsFileName';
      continue;
    }

    final ResultsFile results;
    try {
      results = ResultsFile.fromJson(jsonDecode(text), catalog);
    } on FormatException catch (error) {
      excludedRuns[runId] = 'unreadable JSON: ${error.message}';
      continue;
    } on CheckDataException catch (error) {
      excludedRuns[runId] = 'rejected by the checker: $error';
      continue;
    }

    // Pool only runs matching the target in full (README step 2): a run
    // on another CPU is a different environment, even with the new image.
    final tierB = results.fingerprints[BenchTier.b];
    if (tierB == null) {
      excludedRuns[runId] = 'no tier-B rows';
      continue;
    }

    final mismatches = [
      for (final axis in FingerprintAxis.values)
        if (axis.of(tierB) != axis.of(target)) '${axis.name} ${axis.of(tierB)}',
    ];
    if (mismatches.isNotEmpty) {
      excludedRuns[runId] = mismatches.join(', ');
      continue;
    }

    // A run whose whole tier-B leg errored measured nothing, so it must
    // not count toward the procedure's minimum.
    final measuredTierB = results.rows.any(
      (row) => row.isOk && catalog.scenarios[row.scenario]!.tier == BenchTier.b,
    );
    if (!measuredTierB) {
      excludedRuns[runId] = 'no ok tier-B rows';
      continue;
    }

    usedRuns.add(runId);
    warnings.addAll(_tierACalibrationWarnings(catalog, results));

    for (final row in results.rows) {
      final scenario = row.scenario;
      if (!row.isOk) {
        erroredRows.update(scenario, (count) => count + 1, ifAbsent: () => 1);
        continue;
      }

      values.putIfAbsent(scenario, () => []).add(row.value!);
      if (catalog.scenarios[scenario]!.tier != BenchTier.b) {
        continue;
      }

      final config = row.fingerprint.scenarioConfig;
      final (pooledConfig, pooledRun) = configs.putIfAbsent(
        scenario,
        () => (config, runId),
      );
      if (pooledConfig != config) {
        throw CheckDataException(
          'pooled runs disagree on $scenario scenarioConfig '
          '(${pooledConfig ?? '<none>'} in run $pooledRun, '
          '${config ?? '<none>'} in run $runId): a run measured under '
          'another config belongs to a different baseline',
        );
      }
    }
  }

  final entries = <String, BaselineEntry>{};
  final scenariosWithoutEntry = <String, int>{};
  final tierAMedians = <String, PooledMedian>{};
  for (final budget in catalog.scenarios.values) {
    final pooled = values[budget.id];
    if (budget.tier == BenchTier.a) {
      if (pooled != null) {
        tierAMedians[budget.id] = (
          median: median(pooled),
          unit: budget.unit,
          count: pooled.length,
        );
      }
      continue;
    }

    if (pooled == null) {
      scenariosWithoutEntry[budget.id] = erroredRows[budget.id] ?? 0;
      if (budget.landed) {
        warnings.add(
          '${budget.id} is landed but has no ok rows: the refreshed '
          'baseline has no entry, and enforced tier B fails it',
        );
      }
      continue;
    }

    final config = configs[budget.id]!.$1;
    final previous = current.scenarios[budget.id];
    if (previous != null &&
        previous.scenarioConfigRecorded &&
        previous.scenarioConfig != config) {
      warnings.add(
        '${budget.id} scenarioConfig moved from ${previous.scenarioConfig} '
        'to $config',
      );
    }

    entries[budget.id] = BaselineEntry(
      median: double.parse(median(pooled).toStringAsFixed(_medianDecimals)),
      unit: budget.unit,
      repetitions: pooled.length,
      scenarioConfigRecorded: true,
      scenarioConfig: config,
    );
  }

  if (usedRuns.length < minimumRefreshRuns) {
    warnings.add(
      'only ${usedRuns.length} run(s) match the target; the procedure '
      'needs at least $minimumRefreshRuns',
    );
  }

  return RefreshPool(
    usedRuns: usedRuns,
    excludedRuns: excludedRuns,
    entries: entries,
    scenariosWithoutEntry: scenariosWithoutEntry,
    tierAMedians: tierAMedians,
    warnings: warnings.toList(),
  );
}

/// Tier A runs its own SDK and per-scenario configs, so a refresh moves
/// only the shared machine axes of its calibration. A runtime-axis or
/// config mismatch left over needs a separate tier-A recalibration (e.g.
/// the 2026-09-22 rotation shifted P5's readdir order), which this tool
/// never invents.
Iterable<String> _tierACalibrationWarnings(
  BudgetCatalog catalog,
  ResultsFile results,
) sync* {
  final calibration = catalog.calibratedFingerprint;
  final tierA = results.fingerprints[BenchTier.a];
  if (calibration == null || tierA == null) {
    return;
  }

  for (final axis in FingerprintAxis.values) {
    if (FingerprintAxis.machineAxes.contains(axis)) {
      continue;
    }
    if (axis.of(calibration) != axis.of(tierA)) {
      yield 'tier-A rows ran with ${axis.name} ${axis.of(tierA)}, but '
          'budgets.json calibrates ${axis.of(calibration)}: recalibrate '
          'tier A separately';
    }
  }

  for (final row in results.rows) {
    final calibrated =
        catalog.scenarios[row.scenario]!.calibratedScenarioConfig;
    if (calibrated != null && row.fingerprint.scenarioConfig != calibrated) {
      yield '${row.scenario} ran under '
          "${row.fingerprint.scenarioConfig ?? '<none>'}, but budgets.json "
          'calibrates $calibrated: recalibrate tier A separately';
    }
  }
}

/// [baselineText] with the fingerprint moved to [target] and the
/// scenarios replaced by [pool]'s entries, keeping the file's layout.
String updateBaselineJson(
  String baselineText,
  BenchFingerprint target,
  RefreshPool pool,
) {
  final document = jsonDecode(baselineText) as Map<String, Object?>;
  final fingerprint = document['fingerprint'] as Map<String, Object?>;
  for (final axis in FingerprintAxis.values) {
    fingerprint[axis.name] = axis.of(target);
  }

  // Every pooled entry records its config, which only schema -2 carries.
  document['schema'] = baselineSchemaV2Id;
  document['scenarios'] = {
    for (final MapEntry(key: id, value: entry) in pool.entries.entries)
      id: {
        'median': entry.median,
        'unit': entry.unit,
        'repetitions': entry.repetitions,
        'scenarioConfig': entry.scenarioConfig,
      },
  };
  return _encode(document);
}

/// [budgetsText] with the tier-A calibration's machine axes moved to
/// [target]'s. A missing calibration stays missing: tier A was never
/// calibrated, and a refresh does not invent one.
String updateBudgetsJson(String budgetsText, BenchFingerprint target) {
  final document = jsonDecode(budgetsText) as Map<String, Object?>;
  final calibration = document['calibratedFingerprint'];
  if (calibration is! Map<String, Object?>) {
    return budgetsText;
  }

  for (final axis in FingerprintAxis.machineAxes) {
    calibration[axis.name] = axis.of(target);
  }
  return _encode(document);
}

String _encode(Object? document) =>
    '${const JsonEncoder.withIndent(_jsonIndent).convert(document)}\n';
