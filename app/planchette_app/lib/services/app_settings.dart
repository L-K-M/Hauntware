import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as paths;
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
    this.indentation = const Indentation.spaces(),
    this.fontFamily,
    this.recentTextTools = const [],
    this.saveOptions = const TextSaveOptions(),
  });

  /// Bounds a stored size so a bad file cannot make the editor unreadable.
  /// The range is View › Zoom's, so every size it reaches can be stored.
  static const int minimumFontSize = 9;
  static const int maximumFontSize = 48;
  static const int defaultFontSize = 14;

  /// A stored indentation width outside this range is not one.
  static const int maximumIndentWidth = 16;

  final ThemeMode themeMode;
  final int fontSize;

  /// The indentation for documents that neither use nor mandate one yet, such
  /// as a new document. A file's own indentation, and a format that requires
  /// tabs, still win: this is the editor's `indentationPreference`.
  final Indentation indentation;

  /// A family to try before the platform's monospace one, read from a
  /// hand-edited settings file. Null means the platform's face.
  final String? fontFamily;

  /// The Recent text-tool runs, as [TextToolHistory.encode] wrote them.
  /// Kept opaque: the editor package owns the shape, and entries with a
  /// non-default text option never reach it.
  final List<Object?> recentTextTools;

  /// Opt-in whitespace cleanup. Both choices default off.
  final TextSaveOptions saveOptions;

  AppSettings copyWith({
    ThemeMode? themeMode,
    int? fontSize,
    Indentation? indentation,
    List<Object?>? recentTextTools,
    TextSaveOptions? saveOptions,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    fontSize: fontSize ?? this.fontSize,
    indentation: indentation ?? this.indentation,
    fontFamily: fontFamily,
    recentTextTools: recentTextTools ?? this.recentTextTools,
    saveOptions: saveOptions ?? this.saveOptions,
  );

  Map<String, Object?> toJson() => {
    'themeMode': themeMode.name,
    'fontSize': fontSize,
    'indent': {
      'usesTabs': indentation.style == IndentStyle.tabs,
      'size': indentation.width,
    },
    'trimTrailingWhitespaceOnSave':
        saveOptions.trailingWhitespace == TrailingWhitespacePolicy.trim,
    'ensureFinalNewline': saveOptions.finalNewline == FinalNewlinePolicy.ensure,
    if (fontFamily != null) 'fontFamily': fontFamily,
    if (recentTextTools.isNotEmpty) 'recentTextTools': recentTextTools,
  };

  /// Read a stored document, falling back field by field. One bad value costs
  /// that value, not the whole file.
  static AppSettings fromJson(Map<String, Object?>? json) {
    if (json == null) return const AppSettings();
    const fallback = AppSettings();
    final family = json['fontFamily'];
    return AppSettings(
      themeMode: _themeMode(json['themeMode']) ?? fallback.themeMode,
      fontSize: _fontSize(json['fontSize']) ?? fallback.fontSize,
      indentation: _indentation(json['indent']) ?? fallback.indentation,
      fontFamily: family is String && family.trim().isNotEmpty
          ? family.trim()
          : null,
      recentTextTools: json['recentTextTools'] is List
          ? List<Object?>.of(json['recentTextTools'] as List)
          : const [],
      saveOptions: _saveOptions(json),
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

  static Indentation? _indentation(Object? value) {
    if (value is! Map) return null;
    final size = value['size'];
    final usesTabs = value['usesTabs'];
    if (size is! int ||
        size < 1 ||
        size > maximumIndentWidth ||
        usesTabs is! bool) {
      return null;
    }
    return usesTabs ? Indentation.tabs(width: size) : Indentation.spaces(size);
  }

  /// Both flags default off. A missing key, or one that is not a bool,
  /// keeps that flag off rather than failing the whole file.
  static TextSaveOptions _saveOptions(Map<String, Object?> json) {
    final trim = json['trimTrailingWhitespaceOnSave'];
    final newline = json['ensureFinalNewline'];
    return TextSaveOptions(
      trailingWhitespace: trim == true
          ? TrailingWhitespacePolicy.trim
          : TrailingWhitespacePolicy.preserve,
      finalNewline: newline == true
          ? FinalNewlinePolicy.ensure
          : FinalNewlinePolicy.preserve,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AppSettings &&
      other.themeMode == themeMode &&
      other.fontSize == fontSize &&
      other.indentation == indentation &&
      other.fontFamily == fontFamily &&
      other.saveOptions == saveOptions &&
      _listsEqual(other.recentTextTools, recentTextTools);

  /// The list is JSON-shaped (it is what [TextToolHistory.encode] wrote),
  /// so its canonical encoding is the deep comparison.
  static bool _listsEqual(List<Object?> a, List<Object?> b) =>
      jsonEncode(a) == jsonEncode(b);

  // The same canonical encoding [_listsEqual] compares — equal lists must
  // hash equal, and hashing the list's maps directly would not see them.
  @override
  int get hashCode => Object.hash(
    themeMode,
    fontSize,
    indentation,
    fontFamily,
    saveOptions,
    jsonEncode(recentTextTools),
  );
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

  /// `settings.json` in the platform's per-user configuration directory. With
  /// no such directory to be found, the settings last for this session only.
  static SettingsStore defaultLocation() =>
      switch (defaultFilePath('settings.json')) {
        final path? => LocalSettingsStore(File(path)),
        null => _SessionSettingsStore(),
      };

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

  /// Writes beside the file and renames over it, so a crash mid-write leaves
  /// the previous settings rather than a truncated file that would read as
  /// none at all.
  @override
  Future<void> save(AppSettings settings) async {
    final target = await _destination();
    await target.parent.create(recursive: true);
    final staging = File('${target.path}.tmp');
    await staging.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(settings.toJson())}\n',
      flush: true,
    );
    await staging.rename(target.path);
  }

  /// The file a save replaces: where a link at [file] points, so settings
  /// kept elsewhere, such as in a dotfiles folder, stay linked instead of
  /// being replaced by a copy.
  Future<File> _destination() async {
    if (!await FileSystemEntity.isLink(file.path)) return file;
    try {
      return File(await file.resolveSymbolicLinks());
    } on FileSystemException {
      // A link to a file that does not exist yet: write where it points.
      final target = await Link(file.path).target();
      return File(
        paths.isAbsolute(target)
            ? target
            : paths.join(file.parent.path, target),
      );
    }
  }

  /// The per-user application path for [fileName], wherever the platform
  /// says one belongs — `null` when there is no such place. Shared with the
  /// files Planchette keeps beside `settings.json`, like `window_state.json`.
  static String? defaultFilePath(String fileName) {
    final environment = Platform.environment;
    if (Platform.isMacOS) {
      if (environment['HOME'] case final home? when home.isNotEmpty) {
        return '$home/Library/Application Support/Planchette/$fileName';
      }
    }
    if (Platform.isWindows) {
      if (environment['APPDATA'] case final appData? when appData.isNotEmpty) {
        return '$appData\\Planchette\\$fileName';
      }
    }
    // The XDG base directory spec says to ignore a relative value, which
    // would otherwise put the settings under the working directory.
    if (environment['XDG_CONFIG_HOME'] case final config?
        when paths.isAbsolute(config)) {
      return '$config/planchette/$fileName';
    }
    if (environment['HOME'] case final home? when home.isNotEmpty) {
      return '$home/.config/planchette/$fileName';
    }
    return null;
  }
}

/// Settings kept in memory, for a system with nowhere to store them.
final class _SessionSettingsStore implements SettingsStore {
  AppSettings? _settings;

  @override
  Future<AppSettings?> load() async => _settings;

  @override
  Future<void> save(AppSettings settings) async => _settings = settings;
}

/// The live settings, kept saved as they change.
final class SettingsController extends ChangeNotifier {
  SettingsController({
    required this.store,
    AppSettings initial = const AppSettings(),
  }) : _value = initial;

  final SettingsStore store;
  AppSettings _value;
  String? _error;

  /// The newest value not yet handed to the store. Never more than one write
  /// is in flight, so a slow store cannot land an older value after a newer
  /// one, and values chosen during a write collapse into the newest, so a
  /// slider dragged through twenty sizes writes two files, not twenty.
  AppSettings? _unsaved;

  /// Completes when the running drain has written everything queued.
  Future<void> _pending = Future<void>.value();
  bool _writing = false;

  AppSettings get value => _value;

  /// Why the last save failed, until one succeeds or [clearError].
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
  /// dialog that writes back its starting values costs nothing.
  ///
  /// A failed write is reported through [error] rather than thrown: this is
  /// called from menus and a dialog, and a setting the user just chose is
  /// worth keeping for the session even when the disk said no.
  Future<void> update(AppSettings next) {
    if (next == _value) return Future<void>.value();
    _value = next;
    notifyListeners();
    _unsaved = next;
    // A running drain picks the value up; starting a second one would write
    // concurrently.
    if (!_writing) _pending = _drain();
    return _pending;
  }

  Future<void> _drain() async {
    _writing = true;
    try {
      for (var value = _unsaved; value != null; value = _unsaved) {
        _unsaved = null;
        await _persist(value);
      }
    } finally {
      _writing = false;
    }
  }

  /// Wait for every write [update] has started. A test asserts on the store
  /// after this, and a caller can await it before the app exits.
  Future<void> flush() => _pending;

  void clearError() {
    if (_error == null) return;
    _error = null;
    notifyListeners();
  }

  /// Write [value], not whatever the field holds by the time this runs.
  Future<void> _persist(AppSettings value) async {
    try {
      await store.save(value);
      if (_error != null) clearError();
    } on Exception catch (error) {
      final detail = error is FileSystemException
          ? error.osError?.message ?? error.message
          : '$error';
      _error = 'Could not save settings: $detail';
      notifyListeners();
    }
  }
}
