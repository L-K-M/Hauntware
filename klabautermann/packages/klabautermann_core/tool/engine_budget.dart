// Spike S5 part 1, the engine budget harness (04 §13 S5, 03 §11.4): it
// replays the committed host fixtures for ten hosts plus a journal
// follow through the engine's frame reader, sample pipeline, journal
// parser and an isolate hop, and prints the engine-side figures as
// JSON, which klabautermann/docs/evidence/s5/README.md describes.
//
// Run from klabautermann/packages/klabautermann_core:
//
//   dart run tool/engine_budget.dart [--scenario phone|tenHostsCoreAt2s]
//       [--seconds <n>] [--warmup <n>] [--log-rate <lines/s>] [--heap]
//       [--fixtures <dir>] [--out <file.json>]
//
// Defaults: the phone scenario, 60 s measured after a 10 s warm-up, a
// 1,000 lines/s follow, and klabautermann_host's fixtures. --heap reads
// the live heap after full collections (HeapReadings), which needs
// `dart run`. For timings closer to a release build, compile it first:
//
//   dart compile exe tool/engine_budget.dart -o /tmp/engine_budget
import 'dart:convert';
import 'dart:io';

import 'src/engine_budget.dart';

Future<void> main(List<String> args) async {
  final options = <String, String>{};
  var heap = HeapReadings.off;
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--heap') {
      if (const bool.fromEnvironment('dart.vm.product')) {
        _usage('--heap needs the VM service of `dart run`');
      }
      heap = HeapReadings.afterFullCollection;
      continue;
    }
    final name = args[i].startsWith('--') ? args[i].substring(2) : '';
    if (!const {
          'scenario',
          'seconds',
          'warmup',
          'log-rate',
          'fixtures',
          'out',
        }.contains(name) ||
        i + 1 == args.length) {
      _usage('unexpected argument ${args[i]}');
    }
    options[name] = args[++i];
  }

  final scenario =
      BudgetScenario.values.asNameMap()[options['scenario'] ??
          BudgetScenario.phone.name] ??
      _usage('--scenario takes ${BudgetScenario.values.map((s) => s.name)}');
  final seconds =
      _count(options['seconds'] ?? '60', min: 1) ??
      _usage('--seconds takes a whole number of at least 1');
  final warmup =
      _count(options['warmup'] ?? '10', min: 0) ??
      _usage('--warmup takes a whole number of at least 0');
  final logRate =
      _count(options['log-rate'] ?? '1000', min: 0) ??
      _usage('--log-rate takes a whole number of at least 0');
  final fixtures =
      options['fixtures'] ??
      findHostFixtures() ??
      _usage('no klabautermann_host fixtures here; pass --fixtures');

  final json = await runEngineBudget(
    BudgetPlan.of(
      scenario,
      warmup: Duration(seconds: warmup),
      measure: Duration(seconds: seconds),
      logLinesPerSecond: logRate,
      heap: heap,
    ),
    fixturesRoot: fixtures,
  );
  final text = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
  final out = options['out'];
  out == null ? stdout.write(text) : File(out).writeAsStringSync(text);
}

/// [text] as a whole number of at least [min], or null.
int? _count(String text, {required int min}) => switch (int.tryParse(text)) {
  final n? when n >= min => n,
  _ => null,
};

Never _usage(String message) {
  stderr
    ..writeln('engine_budget: $message')
    ..writeln(
      'usage: dart run tool/engine_budget.dart [options]; '
      'see the header of tool/engine_budget.dart',
    );
  exit(64);
}
