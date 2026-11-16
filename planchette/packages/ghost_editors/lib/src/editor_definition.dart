import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show normalizeEditorExtensions, validateEditorDisplayName;

/// The desktop platform an [ExternalEditorDefinition] launches on.
enum EditorHostPlatform { macos, linux, windows }

/// The desktop platform this process runs on; null on Android and iOS,
/// which have no external in-place editing.
EditorHostPlatform? get currentEditorHostPlatform {
  final override = debugEditorHostPlatform;
  if (override != null) return override();
  if (Platform.isMacOS) return EditorHostPlatform.macos;
  if (Platform.isLinux) return EditorHostPlatform.linux;
  if (Platform.isWindows) return EditorHostPlatform.windows;
  return null;
}

/// Test seam for [currentEditorHostPlatform]; assign `() => null` to
/// simulate a host with no desktop editor platform (Android/iOS).
@visibleForTesting
EditorHostPlatform? Function()? debugEditorHostPlatform;

/// One configured external application.
class ExternalEditorDefinition {
  final String id;
  final String displayName;
  final EditorHostPlatform platform;

  /// Bundle identifier on macOS; absolute executable path elsewhere.
  final String launchTarget;
  final List<String> acceptedExtensions;

  const ExternalEditorDefinition({
    required this.id,
    required this.displayName,
    required this.platform,
    required this.launchTarget,
    this.acceptedExtensions = const [],
  });

  factory ExternalEditorDefinition.fromJson(Map<String, dynamic> json) {
    final platformName = json['platform'];
    final platform = EditorHostPlatform.values.where(
      (value) => value.name == platformName,
    );
    if (platform.isEmpty) {
      throw const FormatException('Unknown editor platform');
    }
    final parsedPlatform = platform.first;
    return ExternalEditorDefinition(
      id: validateEditorId(json['id']),
      displayName: validateEditorDisplayName(json['displayName']),
      platform: parsedPlatform,
      launchTarget: validateEditorTarget(json['launchTarget'], parsedPlatform),
      acceptedExtensions: normalizeEditorExtensions(
        json['acceptedExtensions'] is List
            ? (json['acceptedExtensions'] as List).whereType<String>()
            : const [],
      ),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'displayName': displayName,
    'platform': platform.name,
    'launchTarget': launchTarget,
    'acceptedExtensions': acceptedExtensions,
  };

  ExternalEditorDefinition copyWith({
    String? displayName,
    List<String>? acceptedExtensions,
  }) => ExternalEditorDefinition(
    id: id,
    displayName: validateEditorDisplayName(displayName ?? this.displayName),
    platform: platform,
    launchTarget: launchTarget,
    acceptedExtensions: acceptedExtensions ?? this.acceptedExtensions,
  );

  bool acceptsPath(String path) {
    if (acceptedExtensions.isEmpty) return true;
    final name = path.replaceAll('\\', '/').split('/').last.toLowerCase();
    return acceptedExtensions.any((extension) => name.endsWith('.$extension'));
  }

  bool get isAvailableOnCurrentPlatform =>
      platform == currentEditorHostPlatform;
}

final _editorIdPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');

/// [value] when it is a usable editor id; otherwise throws a
/// [FormatException]. The registry's reserved selectors fall outside this
/// alphabet on purpose, so no stored editor can claim one.
String validateEditorId(Object? value) {
  if (value is! String || !_editorIdPattern.hasMatch(value)) {
    throw const FormatException('Invalid editor id');
  }
  return value;
}

/// [value] when it is a launch target [platform] can use; otherwise throws
/// a [FormatException].
///
/// Absoluteness is judged on the definition's platform, not the host's: a
/// synced or hand-edited registry can carry an other-platform editor (the
/// settings render it disabled), and `File.isAbsolute` would reject a
/// Windows path everywhere but Windows, making the entry unloadable rather
/// than merely unlaunchable.
String validateEditorTarget(Object? value, EditorHostPlatform platform) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 4096 ||
      value.contains('\u0000')) {
    throw const FormatException('Invalid editor target');
  }
  final absolute = switch (platform) {
    EditorHostPlatform.macos => true, // bundle identifier, not a path
    EditorHostPlatform.windows =>
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) || value.startsWith('\\\\'),
    EditorHostPlatform.linux => value.startsWith('/'),
  };
  if (!absolute) {
    throw const FormatException('Editor executable paths must be absolute');
  }
  if (platform == EditorHostPlatform.windows &&
      !value.toLowerCase().endsWith('.exe')) {
    throw const FormatException('Windows editors must be .exe applications');
  }
  return value;
}
