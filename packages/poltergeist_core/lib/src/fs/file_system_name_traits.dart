import 'package:seance_core/seance_core.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Whether a filesystem treats variants on one filename axis as identical.
enum FileSystemNameSensitivity { sensitive, insensitive }

/// The two independent filename-identity properties of one filesystem root.
final class FileSystemNameTraits {
  const FileSystemNameTraits({
    required this.caseSensitivity,
    required this.normalizationSensitivity,
  });

  final FileSystemNameSensitivity caseSensitivity;
  final FileSystemNameSensitivity normalizationSensitivity;
}

/// Joins a probe filename to a filesystem-specific root path.
typedef FileSystemNameJoin = String Function(String rootPath, String name);

/// The probe succeeded far enough to create a file but could not remove it.
/// Callers must surface this because the reserved file may remain visible.
final class FileSystemNameProbeCleanupException implements Exception {
  const FileSystemNameProbeCleanupException({
    required this.path,
    required this.cause,
  });

  final String path;
  final Object cause;

  @override
  String toString() => 'filename probe may remain at "$path": $cause';
}

/// Probe debris uses this prefix and remains recognizable after a crash.
const String fileSystemNameProbePrefix = '.poltergeist-nameprobe';

const String _decomposedProbeLetter = 'e\u0301';
const int _probeSuffixBytes = 8;
final RegExp _probeArtifactName = RegExp(
  r'^\.poltergeist-nameprobe-[0-9a-f]{16}-é$',
  caseSensitive: false,
);

/// Recognizes only the generated probe shape, not user names sharing its
/// human-readable prefix.
bool isFileSystemNameProbeArtifact(String name) =>
    _probeArtifactName.hasMatch(unorm.nfc(name));

/// Resolves case and canonical-normalization sensitivity for [rootPath].
///
/// One empty file is written and looked up through independent case and NFC
/// variants, then deleted. Probe errors are surfaced so the caller can choose
/// its own conservative fallback.
Future<FileSystemNameTraits> probeFileSystemNameTraits(
  RemoteFileSystem fileSystem,
  String rootPath, {
  String probePrefix = fileSystemNameProbePrefix,
  String? probeSuffix,
  FileSystemNameJoin joinPath = remoteJoin,
  RemoteTransferCancellation? cancellation,
}) async {
  final suffix = probeSuffix ?? _randomProbeSuffix();
  final probeName = '$probePrefix-$suffix-$_decomposedProbeLetter';
  final probePath = joinPath(rootPath, probeName);
  RemoteFileEntry? probeEntry;
  Object? uploadError;

  try {
    try {
      probeEntry = await fileSystem.upload(
        probePath,
        const Stream<List<int>>.empty(),
        cancellation: cancellation,
      );
    } catch (error) {
      uploadError = error;
      rethrow;
    }

    cancellation?.throwIfCancelled();
    final caseSensitive = !await _exists(
      fileSystem,
      joinPath(rootPath, probeName.toUpperCase()),
    );
    cancellation?.throwIfCancelled();
    final normalizationSensitive = !await _exists(
      fileSystem,
      joinPath(rootPath, unorm.nfc(probeName)),
    );
    cancellation?.throwIfCancelled();

    return FileSystemNameTraits(
      caseSensitivity: caseSensitive
          ? FileSystemNameSensitivity.sensitive
          : FileSystemNameSensitivity.insensitive,
      normalizationSensitivity: normalizationSensitive
          ? FileSystemNameSensitivity.sensitive
          : FileSystemNameSensitivity.insensitive,
    );
  } finally {
    if (probeEntry != null) {
      try {
        await fileSystem.delete(probeEntry);
      } catch (error) {
        throw FileSystemNameProbeCleanupException(
          path: probeEntry.path,
          cause: error,
        );
      }
    } else if (uploadError != null) {
      var probeMayExist = false;
      try {
        await fileSystem.stat(probePath, followLinks: false);
        probeMayExist = true;
      } on RemoteFileException catch (error) {
        if (error.kind == RemoteFileErrorKind.notFound) {
          // The failed upload left no path to clean up.
        } else {
          throw FileSystemNameProbeCleanupException(
            path: probePath,
            cause: error,
          );
        }
      } catch (error) {
        throw FileSystemNameProbeCleanupException(
          path: probePath,
          cause: error,
        );
      }

      if (probeMayExist) {
        // No returned entry means ownership is unproven; never delete a
        // possible pre-existing collision under a guessed identity.
        throw FileSystemNameProbeCleanupException(
          path: probePath,
          cause: uploadError,
        );
      }
    }
  }
}

Future<bool> _exists(RemoteFileSystem fileSystem, String path) async {
  try {
    await fileSystem.stat(path, followLinks: false);
    return true;
  } on RemoteFileException catch (error) {
    if (error.kind == RemoteFileErrorKind.notFound) return false;
    rethrow;
  }
}

String _randomProbeSuffix() => secureRandomBytes(
  _probeSuffixBytes,
).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
