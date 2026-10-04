import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/ui/adaptive_shell.dart';
import 'package:poltergeist_app/ui/shell/shell_splitter.dart';

import '../compact/compact_harness.dart';

/// D32 §3.1: every region boundary is a one-pixel seam the regions meet,
/// so a region's own horizontal lines (the header divider, the active
/// pane's accent line, a tab bar's edge) run into the vertical lines.
/// The wider grab area floats over its seam instead of pushing the
/// regions apart — it used to leave every such line 3 px short.
void main() {
  testWidgets('regions meet one-pixel seams; grab areas straddle them', (
    tester,
  ) async {
    final harness = CompactHarness();
    await harness.pump(tester, size: const Size(1400, 900));

    Rect rect(Key key) => tester.getRect(find.byKey(key));
    final sidebar = rect(const ValueKey('sidebar.region'));
    final primary = rect(AdaptiveShell.primaryPaneKey);
    final secondary = rect(AdaptiveShell.secondaryPaneKey);
    final inspector = rect(const ValueKey('inspector.region'));

    expect(primary.left - sidebar.right, shellSeamWidth);
    expect(secondary.left - primary.right, shellSeamWidth);
    expect(inspector.left - secondary.right, shellSeamWidth);

    for (final (key, seamLeft) in [
      (const ValueKey('sidebar.splitter'), sidebar.right),
      (AdaptiveShell.splitterKey, primary.right),
      (const ValueKey('inspector.splitter'), secondary.right),
    ]) {
      final splitter = rect(key);
      expect(splitter.width, shellSplitterExtent, reason: '$key');
      expect(
        splitter.center.dx,
        seamLeft + shellSeamWidth / 2,
        reason: '$key is centred on its seam',
      );
    }
  });
}
