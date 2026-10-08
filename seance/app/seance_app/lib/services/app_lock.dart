import 'dart:async';

const appLockBackgroundTimeout = Duration(minutes: 5);

enum AppLockMode { off, on }

enum AppLockAvailability { unavailable, available }

enum AppLockLifecycle { foreground, inactive, background }

/// Device authentication, without exposing plugin mechanics to callers.
abstract interface class DeviceAuthenticator {
  Future<AppLockAvailability> availability();
  Future<void> authenticate();
}

/// Authentication refusal is never an absent credential or a damaged vault.
class AppLockException implements Exception {
  const AppLockException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// One device-local gate for future reads. Existing sessions keep their keys.
class AppLock {
  AppLock({
    required this._authenticator,
    this._mode = AppLockMode.off,
    Duration Function()? elapsed,
    DateTime Function()? wallClock,
  }) : _elapsed = elapsed ?? _monotonicClock(),
       _wallClock = wallClock ?? DateTime.now;

  final DeviceAuthenticator _authenticator;
  final Duration Function() _elapsed;
  final DateTime Function() _wallClock;
  AppLockMode _mode;
  AppLockAvailability _availability = AppLockAvailability.unavailable;
  bool _unlocked = false;
  bool _foreground = true;
  Duration? _backgroundSince;
  DateTime? _backgroundWallSince;
  bool _backgroundExpired = false;
  int _generation = 0;
  Future<void>? _authentication;

  AppLockAvailability get availability => _availability;

  bool get requiresAuthentication {
    _expireBackground();
    return _mode == AppLockMode.on && !_unlocked;
  }

  static Duration Function() _monotonicClock() {
    final clock = Stopwatch()..start();
    return () => clock.elapsed;
  }

  Future<void> refreshAvailability() async {
    try {
      _availability = await _authenticator.availability();
    } catch (_) {
      _availability = AppLockAvailability.unavailable;
    }
  }

  void onLifecycle(AppLockLifecycle lifecycle) {
    // Native auth can make the app inactive. It cannot erase a real absence.
    if (lifecycle == AppLockLifecycle.inactive) return;
    if (lifecycle == AppLockLifecycle.background) {
      _foreground = false;
      _backgroundSince ??= _elapsed();
      _backgroundWallSince ??= _wallClock();
      _expireBackground();
      return;
    }

    _expireBackground();
    _foreground = true;
    if (_authentication != null) return;
    _clearBackground();
  }

  void _clearBackground() {
    _backgroundSince = null;
    _backgroundWallSince = null;
    _backgroundExpired = false;
  }

  void _expireBackground() {
    final since = _backgroundSince;
    if (since == null || _backgroundExpired) return;
    // Stopwatch can pause during OS sleep. Wall time covers that absence;
    // monotonic time still expires if the device clock moves backwards.
    final wallSince = _backgroundWallSince!;
    if (_elapsed() - since < appLockBackgroundTimeout &&
        _wallClock().difference(wallSince) < appLockBackgroundTimeout) {
      return;
    }

    _backgroundExpired = true;
    _unlocked = false;
    _generation++;
  }

  Future<void> requireUnlocked() async {
    if (!requiresAuthentication) return;
    await _authenticate();
  }

  Future<void> _authenticate() {
    final pending = _authentication;
    if (pending != null) return pending;

    final finished = Completer<void>();
    _authentication = finished.future;
    _performAuthentication().then(
      (_) {
        _finishAuthentication();
        finished.complete();
      },
      onError: (Object error, StackTrace stack) {
        _finishAuthentication();
        finished.completeError(error, stack);
      },
    );
    return finished.future;
  }

  void _finishAuthentication() {
    _authentication = null;
    if (!_foreground) return;
    _clearBackground();
  }

  void _requireForeground() {
    if (!_foreground) {
      throw const AppLockException(
        'App lock: return to Séance to authenticate, then retry.',
      );
    }
  }

  void _checkAuthentication(int generation) {
    _expireBackground();
    if (generation != _generation) {
      throw const AppLockException(
        'App lock: authentication expired while Séance was backgrounded. Retry.',
      );
    }
  }

  Future<void> _performAuthentication() async {
    _expireBackground();
    _requireForeground();
    final generation = _generation;
    await refreshAvailability();
    _checkAuthentication(generation);
    _requireForeground();
    if (_availability != AppLockAvailability.available) {
      throw const AppLockException(
        'App lock: device authentication is unavailable. Set up device '
        'security, then retry.',
      );
    }

    try {
      await _authenticator.authenticate();
    } on AppLockException {
      rethrow;
    } catch (_) {
      throw const AppLockException(
        'App lock: device authentication failed. Retry to access saved secrets.',
      );
    }
    _checkAuthentication(generation);
    _unlocked = true;
  }

  /// Check again after async I/O: a read admitted before a timeout cannot
  /// release its result after that timeout, even if another prompt succeeded.
  Future<T> read<T>(Future<T> Function() operation) async {
    await requireUnlocked();
    final generation = _generation;
    _checkRead(generation);
    final result = await operation();
    _checkRead(generation);
    return result;
  }

  void _checkRead(int generation) {
    _expireBackground();
    if (_mode == AppLockMode.on && (!_unlocked || generation != _generation)) {
      throw const AppLockException(
        'App lock: saved-secret access expired. Authenticate again and retry.',
      );
    }
  }

  /// Both transitions need fresh auth. Keep the old gate until the write
  /// succeeds, so a failed disable cannot expose credentials.
  Future<void> changeMode(
    AppLockMode mode, {
    required Future<void> Function() persist,
  }) async {
    if (_mode == mode) return;
    _expireBackground();
    final generation = _generation;
    await _authenticate();
    _checkAuthentication(generation);
    await persist();
    _expireBackground();
    _mode = mode;
    _generation++;
  }
}
