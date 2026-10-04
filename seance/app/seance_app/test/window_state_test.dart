import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';
import 'package:seance_app/services/window_state.dart';

void main() {
  group('WindowStateStore', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('window_state_test');
    });
    tearDown(() async {
      await dir.delete(recursive: true);
    });

    File storeFile() => File('${dir.path}/window_state.json');

    test('a missing file loads as nothing saved', () async {
      expect(await WindowStateStore(storeFile()).load(), isNull);
    });

    test('saves and reloads a snapshot', () async {
      final store = WindowStateStore(storeFile());
      await store.save(
        const GhostWindowSnapshot(
          bounds: Rect.fromLTWH(10, 20, 1000, 700),
          isFullScreen: true,
        ),
      );
      final restored = await WindowStateStore(storeFile()).load();
      expect(restored!.bounds, const Rect.fromLTWH(10, 20, 1000, 700));
      expect(restored.isFullScreen, isTrue);
      expect(restored.isMaximized, isFalse);
    });

    test('an unparseable file loads as nothing saved', () async {
      await storeFile().writeAsString('{not json');
      expect(await WindowStateStore(storeFile()).load(), isNull);
    });

    test('a window_state.json from an earlier release still loads', () async {
      await storeFile().writeAsString(
        '{"x":10.0,"y":20.0,"width":1000.0,"height":700.0,'
        '"isMaximized":false,"isFullScreen":true}',
      );
      final restored = await WindowStateStore(storeFile()).load();
      expect(restored!.bounds, const Rect.fromLTWH(10, 20, 1000, 700));
      expect(restored.isMaximized, isFalse);
      expect(restored.isFullScreen, isTrue);
    });

    test('the file keeps the window_state.json schema', () async {
      await WindowStateStore(storeFile()).save(
        const GhostWindowSnapshot(
          bounds: Rect.fromLTWH(10, 20, 1000, 700),
          isFullScreen: true,
        ),
      );
      expect(jsonDecode(await storeFile().readAsString()), {
        'x': 10.0,
        'y': 20.0,
        'width': 1000.0,
        'height': 700.0,
        'isMaximized': false,
        'isFullScreen': true,
      });
    });

    test('queued saves land last-writer-wins', () async {
      final store = WindowStateStore(storeFile());
      final first = store.save(
        const GhostWindowSnapshot(bounds: Rect.fromLTWH(0, 0, 800, 600)),
      );
      final second = store.save(
        const GhostWindowSnapshot(bounds: Rect.fromLTWH(5, 5, 900, 700)),
      );
      await Future.wait([first, second]);
      final restored = await WindowStateStore(storeFile()).load();
      expect(restored!.bounds, const Rect.fromLTWH(5, 5, 900, 700));
    });
  });
}
