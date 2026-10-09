import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/download_provenance.dart';
import 'package:seance_app/services/external_file_opener.dart';

void main() {
  late Directory directory;
  late File file;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-provenance-');
    file = File('${directory.path}/setup.bin')..writeAsBytesSync([0, 1, 2]);
  });

  tearDown(() => directory.delete(recursive: true));

  test('Windows gets a Mark-of-the-Web stream for the internet zone', () async {
    await DownloadProvenance.forHost(
      EditorHostPlatform.windows,
    ).markDownloaded(file.path);

    // On this non-NTFS test host the stream lands as a sibling file named
    // exactly like the stream path Windows would open.
    expect(
      await File('${file.path}:Zone.Identifier').readAsString(),
      '[ZoneTransfer]\r\nZoneId=3\r\n',
    );
  });

  test('macOS gets a quarantine attribute through xattr', () async {
    final calls = <List<String>>[];
    await DownloadProvenance.forHost(
      EditorHostPlatform.macos,
      runProcess: (executable, arguments) async {
        calls.add([executable, ...arguments]);
        return ProcessResult(0, 0, '', '');
      },
    ).markDownloaded(file.path);

    expect(calls, hasLength(1));
    final call = calls.single;
    expect(call.take(3), ['/usr/bin/xattr', '-wx', 'com.apple.quarantine']);
    final value = String.fromCharCodes([
      for (var i = 0; i < call[3].length; i += 2)
        int.parse(call[3].substring(i, i + 2), radix: 16),
    ]);
    expect(value, matches(RegExp(r'^0081;[0-9a-f]+;Seance;[0-9a-f-]{36}$')));
    expect(call[4], file.path);
  });

  test('a failed mark never stops the caller', () async {
    final failing = DownloadProvenance.forHost(
      EditorHostPlatform.macos,
      runProcess: (_, _) async =>
          ProcessResult(0, 1, '', 'Operation not permitted'),
    );
    final throwing = DownloadProvenance.forHost(
      EditorHostPlatform.macos,
      runProcess: (_, _) => throw const ProcessException('xattr', []),
    );

    await failing.markDownloaded(file.path);
    await throwing.markDownloaded(file.path);
    await DownloadProvenance.forHost(
      EditorHostPlatform.windows,
    ).markDownloaded('${directory.path}/missing/setup.bin');
  });

  test('Linux has nothing to mark', () async {
    var ran = false;
    await DownloadProvenance.forHost(
      EditorHostPlatform.linux,
      runProcess: (_, _) async {
        ran = true;
        return ProcessResult(0, 0, '', '');
      },
    ).markDownloaded(file.path);

    expect(ran, isFalse);
    expect(directory.listSync(), hasLength(1));
  });
}
