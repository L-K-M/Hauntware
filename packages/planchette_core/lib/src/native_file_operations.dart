import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

// Dart's File.rename overwrites an existing destination. A final exists()
// check cannot close that race, and File.create(exclusive: true) would expose
// an empty destination before its contents were ready. These native operations
// publish a fully written sibling while atomically refusing an occupied path.
void renameFileWithoutReplacing(String source, String destination) {
  _checkPath(source);
  _checkPath(destination);
  if (Platform.isWindows) {
    _renameWindows(source, destination);
    return;
  }
  if (!Platform.isMacOS &&
      !Platform.isIOS &&
      !Platform.isLinux &&
      !Platform.isAndroid) {
    throw FileSystemException('Safe no-replace rename is unavailable.', source);
  }
  final oldPath = source.toNativeUtf8();
  final newPath = destination.toNativeUtf8();
  try {
    // Resolve errno before the operation: a lazy symbol lookup after failure
    // could itself change the native thread's error state.
    final errorNumber = _errno();
    late final int result;
    if (Platform.isMacOS || Platform.isIOS) {
      // Darwin <sys/stdio.h>: RENAME_EXCL = 0x00000004.
      result = _renameDarwin(oldPath, newPath, 0x4);
    } else if (Platform.isAndroid) {
      // Bionic only exports renameat2 on newer Android versions. A hard-link
      // publication provides the same no-replace guard on app-owned storage.
      renameUsingHardLink(
        source,
        destination,
        link: () => _link(oldPath, newPath),
        unlink: (path) => _unlink(path == source ? oldPath : newPath),
        readError: () => errorNumber.value,
      );
      return;
    } else {
      // Linux renameat2(2): AT_FDCWD = -100; RENAME_NOREPLACE = 1.
      result = _renameLinux(-100, oldPath, -100, newPath, 1);
    }
    if (result != 0) {
      throw FileSystemException(
        'Could not rename without replacing the destination.',
        destination,
        OSError('Native rename failed', errorNumber.value),
      );
    }
  } on ArgumentError {
    throw FileSystemException('Safe no-replace rename is unavailable.', source);
  } finally {
    calloc.free(oldPath);
    calloc.free(newPath);
  }
}

/// Isolated for deterministic coverage of Android's partial-success path.
/// This helper is internal to the package, not part of its exported API.
void renameUsingHardLink(
  String source,
  String destination, {
  required int Function() link,
  required int Function(String path) unlink,
  required int Function() readError,
}) {
  if (link() != 0) {
    throw FileSystemException(
      'Could not publish the document without replacing the destination.',
      destination,
      OSError('link failed', readError()),
    );
  }
  if (unlink(source) != 0) {
    final error = readError();
    // The destination may already have been replaced by another writer. Never
    // delete it to undo publication; retain both names for recovery instead.
    throw HardLinkCleanupException(source, destination, error);
  }
}

/// A caller must not clean up [path] after this partial publication failure.
final class HardLinkCleanupException extends FileSystemException {
  HardLinkCleanupException(String source, String destination, int error)
    : super(
        'The document was published at $destination, but its source at $source '
        'could not be removed. Both paths have been retained for recovery.',
        source,
        OSError('unlink failed', error),
      );
}

/// Windows uses inherited ACLs; POSIX preserves the existing host policy.
void setFilePermissions(String path, int mode) {
  if (!Platform.isMacOS &&
      !Platform.isIOS &&
      !Platform.isLinux &&
      !Platform.isAndroid) {
    return;
  }
  _checkPath(path);
  final nativePath = path.toNativeUtf8();
  try {
    final errorNumber = _errno();
    if (_chmod(nativePath, mode) != 0) {
      throw FileSystemException(
        'Could not set the document file permissions safely.',
        path,
        OSError('chmod failed', errorNumber.value),
      );
    }
  } finally {
    calloc.free(nativePath);
  }
}

/// ENOENT on POSIX; ERROR_FILE_NOT_FOUND on Windows. Coincidentally 2 on
/// both — the destination file itself vanished mid-save, not a permission
/// or quota failure.
const int _errorNoSuchFile = 2;

/// Windows ERROR_PATH_NOT_FOUND: a parent directory in the path vanished.
/// POSIX reports the same situation as ENOENT ([_errorNoSuchFile]).
const int _errorPathNotFound = 3;

/// Whether [error] means a path vanished mid-operation: the destination or a
/// parent directory. POSIX reports both as [_errorNoSuchFile]; Windows
/// reports a missing parent as [_errorPathNotFound]. Everything else
/// (permissions, quota) is a real failure, not a concurrent-modification
/// signal.
///
/// Lives in this unexported library so hosts do not see it as package API;
/// tests import it from `src/` directly.
bool isVanishedPathError(FileSystemException error, {bool? isWindows}) {
  final code = error.osError?.errorCode;
  return code == _errorNoSuchFile ||
      ((isWindows ?? Platform.isWindows) && code == _errorPathNotFound);
}

/// Sets or clears the Windows read-only attribute, which Dart reports as a
/// mode without write bits, keeping the file's other attributes.
void setWindowsReadOnly(String path, {required bool readOnly}) {
  _checkPath(path);
  final nativePath = _windowsExtendedPath(path).toNativeUtf16();
  try {
    final lastError = _getLastError;
    final attributes = _getFileAttributes(nativePath);
    if (attributes == _invalidFileAttributes) {
      throw FileSystemException(
        'Could not read the document file attributes.',
        path,
        OSError('GetFileAttributesW failed', lastError()),
      );
    }
    final updated = readOnly
        ? attributes | _fileAttributeReadOnly
        : attributes & ~_fileAttributeReadOnly;
    if (updated == attributes) return;
    // FILE_ATTRIBUTE_NORMAL stands for "no attributes" and must be used alone.
    final value = updated == 0 ? _fileAttributeNormal : updated;
    if (_setFileAttributes(nativePath, value) == 0) {
      throw FileSystemException(
        'Could not set the document file attributes.',
        path,
        OSError('SetFileAttributesW failed', lastError()),
      );
    }
  } finally {
    calloc.free(nativePath);
  }
}

// https://learn.microsoft.com/windows/win32/fileio/file-attribute-constants
const _fileAttributeReadOnly = 0x1;
const _fileAttributeNormal = 0x80;
const _invalidFileAttributes = 0xffffffff;

void _checkPath(String path) {
  if (path.contains('\u0000')) throw ArgumentError.value(path, 'path');
}

final _posix = DynamicLibrary.process();
final _renameDarwin = _posix
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, Pointer<Utf8>, int)
    >('renamex_np');
final _renameLinux = _posix
    .lookupFunction<
      Int32 Function(Int32, Pointer<Utf8>, Int32, Pointer<Utf8>, Uint32),
      int Function(int, Pointer<Utf8>, int, Pointer<Utf8>, int)
    >('renameat2');
final _chmod = _posix
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');
final _link = _posix
    .lookupFunction<
      Int32 Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)
    >('link');
final _unlink = _posix
    .lookupFunction<Int32 Function(Pointer<Utf8>), int Function(Pointer<Utf8>)>(
      'unlink',
    );
final _errno = _posix
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      Platform.isMacOS || Platform.isIOS
          ? '__error'
          : Platform.isAndroid
          ? '__errno'
          : '__errno_location',
    );

final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _moveFileEx = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, Pointer<Utf16>, int)
    >('MoveFileExW');
final _getLastError = _kernel32
    .lookupFunction<Uint32 Function(), int Function()>('GetLastError');
final _getFileAttributes = _kernel32
    .lookupFunction<
      Uint32 Function(Pointer<Utf16>),
      int Function(Pointer<Utf16>)
    >('GetFileAttributesW');
final _setFileAttributes = _kernel32
    .lookupFunction<
      Int32 Function(Pointer<Utf16>, Uint32),
      int Function(Pointer<Utf16>, int)
    >('SetFileAttributesW');

void _renameWindows(String source, String destination) {
  final oldPath = _windowsExtendedPath(source).toNativeUtf16();
  final newPath = _windowsExtendedPath(destination).toNativeUtf16();
  try {
    final lastError = _getLastError;
    // MOVEFILE_WRITE_THROUGH (8), without MOVEFILE_REPLACE_EXISTING (1).
    // https://learn.microsoft.com/windows/win32/api/winbase/nf-winbase-movefileexw
    if (_moveFileEx(oldPath, newPath, 8) == 0) {
      throw FileSystemException(
        'Could not rename without replacing the destination.',
        destination,
        OSError('MoveFileExW failed', lastError()),
      );
    }
  } finally {
    calloc.free(oldPath);
    calloc.free(newPath);
  }
}

String _windowsExtendedPath(String path) {
  final absolute = File(
    path,
  ).absolute.uri.normalizePath().toFilePath(windows: true);
  if (absolute.startsWith('\\\\?\\')) return absolute;
  if (absolute.startsWith('\\\\')) {
    return '\\\\?\\UNC\\${absolute.substring(2)}';
  }
  return '\\\\?\\$absolute';
}
