import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// A View › Zoom command.
enum EditorZoom { zoomIn, zoomOut, actualSize }

/// The editor's text size in logical pixels: one range and one set of zoom
/// steps for every app, so Zoom In moves the same way in Planchette, Séance
/// and Poltergeist. Each app stores the size itself; this only says which
/// sizes are valid and where a zoom lands.
abstract final class EditorTextSize {
  /// The bounds a stored size is clamped to, so a bad value cannot make the
  /// editor unreadable.
  static const int minimum = 9;
  static const int maximum = 48;

  /// Actual Size.
  static const int standard = 14;

  /// The sizes Zoom In and Zoom Out step through. A stored size need not be
  /// one of them (a slider reaches every size between); a step goes to the
  /// nearest one past it.
  static const List<int> steps = [
    minimum,
    10,
    11,
    12,
    13,
    standard,
    16,
    18,
    20,
    22,
    24,
    28,
    32,
    36,
    maximum,
  ];

  /// [size] inside the valid range.
  static int clamp(int size) => size.clamp(minimum, maximum);

  /// The size [zoom] leads to from [size]. Zooming past either end keeps
  /// the end: `zoomed(48, EditorZoom.zoomIn)` is 48.
  static int zoomed(int size, EditorZoom zoom) => switch (zoom) {
    EditorZoom.zoomIn => steps.firstWhere(
      (step) => step > size,
      orElse: () => clamp(size),
    ),
    EditorZoom.zoomOut => steps.lastWhere(
      (step) => step < size,
      orElse: () => clamp(size),
    ),
    EditorZoom.actualSize => standard,
  };

  /// Whether [zoom] changes [size]: a host greys the command out otherwise.
  static bool canZoom(int size, EditorZoom zoom) => zoomed(size, zoom) != size;

  /// The chords for [zoom]: Command on Apple platforms and Control
  /// elsewhere. The first is the one a menu shows. The rest cover where `+`
  /// and `-` sit across layouts, shifted or not, and the numeric keypad.
  static List<SingleActivator> activators(
    EditorZoom zoom,
    TargetPlatform platform,
  ) {
    final apple = switch (platform) {
      TargetPlatform.iOS || TargetPlatform.macOS => true,
      _ => false,
    };
    SingleActivator primary(LogicalKeyboardKey key, {bool shift = false}) =>
        SingleActivator(key, meta: apple, control: !apple, shift: shift);
    return switch (zoom) {
      EditorZoom.zoomIn => [
        primary(LogicalKeyboardKey.equal),
        primary(LogicalKeyboardKey.equal, shift: true),
        primary(LogicalKeyboardKey.add),
        primary(LogicalKeyboardKey.add, shift: true),
        primary(LogicalKeyboardKey.numpadAdd),
      ],
      EditorZoom.zoomOut => [
        primary(LogicalKeyboardKey.minus),
        primary(LogicalKeyboardKey.numpadSubtract),
      ],
      EditorZoom.actualSize => [
        primary(LogicalKeyboardKey.digit0),
        primary(LogicalKeyboardKey.numpad0),
      ],
    };
  }
}
