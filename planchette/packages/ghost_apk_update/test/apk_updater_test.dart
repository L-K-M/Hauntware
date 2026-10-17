import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_apk_update/ghost_apk_update.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Records what the plugin would have been asked, over a real directory.
class _FakeInstaller extends ApkInstaller {
  _FakeInstaller(this.directory);

  final Directory directory;
  final installed = <String>[];
  bool refuse = false;

  @override
  Future<String> stagingDirectory() async => directory.path;

  @override
  Future<void> install(String path) async {
    installed.add(path);
    if (refuse) throw PlatformException(code: 'WRONG_PACKAGE');
  }
}

void main() {
  final apkBytes = List<int>.generate(300 * 1024, (i) => i % 251);
  final release = ApkRelease(
    url: Uri.parse('https://example.test/app-android.apk'),
    size: apkBytes.length,
    sha256: sha256.convert(apkBytes).toString(),
  );

  late Directory staging;
  late _FakeInstaller installer;
  late int requests;

  setUp(() async {
    staging = await Directory.systemTemp.createTemp('ghost_apk_update_');
    installer = _FakeInstaller(staging);
    requests = 0;
  });

  tearDown(() => staging.delete(recursive: true));

  /// Serves [body] in 16 KiB chunks, the way a socket delivers it.
  http.Client serving(List<int> body, {int status = HttpStatus.ok}) =>
      MockClient.streaming((request, _) async {
        requests++;
        final chunks = [
          for (var start = 0; start < body.length; start += 16 * 1024)
            body.sublist(start, (start + 16 * 1024).clamp(0, body.length)),
        ];
        return http.StreamedResponse(Stream.fromIterable(chunks), status);
      });

  List<String> stagedNames() => [
    for (final entry in staging.listSync()) entry.uri.pathSegments.last,
  ];

  test('a verified download opens the installer on the staged file', () async {
    final updater = ApkUpdater(client: serving(apkBytes), installer: installer);
    final states = <ApkUpdateState>[];
    updater.addListener(() => states.add(updater.state));

    await updater.update(release);

    expect(updater.state, isA<ApkUpdateReady>());
    expect(installer.installed, ['${staging.path}/update.apk']);
    expect(File(installer.installed.single).readAsBytesSync(), apkBytes);
    expect(stagedNames(), ['update.apk']);

    // Progress climbs to the full size, one notification per percent
    // at most, however many chunks arrive.
    final progress = states.whereType<ApkUpdateDownloading>().toList();
    expect(progress.first.received, 0);
    expect(progress.last.received, apkBytes.length);
    expect(progress.length, lessThanOrEqualTo(102));
  });

  test('a digest mismatch discards the file and never opens it', () async {
    final tampered = [...apkBytes]..[1000] ^= 0xff;
    final updater = ApkUpdater(client: serving(tampered), installer: installer);

    await updater.update(release);

    expect(
      (updater.state as ApkUpdateFailed).failure,
      ApkUpdateFailure.verification,
    );
    expect(installer.installed, isEmpty);
    expect(stagedNames(), isEmpty);
  });

  test('a short or oversized body fails verification', () async {
    for (final body in [
      apkBytes.sublist(0, apkBytes.length - 1),
      [...apkBytes, 0],
    ]) {
      final updater = ApkUpdater(client: serving(body), installer: installer);

      await updater.update(release);

      expect(
        (updater.state as ApkUpdateFailed).failure,
        ApkUpdateFailure.verification,
      );
      expect(stagedNames(), isEmpty);
    }
    expect(installer.installed, isEmpty);
  });

  test('a refused download is a download failure', () async {
    final updater = ApkUpdater(
      client: serving(const [], status: HttpStatus.notFound),
      installer: installer,
    );

    await updater.update(release);

    expect(
      (updater.state as ApkUpdateFailed).failure,
      ApkUpdateFailure.download,
    );
    expect(installer.installed, isEmpty);
  });

  test('an unreachable server is a download failure', () async {
    final updater = ApkUpdater(
      client: MockClient((_) => throw const SocketException('offline')),
      installer: installer,
    );

    await updater.update(release);

    expect(
      (updater.state as ApkUpdateFailed).failure,
      ApkUpdateFailure.download,
    );
  });

  test('a refused install retries without downloading again', () async {
    installer.refuse = true;
    final updater = ApkUpdater(client: serving(apkBytes), installer: installer);

    await updater.update(release);
    expect(
      (updater.state as ApkUpdateFailed).failure,
      ApkUpdateFailure.installer,
    );

    installer.refuse = false;
    await updater.update(release);

    expect(updater.state, isA<ApkUpdateReady>());
    expect(requests, 1);
    expect(installer.installed, hasLength(2));
  });

  test(
    'a newer release downloads again and replaces the staged file',
    () async {
      final newerBytes = [...apkBytes, 1, 2, 3];
      final newer = ApkRelease(
        url: Uri.parse('https://example.test/newer.apk'),
        size: newerBytes.length,
        sha256: sha256.convert(newerBytes).toString(),
      );
      final updater = ApkUpdater(
        client: MockClient.streaming((request, _) async {
          requests++;
          final body = request.url == newer.url ? newerBytes : apkBytes;
          return http.StreamedResponse(Stream.value(body), HttpStatus.ok);
        }),
        installer: installer,
      );

      await updater.update(release);
      await updater.update(newer);

      expect(requests, 2);
      expect(stagedNames(), ['update.apk']);
      expect(File(installer.installed.last).readAsBytesSync(), newerBytes);
    },
  );

  test('Cancel stops the download, discards it and returns to idle', () async {
    final body = StreamController<List<int>>();
    final updater = ApkUpdater(
      client: MockClient.streaming((request, _) async {
        requests++;
        return http.StreamedResponse(body.stream, HttpStatus.ok);
      }),
      installer: installer,
    );

    final running = updater.update(release);
    await pumpEventQueue();
    body.add(apkBytes.sublist(0, 1024));
    await pumpEventQueue();
    expect(updater.state, isA<ApkUpdateDownloading>());

    // A second Update while one runs is ignored.
    await updater.update(release);
    expect(requests, 1);

    updater.cancel();
    body.add(apkBytes.sublist(1024, 2048));
    await running;
    await body.close();

    expect(updater.state, isA<ApkUpdateIdle>());
    expect(installer.installed, isEmpty);
    expect(stagedNames(), isEmpty);
  });
}
