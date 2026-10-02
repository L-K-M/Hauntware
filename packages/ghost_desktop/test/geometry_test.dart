import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

void main() {
  group('GhostWindowSnapshot', () {
    test('round-trips bounds and presentation flags through JSON', () {
      const snapshot = GhostWindowSnapshot(
        bounds: Rect.fromLTWH(120, 80, 1440, 900),
        isMaximized: true,
        isFullScreen: false,
      );
      final restored = GhostWindowSnapshot.fromJson(snapshot.toJson())!;
      expect(restored.bounds, const Rect.fromLTWH(120, 80, 1440, 900));
      expect(restored.isMaximized, isTrue);
      expect(restored.isFullScreen, isFalse);
    });

    test(
      'negative positions survive (a window on a left-of-primary monitor)',
      () {
        const snapshot = GhostWindowSnapshot(
          bounds: Rect.fromLTWH(-1920, -200, 1280, 800),
        );
        final restored = GhostWindowSnapshot.fromJson(snapshot.toJson())!;
        expect(restored.bounds, const Rect.fromLTWH(-1920, -200, 1280, 800));
      },
    );

    test('a snapshot without bounds keeps its flags', () {
      const snapshot = GhostWindowSnapshot(isFullScreen: true);
      final restored = GhostWindowSnapshot.fromJson(snapshot.toJson())!;
      expect(restored.bounds, isNull);
      expect(restored.isFullScreen, isTrue);
    });

    test('malformed JSON reads as nothing saved', () {
      expect(GhostWindowSnapshot.fromJson(null), isNull);
      expect(GhostWindowSnapshot.fromJson('not a map'), isNull);
      expect(GhostWindowSnapshot.fromJson([1, 2, 3]), isNull);
    });

    test('garbage geometry drops the bounds but keeps the flags', () {
      for (final bad in <Map<String, Object?>>[
        {'x': 'left', 'y': 0, 'width': 800, 'height': 600},
        {'x': 0, 'y': 0, 'width': 800}, // height missing
        {'x': 0, 'y': 0, 'width': 0, 'height': 600},
        {'x': 0, 'y': 0, 'width': -800, 'height': 600},
        {'x': double.nan, 'y': 0, 'width': 800, 'height': 600},
        {'x': 0, 'y': double.infinity, 'width': 800, 'height': 600},
      ]) {
        final restored = GhostWindowSnapshot.fromJson({
          ...bad,
          'isMaximized': true,
        })!;
        expect(restored.bounds, isNull, reason: '$bad');
        expect(restored.isMaximized, isTrue, reason: '$bad');
      }
    });

    test('non-bool flags read as false', () {
      final restored = GhostWindowSnapshot.fromJson({
        'isMaximized': 'yes',
        'isFullScreen': 1,
      })!;
      expect(restored.isMaximized, isFalse);
      expect(restored.isFullScreen, isFalse);
    });
  });

  group('resolveRestorableFrame', () {
    const laptop = Rect.fromLTWH(0, 0, 1512, 945);
    const external = Rect.fromLTWH(1512, -300, 2560, 1440);

    test('a frame on a connected display restores as saved', () {
      const saved = Rect.fromLTWH(100, 100, 1200, 800);
      expect(resolveRestorableFrame(saved, [laptop, external]), saved);
    });

    test('a frame on the secondary display restores there', () {
      const saved = Rect.fromLTWH(1800, -100, 1600, 1200);
      expect(resolveRestorableFrame(saved, [laptop, external]), saved);
    });

    test('a frame on a disconnected monitor falls back to the default', () {
      const saved = Rect.fromLTWH(1800, -100, 1600, 1200);
      expect(resolveRestorableFrame(saved, [laptop]), isNull);
    });

    test('a partially visible frame still restores', () {
      // Hanging off the right edge, but plenty left to grab.
      const saved = Rect.fromLTWH(1300, 200, 1000, 700);
      expect(resolveRestorableFrame(saved, [laptop]), saved);
    });

    test('a sliver of overlap is not enough to restore', () {
      // Only 40x945 points remain on-screen: too thin to grab the title bar.
      const saved = Rect.fromLTWH(1472, 0, 1000, 700);
      expect(resolveRestorableFrame(saved, [laptop]), isNull);
    });

    test('a frame hanging down from above every display is not restorable', () {
      // A 100pt-tall band of the window is visible, but the title bar is
      // above the screen — nothing to drag.
      const saved = Rect.fromLTWH(200, -600, 800, 700);
      expect(resolveRestorableFrame(saved, [laptop]), isNull);
    });

    test('a frame starting at the display top edge restores', () {
      const saved = Rect.fromLTWH(200, 0, 800, 700);
      expect(resolveRestorableFrame(saved, [laptop]), saved);
    });

    test('degenerate or non-finite frames fall back to the default', () {
      expect(resolveRestorableFrame(null, [laptop]), isNull);
      expect(
        resolveRestorableFrame(const Rect.fromLTWH(0, 0, 50, 900), [laptop]),
        isNull,
      );
      expect(
        resolveRestorableFrame(const Rect.fromLTWH(0, 0, 900, 50), [laptop]),
        isNull,
      );
      expect(
        resolveRestorableFrame(const Rect.fromLTWH(double.nan, 0, 800, 600), [
          laptop,
        ]),
        isNull,
      );
      expect(
        resolveRestorableFrame(
          const Rect.fromLTWH(0, 0, double.infinity, 600),
          [laptop],
        ),
        isNull,
      );
    });

    test('no connected displays means no restore', () {
      expect(
        resolveRestorableFrame(const Rect.fromLTWH(0, 0, 800, 600), const []),
        isNull,
      );
    });
  });

  group('clampFrameToWorkArea', () {
    const primary = Rect.fromLTWH(0, 0, 1920, 1040);
    const side = Rect.fromLTWH(1920, 0, 2560, 1440);

    test('a frame inside a work area restores unchanged', () {
      const saved = Rect.fromLTWH(200, 100, 1100, 800);
      expect(
        clampFrameToWorkArea(
          bounds: saved,
          workAreas: [primary, side],
          fallbackWorkArea: primary,
        ),
        saved,
      );
    });

    test('a frame overlapping the secondary display clamps into it', () {
      const saved = Rect.fromLTWH(2400, 200, 1500, 900);
      expect(
        clampFrameToWorkArea(
          bounds: saved,
          workAreas: [primary, side],
          fallbackWorkArea: primary,
        ),
        const Rect.fromLTWH(2400, 200, 1500, 900),
      );
    });

    test('a frame on a disconnected monitor centers on the fallback', () {
      const saved = Rect.fromLTWH(6000, 4000, 900, 600);
      expect(
        clampFrameToWorkArea(
          bounds: saved,
          workAreas: [primary],
          fallbackWorkArea: primary,
        ),
        const Rect.fromLTWH(510, 220, 900, 600),
      );
    });

    test('a frame wider than the target shrinks to fit', () {
      const saved = Rect.fromLTWH(-500, -400, 3000, 2000);
      expect(
        clampFrameToWorkArea(
          bounds: saved,
          workAreas: [primary],
          fallbackWorkArea: primary,
        ),
        const Rect.fromLTWH(0, 0, 1920, 1040),
      );
    });
  });
}
