import 'dart:convert';
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

/// Copies each extended attribute of [source] onto [destination], on Linux
/// and macOS, and returns the names it could not copy.
///
/// A save replaces the file, so without this the attributes stay on the
/// moved-aside original and are deleted with it: Finder tags and comments,
/// download quarantine, and on Linux the `system.posix_acl_access` ACL and
/// any `user.*` data. Best effort by design: a namespace the process may not
/// write (Linux `trusted.*`, a SELinux label it cannot assign) or a
/// destination file system without attributes must not refuse a save whose
/// text is otherwise ready, so such names are returned, never thrown.
/// Symbolic links are not followed on either side. Other platforms copy
/// nothing.
List<String> copyExtendedAttributes(String source, String destination) {
  if (!Platform.isLinux && !Platform.isMacOS) return const [];
  _checkPath(source);
  _checkPath(destination);
  final from = source.toNativeUtf8();
  final to = destination.toNativeUtf8();
  final skipped = <String>[];
  try {
    final names = _readNative(
      (buffer, size) => _listAttributes(from, buffer, size),
    );
    if (names == null) return const [];
    // The list is NUL-separated names, each NUL-terminated.
    var start = 0;
    for (var i = 0; i < names.length; i++) {
      if (names[i] != 0) continue;
      if (i > start) {
        final name = utf8.decode(names.sublist(start, i), allowMalformed: true);
        if (!_copyAttribute(from, to, names.sublist(start, i))) {
          skipped.add(name);
        }
      }
      start = i + 1;
    }
    return skipped;
  } finally {
    calloc.free(from);
    calloc.free(to);
  }
}

/// Whether one attribute, named by its raw bytes, reached [to].
bool _copyAttribute(Pointer<Utf8> from, Pointer<Utf8> to, List<int> name) {
  final nativeName = calloc<Uint8>(name.length + 1);
  try {
    nativeName.asTypedList(name.length).setAll(0, name);
    nativeName[name.length] = 0;
    final key = nativeName.cast<Utf8>();
    final value = _readNative(
      (buffer, size) => _getAttribute(from, key, buffer, size),
    );
    if (value == null) return false;
    final nativeValue = calloc<Uint8>(value.isEmpty ? 1 : value.length);
    try {
      nativeValue.asTypedList(value.length).setAll(0, value);
      return _setAttribute(to, key, nativeValue, value.length) == 0;
    } finally {
      calloc.free(nativeValue);
    }
  } finally {
    calloc.free(nativeName);
  }
}

/// Runs a size-then-fill native read: [call] with a null buffer answers the
/// size, then fills a buffer of that size. Retried when the value grew in
/// between; null when the call fails.
List<int>? _readNative(int Function(Pointer<Uint8> buffer, int size) call) {
  for (var attempt = 0; attempt < 3; attempt++) {
    final size = call(nullptr, 0);
    if (size < 0) return null;
    if (size == 0) return const [];
    final buffer = calloc<Uint8>(size);
    try {
      final read = call(buffer, size);
      if (read >= 0) return List<int>.of(buffer.asTypedList(read));
    } finally {
      calloc.free(buffer);
    }
  }
  return null;
}

/// macOS XATTR_NOFOLLOW: act on a symbolic link itself.
const int _darwinNoFollow = 0x1;

int _listAttributes(Pointer<Utf8> path, Pointer<Uint8> buffer, int size) =>
    Platform.isMacOS
    ? _listXattrDarwin(path, buffer, size, _darwinNoFollow)
    : _listXattrLinux(path, buffer, size);

int _getAttribute(
  Pointer<Utf8> path,
  Pointer<Utf8> name,
  Pointer<Uint8> buffer,
  int size,
) => Platform.isMacOS
    ? _getXattrDarwin(path, name, buffer, size, 0, _darwinNoFollow)
    : _getXattrLinux(path, name, buffer, size);

int _setAttribute(
  Pointer<Utf8> path,
  Pointer<Utf8> name,
  Pointer<Uint8> value,
  int size,
) => Platform.isMacOS
    ? _setXattrDarwin(path, name, value, size, 0, _darwinNoFollow)
    : _setXattrLinux(path, name, value, size, 0);

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
// Linux <sys/xattr.h>, the l-variants that do not follow links.
final _listXattrLinux = _posix
    .lookupFunction<
      IntPtr Function(Pointer<Utf8>, Pointer<Uint8>, UintPtr),
      int Function(Pointer<Utf8>, Pointer<Uint8>, int)
    >('llistxattr');
final _getXattrLinux = _posix
    .lookupFunction<
      IntPtr Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, UintPtr),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, int)
    >('lgetxattr');
final _setXattrLinux = _posix
    .lookupFunction<
      Int32 Function(
        Pointer<Utf8>,
        Pointer<Utf8>,
        Pointer<Uint8>,
        UintPtr,
        Int32,
      ),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, int, int)
    >('lsetxattr');
// Darwin <sys/xattr.h>, with a resource-fork position and options.
final _listXattrDarwin = _posix
    .lookupFunction<
      IntPtr Function(Pointer<Utf8>, Pointer<Uint8>, UintPtr, Int32),
      int Function(Pointer<Utf8>, Pointer<Uint8>, int, int)
    >('listxattr');
final _getXattrDarwin = _posix
    .lookupFunction<
      IntPtr Function(
        Pointer<Utf8>,
        Pointer<Utf8>,
        Pointer<Uint8>,
        UintPtr,
        Uint32,
        Int32,
      ),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, int, int, int)
    >('getxattr');
final _setXattrDarwin = _posix
    .lookupFunction<
      Int32 Function(
        Pointer<Utf8>,
        Pointer<Utf8>,
        Pointer<Uint8>,
        UintPtr,
        Uint32,
        Int32,
      ),
      int Function(Pointer<Utf8>, Pointer<Utf8>, Pointer<Uint8>, int, int, int)
    >('setxattr');
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
