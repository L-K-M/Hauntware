import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/window_state.dart';

/// Planchette's `window_state.json` through the atomic writer settings.json
/// uses. Loading, the schema and save ordering are ghost_desktop's
/// GhostWindowStateFile tests.
void main() {
  late Directory tempDir;
  late File stateFile;
  late GhostWindowStateFile store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('window_state_test');
    stateFile = File(paths.join(tempDir.path, 'window_state.json'));
    store = windowStateFile(stateFile);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test(
    'a save through a symlink writes the link target',
    () async {
      final target = File(paths.join(tempDir.path, 'real_state.json'));
      final link = Link(paths.join(tempDir.path, 'linked_state.json'));
      await link.create(target.path);

      final linked = windowStateFile(File(link.path));
      const snapshot = GhostWindowSnapshot(
        bounds: Rect.fromLTWH(5, 5, 640, 480),
      );
      await linked.save(snapshot);

      expect(await target.exists(), isTrue);
      expect(await FileSystemEntity.isLink(link.path), isTrue);
      expect(await windowStateFile(target).load(), snapshot);
    },
    // Link.create needs administrator or developer-mode privileges there.
    skip: Platform.isWindows ? 'symlink creation needs privileges' : null,
  );

  test('a crash mid-write leaves the previous state readable', () async {
    const first = GhostWindowSnapshot(bounds: Rect.fromLTWH(1, 1, 100, 100));
    await store.save(first);
    // A staging file left behind by an interrupted save is inert.
    await File('${stateFile.path}.tmp').writeAsString('{"x":');
    expect(await store.load(), first);
  });

  test('a failed staging write leaves the previous state', () async {
    const first = GhostWindowSnapshot(bounds: Rect.fromLTWH(1, 1, 100, 100));
    await store.save(first);
    expect(
      await stateFile.readAsString(),
      '${const JsonEncoder.withIndent('  ').convert(first.toJson())}\n',
    );
    final original = await stateFile.rename(
      '${stateFile.path}.before-test-write',
    );
    final blocker = await Directory(stateFile.path).create();
    try {
      await expectLater(
        store.save(const GhostWindowSnapshot(isMaximized: true)),
        throwsA(isA<FileSystemException>()),
      );
    } finally {
      await blocker.delete();
      await original.rename(stateFile.path);
    }
    expect(await store.load(), first);
  });
}
