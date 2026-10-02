import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/window_state.dart';

void main() {
  late Directory tempDir;
  late File stateFile;
  late WindowStateStore store;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('window_state_test');
    stateFile = File(paths.join(tempDir.path, 'window_state.json'));
    store = WindowStateStore(stateFile);
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('a missing file loads as no state', () async {
    expect(await store.load(), isNull);
  });

  test('a saved snapshot round-trips through the file', () async {
    const snapshot = GhostWindowSnapshot(
      bounds: Rect.fromLTWH(120, 80, 1180, 760),
      isMaximized: true,
    );
    await store.save(snapshot);

    final reloaded = WindowStateStore(stateFile);
    expect(await reloaded.load(), snapshot);
  });

  test('the file uses the shared window-state schema', () async {
    await store.save(
      const GhostWindowSnapshot(
        bounds: Rect.fromLTWH(10, 20, 800, 600),
        isFullScreen: true,
      ),
    );

    final decoded = jsonDecode(await stateFile.readAsString());
    expect(decoded, {
      'x': 10.0,
      'y': 20.0,
      'width': 800.0,
      'height': 600.0,
      'isMaximized': false,
      'isFullScreen': true,
    });
  });

  test('flags without a frame persist on their own', () async {
    const snapshot = GhostWindowSnapshot(isMaximized: true);
    await store.save(snapshot);
    expect(await store.load(), snapshot);
  });

  test(
    'a malformed file loads as no state, then a save overwrites it',
    () async {
      await stateFile.writeAsString('this is not json');
      expect(await store.load(), isNull);

      // Malformed geometry is discarded; what remains is an empty snapshot.
      await stateFile.writeAsString('{"x": "soon", "width": -4}');
      expect(await store.load(), const GhostWindowSnapshot());

      const snapshot = GhostWindowSnapshot(
        bounds: Rect.fromLTWH(0, 0, 900, 700),
      );
      await store.save(snapshot);
      expect(await store.load(), snapshot);
    },
  );

  test(
    'a save through a symlink writes the link target',
    () async {
      final target = File(paths.join(tempDir.path, 'real_state.json'));
      final link = Link(paths.join(tempDir.path, 'linked_state.json'));
      await link.create(target.path);

      final linked = WindowStateStore(File(link.path));
      const snapshot = GhostWindowSnapshot(
        bounds: Rect.fromLTWH(5, 5, 640, 480),
      );
      await linked.save(snapshot);

      expect(await target.exists(), isTrue);
      expect(await FileSystemEntity.isLink(link.path), isTrue);
      expect(await WindowStateStore(target).load(), snapshot);
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
}
