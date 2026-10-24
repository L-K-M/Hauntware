import 'package:flutter/foundation.dart';

/// The longest device name Settings takes; the host syslog line caps each
/// part at 200 characters anyway.
const int kDeviceNameMaxLength = 64;

/// The device name's default (M5 plan Q6): what the host syslog line
/// names (SAF-13). It names the platform, never the device's hostname,
/// and stays in English, since it is written into every host's journal,
/// which an admin reads with every other device's lines.
String defaultDeviceName(TargetPlatform platform) {
  final name = switch (platform) {
    TargetPlatform.android => 'Android',
    TargetPlatform.fuchsia => 'Fuchsia',
    TargetPlatform.iOS => 'iOS',
    TargetPlatform.linux => 'Linux',
    TargetPlatform.macOS => 'macOS',
    TargetPlatform.windows => 'Windows',
  };
  return 'Klabautermann on $name';
}

/// What Settings reads and changes of the device name (M5 plan Q6), apart
/// from where it runs: [DeviceNameController] in the app, and a copy kept
/// over the settings link in the desktop settings window. [value] is the
/// name the host syslog line gives this device (SAF-13).
abstract interface class DeviceNameSettings implements ValueListenable<String> {
  /// Names the device [name], trimmed; a blank name means the default. A
  /// no-op when that is already in force. A change applied but not saved
  /// throws [DeviceNameNotSavedException], in the app and, over the link,
  /// in the window; any other throw means it did not apply.
  Future<void> setDeviceName(String name);
}

/// A device name that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class DeviceNameNotSavedException implements Exception {
  const DeviceNameNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's device name. The composition root restores it from
/// `settings.json`, null for the default ([fallback]), hands every value
/// to the engine through [apply] (the first at once, since the engine
/// names no device until told) and saves every change, null again for the
/// default; without a save callback, as in most tests, it is held in
/// memory only. A change applies before it is saved.
final class DeviceNameController extends ChangeNotifier
    implements DeviceNameSettings {
  DeviceNameController({
    String? stored,
    required this.fallback,
    required this._apply,
    this._save,
  }) : _value = stored ?? fallback {
    _apply(_value);
  }

  final String fallback;
  String _value;

  /// Whether [_value] is what settings.json holds; a failed save leaves it
  /// false, so the same name set again saves rather than returns.
  bool _saved = true;
  final void Function(String name) _apply;
  final Future<void> Function(String? name)? _save;

  @override
  String get value => _value;

  @override
  Future<void> setDeviceName(String name) async {
    final trimmed = name.trim();
    final next = trimmed.isEmpty ? fallback : trimmed;
    if (next == _value && _saved) return;
    // A throw from apply means the engine never took it, so nothing is
    // kept either.
    if (next != _value) {
      _apply(next);
      _value = next;
      notifyListeners();
    }
    try {
      await _save?.call(next == fallback ? null : next);
      _saved = true;
    } on Exception catch (error, stackTrace) {
      _saved = false;
      Error.throwWithStackTrace(
        DeviceNameNotSavedException('The device name was not saved: $error'),
        stackTrace,
      );
    }
  }
}
