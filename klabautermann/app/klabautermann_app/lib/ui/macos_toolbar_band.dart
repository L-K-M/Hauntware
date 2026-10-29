import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// The height of the titlebar band the empty unified toolbar claims on
/// macOS (`installMacosTitlebar`); the traffic lights sit centred in it.
/// Séance and Poltergeist use the same 52 pt.
const double macosToolbarBandHeight = 52;

/// Publishes whether the band is showing to the widgets that lay out
/// around it. It is gone in full screen, where the runner hides the
/// toolbar (ghost_desktop's `MacosToolbarBandChannel`): nothing then
/// claims the top 52 pt and no traffic lights sit in the window.
///
/// Only the main window's app has one, and only when the titlebar was
/// installed: without a scope there is no band, as in the settings window
/// and on every other platform (Séance's rule).
class MacosToolbarBandScope extends InheritedNotifier<ValueListenable<bool>> {
  const MacosToolbarBandScope({
    super.key,
    required ValueListenable<bool> band,
    required super.child,
  }) : super(notifier: band);

  /// Whether the band is showing; rebuilds [context] when that changes.
  static bool visibleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<MacosToolbarBandScope>()
          ?.notifier
          ?.value ??
      false;

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
/// reservation above every route; without one, [child] alone.
Widget withMacosToolbarBand(
  ValueListenable<bool>? band, {
  required Widget child,
}) {
  if (band == null) return child;
  return MacosToolbarBandScope(
    band: band,
    child: ReserveMacosToolbarBand(child: child),
  );
}

/// Reserves the band for everything the root navigator shows: the shells,
/// the settings route, dialogs, popup menus and the top toasts.
///
/// The band takes every mouse-down for window drag and double-click zoom,
/// so nothing interactive may sit in it. Adding the band to `MediaQuery`
/// padding moves every surface below it the way a status bar inset would,
/// following Séance's `ReserveMacosToolbarBand`: an `AppBar` grows by the
/// padding and paints its background up into the band, `SafeArea`,
/// `showDialog`'s safe area and the popup-menu layout keep clear of it,
/// and the desktop shell paints its panes up through it while starting
/// their content below. Unlike Séance and Poltergeist, no header draws
/// under the band yet, so nothing takes the reservation back.
///
/// A no-op off macOS and while [MacosToolbarBandScope] reports the band
/// gone. The [MediaQuery] stays in the tree either way: dropping it when
/// the band goes would re-parent everything below it and lose its state.
class ReserveMacosToolbarBand extends StatelessWidget {
  const ReserveMacosToolbarBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _shiftTop(context, _bandHeight(context), child);
  }
}

/// Takes the band [ReserveMacosToolbarBand] added back out for the
/// desktop shell, whose header and rail band draw under it and wrap
/// their controls in `MacosToolbarPassthrough`. Without this the shell's
/// safe areas would push its content down a band and every scroll view
/// in it would pad its top by 52 pt.
///
/// While an opaque route covers the shell, the offstage bands' passthrough
/// views stay registered with the window. Clicks on those rects reach
/// Flutter over the covering route's empty band padding, where nothing is
/// interactive, so the only cost is that the window cannot be dragged
/// from those few spots until the route pops.
class ClaimMacosToolbarBand extends StatelessWidget {
  const ClaimMacosToolbarBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return _shiftTop(context, -_bandHeight(context), child);
  }
}

/// Zero off macOS and in full screen. The [MediaQuery] from [_shiftTop]
/// stays in the tree either way: dropping it when the band goes would
/// re-parent everything below it and lose its state.
double _bandHeight(BuildContext context) =>
    Theme.of(context).platform == TargetPlatform.macOS &&
        MacosToolbarBandScope.visibleOf(context)
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
