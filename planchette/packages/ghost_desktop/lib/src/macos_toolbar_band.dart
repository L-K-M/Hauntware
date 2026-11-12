import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const _queryMethod = 'isToolbarBandVisible';
const _changedMethod = 'toolbarBandChanged';

/// The room the traffic lights take at a macOS window's leading edge
/// under a unified titlebar, in logical pixels: no control of the app's
/// header may start inside it. That holds in full screen too, where the
/// titlebar slides in over the header when the pointer reaches the top
/// of the screen, its lights where they sit in a window.
const double macosTrafficLightsInset = 76;

/// Whether macOS currently shows the unified toolbar band that the app's
/// header draws under, as the runner reports it.
///
/// The band exists only while the window is windowed. In full screen
/// AppKit would keep the toolbar permanently visible in an opaque strip
/// above the content, covering the header, so the runner hides the toolbar
/// for the duration and the titlebar only slides in with the menu bar. The
/// runner reports each switch as the transition *begins* (AppKit's
/// will-enter and will-exit edges), so the layout changes with the toolbar
/// instead of snapping after the animation.
///
/// The value starts true, the windowed layout, and stays true when no
/// runner answers the channel (every platform but macOS).
///
/// It is the channel's only Dart handler: any other runner-to-Dart method
/// on it gets a missing-plugin reply, and a second handler on the same
/// channel would detach this one.
final class MacosToolbarBandChannel extends ValueNotifier<bool> {
  /// Listens on the app's window method channel, [channelName] (for
  /// example `seance/window`). [onStartError] receives a [start] query the
  /// runner failed or answered with something other than a bool.
  MacosToolbarBandChannel({
    required String channelName,
    required this._onStartError,
  }) : _channel = MethodChannel(channelName),
       super(true) {
    _channel.setMethodCallHandler(_handle);
  }

  final MethodChannel _channel;
  final void Function(Object error, StackTrace stackTrace) _onStartError;

  /// Asks the runner for the band's state, which a window restored
  /// straight into full screen changed before the handler was set.
  ///
  /// Never throws: the band is only a layout hint, so a failure goes to
  /// `onStartError` and leaves the windowed layout.
  Future<void> start() async {
    try {
      final visible = await _channel.invokeMethod<bool>(_queryMethod);
      if (visible != null) value = visible;
    } on MissingPluginException {
      // No runner side: the windowed layout stands.
    } catch (error, stackTrace) {
      _onStartError(error, stackTrace);
    }
  }

  Future<void> _handle(MethodCall call) async {
    if (call.method != _changedMethod) {
      throw MissingPluginException();
    }
    final visible = call.arguments;
    if (visible is! bool) {
      throw PlatformException(
        code: 'BAD_ARGS',
        message: '$_changedMethod needs a bool argument',
      );
    }
    value = visible;
  }

  @override
  void dispose() {
    _channel.setMethodCallHandler(null);
    super.dispose();
  }
}

/// The height of the titlebar band the empty unified NSToolbar claims on
/// macOS, in logical pixels: a host's macOS header height matches it, so
/// the traffic lights sit centred on the header.
const double macosToolbarBandHeight = 52;

/// Publishes whether the band is showing to the widgets that lay out
/// around it. It is gone in full screen, where the runner hides the
/// toolbar ([MacosToolbarBandChannel]): nothing then claims the top
/// 52 pt and no traffic lights sit in the window.
///
/// Only a window whose titlebar was installed has one: without a scope
/// there is no band and no integrated titlebar. A host whose windowed
/// layout has the band even without a runner report passes
/// [visibleOf]'s `windowedWithoutScope`.
class MacosToolbarBandScope extends InheritedNotifier<ValueListenable<bool>> {
  const MacosToolbarBandScope({
    super.key,
    required ValueListenable<bool> band,
    required super.child,
  }) : super(notifier: band);

  /// Whether the band is showing; rebuilds [context] when that changes.
  /// With no scope, [windowedWithoutScope] is the answer.
  static bool visibleOf(
    BuildContext context, {
    bool windowedWithoutScope = false,
  }) =>
      context
          .dependOnInheritedWidgetOfExactType<MacosToolbarBandScope>()
          ?.notifier
          ?.value ??
      windowedWithoutScope;

  /// Whether this window draws its header under the unified toolbar: on
  /// macOS, with the titlebar installed, in full screen too (where the
  /// band itself is hidden but the header stays at the top).
  static bool unifiedToolbarOf(BuildContext context) =>
      Theme.of(context).platform == TargetPlatform.macOS &&
      context.dependOnInheritedWidgetOfExactType<MacosToolbarBandScope>() !=
          null;
}

/// What the main window's `MaterialApp.builder` wraps the navigator in:
/// with a [band] (the titlebar is installed), its scope and the band's
/// reservation above every route; without one, [child] alone, unless
/// [windowedWithoutScope] keeps the reservation for a host whose
/// windowed layout has the band without a runner report.
Widget withMacosToolbarBand(
  ValueListenable<bool>? band, {
  required Widget child,
  bool windowedWithoutScope = false,
}) {
  if (band == null) {
    return windowedWithoutScope
        ? ReserveMacosToolbarBand(windowedWithoutScope: true, child: child)
        : child;
  }
  return MacosToolbarBandScope(
    band: band,
    child: ReserveMacosToolbarBand(
      windowedWithoutScope: windowedWithoutScope,
      child: child,
    ),
  );
}

/// Reserves the macOS toolbar band for everything the root navigator
/// shows: pushed routes, dialogs, sheets, popup menus, and the root
/// overlay's top toasts.
///
/// The band takes every mouse-down for window drag and double-click zoom,
/// except where a passthrough view hands the click back to Flutter, and
/// only the header and the rail's resize handle register those. Adding
/// the band to `MediaQuery` padding moves every other surface's
/// interactive chrome below it the way a status bar inset would: an
/// `AppBar` grows by the padding and paints its background up into the
/// band, and `showDialog`'s safe area, popup-menu layout, and the toast
/// column's `SafeArea` all keep clear of it. The empty band above them
/// then drags and zooms the window natively, as a titlebar should.
///
/// The shell takes the band back with [ClaimMacosToolbarBand]: its
/// header is the one surface meant to draw under it. Other platforms
/// have no band, so both widgets are no-ops there, and so are they on
/// macOS while [MacosToolbarBandScope] reports the band gone.
class ReserveMacosToolbarBand extends StatelessWidget {
  const ReserveMacosToolbarBand({
    super.key,
    required this.child,
    this.windowedWithoutScope = false,
  });

  final Widget child;

  /// The host's no-scope default: whether the windowed layout counts as
  /// banded when no [MacosToolbarBandScope] is above this widget.
  final bool windowedWithoutScope;

  @override
  Widget build(BuildContext context) {
    return _shiftTop(
      context,
      _bandHeight(context, windowedWithoutScope: windowedWithoutScope),
      child,
    );
  }
}

/// Takes the band [ReserveMacosToolbarBand] added back out for the
/// workspace shell, which draws its header under the band and wraps the
/// header's controls in passthrough views. Without this the shell's safe
/// area would push the whole window content down a band, and every
/// scroll view in it would pad its top by 52 pt.
///
/// While an opaque route covers the shell, the offstage header's
/// passthrough views stay registered with the window. Clicks on those
/// rects reach Flutter over the covering route's empty band padding,
/// where nothing is interactive, so the only cost is that the window
/// cannot be dragged from those few spots until the route pops.
class ClaimMacosToolbarBand extends StatelessWidget {
  const ClaimMacosToolbarBand({
    super.key,
    required this.child,
    this.windowedWithoutScope = false,
  });

  final Widget child;

  /// Must match the [ReserveMacosToolbarBand] it undoes, so a host
  /// without a scope keeps its no-scope default here too.
  final bool windowedWithoutScope;

  @override
  Widget build(BuildContext context) {
    return _shiftTop(
      context,
      -_bandHeight(context, windowedWithoutScope: windowedWithoutScope),
      child,
    );
  }
}

/// Zero off macOS and in full screen. The [MediaQuery] from [_shiftTop]
/// stays in the tree either way: dropping it when the band goes would
/// re-parent the whole app below it and lose its state.
double _bandHeight(BuildContext context, {bool windowedWithoutScope = false}) =>
    Theme.of(context).platform == TargetPlatform.macOS &&
        MacosToolbarBandScope.visibleOf(
          context,
          windowedWithoutScope: windowedWithoutScope,
        )
    ? macosToolbarBandHeight
    : 0;

Widget _shiftTop(BuildContext context, double delta, Widget child) {
  final data = MediaQuery.of(context);
  double shifted(double top) => (top + delta).clamp(0, double.infinity);
  return MediaQuery(
    data: data.copyWith(
      padding: data.padding.copyWith(top: shifted(data.padding.top)),
      viewPadding: data.viewPadding.copyWith(
        top: shifted(data.viewPadding.top),
      ),
    ),
    child: child,
  );
}
