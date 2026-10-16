// The HWS/1 capture tool (03 §6.5, D53). It lives in klabautermann_core
// so that its SSH mode can reach SshLink; today it runs locally.
//
// Run from klabautermann/packages/klabautermann_core:
//
//   dart run tool/capture_fixtures.dart capture [--sh <shell> |
//       --login-shell <shell>] [--platform <id>] [--out <dir>]
//       [--redact <text>]... [--replace]
//   dart run tool/capture_fixtures.dart measure [--sh <shell>]...
//       [--login-shell <shell>]... [--ticks <n>] [--procs <n>,<n>,...]
//       [--out <file.json>]
//
// capture runs the real program once per collector, as `<sh> -s` under
// the start command's environment, started under the name `sh` (default
// this machine's `sh`), or as `<login shell> -c '<start command>'` the
// way sshd runs it. It redacts the payloads and reviews the result (03
// §6.5). When the review finds nothing it writes `<out>/<platform>/`
// (default ../klabautermann_host/test/fixtures, the platform from the
// probe's os-release), emptying an existing directory only with
// --replace; otherwise it writes nothing and lists the lines, and
// --redact removes a value the rules cannot know. Review the diff, then
// run `dart run tool/regen_goldens.dart` in klabautermann_host.
//
// measure runs the real program as `<sh> -s` under the start command's
// environment, started under the name `sh`, for each --sh shell (fast
// tick, procs, slow tick), and as `<login shell> -c '<start command>'`
// for each --login-shell (output before READY; the start command then
// execs this machine's `sh`). Both default to dash and bash. It writes
// the evidence JSON to --out or stdout.
import 'dart:convert';
import 'dart:io';

import 'src/fixture_capture.dart';
import 'src/local_sampler.dart';
import 'src/redaction.dart';
import 'src/s2_measure.dart';

/// Each command's options that take a value, and its flags.
const _commands = {
  'capture': (
    valued: {'sh', 'login-shell', 'platform', 'out', 'redact'},
    flags: {'replace'},
  ),
  'measure': (
    valued: {'sh', 'login-shell', 'ticks', 'procs', 'out'},
    flags: <String>{},
  ),
};

Future<void> main(List<String> args) async {
  final command = args.isEmpty ? null : args.first;
  final spec = _commands[command] ?? _usage('expected capture or measure');
  final options = <String, List<String>>{};
  for (var i = 1; i < args.length; i++) {
    final name = args[i].startsWith('--') ? args[i].substring(2) : '';
    if (spec.flags.contains(name)) {
      options[name] = const [];
    } else if (spec.valued.contains(name) && i + 1 < args.length) {
      (options[name] ??= []).add(args[++i]);
    } else {
      _usage('unexpected argument ${args[i]}');
    }
  }

  if (command == 'capture') {
    await _capture(options);
  } else {
    await _measure(options);
  }
}

Future<void> _capture(Map<String, List<String>> options) async {
  final root = options['out']?.last ?? '../klabautermann_host/test/fixtures';
  if (!Directory(root).existsSync()) _usage('$root does not exist');
  final replace = options.containsKey('replace');
  final platformOption = options['platform']?.last;
  if (platformOption != null && !isPlatformId(platformOption)) {
    _usage('--platform takes lowercase words and digits joined by hyphens');
  }
  // Checked again before the write, when the probe names the platform.
  if (platformOption != null &&
      !replace &&
      Directory('$root/$platformOption').existsSync()) {
    _usage('$root/$platformOption exists; pass --replace to empty it');
  }
  if (options['redact']?.any((v) => v.length < 2) ?? false) {
    _usage('--redact takes values of at least 2 characters');
  }
  final sh = options['sh']?.last;
  final login = options['login-shell']?.last;
  if (sh != null && login != null) _usage('pass --sh or --login-shell');
  final name = login ?? sh ?? 'sh';
  final shell = name.contains('/')
      ? name
      : findOnCapturePath(name) ?? _usage('$name is not on $kCapturePath');

  final user = await _user();
  final home = Platform.environment['HOME'] ?? '/';
  final Capture capture;
  try {
    capture = await captureLocal(
      login == null
          ? SamplerLaunch.stdinShell(shell)
          : SamplerLaunch.loginShell(shell),
      // A login launch gets sshd's session variables, as over SSH.
      runEnvironment(
        home: home,
        user: user,
        shell: login == null ? null : shell,
        ssh: login != null,
      ),
    );
  } on ArgumentError catch (e) {
    _usage('${e.invalidValue} ${e.message}');
  } on Exception catch (e) {
    _fail('capture failed: $e');
  }

  final profile = capture.profile;
  final platform =
      platformOption ??
      platformIdFor(profile) ??
      _usage('no platform id from the probe; pass --platform');
  final redactor = Redactor(
    captureLiterals(
      profile,
      hostNames: [
        Platform.localHostname,
        ...capture.hostNames,
        // hostname(5): the first line that is not a comment.
        ?_readIfPresent('/etc/hostname')
            ?.split('\n')
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty && !l.startsWith('#'))
            .firstOrNull,
      ],
      home: home,
      passwd: _readIfPresent('/etc/passwd') ?? '',
      searchDomains: resolvDomains(_readIfPresent('/etc/resolv.conf') ?? ''),
      extra: options['redact'] ?? const [],
    ),
  );
  final FixtureFiles rendered;
  try {
    rendered = renderFixtureFiles(
      capture,
      redactor,
      capturedAt: DateTime.now(),
    );
  } on CaptureFailure catch (e) {
    _fail('$e');
  }
  if (rendered.residue.isNotEmpty) {
    stderr.writeln(
      'capture_fixtures: the review found lines the redaction left; '
      'nothing was written:',
    );
    for (final r in rendered.residue) {
      stderr.writeln('  $r');
      // Never into a log: the line may hold the secret it was flagged for.
      if (stderr.hasTerminal) {
        stderr.writeln(
          '    ${utf8.decode(latin1.encode(r.text), allowMalformed: true)}',
        );
      }
    }
    _fail(
      'remove each value with --redact <text>, or fix the host, and '
      'capture again',
    );
  }

  final dir = Directory('$root/$platform');
  final List<String> removed;
  try {
    removed = writeFixtureDir(dir, rendered, replace: replace);
  } on CaptureFailure catch (e) {
    _usage(e.message);
  } on FileSystemException catch (e) {
    _fail('writing ${dir.path} failed: $e');
  }
  final replaced = [
    for (final MapEntry(:key, :value) in rendered.counts.entries) '$key $value',
  ];
  stdout
    ..writeln(
      'Wrote ${dir.path}; replaced '
      '${replaced.isEmpty ? 'nothing' : replaced.join(', ')}.',
    )
    ..writeln('Review the diff, then run tool/regen_goldens.dart.');
  if (removed.isNotEmpty) {
    stdout.writeln('Removed, restore with git if wanted: ${removed.join(' ')}');
  }
}

Future<void> _measure(Map<String, List<String>> options) async {
  final ticks =
      _count(options['ticks']?.last ?? '500', min: 1) ??
      _usage('--ticks takes a whole number of at least 1');
  final extraProcesses = [
    for (final n in (options['procs']?.last ?? '1000,2000,3000').split(','))
      _count(n, min: 0) ??
          _usage('--procs takes whole numbers of at least 0, comma-separated'),
  ];

  final json = await measureAll(
    samplerShells: options['sh'] ?? const ['dash', 'bash'],
    loginShells: options['login-shell'] ?? const ['dash', 'bash'],
    user: await _user(),
    ticks: ticks,
    extraProcesses: extraProcesses,
  );
  final text = '${const JsonEncoder.withIndent('  ').convert(json)}\n';
  final out = options['out']?.last;
  out == null ? stdout.write(text) : File(out).writeAsStringSync(text);
}

String? _readIfPresent(String path) {
  final file = File(path);
  return file.existsSync() ? file.readAsStringSync() : null;
}

Future<String> _user() async =>
    (await Process.run('id', ['-un'])).stdout.toString().trim();

/// [text] as a whole number of at least [min], or null.
int? _count(String text, {required int min}) => switch (int.tryParse(text)) {
  final n? when n >= min => n,
  _ => null,
};

Never _fail(String message) {
  stderr.writeln('capture_fixtures: $message');
  exit(1);
}

Never _usage(String message) {
  stderr
    ..writeln('capture_fixtures: $message')
    ..writeln(
      'usage: dart run tool/capture_fixtures.dart capture|measure '
      '[options]; see the header of tool/capture_fixtures.dart',
    );
  exit(64);
}
