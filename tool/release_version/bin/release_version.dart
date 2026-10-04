// This executable and its library stay outside the shipped applications.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../lib/release_version_cli.dart';

void main(List<String> arguments) {
  exitCode = runReleaseVersionCommand(arguments);
}
