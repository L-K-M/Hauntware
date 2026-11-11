// Ported from Séance app/seance_app/lib/services/file_export_service.dart; see docs/PORTS.md.
import 'dart:io';

import 'package:flutter/services.dart';

/// Injectable boundary around Android's Storage Access Framework channel.
abstract interface class FileExportPlatform {
  Future<bool> pickExportDirectory();

  Future<bool> hasExportDirectoryAccess();

  Future<String> exportFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  });

  Future<void> releaseExportDirectory();
}

/// The Android implementation of [FileExportPlatform].
class MethodChannelFileExportPlatform implements FileExportPlatform {
  static const channelName = 'poltergeist/files';

  final MethodChannel _channel;

  MethodChannelFileExportPlatform({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(channelName);

  @override
  Future<bool> pickExportDirectory() async {
    final selected = await _channel.invokeMethod<bool>('pickExportDirectory');
    if (selected == null) {
      throw PlatformException(
        code: 'INVALID_RESULT',
        message: 'Android returned no directory selection result.',
      );
    }
    return selected;
  }

  @override
  Future<bool> hasExportDirectoryAccess() async {
    final hasAccess = await _channel.invokeMethod<bool>(
      'hasExportDirectoryAccess',
    );
    if (hasAccess == null) {
      throw PlatformException(
        code: 'INVALID_RESULT',
        message: 'Android returned no directory access result.',
      );
    }
    return hasAccess;
  }

  @override
  Future<String> exportFile({
    required String sourcePath,
    required String fileName,
    required String mimeType,
  }) async {
    final uri = await _channel.invokeMethod<String>('exportFile', {
      'sourcePath': sourcePath,
      'fileName': fileName,
      'mimeType': mimeType,
    });
    if (uri == null || uri.isEmpty) {
      throw PlatformException(
        code: 'INVALID_RESULT',
        message: 'Android returned no exported document URI.',
      );
    }
    return uri;
  }

  @override
  Future<void> releaseExportDirectory() =>
      _channel.invokeMethod<void>('releaseExportDirectory');
}

/// A local cache file plus the metadata used when exporting it.
class StagedExportFile {
  final File file;
  final String fileName;
  final String mimeType;

  const StagedExportFile({
    required this.file,
    required this.fileName,
    required this.mimeType,
  });
}

/// Exports staged files through Android's SAF. The desktop save panels
/// belong to the caller ([PlatformSecretsExportFiles]), which writes the
/// picked destination itself and never stages a file.
class FileExportService {
  final FileExportPlatform _platform;
  final bool _useAndroidSaf;

  FileExportService({
    FileExportPlatform? platform,
    bool? useAndroidSaf,
  }) : _platform = platform ?? MethodChannelFileExportPlatform(),
       _useAndroidSaf = useAndroidSaf ?? Platform.isAndroid;

  Future<bool> pickExportDirectory() {
    if (!_useAndroidSaf) return Future<bool>.value(false);
    return _platform.pickExportDirectory();
  }

  Future<bool> hasExportDirectoryAccess() {
    if (!_useAndroidSaf) return Future<bool>.value(false);
    return _platform.hasExportDirectoryAccess();
  }

  Future<void> releaseExportDirectory() {
    if (!_useAndroidSaf) return Future<void>.value();
    return _platform.releaseExportDirectory();
  }

  /// Hands the staged file to Android's document provider. Only called
  /// where SAF is in use; a null result means the user cancelled.
  Future<String?> exportFile(StagedExportFile stagedFile) async {
    if (!await stagedFile.file.exists()) {
      throw StateError('The staged export file no longer exists.');
    }
    return _platform.exportFile(
      sourcePath: stagedFile.file.path,
      fileName: stagedFile.fileName,
      mimeType: stagedFile.mimeType,
    );
  }
}
