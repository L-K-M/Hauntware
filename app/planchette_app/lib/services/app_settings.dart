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
    // `load` is called from `main()` before `runApp`, so anything it lets
    // escape is the reason the application refuses to open. A file that is
    // missing, unreadable, or not settings at all is worth starting over from
    // rather than refusing to start.
    try {
      if (!await file.exists()) return null;
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map) return null;
      return AppSettings.fromJson(Map<String, Object?>.from(decoded));
    } on Exception {
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

  /// Values waiting to be written, oldest first. Never more than one write is
  /// in flight, so a slow store cannot land an older value after a newer one.
  final List<AppSettings> _queue = [];

  /// Completes when the current drain finishes.
  Future<void> _pending = Future<void>.value();

  /// Whether a drain is running.
  bool _writing = false;

  AppSettings get value => _value;
  String? get error => _error;

  /// Adopt what was stored, or the defaults when there was nothing usable.
  ///
  /// A store that throws is treated as having nothing, for the same reason
  /// [LocalSettingsStore.load] swallows its own failures: this runs before the
  /// first frame and a settings file must never be able to stop the app.
  Future<void> load() async {
    try {
      _value = await store.load() ?? const AppSettings();
    } on Exception {
      _value = const AppSettings();
    }
    notifyListeners();
  }

  /// Apply [next] and save it. An identical value does nothing at all, so a
  /// dialog that writes back its starting values on dismiss costs nothing.
  ///
  /// A failed write is reported through [error] rather than thrown: this is
  /// called from a dialog's button press, and a setting the user just chose is
  /// worth keeping even when the disk said no.
  Future<void> update(AppSettings next) {
    if (next == _value) return Future<void>.value();

    _value = next;
    notifyListeners();
    // Queued rather than written here: two updates in quick succession would
    // otherwise write concurrently, and the slower one could land last and
    // leave a value the user has already moved on from.
    _queue.add(next);
    // A drain in progress will pick this up; joining it is what keeps two
    // writes from overlapping.
    return _writing ? _pending : _drain();
  }

  /// Write everything queued, one at a time, in the order it was chosen.
  ///
  /// A queue rather than a `.then` chain on purpose: a caller awaiting a chain
  /// needs an extra turn of the event loop, which a widget test that has not
  /// pumped yet does not give it.
  Future<void> _drain() async {
    _writing = true;
    try {
      while (_queue.isNotEmpty) {
        await _persist(_queue.removeAt(0));
      }
    } finally {
      _writing = false;
      _pending = Future<void>.value();
    }
  }

  /// Wait for the writes [update] has queued. A dialog calls this before it
  /// closes so its button press is not reported as done while the write is in
  /// flight, and a test asserts on the store after this.
  Future<void> flush() => _pending;

  /// Write [value], not whatever the field holds by the time this runs: a queue
  /// of saves should not be able to collapse two of them into one value.
  Future<void> _persist(AppSettings value) async {
    try {
      await store.save(value);
      _error = null;
    } on FileSystemException catch (error) {
      _error =
          'Could not save settings: ${error.osError?.message ?? error.message}';
      notifyListeners();
    }
  }
}
