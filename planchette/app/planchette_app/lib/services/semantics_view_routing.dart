import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:ghost_desktop/ghost_desktop.dart';

import 'window_host.dart';

/// The app's binding: Flutter's, plus the routing that gives an extra
/// document window's accessibility actions to its own view.
///
/// Flutter 3.47's macOS embedder dispatches every view's accessibility
/// actions as the implicit view's: its accessibility bridge calls the
/// engine without a view id (AccessibilityBridgeMac.mm, "Remove implicit
/// view assumption", flutter/flutter#142845). A VoiceOver press on a
/// button in an extra window would reach the main window's tree under the
/// button's node id, where no such node exists, and do nothing. The
/// runner routes each window's semantics tree to its own window
/// (PlanchetteFlutterViewController.m), so this is the other direction.
final class PlanchetteBinding extends WidgetsFlutterBinding {
  PlanchetteBinding._();

  static bool _initialized = false;

  /// Installs this binding, unless one is already running — the test
  /// harness's, say, which stays in charge rather than being replaced
  /// (a second BindingBase would assert in debug).
  static WidgetsBinding ensureInitialized() {
    // Asking WidgetsBinding.instance cannot tell: before any binding it
    // throws a FlutterError only from an assert, and release builds hit a
    // null check instead. Only debug builds record the running binding's
    // type, so null in release means none, which holds there: no harness.
    if (_initialized || BindingBase.debugBindingType() != null) {
      return WidgetsBinding.instance;
    }
    _initialized = true;
    return PlanchetteBinding._();
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
