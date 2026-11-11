// P1-03a: a log or diagnostic export is remote-sourced, so the export
// host stamps what it saves or shares as downloaded and owner-only.
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/ui/logs/log_export.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('klabautermann-export-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => root.path,
        );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('a staged share file is marked and owner-only', () async {
    final marked = <String>[];
    final provenance = DownloadProvenance.forHost(
      ProvenancePlatform.macos,
      agent: 'Klabautermann',
      runProcess: (executable, arguments) async {
        marked.add(arguments.last);
        return ProcessResult(0, 0, '', '');
      },
    );

    final file = await stageMarkedExport(
      'logs.txt',
      Uint8List.fromList([1, 0, 1]),
      provenance,
    );

    expect(file.existsSync(), isTrue);
    expect(marked, [file.path]);
    if (!Platform.isWindows) {
      expect(file.statSync().mode & 0x1ff, 0x180);
    }
  });

  test('a failed staging write deletes its temporary directory', () async {
    final provenance = DownloadProvenance.forHost(
      ProvenancePlatform.linux,
      agent: 'Klabautermann',
    );

    await expectLater(
      stageMarkedExport(
        'missing/logs.txt',
        Uint8List.fromList([1, 0, 1]),
        provenance,
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(stagedExports(root), isEmpty);
  });

  test('markSavedExport swallows a failed mark', () async {
    final file = File('${root.path}/saved.log')..writeAsBytesSync([1]);

    await markSavedExport(file.path, _ThrowingProvenance());

    expect(file.existsSync(), isTrue);
  });

  test('only a saved file has a path to mark', () {
    final file = File('${root.path}/saved.log');

    expect(savedExportPath(file.uri), file.path);
    // Android's picker saves through a document provider.
    expect(
      savedExportPath(
        Uri.parse('content://com.android.providers.downloads/document/7'),
      ),
      isNull,
    );
  });

  // Plain tests: staging does real file I/O, which never completes
  // under testWidgets' fake clock.
  test('a shared export is staged until the retention ends', () async {
    mockShareHandler((call) async => 'dev.fluttercommunity.plus/share/success');

    await shareOnce(retention: const Duration(milliseconds: 50));

    expect(stagedExports(root), hasLength(1));

    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(stagedExports(root), isEmpty);
  });

  test('a failed share deletes its staged export', () async {
    mockShareHandler(
      (call) async => throw PlatformException(code: 'share_failed'),
    );

    await expectLater(
      shareOnce(retention: const Duration(hours: 1)),
      throwsA(isA<PlatformException>()),
    );

    expect(stagedExports(root), isEmpty);
  });
}

void mockShareHandler(Future<dynamic> Function(MethodCall call) handler) {
  const channel = MethodChannel('dev.fluttercommunity.plus/share');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(channel, handler);
  addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
}

List<Directory> stagedExports(Directory root) =>
    root.listSync().whereType<Directory>().toList();

Future<void> shareOnce({required Duration retention}) async {
  final host = PluginLogExportHost(
    provenance: DownloadProvenance.forHost(
      ProvenancePlatform.macos,
      agent: 'Klabautermann',
      runProcess: (executable, arguments) async => ProcessResult(0, 0, '', ''),
    ),
    stagedRetention: retention,
  );
  await host.share('logs.txt', Uint8List.fromList([1, 0, 1]));
}

final class _ThrowingProvenance extends DownloadProvenance {
  _ThrowingProvenance() : super(agent: 'Klabautermann');

  @override
  Future<void> markDownloaded(String path) async => throw StateError('no');
}
