import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:planchette_app/services/app_settings.dart';

/// A settings store the tests own. Fails the same way [LocalSettingsStore]
/// does, so the controller's error handling is exercised for real.
class MemorySettings implements SettingsStore {
  String? stored;
  bool failSaves = false;
  int writes = 0;

  @override
  Future<AppSettings?> load() async {
    final raw = stored;
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      return AppSettings.fromJson(Map<String, Object?>.from(decoded));
    } on FormatException {
      // Same contract as the real store: a file nobody can read is no settings
      // at all, not a failure.
      return null;
    }
  }

  @override
  Future<void> save(AppSettings settings) async {
    if (failSaves) {
      throw const FileSystemException('disk full', '/nowhere/settings.json');
    }
    writes++;
    stored = jsonEncode(settings.toJson());
  }
}

/// A store whose reads always fail, as an unreadable settings file would.
class ThrowingSettings implements SettingsStore {
  ThrowingSettings(this.error);
  final Object error;

  @override
  Future<AppSettings?> load() async => throw error;

  @override
  Future<void> save(AppSettings settings) async => throw error;
}

/// A store whose writes do not finish until the test says so, so two saves can
/// be made to land in the order that breaks an unserialized controller.
///
/// The order is arranged by the test rather than by a timer, because a test
/// binding's fake clock never advances on its own and a `Future.delayed` here
/// would hang rather than race.
class SlowSettings implements SettingsStore {
  /// In the order the writes were requested.
  final written = <AppSettings>[];

  /// In the order the writes finished, which is what ends up on disk.
  final completed = <AppSettings>[];

  /// One per requested write, in the same order as [written].
  final _releases = <Completer<void>>[];

  @override
  Future<AppSettings?> load() async =>
      completed.isEmpty ? null : completed.last;

  @override
  Future<void> save(AppSettings settings) async {
    written.add(settings);
    final release = Completer<void>();
    _releases.add(release);
    await release.future;
    completed.add(settings);
  }

  /// Let the oldest pending write finish.
  void finishOldest() => _releases.removeAt(0).complete();

  /// Let every pending write finish.
  void finishAll() {
    while (_releases.isNotEmpty) {
      _releases.removeAt(0).complete();
    }
  }
}
