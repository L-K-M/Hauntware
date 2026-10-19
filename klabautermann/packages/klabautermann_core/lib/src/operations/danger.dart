// The danger findings a plan's preview shows (AI-01, M4 plan M8):
// DangerLinter reads each shell step's words and, for an API step, the
// Docker CLI command that does the same, so a volume removal is flagged
// whichever way the plan reaches the engine.
import 'package:seance_core/seance_core.dart' show DangerFinding, DangerLinter;

import 'plan_types.dart';

/// What the linter finds in [steps], in step order.
List<DangerFinding> lintSteps(Iterable<PlanStep> steps) => [
  for (final step in steps)
    ...switch (step) {
      // The exact command line quotes every word behind its locale
      // wrapper, which the linter's patterns cannot see through, so it
      // reads the argv joined by spaces: the same words.
      ShellStep(:final argv) => DangerLinter.scan(argv.join(' ')),
      final ApiStep api => switch (cliEquivalent(api)) {
        final cli? => DangerLinter.scan(cli),
        null => const <DangerFinding>[],
      },
    },
];

final _versioned = RegExp(r'^/v\d+\.\d+(/.*)$');

/// The Docker CLI command that does what [step] does, for the linter, or
/// null for a request it has no rule about (reads, pulls).
String? cliEquivalent(ApiStep step) {
  final path = _versioned.firstMatch(step.path)?[1] ?? step.path;
  final segments = path.split('/').where((s) => s.isNotEmpty).toList();
  bool flag(String name) => const {'1', 'true'}.contains(step.query[name]);

  switch ((step.method, segments)) {
    case ('DELETE', ['containers', final id]):
      return [
        'docker rm',
        if (flag('force')) '-f',
        if (flag('v')) '-v',
        id,
      ].join(' ');
    case ('DELETE', ['images', ...final name]) when name.isNotEmpty:
      return ['docker rmi', if (flag('force')) '-f', name.join('/')].join(' ');
    case ('DELETE', ['volumes', final name]):
      return ['docker volume rm', if (flag('force')) '-f', name].join(' ');
    case ('POST', ['containers', final id, 'kill']):
      return [
        'docker kill',
        if (step.query['signal'] case final signal?) '-s $signal',
        id,
      ].join(' ');
    case ('POST', [final kind, 'prune'])
        when const {
          'containers',
          'images',
          'volumes',
          'networks',
        }.contains(kind):
      return 'docker ${kind.substring(0, kind.length - 1)} prune -f';
    case ('POST', ['containers', final id, final verb])
        when const {
          'start',
          'stop',
          'restart',
          'pause',
          'unpause',
        }.contains(verb):
      return 'docker $verb $id';
  }
  return null;
}
