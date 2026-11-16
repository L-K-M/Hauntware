import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import 'editor_definition.dart';
import 'editor_fields.dart';

/// Starts a detached editor process. Injectable so tests never launch one.
typedef EditorProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// Shows the platform's executable picker (Linux and Windows) and returns
/// the chosen path, or null on cancellation.
typedef EditorExecutablePicker =
    Future<String?> Function(EditorHostPlatform platform, String dialogTitle);

/// Launches and picks configured external editors without ever
/// constructing a shell command.
///
/// macOS goes through the app's runner [channel] (`openWithApplication`
/// with a path and bundle identifier, `pickApplication` with the panel's
/// title); Linux and Windows start the executable directly. Each app keeps
/// its own channel name and its own System default launch.
final class GhostEditorLauncher {
  const GhostEditorLauncher({
    required this.channel,
    this._processStarter,
    this._executablePicker,
  });

  final MethodChannel channel;
  final EditorProcessStarter? _processStarter;
  final EditorExecutablePicker? _executablePicker;

  Future<void> openWith(String path, ExternalEditorDefinition editor) async {
    if (!editor.isAvailableOnCurrentPlatform) {
      throw UnsupportedError(
        '${editor.displayName} is configured for another platform.',
      );
    }
    if (editor.platform == EditorHostPlatform.macos) {
      await channel.invokeMethod<void>('openWithApplication', {
        'path': path,
        'bundleIdentifier': editor.launchTarget,
      });
      return;
    }

    final executable = File(editor.launchTarget);
    final type = await FileSystemEntity.type(editor.launchTarget);
    if (!executable.isAbsolute || type != FileSystemEntityType.file) {
      throw StateError(
        '${editor.displayName} is no longer installed at '
        '${editor.launchTarget}.',
      );
    }
    if (editor.platform == EditorHostPlatform.linux &&
        ((await executable.stat()).mode & 0x49) == 0) {
      throw StateError('${editor.displayName} is not executable.');
    }
    await (_processStarter ?? _startDetached)(editor.launchTarget, [path]);
  }

  static Future<Process> _startDetached(
    String executable,
    List<String> arguments,
  ) => Process.start(
    executable,
    arguments,
    runInShell: false,
    mode: ProcessStartMode.detached,
  );

  /// Picks an application and returns its definition, with a fresh id and
  /// no extension filter; null on cancellation or on a host without a
  /// desktop editor platform. [dialogTitle] is the caller's own string.
  Future<ExternalEditorDefinition?> pickEditor({
    required String dialogTitle,
  }) async {
    final platform = currentEditorHostPlatform;
    if (platform == null) return null;

    if (platform == EditorHostPlatform.macos) {
      final result = await channel.invokeMapMethod<String, dynamic>(
        'pickApplication',
        {'title': dialogTitle},
      );
      if (result == null) return null;
      final bundleIdentifier = result['bundleIdentifier'] as String?;
      if (bundleIdentifier == null || bundleIdentifier.isEmpty) {
        throw StateError('The selected application has no bundle identifier.');
      }
      return ExternalEditorDefinition(
        id: _uuidV4(),
        displayName: validateEditorDisplayName(result['displayName']),
        platform: platform,
        launchTarget: bundleIdentifier,
      );
    }

    final path = await (_executablePicker ?? _defaultPickExecutable)(
      platform,
      dialogTitle,
    );
    if (path == null) return null;
    final file = File(path);
    final type = await FileSystemEntity.type(path);
    if (!file.isAbsolute || type != FileSystemEntityType.file) {
      throw StateError('Choose a regular executable file.');
    }
    if (platform == EditorHostPlatform.windows &&
        !path.toLowerCase().endsWith('.exe')) {
      throw StateError('Windows editors must be .exe applications.');
    }
    if (platform == EditorHostPlatform.linux &&
        ((await file.stat()).mode & 0x49) == 0) {
      throw StateError('The selected file is not executable.');
    }
    final name = path.split(Platform.pathSeparator).last;
    return ExternalEditorDefinition(
      id: _uuidV4(),
      displayName: validateEditorDisplayName(
        platform == EditorHostPlatform.windows &&
                name.toLowerCase().endsWith('.exe')
            ? name.substring(0, name.length - 4)
            : name,
      ),
      platform: platform,
      launchTarget: path,
    );
  }

  static Future<String?> _defaultPickExecutable(
    EditorHostPlatform platform,
    String dialogTitle,
  ) async {
    final picked = await FilePicker.pickFile(
      dialogTitle: dialogTitle,
      type: platform == EditorHostPlatform.windows
          ? FileType.custom
          : FileType.any,
      allowedExtensions: platform == EditorHostPlatform.windows
          ? const ['exe']
          : null,
      windowsOptions: const WindowsOptions(lockParentWindow: true),
    );
    return picked?.path;
  }
}

final _random = Random.secure();

/// A random (version 4) UUID: the id of a newly picked editor.
String _uuidV4() {
  final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
