import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Flushes a local directory entry where the platform exposes a proven
/// primitive. Linux uses `open(O_DIRECTORY)` plus `fsync`; other platforms
/// retain the explicit unsupported-handle behavior tracked by PGE-03a.
Future<void> syncLocalDirectory(Directory directory) async {
  if (Platform.isLinux) {
    _syncLinuxDirectory(directory.path);
    return;
  }

  await _syncUnsupportedPlatformDirectory(directory);
}

const int _openReadOnly = 0;
const int _linuxOpenDirectory = 1 << 16;
const int _linuxCloseOnExec = 1 << 19;
const int _posixIsDirectory = 21;
const int _windowsAccessDenied = 5;

final class _LinuxDirectorySyncBindings {
  _LinuxDirectorySyncBindings(DynamicLibrary libc)
    : open = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32, Uint32),
            int Function(Pointer<Utf8>, int, int)
          >('open'),
      fsync = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'fsync',
      ),
      close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
        'close',
      ),
      errnoLocation = libc
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            '__errno_location',
          );

  final int Function(Pointer<Utf8>, int, int) open;
  final int Function(int) fsync;
  final int Function(int) close;
  final Pointer<Int32> Function() errnoLocation;

  int get errno => errnoLocation().value;
}

_LinuxDirectorySyncBindings? _linuxBindings;

_LinuxDirectorySyncBindings _bindingsFor(String path) {
  try {
    return _linuxBindings ??= _LinuxDirectorySyncBindings(
      DynamicLibrary.process(),
    );
  } on Object catch (error) {
    throw FileSystemException(
      'native directory fsync is unavailable: $error',
      path,
    );
  }
}

void _syncLinuxDirectory(String path) {
  final bindings = _bindingsFor(path);
  final nativePath = path.toNativeUtf8();
  final descriptor = bindings.open(
    nativePath,
    _openReadOnly | _linuxOpenDirectory | _linuxCloseOnExec,
    0,
  );
  if (descriptor < 0) {
    final errno = bindings.errno;
    malloc.free(nativePath);
    throw _systemCallFailure('open directory', path, errno);
  }

  FileSystemException? failure;
  if (bindings.fsync(descriptor) != 0) {
    failure = _systemCallFailure('fsync directory', path, bindings.errno);
  }

  if (bindings.close(descriptor) != 0 && failure == null) {
    failure = _systemCallFailure('close directory', path, bindings.errno);
  }
  malloc.free(nativePath);

  if (failure != null) throw failure;
}

FileSystemException _systemCallFailure(
  String operation,
  String path,
  int errno,
) => FileSystemException(
  '$operation failed',
  path,
  OSError('errno $errno', errno),
);

Future<void> _syncUnsupportedPlatformDirectory(Directory directory) async {
  final RandomAccessFile handle;
  try {
    handle = await File(directory.path).open();
  } on FileSystemException catch (error) {
    if (_isUnsupportedDirectoryOpen(error)) return;

    rethrow;
  }

  try {
    await handle.flush();
  } finally {
    await handle.close();
  }
}

bool _isUnsupportedDirectoryOpen(FileSystemException error) {
  final errorCode = error.osError?.errorCode;
  if (Platform.isWindows) return errorCode == _windowsAccessDenied;

  return errorCode == _posixIsDirectory;
}
