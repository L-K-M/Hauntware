import 'dart:ui' show Rect;

/// The desktop main-window geometry carried across launches. [bounds] is the
/// last user-arranged *normal* frame (never a maximized or full-screen one) —
/// the position doubles as the monitor choice, so restoring it puts the window
/// back on the display it was closed on. The flags say how the window was
/// presented on top of that frame.
///
/// The coordinate space of [bounds] is host-defined (see
/// [GhostCoordinateSpace]): Séance stores physical pixels on Windows because
/// window_manager converts with the *current* monitor's ratio while
/// screen_retriever scales each display by its own, so on mixed-DPI Windows
/// setups no single logical space is stable across a relaunch. Physical
/// pixels are the one space every Windows API maps into exactly. The file is
/// device-local, so the unit never has to travel.
final class GhostWindowSnapshot {
  final Rect? bounds;
  final bool isMaximized;
  final bool isFullScreen;

  const GhostWindowSnapshot({
    this.bounds,
    this.isMaximized = false,
    this.isFullScreen = false,
  });

  /// The JSON shape Séance's `window_state.json` established. Shared so every
  /// host persisting this layout reads and writes the same file — hosts with
  /// a different schema keep their own codec inside their persistence
  /// adapter instead.
  Map<String, dynamic> toJson() => {
    if (bounds != null) 'x': bounds!.left,
    if (bounds != null) 'y': bounds!.top,
    if (bounds != null) 'width': bounds!.width,
    if (bounds != null) 'height': bounds!.height,
    'isMaximized': isMaximized,
    'isFullScreen': isFullScreen,
  };

  /// Tolerant parse: anything malformed reads as "nothing saved". Window
  /// geometry is cheap to lose, so there is no quarantine ceremony here — the
  /// next save simply overwrites a bad file.
  static GhostWindowSnapshot? fromJson(Object? json) {
    if (json is! Map) return null;
    double? dim(Object? value) {
      if (value is! num) return null;
      final d = value.toDouble();
      return d.isFinite ? d : null;
    }

    final x = dim(json['x']);
    final y = dim(json['y']);
    final width = dim(json['width']);
    final height = dim(json['height']);
    Rect? bounds;
    if (x != null &&
        y != null &&
        width != null &&
        height != null &&
        width > 0 &&
        height > 0) {
      bounds = Rect.fromLTWH(x, y, width, height);
    }
    return GhostWindowSnapshot(
      bounds: bounds,
      isMaximized: json['isMaximized'] == true,
      isFullScreen: json['isFullScreen'] == true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GhostWindowSnapshot &&
      other.bounds == bounds &&
      other.isMaximized == isMaximized &&
      other.isFullScreen == isFullScreen;

  @override
  int get hashCode => Object.hash(bounds, isMaximized, isFullScreen);
}
