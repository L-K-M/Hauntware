import 'package:flutter/foundation.dart';

/// What Settings reads and changes of the device's "sync passwords"
/// switch (03 §4.5, SYN-02), apart from where it runs:
/// [SyncSecretsController] in the app, and a copy kept over the settings
/// link in the desktop settings window. [value] is whether sync rounds
/// apply the passwords and keys other devices synced into this device's
/// vault.
abstract interface class SyncSecretsSettings implements ValueListenable<bool> {
  /// Turns the switch on or off; a no-op when [enabled] is already in
  /// force. A change applied but not saved throws
  /// [SyncSecretsNotSavedException], in the app and, over the link, in
  /// the window; any other throw means it did not apply.
  Future<void> setSyncSecrets(bool enabled);
}

/// A switch change that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class SyncSecretsNotSavedException implements Exception {
  const SyncSecretsNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's "sync passwords" switch. The composition root restores it
/// from `settings.json`, hands every value to the engine through [apply]
/// (the first at once, since the engine starts with the switch off) and
/// saves every change; without a save callback, as in most tests, it is
/// held in memory only. A change applies before it is saved.
final class SyncSecretsController extends ChangeNotifier
    implements SyncSecretsSettings {
  SyncSecretsController({
    bool syncSecrets = false,
    required this._apply,
    this._save,
  }) : _value = syncSecrets {
    _apply(_value);
  }

  bool _value;
  final void Function(bool enabled) _apply;
  final Future<void> Function(bool enabled)? _save;

  @override
  bool get value => _value;

  @override
  Future<void> setSyncSecrets(bool enabled) async {
    if (enabled == _value) return;
    _value = enabled;
    _apply(enabled);
    notifyListeners();
    try {
      await _save?.call(enabled);
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        SyncSecretsNotSavedException(
          'The sync passwords setting was not saved: $error',
        ),
        stackTrace,
      );
    }
  }
}
