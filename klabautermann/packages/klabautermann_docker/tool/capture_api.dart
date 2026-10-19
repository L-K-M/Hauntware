// The recorded Docker API capture tool (03 §11.1, D21; spike S1).
//
// Run from klabautermann/packages/klabautermann_docker, or compiled, as
// test/integration/capture.sh does:
//
//   dart run tool/capture_api.dart capture --socket <path> --out <dir>
//       --expect-api <major.minor> --seed-image <repo>:<tag>@sha256:<hex>
//       [--daemon-image <ref>] [--run <id>] [--wait <seconds>]
//   dart run tool/capture_api.dart check <committed dir> <captured dir>
//
// capture seeds the daemon behind --socket through the Engine API and
// records each exchange's raw response bytes into --out, whose name is
// the corpus name (`api-1.55`, `api-podman`); it fails when the daemon's
// API maximum differs from --expect-api. It creates containers, an
// image, a network and a volume: use a disposable daemon only.
//
// check compares two corpus directories by structure (exchange list,
// statuses, content types, header names, body kinds and JSON key paths,
// never values) and exits 1 listing the differences.
import 'dart:io';

import 'package:klabautermann_docker/klabautermann_docker.dart';

import 'src/api_capture.dart';
import 'src/api_corpus.dart';

const _valued = {
  'socket',
  'out',
  'expect-api',
  'seed-image',
  'daemon-image',
  'run',
  'wait',
};

Future<void> main(List<String> args) async {
  switch (args) {
    case ['check', final committed, final captured]:
      _check(committed, captured);
    case ['capture', ...final rest]:
      await _capture(rest);
    default:
      _usage('expected capture or check');
  }
}

Future<void> _capture(List<String> args) async {
  final options = <String, String>{};
  for (var i = 0; i < args.length; i++) {
    final name = args[i].startsWith('--') ? args[i].substring(2) : '';
    if (!_valued.contains(name) || i + 1 >= args.length) {
      _usage('unexpected argument ${args[i]}');
    }
    options[name] = args[++i];
  }
  String required(String name) =>
      options[name] ?? _usage('--$name is required');

  final expectApi = ApiVersion.tryParse(required('expect-api'));
  if (expectApi == null) _usage('--expect-api takes <major>.<minor>');
  final wait = int.tryParse(options['wait'] ?? '90');
  if (wait == null || wait <= 0) _usage('--wait takes positive seconds');

  try {
    await runCapture(
      CaptureOptions(
        socketPath: required('socket'),
        outDir: required('out'),
        expectApi: expectApi,
        seedImage: required('seed-image'),
        daemonImage: options['daemon-image'],
        run: options['run'],
        wait: Duration(seconds: wait),
      ),
    );
  } on CaptureException catch (e) {
    stderr.writeln('capture_api: $e');
    exit(1);
  }
}

void _check(String committed, String captured) {
  final List<String> differences;
  try {
    differences = compareCorpora(_read(committed), _read(captured));
  } on FormatException catch (e) {
    stderr.writeln('capture_api: ${e.message}');
    exit(1);
  }
  if (differences.isEmpty) {
    stdout.writeln('$captured matches $committed');
    return;
  }
  stderr.writeln('capture_api: $captured differs from $committed:');
  for (final line in differences) {
    stderr.writeln('  $line');
  }
  exit(1);
}

(CorpusManifest, List<ExchangeShape>) _read(String dir) {
  if (!Directory(dir).existsSync()) {
    throw FormatException('$dir does not exist');
  }
  try {
    return readCorpus((file) {
      final f = File('$dir/$file');
      return f.existsSync() ? f.readAsBytesSync() : null;
    });
  } on FormatException catch (e) {
    throw FormatException('$dir: ${e.message}');
  }
}

Never _usage(String message) {
  stderr
    ..writeln('capture_api: $message')
    ..writeln(
      'usage: capture_api.dart capture --socket <path> --out <dir> '
      '--expect-api <major.minor> --seed-image <ref@digest> '
      '[--daemon-image <ref>] [--run <id>] [--wait <seconds>]',
    )
    ..writeln('       capture_api.dart check <committed dir> <captured dir>');
  exit(2);
}
