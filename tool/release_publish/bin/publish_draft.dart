// This executable stays outside the shipped application.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../lib/release_publish_cli.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runReleasePublishCommand(arguments);
}
