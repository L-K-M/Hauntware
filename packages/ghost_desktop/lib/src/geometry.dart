import 'dart:ui';

/// Séance's missing-monitor rule: decide whether a saved frame can be
/// restored onto the currently connected displays (their visible areas, in
/// the same coordinate space as the frame). Returns the frame to restore, or
/// null to fall back to the platform's default placement — when the monitor
/// the window lived on is gone, or the saved values are degenerate.
/// "Restorable" means enough of the frame lands on some display to grab the
/// title bar and drag the window back by hand — which is specifically the
/// frame's *top* strip: a frame hanging down from above every screen shows
/// plenty of window but nothing to drag.
Rect? resolveRestorableFrame(Rect? saved, Iterable<Rect> workAreas) {
  if (saved == null) return null;
  const minimumWindowSize = 100.0;
  if (!saved.left.isFinite ||
      !saved.top.isFinite ||
      !saved.width.isFinite ||
      !saved.height.isFinite) {
    return null;
  }
  if (saved.width < minimumWindowSize || saved.height < minimumWindowSize) {
    return null;
  }
  for (final area in workAreas) {
    final overlap = saved.intersect(area);
    if (overlap.width < minimumWindowSize || overlap.height < 50) continue;
    // The title bar sits at the frame's top edge, so that edge must be on
    // this display (1px of tolerance for rounding), or the visible chunk is
    // un-draggable.
    if (saved.top < area.top - 1) continue;
    return saved;
  }
  return null;
}

/// Poltergeist's missing-monitor rule: instead of rejecting a frame whose
/// display is gone, clamp it onto the work area it overlapped most (or center
/// it on the primary fallback), so the window always opens fully on-screen.
Rect clampFrameToWorkArea({
  required Rect bounds,
  required List<Rect> workAreas,
  required Rect fallbackWorkArea,
}) {
  // Degenerate or non-finite saved geometry (NaN survives num.clamp, so it
  // must be stopped here): center a usable frame on the fallback rather
  // than propagate it into the native setBounds.
  if (!bounds.left.isFinite ||
      !bounds.top.isFinite ||
      !bounds.width.isFinite ||
      !bounds.height.isFinite ||
      // Sub-pixel too: 0 < w < 1 passes coverage trivially and would
      // "restore" an invisible window.
      bounds.width < 1 ||
      bounds.height < 1) {
    final width = fallbackWorkArea.width < 960.0
        ? fallbackWorkArea.width
        : 960.0;
    final height = fallbackWorkArea.height < 640.0
        ? fallbackWorkArea.height
        : 640.0;
    return Rect.fromCenter(
      center: fallbackWorkArea.center,
      width: width,
      height: height,
    );
  }

  // A frame already fully covered by the present work areas — one
  // legitimately spanning two displays, for instance — is not a
  // missing-monitor case at all: nothing is off-screen to recover.
  // Work areas are disjoint, so summing per-area intersections is the
  // union's coverage.
  var covered = 0.0;
  for (final area in workAreas) {
    final overlap = bounds.intersect(area);
    covered +=
        overlap.width.clamp(0.0, double.infinity) *
        overlap.height.clamp(0.0, double.infinity);
  }
  if (covered >= bounds.width * bounds.height - 1) return bounds;

  final target = _bestWorkArea(bounds, workAreas) ?? fallbackWorkArea;
  final width = bounds.width.clamp(0, target.width).toDouble();
  final height = bounds.height.clamp(0, target.height).toDouble();
  final size = Size(width, height);

  if (!_overlaps(bounds, target)) {
    final left = target.left + (target.width - size.width) / 2;
    final top = target.top + (target.height - size.height) / 2;
    return Rect.fromLTWH(left, top, size.width, size.height);
  }

  final left = bounds.left.clamp(target.left, target.right - width).toDouble();
  final top = bounds.top.clamp(target.top, target.bottom - height).toDouble();
  return Rect.fromLTWH(left, top, width, height);
}

Rect? _bestWorkArea(Rect bounds, List<Rect> workAreas) {
  Rect? best;
  var bestOverlap = 0.0;
  for (final workArea in workAreas) {
    final overlap = bounds.intersect(workArea);
    final area =
        (overlap.width.clamp(0, double.infinity) *
                overlap.height.clamp(0, double.infinity))
            .toDouble();
    if (area <= bestOverlap) continue;

    best = workArea;
    bestOverlap = area;
  }

  return best;
}

bool _overlaps(Rect first, Rect second) {
  final overlap = first.intersect(second);
  return overlap.width > 0 && overlap.height > 0;
}
