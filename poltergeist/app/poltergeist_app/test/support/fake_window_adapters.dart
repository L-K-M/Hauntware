import 'package:ghost_desktop/ghost_desktop.dart';

/// The integrated titlebar for `DesktopWindowLifecycle` tests, counting
/// installs; the window, display and debounce fakes are ghost_desktop's
/// (`package:ghost_desktop/testing.dart`).
final class FakeMacTitlebarAdapter implements MacosTitlebarAdapter {
  int installCalls = 0;

  @override
  Future<void> install() async => installCalls++;

  @override
  Future<void> reset() async {}
}
