// `flutter drive`'s host side of the frame-timing test
// (integration_test/frame_timing_test.dart): it writes the test's report
// as frame-timing.json to $KLABAUTERMANN_EVIDENCE_DIR when that is set,
// otherwise to integration_test's output directory (build/), also when
// the test fails, so a partial run still leaves what it measured.
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() {
  final evidence = Platform.environment['KLABAUTERMANN_EVIDENCE_DIR'];
  return integrationDriver(
    responseDataCallback: (data) => writeResponseData(
      data,
      testOutputFilename: 'frame-timing',
      destinationDirectory: evidence == null || evidence.isEmpty
          ? null
          : evidence,
    ),
    writeResponseOnFailure: true,
  );
}
