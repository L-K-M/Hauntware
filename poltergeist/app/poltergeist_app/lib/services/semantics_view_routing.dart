import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

import 'workspace_windows/window_host.dart';

/// The app's binding: Flutter's, plus the routing that gives an extra
/// workspace window's accessibility actions to its own view (00 D39).
///
/// Flutter 3.47's macOS embedder dispatches every view's accessibility
/// actions as the implicit view's: its accessibility bridge calls the
/// engine without a view id (AccessibilityBridgeMac.mm, "Remove implicit
/// view assumption", flutter/flutter#142845). A VoiceOver press on a
/// button in an extra window would reach the main window's tree under the
/// button's node id, where no such node exists, and do nothing. The
/// runner routes each window's semantics tree to its own window
/// (PoltergeistFlutterViewController.m), so this is the other direction.
final class PoltergeistBinding extends WidgetsFlutterBinding {
  PoltergeistBinding._();

  static bool _initialized = false;

  /// Installs this binding, unless one is already running.
  static WidgetsBinding ensureInitialized() {
    if (!_initialized) {
      _initialized = true;
      PoltergeistBinding._();
    }
    return WidgetsBinding.instance;
  }

  @override
  void performSemanticsAction(SemanticsActionEvent action) {
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      final viewId = semanticsActionView(
        viewId: action.viewId,
        nodeId: action.nodeId,
        trees: {
          for (final view in renderViews)
            view.flutterView.viewId:
                view.owner?.semanticsOwner?.rootSemanticsNode,
        },
        mainViewId: mainWindowViewId,
      );
      if (viewId != action.viewId) {
        action = action.copyWith(viewId: viewId);
      }
    }
    super.performSemanticsAction(action);
  }
}
