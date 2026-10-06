import 'package:flutter_test/flutter_test.dart';
import 'package:open_file_platform_interface/open_file_platform_interface.dart';

/// Records what the system's default app is asked to open, instead of
/// launching it, until the current test ends.
List<String> recordSystemOpens() {
  final previous = OpenFilePlatform.platform;
  final recorder = _RecordingOpenFile();
  OpenFilePlatform.platform = recorder;
  addTearDown(() => OpenFilePlatform.platform = previous);
  return recorder.opened;
}

class _RecordingOpenFile extends OpenFilePlatform {
  final opened = <String>[];

  @override
  Future<OpenResult> open(
    String? filePath, {
    String? type,
    bool isIOSAppOpen = false,
    String linuxDesktopName = 'xdg',
    bool linuxUseGio = false,
    bool linuxByProcess = false,
  }) async {
    opened.add(filePath!);
    return OpenResult();
  }
}
