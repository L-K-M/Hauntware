import 'dart:ui' show FlutterView;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../services/document_windows.dart';

/// Where the macOS menu bar's items come from with several windows: the
/// active window's shell publishes its items here and the windows root
/// renders the app's one `PlatformMenuBar` from them. Each window rendering
/// its own bar would fight over the one native menu bar, and a closing
/// window's bar would clear the menus the next window had just set.
///
/// Publishing goes through [publish]/[clear] rather than `value` directly
/// so a window that is going away can retract only its own items.
final class MenuBarSlot extends ValueNotifier<List<PlatformMenuItem>> {
  MenuBarSlot(super.value);

  Object? _owner;

  /// The active window's latest items. [owner] is its DocumentWindow.
  void publish(Object owner, List<PlatformMenuItem> menus) {
    _owner = owner;
    value = menus;
  }

  /// [owner]'s window is gone: retract its items so a stale row cannot
  /// run a dead command. Another window's items are left alone.
  void clear(Object owner) {
    if (identical(_owner, owner)) value = const [];
  }
}

/// The desktop app's root: one [View] per open document window, each
/// rendering the app [buildWindow] builds for it, over the one engine and
/// isolate every window shares.
///
/// A window's view comes from the runner, so a window only renders once
/// the engine has added its view; the runner's `create` reply and the
/// engine's view announcement arrive in either order.
class DocumentWindowsRoot extends StatefulWidget {
  const DocumentWindowsRoot({
    super.key,
    required this.windows,
    required this.buildWindow,
    this.viewFor,
  });

  final DocumentWindows windows;

  /// The app for one window: its `PlanchetteApp`. [menuSlot] is null off
  /// macOS, where each window renders its own in-window menu bar instead.
  final Widget Function(DocumentWindow window, MenuBarSlot? menuSlot)
  buildWindow;

  /// Looks a view up by id; null reads the engine's views. A test seam.
  final FlutterView? Function(int viewId)? viewFor;

  @override
  State<DocumentWindowsRoot> createState() => _DocumentWindowsRootState();
}

class _DocumentWindowsRootState extends State<DocumentWindowsRoot>
    with WidgetsBindingObserver {
  /// macOS: the one native menu bar, fed by the active window.
  MenuBarSlot? _menuSlot;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.windows.addListener(_changed);
    if (defaultTargetPlatform == TargetPlatform.macOS) {
      _menuSlot = MenuBarSlot(const []);
    }
  }

  @override
  void didUpdateWidget(DocumentWindowsRoot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.windows, widget.windows)) return;
    oldWidget.windows.removeListener(_changed);
    widget.windows.addListener(_changed);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.windows.removeListener(_changed);
    _menuSlot?.dispose();
    super.dispose();
  }

  /// A view came or went: the engine reports both as a metrics change.
  @override
  void didChangeMetrics() => _changed();

  void _changed() {
    if (mounted) setState(() {});
  }

  FlutterView? _view(DocumentWindow window) =>
      widget.viewFor?.call(window.viewId) ??
      WidgetsBinding.instance.platformDispatcher.view(id: window.viewId);

  @override
  Widget build(BuildContext context) {
    final views = ViewCollection(
      views: [
        for (final window in widget.windows.windows)
          if (_view(window) case final view?)
            View(
              key: ValueKey(window.serial),
              view: view,
              child: FocusScope(
                node: window.focusScope,
                child: widget.buildWindow(window, _menuSlot),
              ),
            ),
      ],
    );
    final menuSlot = _menuSlot;
    if (menuSlot == null) return views;
    return ValueListenableBuilder<List<PlatformMenuItem>>(
      valueListenable: menuSlot,
      builder: (context, menus, child) =>
          PlatformMenuBar(menus: menus, child: child),
      child: views,
    );
  }
}
