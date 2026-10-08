import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _queryMethod = 'isToolbarBandVisible';
const _changedMethod = 'toolbarBandChanged';

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
