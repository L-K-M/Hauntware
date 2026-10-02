import 'package:flutter/services.dart';

/// The engine's implicit view: the first window, which the runners create
/// with the app and which can never leave the engine.
const int mainWindowViewId = 0;

/// The channel the desktop runners' window host listens on
/// (runner document_windows.* beside the app's single-window setup).
const MethodChannel documentWindowsChannel = MethodChannel(
  'planchette/windows',
);

enum WindowHostMethod {
  isAvailable,
  create,
  destroy,
  activate,
  hide,
  isFullScreen,
  setFullScreen,
  setTitle,
  pickOpenFiles,
  pickSavePath,
}

enum WindowHostEvent { activated, closeRequested }

enum WindowHostKey {
  viewId,
  engineId,
  fullScreen,
  title,
  suggestedName,
  initialDirectory,
  paths,
}

/// What a runner's window host reports back to Dart.
abstract interface class WindowHostListener {
  /// A window took the front: on Linux its GTK focus, on Windows its
  /// WM_ACTIVATE, on macOS its becoming key. Carries the view id.
  void onWindowActivated(int viewId);

  /// The user asked a window to close. Dart decides: it removes the
  /// window's widgets and then calls destroy, or declines. Carries the
  /// view id.
  void onWindowCloseRequested(int viewId);
}

/// The runner's window host: it owns the native windows that hold the extra
/// views on this engine (each a DocumentWindow). The main window's Flutter
/// view is the engine's implicit one, so the runner cannot remove it —
/// destroy on it is a no-op and hiding it keeps its view alive.
abstract interface class WindowHost {
  /// Who hears [WindowHostEvent]s. One at a time, cleared on dispose.
  set listener(WindowHostListener? listener);

  /// Whether this runner hosts extra windows at all. Where it does not —
  /// a non-desktop build, a run under `flutter test` — the app stays at
  /// one window.
  Future<bool> isAvailable();

  /// Opens a window on the app's own engine and returns the id the engine
  /// gave its view — never [mainWindowViewId], which is the implicit view.
  /// [title] becomes the native window's title. Throws
  /// [WindowHostException] when no window came up.
  Future<int> create({String? title});

  /// Removes the window's view from the engine and closes the window.
  /// On the main window's view id this does nothing: that view is the
  /// engine's own and goes only with the app.
  Future<void> destroy(int viewId);

  /// Brings the window to the front and focuses it, showing it again if it
  /// was hidden (the main window after its close button ran while other
  /// windows were open).
  Future<void> activate(int viewId);

  /// Hides the window without closing it; activate shows it again.
  /// Meaningful for the main window, whose view cannot be destroyed.
  Future<void> hide(int viewId);

  /// Whether the window is full screen.
  Future<bool> isFullScreen(int viewId);

  /// Takes the window in or out of full screen.
  Future<void> setFullScreen(int viewId, {required bool fullScreen});

  /// Sets the native window's title. window_manager covers only the main
  /// window, so every other window's dirty marker and document name go
  /// through here.
  Future<void> setTitle(int viewId, String title);

  /// The window's own open dialog. file_selector's dialogs parent to the
  /// plugin registry's view — the main window — which may be hidden while
  /// other windows are open, so the runner shows the pickers for the window
  /// that asked. Returns the chosen paths (empty on cancel).
  Future<List<String>> pickOpenFiles(int viewId);

  /// The window's own save dialog. Returns the chosen path, or null on
  /// cancel. [suggestedName] fills the name field; [initialDirectory] the
  /// folder it opens on.
  Future<String?> pickSavePath(
    int viewId, {
    required String suggestedName,
    String? initialDirectory,
  });
}

/// A window-host call that went wrong at the boundary: the runner refused
/// or failed, or the channel is not there at all.
final class WindowHostException implements Exception {
  const WindowHostException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// [WindowHost] over the runners' `planchette/windows` channel.
final class MethodChannelWindowHost implements WindowHost {
  MethodChannelWindowHost({int? Function()? engineId})
    : _engineId = engineId ?? _currentEngineId;

  final int? Function() _engineId;

  static int? _currentEngineId() =>
      ServicesBinding.instance.platformDispatcher.engineId;

  WindowHostListener? _listener;

  @override
  set listener(WindowHostListener? listener) {
    _listener = listener;
    documentWindowsChannel.setMethodCallHandler(
      listener == null ? null : _handle,
    );
  }

  @override
  Future<bool> isAvailable() async {
    try {
      return await documentWindowsChannel.invokeMethod<bool>(
            WindowHostMethod.isAvailable.name,
          ) ??
          false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<int> create({String? title}) async {
    final Object? viewId;
    try {
      viewId = await documentWindowsChannel.invokeMethod<Object?>(
        WindowHostMethod.create.name,
        {
          WindowHostKey.engineId.name: _engineId(),
          WindowHostKey.title.name: ?title,
        },
      );
    } on MissingPluginException {
      throw const WindowHostException('no window host on this platform');
    } on PlatformException catch (error) {
      throw WindowHostException(error.message ?? error.code);
    }
    if (viewId is! int) {
      throw const WindowHostException('the runner answered no view id');
    }
    return viewId;
  }

  @override
  Future<void> destroy(int viewId) => _invoke(WindowHostMethod.destroy, viewId);

  @override
  Future<void> activate(int viewId) =>
      _invoke(WindowHostMethod.activate, viewId);

  @override
  Future<void> hide(int viewId) => _invoke(WindowHostMethod.hide, viewId);

  @override
  Future<bool> isFullScreen(int viewId) async {
    try {
      return await documentWindowsChannel.invokeMethod<bool>(
            WindowHostMethod.isFullScreen.name,
            {WindowHostKey.viewId.name: viewId},
          ) ??
          false;
    } on MissingPluginException {
      throw const WindowHostException('no window host on this platform');
    } on PlatformException catch (error) {
      throw WindowHostException(error.message ?? error.code);
    }
  }

  @override
  Future<void> setFullScreen(int viewId, {required bool fullScreen}) => _invoke(
    WindowHostMethod.setFullScreen,
    viewId,
    extra: {WindowHostKey.fullScreen.name: fullScreen},
  );

  @override
  Future<void> setTitle(int viewId, String title) => _invoke(
    WindowHostMethod.setTitle,
    viewId,
    extra: {WindowHostKey.title.name: title},
  );

  @override
  Future<List<String>> pickOpenFiles(int viewId) async {
    final Object? answer;
    try {
      answer = await documentWindowsChannel.invokeMethod<Object?>(
        WindowHostMethod.pickOpenFiles.name,
        {WindowHostKey.viewId.name: viewId},
      );
    } on MissingPluginException {
      throw const WindowHostException('no window host on this platform');
    } on PlatformException catch (error) {
      throw WindowHostException(error.message ?? error.code);
    }
    if (answer is! List) {
      throw const WindowHostException('the runner answered no path list');
    }
    return [for (final path in answer) '$path'];
  }

  @override
  Future<String?> pickSavePath(
    int viewId, {
    required String suggestedName,
    String? initialDirectory,
  }) async {
    try {
      return await documentWindowsChannel
          .invokeMethod<String?>(WindowHostMethod.pickSavePath.name, {
            WindowHostKey.viewId.name: viewId,
            WindowHostKey.suggestedName.name: suggestedName,
            WindowHostKey.initialDirectory.name: ?initialDirectory,
          });
    } on MissingPluginException {
      throw const WindowHostException('no window host on this platform');
    } on PlatformException catch (error) {
      throw WindowHostException(error.message ?? error.code);
    }
  }

  Future<void> _invoke(
    WindowHostMethod method,
    int viewId, {
    Map<String, Object?> extra = const {},
  }) async {
    try {
      await documentWindowsChannel.invokeMethod<void>(method.name, {
        WindowHostKey.viewId.name: viewId,
        ...extra,
      });
    } on MissingPluginException {
      throw const WindowHostException('no window host on this platform');
    } on PlatformException catch (error) {
      throw WindowHostException(error.message ?? error.code);
    }
  }

  /// The runner's reports. Anything not a map carrying an int viewId is a
  /// wiring bug at the boundary; dropping it keeps a malformed report from
  /// acting on the wrong window.
  Future<Object?> _handle(MethodCall call) async {
    final arguments = call.arguments;
    final viewId = arguments is Map
        ? arguments[WindowHostKey.viewId.name]
        : null;
    if (viewId is! int) return null;
    switch (call.method) {
      case 'activated':
        _listener?.onWindowActivated(viewId);
      case 'closeRequested':
        _listener?.onWindowCloseRequested(viewId);
    }
    return null;
  }
}

/// No runner behind the channel, as under `flutter test`: one window, and
/// every operation fails closed and says so.
final class UnavailableWindowHost implements WindowHost {
  const UnavailableWindowHost();

  @override
  set listener(WindowHostListener? listener) {}

  @override
  Future<bool> isAvailable() async => false;

  @override
  Future<int> create({String? title}) async =>
      throw const WindowHostException('no window host on this platform');

  @override
  Future<void> destroy(int viewId) async {}

  @override
  Future<void> activate(int viewId) async {}

  @override
  Future<void> hide(int viewId) async {}

  @override
  Future<bool> isFullScreen(int viewId) async => false;

  @override
  Future<void> setFullScreen(int viewId, {required bool fullScreen}) async {}

  @override
  Future<void> setTitle(int viewId, String title) async {}

  @override
  Future<List<String>> pickOpenFiles(int viewId) async =>
      throw const WindowHostException('no window host on this platform');

  @override
  Future<String?> pickSavePath(
    int viewId, {
    required String suggestedName,
    String? initialDirectory,
  }) async =>
      throw const WindowHostException('no window host on this platform');
}
