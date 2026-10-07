import 'package:flutter/rendering.dart';

/// The view whose tree holds [nodeId], for an accessibility action the
/// engine addressed to [viewId].
///
/// Flutter 3.47's macOS embedder dispatches every view's accessibility
/// actions as the main view's: its accessibility bridge calls the engine
/// without a view id (AccessibilityBridgeMac.mm, "Remove implicit view
/// assumption", flutter/flutter#142845). A host binding with extra windows
/// routes each action back through this lookup.
///
/// Only an action addressed to [mainViewId] can be misaddressed, and the
/// framework numbers semantics nodes from one counter for every view, so a
/// node id names one view's node, except each tree's root, which is 0 in
/// every view. The main window keeps whatever it holds, and its root; any
/// other node goes to the view that has it. An id no tree holds stays where
/// it was addressed: the screen reader acted on a node a later update
/// removed, which the framework ignores.
int semanticsActionView({
  required int viewId,
  required int nodeId,
  required Map<int, SemanticsNode?> trees,
  required int mainViewId,
}) {
  if (viewId != mainViewId || nodeId == 0) return viewId;
  final main = trees[mainViewId];
  if (main != null && _holds(main, nodeId)) return viewId;
  for (final MapEntry(key: other, value: root) in trees.entries) {
    if (other == mainViewId || root == null) continue;
    if (_holds(root, nodeId)) return other;
  }
  return viewId;
}

bool _holds(SemanticsNode node, int id) {
  if (node.id == id) return true;
  var found = false;
  node.visitChildren((child) {
    found = _holds(child, id);
    return !found;
  });
  return found;
}
