// Loads a store named by a bare relative filename, so its sweep lists '.':
// this process's working directory, which the incident store test sets.
// Moving Directory.current inside the test runner instead would move it for
// every suite running beside that test.
import 'dart:io';

import 'package:poltergeist_core/poltergeist_core.dart';

Future<void> main() async {
  final loaded = await FileIncidentStore(File('incidents.json')).load();
  stdout.write(loaded.length);
}
