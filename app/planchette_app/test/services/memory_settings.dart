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
