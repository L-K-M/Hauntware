// The desktop Settings window's link: a window on a second Flutter engine,
// whose isolate shares nothing with the app's, kept in step with the app
// over two method channels the product's runners provide.
//
//   app engine                         runner                window engine
//   ───────────────────────            ──────                ─────────────────────
//   GhostSettingsWindowHost  ─control─▶ open / closed
//                            ◀─link──▶  relays byte    ◀─link─▶ GhostSettingsWindowClient
//                                       for byte
//
// The window is created the first time Settings opens and kept until the
// app quits: closing it only hides it. Tearing a second engine down is what
// the runners avoid; on Linux, Flutter 3.47's embedder terminates the EGL
// display every engine in the process shares when one is disposed, and the
// app's window then dies with an X error. What a hidden window must not
// keep is its screen, so the window drops it on `hidden` and mounts a fresh
// one, from the settings as they are then, on `show`.
//
// Every payload on the link is a JSON string in both directions, so each
// side decodes exactly what the other encoded rather than whatever shape the
// standard codec rebuilds maps into. The engine owns the handshake, the
// snapshots and the quit question; each product owns its sections, its
// method names, its codecs and its runners.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;

/// The link methods the engine owns. Each crosses as its [name], so these
/// names are reserved: a product method spelled the same would never reach
/// the product.
enum GhostSettingsLinkMethod {
  // Window → app.
  hello,
  requestAppExit,

  // App → window.
  snapshot,
  selectTab,
  hidden,
  show,
}

/// The control channel's methods: `open` from the app, `closed` from the
/// runner when the user closes (hides) the window.
enum GhostSettingsControlMethod { open, closed }

/// The keys of the engine's own envelopes (`hello`'s reply and `show`).
enum GhostSettingsLinkKey { snapshot, tab }

/// The code an app-side failure crosses with when the product has no error
/// codec of its own.
const _failedCode = 'settings-failed';

/// What the window shows: a Settings screen opened on [tab]. [generation]
/// changes every time the window is shown, so each showing is a fresh
/// screen rather than the last one's fields and half-typed secrets.
@immutable
final class GhostSettingsPage<TTab extends Enum> {
  const GhostSettingsPage({required this.tab, required this.generation});

  final TTab tab;
  final int generation;
}

/// The product's half of the app side: what the window renders, and how a
/// product method runs.
final class GhostSettingsSections {
  const GhostSettingsSections({
    required this.snapshot,
    required this.handleCall,
    this.changes = const [],
  });

  /// Everything the window renders, as JSON-encodable values. Built for
  /// `hello`, for each `show`, and after each change while the window
  /// shows.
  final Map<String, Object?> Function() snapshot;

  /// Runs a product method in the app's isolate, with its decoded
  /// argument, and answers a JSON-encodable result or null. Throws
  /// [MissingPluginException] for a method the product does not know; any
  /// other throw crosses to the window as the product's encoded error.
  final Future<Object?> Function(String method, Object? argument) handleCall;

  /// What moves a value the snapshot shows.
  final List<Listenable> changes;
}

/// The app's side of the Settings window: opens it, answers what it asks
/// through the product's [GhostSettingsSections], and sends it a fresh
/// snapshot whenever they change while it shows.
final class GhostSettingsWindowHost<TTab extends Enum> {
  /// [control] and [link] are the product's channels
  /// (`<product>/settings_window`, `<product>/settings_link`). [encodeError]
  /// turns an app-side failure into what the window decodes; by default a
  /// `settings-failed` code carrying what the error printed.
  /// [requestAppExit] answers the window's quit question, the app's own
  /// observers by default.
  GhostSettingsWindowHost({
    required this._control,
    required this._link,
    required TTab initialTab,
    required GhostSettingsSections sections,
    PlatformException Function(Object error)? encodeError,
    Future<AppExitResponse> Function()? requestAppExit,
  }) : _tab = initialTab,
       _encodeError = encodeError ?? _encodeFailure,
       _requestAppExit =
           requestAppExit ?? WidgetsBinding.instance.handleRequestAppExit {
    _control.setMethodCallHandler(_handleControl);
    _link.setMethodCallHandler(_handleLink);
    attach(sections);
  }

  final MethodChannel _control;
  final MethodChannel _link;
  final PlatformException Function(Object error) _encodeError;

  /// The app's answer to "may the application quit?": its own observers'.
  /// The window forwards the question here because on macOS every engine
  /// makes itself the app delegate's termination handler when it starts,
  /// so once the window's engine exists ⌘Q asks the window's isolate,
  /// which would answer "exit" without consulting them.
  final Future<AppExitResponse> Function() _requestAppExit;

  GhostSettingsSections _sections = const GhostSettingsSections(
    snapshot: _noSnapshot,
    handleCall: _noCall,
  );
  List<Listenable> _listening = const [];

  /// Whether the window's engine has said hello. It is never torn down, so
  /// this stays true once set, unless the link stops answering.
  bool _connected = false;

  /// Whether the window is showing, rather than closed and hidden.
  bool _visible = false;

  /// The tab the next window opens on, or the open one switches to.
  TTab _tab;

  /// The last snapshot sent, encoded, so a change that moves nothing the
  /// window shows costs a comparison rather than a message.
  String? _lastSnapshot;
  bool _snapshotScheduled = false;

  /// Whether a window engine is connected: it said hello and has not
  /// stopped answering since.
  bool get connected => _connected;

  /// Whether the window is showing, rather than closed and hidden.
  bool get visible => _visible;

  /// Binds the sections; rebinding replaces them and their listeners, and
  /// sends a showing window what changed.
  void attach(GhostSettingsSections sections) {
    for (final listenable in _listening) {
      listenable.removeListener(snapshotChanged);
    }
    _sections = sections;
    _listening = [...sections.changes];
    for (final listenable in _listening) {
      listenable.addListener(snapshotChanged);
    }
    snapshotChanged();
  }

  /// Something the snapshot shows changed without one of the sections'
  /// [GhostSettingsSections.changes] announcing it. Bursts coalesce into
  /// one snapshot, sent after the current event; a hidden window is sent
  /// nothing.
  void snapshotChanged() {
    if (!_connected || !_visible || _snapshotScheduled) return;
    _snapshotScheduled = true;
    scheduleMicrotask(() {
      _snapshotScheduled = false;
      unawaited(_sendSnapshot());
    });
  }

  /// Opens the window on [tab], or brings it forward and switches it there.
  /// False when the runner has no Settings window (a build from before it
  /// existed, or a test) or could not create one, so the caller can show
  /// its in-app Settings instead.
  Future<bool> open(TTab tab) async {
    _tab = tab;
    if (_connected) {
      try {
        if (_visible) {
          await _link.invokeMethod<void>(
            GhostSettingsLinkMethod.selectTab.name,
            jsonEncode(tab.name),
          );
        } else {
          // A fresh screen from the settings as they are now, before the
          // window reappears: nothing was sent while it was hidden.
          final snapshot = _sections.snapshot();
          _lastSnapshot = jsonEncode(snapshot);
          await _link.invokeMethod<void>(
            GhostSettingsLinkMethod.show.name,
            jsonEncode({
              GhostSettingsLinkKey.snapshot.name: snapshot,
              GhostSettingsLinkKey.tab.name: tab.name,
            }),
          );
        }
      } on MissingPluginException {
        // The engine went away after all; a new one says hello, and opens
        // on `_tab`.
        _connected = false;
      }
    }
    try {
      await _control.invokeMethod<void>(GhostSettingsControlMethod.open.name);
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
    // A first window becomes visible when it says hello, which may already
    // have happened; one being shown again, here.
    if (_connected) _visible = true;
    // A change made while `show` was in flight was not sent, since the
    // window did not count as showing yet; the dedupe makes this a no-op
    // when nothing changed.
    snapshotChanged();
    return true;
  }

  void dispose() {
    for (final listenable in _listening) {
      listenable.removeListener(snapshotChanged);
    }
    _listening = const [];
    _control.setMethodCallHandler(null);
    _link.setMethodCallHandler(null);
  }

  Future<Object?> _handleControl(MethodCall call) async {
    if (call.method != GhostSettingsControlMethod.closed.name) return null;
    _visible = false;
    _lastSnapshot = null;
    if (!_connected) return null;
    try {
      await _link.invokeMethod<void>(GhostSettingsLinkMethod.hidden.name);
    } on MissingPluginException {
      _connected = false;
    }
    return null;
  }

  Future<void> _sendSnapshot() async {
    if (!_connected || !_visible) return;
    final encoded = jsonEncode(_sections.snapshot());
    if (encoded == _lastSnapshot) return;
    _lastSnapshot = encoded;
    try {
      await _link.invokeMethod<void>(
        GhostSettingsLinkMethod.snapshot.name,
        encoded,
      );
    } on MissingPluginException {
      _connected = false;
      _lastSnapshot = null;
    } on PlatformException {
      // The window failed to apply it. Forgotten, so the next change sends
      // it again rather than the dedupe skipping what never arrived; and
      // caught, since nothing awaits this.
      _lastSnapshot = null;
    }
  }

  Future<Object?> _handleLink(MethodCall call) async {
    try {
      final Object? argument = call.arguments is String
          ? jsonDecode(call.arguments as String)
          : null;
      final result = await _dispatch(call.method, argument);
      return result == null ? null : jsonEncode(result);
    } on MissingPluginException {
      rethrow;
    } catch (error, stackTrace) {
      // The window shows the failure as the in-app Settings would; the
      // app's error reporter hears about it here, where the stack is.
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stackTrace),
      );
      throw _encodeError(error);
    }
  }

  Future<Object?> _dispatch(String method, Object? argument) async {
    switch (GhostSettingsLinkMethod.values.asNameMap()[method]) {
      case GhostSettingsLinkMethod.hello:
        // Built first: a window whose hello failed is not connected.
        final snapshot = _sections.snapshot();
        _lastSnapshot = jsonEncode(snapshot);
        _connected = true;
        _visible = true;
        return {
          GhostSettingsLinkKey.snapshot.name: snapshot,
          GhostSettingsLinkKey.tab.name: _tab.name,
        };
      case GhostSettingsLinkMethod.requestAppExit:
        return (await _requestAppExit()).name;
      case GhostSettingsLinkMethod.snapshot:
      case GhostSettingsLinkMethod.selectTab:
      case GhostSettingsLinkMethod.hidden:
      case GhostSettingsLinkMethod.show:
        throw MissingPluginException('$method goes to the window');
      case null:
        return _sections.handleCall(method, argument);
    }
  }

  static PlatformException _encodeFailure(Object error) =>
      PlatformException(code: _failedCode, message: '$error');

  static Map<String, Object?> _noSnapshot() => const {};

  static Future<Object?> _noCall(String method, Object? argument) =>
      throw MissingPluginException('No settings method $method');
}

/// The window's side of the link: says hello, keeps the product's copy of
/// the app's settings current from each snapshot, and runs every call in
/// the app's isolate.
///
/// A product subclasses it with its sections' models, decodes its snapshot
/// in [applySnapshot], and offers a static `connect` that constructs the
/// subclass and awaits [connectToApp].
abstract class GhostSettingsWindowClient<TTab extends Enum>
    extends ChangeNotifier {
  /// [tabs] are the product's tab values, which cross by name.
  /// [decodeError] rebuilds an app-side failure from what the host's
  /// `encodeError` sent; [lostError] is what a call throws when no app
  /// answers it.
  GhostSettingsWindowClient({
    required this._link,
    required this._tabs,
    required this._decodeError,
    required this._lostError,
  });

  final MethodChannel _link;
  final List<TTab> _tabs;
  final Exception Function(PlatformException error) _decodeError;
  final Exception Function() _lostError;

  final StreamController<TTab> _tabRequests = StreamController.broadcast();
  int _generation = 1;
  bool _lost = false;

  /// What the window shows: nothing while it is hidden (or before
  /// [connectToApp] answers), else a [GhostSettingsPage].
  final ValueNotifier<GhostSettingsPage<TTab>?> page = ValueNotifier(null);

  /// Tabs the app asks a showing window to switch to (Settings chosen again
  /// while the window is behind).
  Stream<TTab> get tabRequests => _tabRequests.stream;

  /// Whether a call found no app to answer it: the app went away, and the
  /// window can only say so.
  bool get lost => _lost;

  /// Says hello to the app and applies its first snapshot. Throws when
  /// there is no app to answer (the window was started by hand rather than
  /// by the app); the link is then unhooked again.
  @protected
  Future<void> connectToApp() async {
    _link.setMethodCallHandler(_handle);
    try {
      final hello = (await invoke(GhostSettingsLinkMethod.hello.name))! as Map;
      applySnapshot(_object(hello[GhostSettingsLinkKey.snapshot.name]));
      page.value = GhostSettingsPage(
        tab: _tabs.byName(hello[GhostSettingsLinkKey.tab.name]! as String),
        generation: 0,
      );
    } catch (_) {
      // Nothing may reach a window that never got its page.
      _link.setMethodCallHandler(null);
      rethrow;
    }
  }

  /// Replaces the product's copy of the app's settings with [snapshot],
  /// the map its host's [GhostSettingsSections.snapshot] built. The engine
  /// notifies listeners after every snapshot but the first.
  @protected
  void applySnapshot(Map<String, Object?> snapshot);

  /// Runs the product's [method] in the app's isolate with [argument]
  /// (JSON-encodable) and answers its decoded result. Throws the product's
  /// decoded error when the app reports a failure, and its lost error when
  /// no app answers.
  @protected
  Future<Object?> invoke(String method, [Object? argument]) async {
    try {
      final reply = await _link.invokeMethod<String>(
        method,
        argument == null ? null : jsonEncode(argument),
      );
      return reply == null ? null : jsonDecode(reply);
    } on PlatformException catch (error) {
      throw _decodeError(error);
    } on MissingPluginException {
      if (!_lost) {
        _lost = true;
        notifyListeners();
      }
      throw _lostError();
    }
  }

  /// Whether the application may quit, as the app's isolate decides it
  /// (see [GhostSettingsWindowHost]'s quit question). With no app left to
  /// ask, quitting is not held up.
  Future<AppExitResponse> requestAppExit() async {
    try {
      final name = await invoke(GhostSettingsLinkMethod.requestAppExit.name);
      return AppExitResponse.values.byName(name! as String);
    } on Exception {
      return AppExitResponse.exit;
    }
  }

  Future<Object?> _handle(MethodCall call) async {
    final Object? argument = call.arguments is String
        ? jsonDecode(call.arguments as String)
        : null;
    switch (GhostSettingsLinkMethod.values.asNameMap()[call.method]) {
      case GhostSettingsLinkMethod.snapshot:
        applySnapshot(_object(argument));
        notifyListeners();
      case GhostSettingsLinkMethod.selectTab:
        _tabRequests.add(_tabs.byName(argument! as String));
      case GhostSettingsLinkMethod.hidden:
        page.value = null;
      case GhostSettingsLinkMethod.show:
        final json = _object(argument);
        applySnapshot(_object(json[GhostSettingsLinkKey.snapshot.name]));
        notifyListeners();
        page.value = GhostSettingsPage(
          tab: _tabs.byName(json[GhostSettingsLinkKey.tab.name]! as String),
          generation: _generation++,
        );
      case GhostSettingsLinkMethod.hello:
      case GhostSettingsLinkMethod.requestAppExit:
      case null:
        throw MissingPluginException(
          'No settings window method ${call.method}',
        );
    }
    return null;
  }

  static Map<String, Object?> _object(Object? json) =>
      (json! as Map).cast<String, Object?>();

  @override
  void dispose() {
    _link.setMethodCallHandler(null);
    unawaited(_tabRequests.close());
    page.dispose();
    super.dispose();
  }
}
