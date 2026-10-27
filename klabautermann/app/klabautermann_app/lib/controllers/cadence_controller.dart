import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart' show CadenceProfile;

/// The polling budget's presets (SAF-19): [automatic] samples at the
/// Desktop column's cadence on a computer and the Phone column's on a
/// phone or tablet (03 §6.4); the others pick a column on any device.
enum CadencePreset {
  automatic,
  desktop,
  phone,
  cellularSaver;

  /// The preset [name] names, or [automatic] for null or a name this
  /// version does not know.
  static CadencePreset parse(String? name) => switch (name) {
    final name? => values.asNameMap()[name] ?? automatic,
    null => automatic,
  };

  /// The 6.4 column this preset samples at on [platform].
  CadenceProfile profileOn(TargetPlatform platform) => switch (this) {
    automatic => switch (platform) {
      TargetPlatform.android ||
      TargetPlatform.iOS ||
      TargetPlatform.fuchsia => CadenceProfile.phone,
      TargetPlatform.linux ||
      TargetPlatform.macOS ||
      TargetPlatform.windows => CadenceProfile.desktop,
    },
    desktop => CadenceProfile.desktop,
    phone => CadenceProfile.phone,
    cellularSaver => CadenceProfile.cellularSaver,
  };
}

/// What Settings reads and changes of the polling budget, apart from
/// where it runs: [CadenceController] in the app, and a copy kept over
/// the settings link in the desktop settings window.
abstract interface class CadenceSettings
    implements ValueListenable<CadencePreset> {
  /// Picks [preset]; a no-op when it is in force and saved. A change
  /// applied but not saved throws [CadenceNotSavedException], in the app
  /// and, over the link, in the window; any other throw means it did not
  /// apply.
  Future<void> setCadence(CadencePreset preset);
}

/// A preset that applied but was not saved: it lasts until the app
/// restarts unless a later save carries it. [message] is what the failed
/// save printed.
final class CadenceNotSavedException implements Exception {
  const CadenceNotSavedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The app's polling budget (SAF-19): the composition root restores the
/// preset from `settings.json`, saves every change there and sends the
/// engine its 6.4 column whenever the preset changes; without a save
/// callback, as in most tests, it is held in memory only. A change
/// applies before it is saved, as the appearance does.
final class CadenceController extends ChangeNotifier
    implements CadenceSettings {
  CadenceController({
    CadencePreset preset = CadencePreset.automatic,
    this._save,
  }) : _value = preset,
       _saved = preset;

  CadencePreset _value;

  /// The preset last known to be in `settings.json`: after a failed save,
  /// picking the same preset again tries the save again.
  CadencePreset _saved;
  final Future<void> Function(String name)? _save;

  @override
  CadencePreset get value => _value;

  @override
  Future<void> setCadence(CadencePreset preset) async {
    if (preset == _value && preset == _saved) return;
    if (preset != _value) {
      _value = preset;
      notifyListeners();
    }
    try {
      await _save?.call(preset.name);
      _saved = preset;
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        CadenceNotSavedException('The polling budget was not saved: $error'),
        stackTrace,
      );
    }
  }
}

/// The columns a server can be capped at (SAF-19): Desktop would cap
/// nothing, since a cap never speeds a server up (03 §10.1).
enum CadenceCap {
  phone,
  cellularSaver;

  /// The cap [name] names, or null for null or a name this version does
  /// not know, which caps nothing.
  static CadenceCap? parse(String? name) =>
      name == null ? null : values.asNameMap()[name];

  /// The 6.4 column this cap holds a server to.
  CadenceProfile get profile => switch (this) {
    phone => CadenceProfile.phone,
    cellularSaver => CadenceProfile.cellularSaver,
  };
}

/// What Settings reads and changes of the per-server caps, apart from
/// where it runs: [CadenceCapsController] in the app, and a copy kept
/// over the settings link in the desktop settings window. The value maps
/// each capped server's id to its cap.
abstract interface class CadenceCapSettings
    implements ValueListenable<Map<String, CadenceCap>> {
  /// Caps [serverId] at [cap], null to lift it; a no-op when that is in
  /// force and saved. Throws as [CadenceSettings.setCadence] does, with
  /// [CadenceNotSavedException] for a cap applied but not saved.
  Future<void> setCap(String serverId, CadenceCap? cap);
}

/// The app's per-server caps (SAF-19): the composition root restores them
/// from `settings.json`, saves every change there and sends the engine
/// each cap that changed. Without a save callback, as in most tests, they
/// are held in memory only. A change applies before it is saved.
final class CadenceCapsController extends ChangeNotifier
    implements CadenceCapSettings {
  CadenceCapsController({Map<String, CadenceCap> caps = const {}, this._save})
    : _value = Map.unmodifiable(caps),
      _saved = Map.unmodifiable(caps);

  Map<String, CadenceCap> _value;

  /// The caps last known to be in `settings.json`, as
  /// [CadenceController]'s saved preset.
  Map<String, CadenceCap> _saved;
  final Future<void> Function(String serverId, String? name)? _save;

  @override
  Map<String, CadenceCap> get value => _value;

  @override
  Future<void> setCap(String serverId, CadenceCap? cap) async {
    if (cap == _value[serverId] && cap == _saved[serverId]) return;
    if (cap != _value[serverId]) {
      _value = _with(_value, serverId, cap);
      notifyListeners();
    }
    try {
      await _save?.call(serverId, cap?.name);
      _saved = _with(_saved, serverId, cap);
    } on Exception catch (error, stackTrace) {
      Error.throwWithStackTrace(
        CadenceNotSavedException('The polling cap was not saved: $error'),
        stackTrace,
      );
    }
  }

  static Map<String, CadenceCap> _with(
    Map<String, CadenceCap> caps,
    String serverId,
    CadenceCap? cap,
  ) => Map.unmodifiable({
    for (final MapEntry(:key, :value) in caps.entries)
      if (key != serverId) key: value,
    serverId: ?cap,
  });
}
