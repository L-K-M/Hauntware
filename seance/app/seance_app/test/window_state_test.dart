import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:seance_app/services/window_state.dart';

/// Séance's `window_state.json` through its own atomic writer. The store's
/// loading and save ordering are ghost_desktop's GhostWindowStateFile tests.
void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('window_state_test');
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });

  File storeFile() => File('${dir.path}/window_state.json');

  test('the file keeps the window_state.json schema', () async {
    const snapshot = GhostWindowSnapshot(
      bounds: Rect.fromLTWH(10, 20, 1000, 700),
      isFullScreen: true,
    );
    await windowStateFile(storeFile()).save(snapshot);

    expect(
      await storeFile().readAsString(),
      '{"x":10.0,"y":20.0,"width":1000.0,"height":700.0,'
      '"isMaximized":false,"isFullScreen":true}',
    );
    expect(jsonDecode(await storeFile().readAsString()), snapshot.toJson());
    expect(await windowStateFile(storeFile()).load(), snapshot);
  });

  test('queued saves land last-writer-wins', () async {
    final store = windowStateFile(storeFile());
    await Future.wait([
      store.save(
        const GhostWindowSnapshot(bounds: Rect.fromLTWH(0, 0, 800, 600)),
      ),
      store.save(
        const GhostWindowSnapshot(bounds: Rect.fromLTWH(5, 5, 900, 700)),
      ),
    ]);
    final restored = await windowStateFile(storeFile()).load();
    expect(restored!.bounds, const Rect.fromLTWH(5, 5, 900, 700));
  });
}
