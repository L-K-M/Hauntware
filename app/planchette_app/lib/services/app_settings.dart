import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// What the user chose, as one immutable value.
///
/// Everything here survives a restart, so it is deliberately small and
/// deliberately tolerant: a settings file that is missing, hand-edited or from a
/// newer version must never stop the app from opening. [fromJson] falls back to
/// the default for anything it cannot make sense of rather than throwing.
final class AppSettings {
  const AppSettings({
    this.themeMode = ThemeMode.system,
    this.fontSize = defaultFontSize,
    this.indent = const EditorIndent(),
    this.fontFamily,
  });

  /// Bounds a stored size so a bad file cannot make the editor unreadable.
  static const int minimumFontSize = 9;
  static const int maximumFontSize = 40;
  static const int defaultFontSize = 14;

  final ThemeMode themeMode;
  final int fontSize;
  final EditorIndent indent;

  /// Null means the platform's default fixed-width face, which is what the
  /// editor already uses.
  final String? fontFamily;

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? fontSize,
    EditorIndent? indent,
    String? fontFamily,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    fontSize: fontSize ?? this.fontSize,
    indent: indent ?? this.indent,
    fontFamily: fontFamily ?? this.fontFamily,
  );

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'fontSize': fontSize,
    'indent': {'usesTabs': indent.usesTabs, 'size': indent.size},
    if (fontFamily != null) 'fontFamily': fontFamily,
  };

  /// Read a stored document, falling back field by field. One bad value costs
  /// that value, not the whole file.
  static AppSettings fromJson(Map<String, Object?>? json) {
    if (json == null) return const AppSettings();
    const fallback = AppSettings();
    return AppSettings(
      themeMode: _themeMode(json['themeMode']) ?? fallback.themeMode,
      fontSize: _fontSize(json['fontSize']) ?? fallback.fontSize,
      indent: _indent(json['indent']) ?? fallback.indent,
      fontFamily: json['fontFamily'] is String
          ? json['fontFamily'] as String
          : null,
    );
  }

  static ThemeMode? _themeMode(Object? value) => switch (value) {
    'system' => ThemeMode.system,
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => null,
  };

  static int? _fontSize(Object? value) =>
      value is int && value >= minimumFontSize && value <= maximumFontSize
      ? value
      : null;

  static EditorIndent? _indent(Object? value) {
    if (value is! Map) return null;
    final size = value['size'];
    final usesTabs = value['usesTabs'];
    if (size is! int || size < 0 || size > 16 || usesTabs is! bool) {
      return null;
    }
    return EditorIndent(usesTabs: usesTabs, size: size);
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.fontSize == fontSize &&
      other.indent == indent &&
      other.fontFamily == fontFamily;

  @override
  int get hashCode => Object.hash(themeMode, fontSize, indent, fontFamily);
}

/// Where the user's choices live. Abstract so tests can supply their own.
abstract interface class SettingsStore {
  /// The stored settings, or null when there are none to be had. A file that
  /// cannot be read is absent as far as callers are concerned.
  Future<AppSettings?> load();

  Future<void> save(AppSettings settings);
}

/// The settings file, wherever the platform says a per-user application keeps
/// one.
final class LocalSettingsStore implements SettingsStore {
  LocalSettingsStore(this.file);

  /// `settings.json` in the platform's per-user configuration directory, named
  /// after the application id so it cannot collide with anything else.
  factory LocalSettingsStore.defaultLocation() =>
      LocalSettingsStore(File(_defaultPath()));

  final File file;

  @override
  Future<AppSettings?> load() async {
    if (!await file.exists()) return null;
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return AppSettings.fromJson(Map<String, Object?>.from(decoded));
    } on FormatException {
      // A truncated or hand-mangled file is worth starting over from, not
      // worth refusing to start over from.
      return null;
    }
  }

  @override
  Future<void> save(AppSettings settings) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(settings.toJson())}\n',
    );
  }

  static String _defaultPath() {
    if (Platform.isMacOS) {
      final home = Platform.environment['HOME'];
      if (home != null) {
        return '$home/Library/Application Support/Planchette/settings.json';
      }
    }
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null) {
        return '${appData.replaceAll(r'\', '/')}/Planchette/settings.json';
      }
    }
    final config = Platform.environment['XDG_CONFIG_HOME'];
    if (config != null && config.isNotEmpty) {
      return '$config/planchette/settings.json';
    }
    final home = Platform.environment['HOME'];
    if (home != null) return '$home/.config/planchette/settings.json';
    return '.planchette-settings.json';
  }
}

/// The live settings, kept saved as they change.
final class SettingsController extends ChangeNotifier {
  SettingsController({required this.store});

  final SettingsStore store;
  AppSettings _value = const AppSettings();
  String? _error;
  Future<void> _pending = Future<void>.value();

  AppSettings get value => _value;
  String? get error => _error;

  /// Adopt what was stored, or the defaults when there was nothing usable.
  Future<void> load() async {
    _value = await store.load() ?? const AppSettings();
    notifyListeners();
  }

  /// Apply [next] and save it. An identical value does nothing at all, so a
  /// dialog that writes back its starting values on dismiss costs nothing.
  ///
  /// A failed write is reported through [error] rather than thrown: this is
  /// called from a dialog's button press, and a setting the user just chose is
  /// worth keeping even when the disk said no.
  Future<void> update(AppSettings next) async {
    if (next == _value) return;
    _value = next;
    notifyListeners();
    _pending = _persist();
    await _pending;
  }

  /// Wait for a save started by [update]. A dialog calls this before it closes
  /// so its button press is not reported as done while the write is in flight.
  Future<void> flush() => _pending;

  Future<void> _persist() async {
    try {
      await store.save(_value);
      _error = null;
    } on FileSystemException catch (error) {
      _error =
          'Could not save settings: ${error.osError?.message ?? error.message}';
      notifyListeners();
    }
  }
}
