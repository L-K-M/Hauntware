// The CI tool stays outside the shipped packages.
// ignore_for_file: avoid_relative_lib_imports

import 'dart:io';

import '../../import_guard/lib/guards_config.dart';
import '../lib/protocol_guard.dart';

Future<void> main(List<String> arguments) async {
  final String? productName;
  try {
    productName = parseProductArgument(arguments);
  } on FormatException catch (error) {
    stderr.writeln('error: ${error.message}');
    exitCode = 64;
    return;
  }

  try {
    final config = await loadGuardsConfig(File(guardsConfigPath));
    final products = productName == null
        ? config.products.values
        : [config.product(productName)];
    var failed = false;
    for (final product in products) {
      final violations = await checkProtocol(Directory.current.path, product);
      for (final violation in violations) {
        stderr.writeln('error: $violation');
      }
      failed = failed || violations.isNotEmpty;
    }
    exitCode = failed ? 1 : 0;
  } catch (error) {
    // Missing, malformed, or unreadable input must fail the CI gate.
    stderr.writeln('error: protocol scan failed: $error');
    exitCode = 2;
  }
}
