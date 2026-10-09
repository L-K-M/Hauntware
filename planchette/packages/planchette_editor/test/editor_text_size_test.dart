import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  test('zoom steps through the shared sizes', () {
    expect(EditorTextSize.zoomed(14, EditorZoom.zoomIn), 16);
    expect(EditorTextSize.zoomed(14, EditorZoom.zoomOut), 13);
    expect(EditorTextSize.zoomed(36, EditorZoom.zoomIn), 48);
    expect(EditorTextSize.zoomed(30, EditorZoom.actualSize), 14);
  });

  test('a size between steps goes to the nearest step past it', () {
    expect(EditorTextSize.zoomed(15, EditorZoom.zoomIn), 16);
    expect(EditorTextSize.zoomed(15, EditorZoom.zoomOut), 14);
  });

  test('a size outside the range zooms back into it', () {
    for (final zoom in [EditorZoom.zoomIn, EditorZoom.zoomOut]) {
      expect(EditorTextSize.zoomed(60, zoom), EditorTextSize.maximum);
      expect(EditorTextSize.zoomed(4, zoom), EditorTextSize.minimum);
    }
  });

  test('zooming past either end keeps the end', () {
    expect(EditorTextSize.zoomed(48, EditorZoom.zoomIn), 48);
    expect(EditorTextSize.zoomed(9, EditorZoom.zoomOut), 9);
    expect(EditorTextSize.canZoom(48, EditorZoom.zoomIn), isFalse);
    expect(EditorTextSize.canZoom(9, EditorZoom.zoomOut), isFalse);
    expect(EditorTextSize.canZoom(14, EditorZoom.actualSize), isFalse);
    expect(EditorTextSize.canZoom(16, EditorZoom.actualSize), isTrue);
  });

  test('a stored size is clamped to the range', () {
    expect(EditorTextSize.clamp(4), EditorTextSize.minimum);
    expect(EditorTextSize.clamp(99), EditorTextSize.maximum);
    expect(EditorTextSize.clamp(17), 17);
    expect(EditorTextSize.steps.first, EditorTextSize.minimum);
    expect(EditorTextSize.steps.last, EditorTextSize.maximum);
    expect(EditorTextSize.steps, contains(EditorTextSize.standard));
  });

  test('chords use Command on Apple platforms and Control elsewhere', () {
    final mac = EditorTextSize.activators(
      EditorZoom.zoomIn,
      TargetPlatform.macOS,
    ).first;
    expect(mac.trigger, LogicalKeyboardKey.equal);
    expect(mac.meta, isTrue);
    expect(mac.control, isFalse);

    final linux = EditorTextSize.activators(
      EditorZoom.zoomOut,
      TargetPlatform.linux,
    ).first;
    expect(linux.trigger, LogicalKeyboardKey.minus);
    expect(linux.control, isTrue);
    expect(linux.meta, isFalse);

    expect(
      EditorTextSize.activators(
        EditorZoom.actualSize,
        TargetPlatform.iOS,
      ).map((chord) => chord.trigger),
      [LogicalKeyboardKey.digit0, LogicalKeyboardKey.numpad0],
    );
  });
}
