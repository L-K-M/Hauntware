// The HWS/1 capture tool (03 §6.5, D53). It lives in klabautermann_core
// so that its SSH mode can reach SshLink; today it runs locally and has
// one command, spike S2's measurements (04 §13 S2). Fixture capture
// with its redaction review follows.
//
// Run from klabautermann/packages/klabautermann_core:
//
//   dart run tool/capture_fixtures.dart measure [--sh <shell>]...
//       [--login-shell <shell>]... [--ticks <n>] [--procs <n>,<n>,...]
//       [--out <file.json>]
//
// measure runs the real program as `<sh> -s` under the start command's
// environment, started under the name `sh`, for each --sh shell (fast
// tick, procs, slow tick), and as `<login shell> -c '<start command>'`
// for each --login-shell (output before READY; the start command then
// execs this machine's `sh`). Both default to dash and bash. It writes
// the evidence JSON to --out or stdout.
import 'dart:convert';
import 'dart:io';

import 'src/s2_measure.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.first != 'measure') _usage('expected measure');
  final options = <String, List<String>>{};
  for (var i = 1; i < args.length; i++) {
    final name = args[i].startsWith('--') ? args[i].substring(2) : '';
    if (!const {'sh', 'login-shell', 'ticks', 'procs', 'out'}.contains(name) ||
        i + 1 == args.length) {
      _usage('unexpected argument ${args[i]}');
    }
    (options[name] ??= []).add(args[++i]);
  }

  final user = (await Process.run('id', ['-un'])).stdout.toString().trim();
  final json = await measureAll(
    samplerShells: options['sh'] ?? const ['dash', 'bash'],
    loginShells: options['login-shell'] ?? const ['dash', 'bash'],
    user: user,
    ticks: int.parse(options['ticks']?.last ?? '500'),
    extraProcesses: [
      for (final n in (options['procs']?.last ?? '1000,2000,3000').split(','))
        int.parse(n),
    ],
  );
  final text = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
  final out = options['out']?.last;
  out == null ? stdout.write(text) : File(out).writeAsStringSync(text);
}

Never _usage(String message) {
  stderr
    ..writeln('capture_fixtures: $message')
    ..writeln(
      'usage: dart run tool/capture_fixtures.dart measure [options]; '
      'see the header of tool/capture_fixtures.dart',
    );
  exit(64);
}
