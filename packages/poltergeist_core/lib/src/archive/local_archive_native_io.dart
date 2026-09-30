part of 'local_archive_service.dart';

const int _posixCurrentDirectory = -100;
const int _posixRenameNoReplace = 1;
const int _posixNonBlocking = 0x800;
const int _darwinNonBlocking = 0x4;
const int _posixCloseOnExec = 0x80000;
const int _darwinCloseOnExec = 0x1000000;
const int _darwinNoFollow = 0x100;
const int _nativeStatBufferBytes = 256;
const int _maximumFdInfoBytes = 4096;
const int _posixInterrupted = 4;
const int _darwinRenameExclusive = 4;
const int _posixAlreadyExists = 17;
const int _armRenameAt2SystemCall = 382;
const int _arm64RenameAt2SystemCall = 276;
const int _ia32RenameAt2SystemCall = 353;
const int _x64RenameAt2SystemCall = 316;
const int _riscvRenameAt2SystemCall = 276;
const int _windowsAlreadyExists = 183;
const int _windowsFileExists = 80;
const int _windowsGenericRead = 0x80000000;
const int _windowsShareRead = 0x1;
const int _windowsShareWrite = 0x2;
const int _windowsShareDelete = 0x4;
const int _windowsOpenExisting = 3;
const int _windowsFileAttributeNormal = 0x80;
const int _windowsFileAttributeDirectory = 0x10;
const int _windowsFileAttributeReparsePoint = 0x400;
const int _windowsOpenReparsePoint = 0x00200000;
const int _windowsSequentialScan = 0x08000000;
const int _windowsMoveWriteThrough = 0x8;
const int _windowsFileBasicInfo = 0;
const int _windowsFileBasicInfoBytes = 40;
const int _windowsFileInformationBytes = 52;
const int _windowsFileTimeEpochMicroseconds = 11644473600000000;

final RegExp _linuxFdInfoInodePattern = RegExp(
  r'^ino:[ \t]*(\d+)[ \t]*\r?\n',
  multiLine: true,
);
final RegExp _linuxFdInfoMountPattern = RegExp(
  r'^mnt_id:[ \t]*(\d+)[ \t]*\r?\n',
  multiLine: true,
);

AbstractFileHandle _openCreationInput(_CreationEntry entry) {
  if (Platform.isWindows) return _WindowsReadHandle(entry);
  return _PosixReadHandle(entry);
}

AbstractFileHandle _openArchiveInput(String path, FileStat expected) {
  if (Platform.isWindows) return _WindowsReadHandle.archive(path, expected);
  return _PosixReadHandle.archive(path, expected);
}

_CreationFileIdentity _inspectCreationFile(String path, FileStat expected) {
  if (Platform.isWindows) {
    final handle = _WindowsArchiveIo.instance.openNoFollow(path);
    try {
      final details = _WindowsArchiveIo.instance.details(handle);
      _validateCreationFileDetails(path, expected, details);
      return details.identity;
    } finally {
      _WindowsArchiveIo.instance.close(handle);
    }
  }

  final descriptor = _PosixArchiveIo.instance.openNoFollow(path);
  try {
    final details = _PosixArchiveIo.instance.details(descriptor, path);
    _validateCreationFileDetails(path, expected, details);
    return details.identity;
  } finally {
    _PosixArchiveIo.instance.close(descriptor);
  }
}

void _validateCreationFileDetails(
  String path,
  FileStat expected,
  _CreationFileDetails actual,
) {
  if (!actual.isRegularFile ||
      actual.isReparsePoint ||
      actual.length != expected.size ||
      actual.modified != expected.modified) {
    throw _WorkerAbort(
      LocalArchiveErrorKind.conflict,
      'A source file changed while it was being archived.',
      path: path,
    );
  }
}

bool _renameArchivePayloadNoReplace(String source, String destination) {
  if (Platform.isWindows) {
    return _WindowsArchiveIo.instance.renameNoReplace(source, destination);
  }
  return _PosixArchiveIo.instance.renameNoReplace(source, destination);
}

/// Exercises buffer growth with an injected allocator.
///
/// Public only so allocation failure ordering can be regression-tested.
@visibleForTesting
void resizeNativeReadBufferForTesting(
  Allocator allocator, {
  required int initialCapacity,
  required int replacementCapacity,
}) {
  final buffer = _NativeReadBuffer(allocator);
  try {
    buffer.acquire(initialCapacity);
    buffer.acquire(replacementCapacity);
  } finally {
    buffer.close();
  }
}

/// Invokes Linux `renameat2`, falling back when symbol resolution fails.
///
/// Public only so both injected resolution outcomes can be tested.
@visibleForTesting
int invokeLinuxRenameAt2ForTesting({
  required int Function() resolveAndInvoke,
  required int Function() invokeSyscall,
}) => _invokeLinuxRenameAt2(
  resolveAndInvoke: resolveAndInvoke,
  invokeSyscall: invokeSyscall,
);

int _invokeLinuxRenameAt2({
  required int Function() resolveAndInvoke,
  required int Function() invokeSyscall,
}) {
  try {
    return resolveAndInvoke();
  } on ArgumentError {
    return invokeSyscall();
  }
}

/// Parses a complete Linux descriptor identity from fdinfo text.
///
/// Identity lines require terminators so a partial number is never accepted.
@visibleForTesting
({int mountId, int inode}) parseLinuxFdInfoIdentity(String text, String path) {
  final inode = _linuxFdInfoInodePattern.firstMatch(text);
  final mount = _linuxFdInfoMountPattern.firstMatch(text);
  if (inode == null || mount == null) {
    throw FileSystemException(
      'Could not identify the opened archive source.',
      path,
    );
  }

  return (
    mountId: int.parse(mount.group(1)!),
    inode: int.parse(inode.group(1)!),
  );
}

/// Rejects the sentinel returned when descriptor stat lookup fails.
@visibleForTesting
void validateArchiveDescriptorStat(FileStat stat, String path) {
  if (stat.type != FileSystemEntityType.notFound) return;

  throw FileSystemException(
    'Could not identify the opened archive source.',
    path,
  );
}

/// Triggers the platform seek error path using an invalid native handle.
@visibleForTesting
void failNativeArchiveSeekForTesting(String path) {
  if (Platform.isWindows) {
    _WindowsArchiveIo.instance.seek(0, 0, path);
    return;
  }

  _PosixArchiveIo.instance.seek(-1, 0, path);
}

String _windowsExtendedPath(String path) {
  final absolute = p.windows.normalize(p.windows.absolute(path));
  if (absolute.startsWith(r'\\?\')) return absolute;
  if (absolute.startsWith(r'\\')) {
    return '${r'\\?\UNC\'}${absolute.substring(2)}';
  }
  return '${r'\\?\'}$absolute';
}

final class _PosixReadHandle extends AbstractFileHandle {
  _PosixReadHandle(_CreationEntry entry)
    : _path = entry.sourcePath,
      _fileDescriptor = _PosixArchiveIo.instance.openNoFollow(
        entry.sourcePath,
      ) {
    try {
      final details = _PosixArchiveIo.instance.details(
        _fileDescriptor,
        entry.sourcePath,
      );
      if (!details.isRegularFile ||
          details.length != entry.size ||
          details.modified != entry.modified ||
          details.identity != entry.identity) {
        throw _WorkerAbort(
          LocalArchiveErrorKind.conflict,
          'A source file changed while it was being archived.',
          path: entry.sourcePath,
        );
      }
      _length = details.length;
    } on Object {
      _PosixArchiveIo.instance.close(_fileDescriptor);
      _fileDescriptor = -1;
      rethrow;
    }
  }

  _PosixReadHandle.archive(String path, FileStat expected)
    : _path = path,
      _fileDescriptor = _PosixArchiveIo.instance.openNoFollow(path) {
    try {
      final details = _PosixArchiveIo.instance.details(_fileDescriptor, path);
      _validateCreationFileDetails(path, expected, details);
      _length = details.length;
    } on Object {
      _PosixArchiveIo.instance.close(_fileDescriptor);
      _fileDescriptor = -1;
      rethrow;
    }
  }

  final String _path;
  int _fileDescriptor;
  late final int _length;
  int _position = 0;
  final _NativeReadBuffer _buffer = _NativeReadBuffer();

  @override
  int get position => _position;

  @override
  set position(int value) {
    if (!isOpen) throw StateError('Archive source is closed.');
    if (_PosixArchiveIo.instance.seek(_fileDescriptor, value, _path) != value) {
      throw FileSystemException('Could not seek the archive source.', _path);
    }
    _position = value;
  }

  @override
  int get length => _length;

  @override
  bool get isOpen => _fileDescriptor >= 0;

  @override
  bool open({FileAccess mode = FileAccess.read}) => isOpen;

  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() {
    if (!isOpen) return;
    final descriptor = _fileDescriptor;
    _fileDescriptor = -1;
    try {
      _PosixArchiveIo.instance.close(descriptor);
    } finally {
      _buffer.close();
    }
  }

  @override
  int readInto(Uint8List buffer, [int? length]) {
    if (!isOpen) throw StateError('Archive source is closed.');
    _throwIfWorkerCancelled();
    final count = length ?? buffer.length;
    if (count < 0 || count > buffer.length) {
      throw RangeError.range(count, 0, buffer.length, 'length');
    }
    final nativeBuffer = _buffer.acquire(count);
    final bytesRead = readNativeFileFully(count, (offset, remaining) {
      _throwIfWorkerCancelled();
      return _PosixArchiveIo.instance.read(
        _fileDescriptor,
        buffer,
        offset,
        remaining,
        nativeBuffer,
      );
    });
    if (bytesRead < count && _position + bytesRead < _length) {
      throw FileSystemException(
        'Archive source ended before its expected length.',
        _path,
      );
    }
    _position += bytesRead;
    return bytesRead;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    throw UnsupportedError('Archive source handles are read-only.');
  }
}

final class _WindowsReadHandle extends AbstractFileHandle {
  _WindowsReadHandle(_CreationEntry entry)
    : _path = entry.sourcePath,
      _handle = _WindowsArchiveIo.instance.openNoFollow(entry.sourcePath) {
    try {
      final details = _WindowsArchiveIo.instance.details(_handle);
      if (!details.isRegularFile ||
          details.isReparsePoint ||
          details.length != entry.size ||
          details.modified != entry.modified ||
          details.identity != entry.identity) {
        throw _WorkerAbort(
          LocalArchiveErrorKind.conflict,
          'A source file changed while it was being archived.',
          path: entry.sourcePath,
        );
      }
      _length = details.length;
    } on Object {
      _WindowsArchiveIo.instance.close(_handle);
      _handle = 0;
      rethrow;
    }
  }

  _WindowsReadHandle.archive(String path, FileStat expected)
    : _path = path,
      _handle = _WindowsArchiveIo.instance.openNoFollow(path) {
    try {
      final details = _WindowsArchiveIo.instance.details(_handle);
      _validateCreationFileDetails(path, expected, details);
      _length = details.length;
    } on Object {
      _WindowsArchiveIo.instance.close(_handle);
      _handle = 0;
      rethrow;
    }
  }

  final String _path;
  int _handle;
  late final int _length;
  int _position = 0;
  final _NativeReadBuffer _buffer = _NativeReadBuffer();

  @override
  int get position => _position;

  @override
  set position(int value) {
    if (!isOpen) throw StateError('Archive source is closed.');
    _WindowsArchiveIo.instance.seek(_handle, value, _path);
    _position = value;
  }

  @override
  int get length => _length;

  @override
  bool get isOpen => _handle != 0;

  @override
  bool open({FileAccess mode = FileAccess.read}) => isOpen;

  @override
  Future<void> close() async => closeSync();

  @override
  void closeSync() {
    if (!isOpen) return;
    final handle = _handle;
    _handle = 0;
    try {
      _WindowsArchiveIo.instance.close(handle);
    } finally {
      _buffer.close();
    }
  }

  @override
  int readInto(Uint8List buffer, [int? length]) {
    if (!isOpen) throw StateError('Archive source is closed.');
    _throwIfWorkerCancelled();
    final count = length ?? buffer.length;
    if (count < 0 || count > buffer.length) {
      throw RangeError.range(count, 0, buffer.length, 'length');
    }
    final nativeBuffer = _buffer.acquire(count);
    final bytesRead = readNativeFileFully(count, (offset, remaining) {
      _throwIfWorkerCancelled();
      return _WindowsArchiveIo.instance.read(
        _handle,
        buffer,
        offset,
        remaining,
        nativeBuffer,
      );
    });
    if (bytesRead < count && _position + bytesRead < _length) {
      throw FileSystemException(
        'Archive source ended before its expected length.',
        _path,
      );
    }
    _position += bytesRead;
    return bytesRead;
  }

  @override
  void writeFromSync(List<int> buffer, [int start = 0, int? end]) {
    throw UnsupportedError('Archive source handles are read-only.');
  }
}

final class _CreationFileIdentity {
  const _CreationFileIdentity(this.volume, this.file);

  final int volume;
  final int file;

  @override
  bool operator ==(Object other) =>
      other is _CreationFileIdentity &&
      other.volume == volume &&
      other.file == file;

  @override
  int get hashCode => Object.hash(volume, file);
}

final class _CreationFileDetails {
  const _CreationFileDetails({
    required this.length,
    required this.modified,
    required this.isRegularFile,
    required this.isReparsePoint,
    required this.identity,
  });

  final int length;
  final DateTime modified;
  final bool isRegularFile;
  final bool isReparsePoint;
  final _CreationFileIdentity identity;
}

final class _NativeReadBuffer {
  _NativeReadBuffer([this._allocator = calloc]);

  final Allocator _allocator;
  Pointer<Uint8> _pointer = nullptr;
  int _capacity = 0;

  Pointer<Uint8> acquire(int capacity) {
    if (capacity <= _capacity) return _pointer;

    final replacement = _allocator.allocate<Uint8>(capacity);
    final previous = _pointer;
    _pointer = replacement;
    _capacity = capacity;
    if (previous != nullptr) _allocator.free(previous);

    return _pointer;
  }

  void close() {
    if (_pointer == nullptr) return;
    _allocator.free(_pointer);
    _pointer = nullptr;
    _capacity = 0;
  }
}

final class _PosixArchiveIo {
  _PosixArchiveIo._()
    : _open = DynamicLibrary.process().lookupFunction<_OpenNative, _OpenDart>(
        'open',
      ),
      _read = DynamicLibrary.process().lookupFunction<_ReadNative, _ReadDart>(
        'read',
      ),
      _seek = DynamicLibrary.process().lookupFunction<_SeekNative, _SeekDart>(
        Platform.isAndroid ? 'lseek64' : 'lseek',
      ),
      _close = DynamicLibrary.process()
          .lookupFunction<_CloseNative, _CloseDart>('close'),
      _fstat = DynamicLibrary.process()
          .lookupFunction<_FstatNative, _FstatDart>('fstat'),
      _errno = DynamicLibrary.process()
          .lookupFunction<_ErrnoNative, _ErrnoDart>(
            Platform.isMacOS || Platform.isIOS
                ? '__error'
                : Platform.isAndroid
                ? '__errno'
                : '__errno_location',
          );

  static final _PosixArchiveIo instance = _PosixArchiveIo._();

  final _OpenDart _open;
  final _ReadDart _read;
  final _SeekDart _seek;
  final _CloseDart _close;
  final _FstatDart _fstat;
  final _ErrnoDart _errno;

  int openNoFollow(String path) {
    if (!p.isAbsolute(path)) {
      throw FileSystemException('Archive source path is not absolute.', path);
    }
    final nativePath = path.toNativeUtf8();
    try {
      final flags = Platform.isMacOS || Platform.isIOS
          ? _darwinNoFollow | _darwinCloseOnExec | _darwinNonBlocking
          : _linuxFileFlags();
      final descriptor = _retryOpen(nativePath.cast(), flags);
      if (descriptor >= 0) return descriptor;
      throw FileSystemException(
        'Could not safely open the archive source (errno ${_errno().value}).',
        path,
      );
    } finally {
      calloc.free(nativePath);
    }
  }

  int _linuxFileFlags() {
    final usesArmAndroidFlags =
        Platform.isAndroid &&
        (Abi.current() == Abi.androidArm || Abi.current() == Abi.androidArm64);
    final noFollow = usesArmAndroidFlags ? 0x8000 : 0x20000;
    final largeFile = Platform.isAndroid
        ? usesArmAndroidFlags
              ? 0x20000
              : 0x8000
        : 0;
    return noFollow | _posixCloseOnExec | _posixNonBlocking | largeFile;
  }

  int _retryOpen(Pointer<Uint8> path, int flags) {
    while (true) {
      final descriptor = _open(path, flags);
      if (descriptor >= 0 || _errno().value != _posixInterrupted) {
        return descriptor;
      }
    }
  }

  _CreationFileDetails details(int descriptor, String path) {
    final descriptorRoot = Platform.isLinux || Platform.isAndroid
        ? '/proc/self/fd'
        : '/dev/fd';
    final stat = FileStat.statSync('$descriptorRoot/$descriptor');
    validateArchiveDescriptorStat(stat, path);
    final identity = Platform.isLinux || Platform.isAndroid
        ? _linuxIdentity(descriptor, path)
        : _darwinIdentity(descriptor, path);
    return _CreationFileDetails(
      length: stat.size,
      modified: stat.modified,
      isRegularFile: stat.type == FileSystemEntityType.file,
      isReparsePoint: false,
      identity: identity,
    );
  }

  _CreationFileIdentity _linuxIdentity(int descriptor, String path) {
    final info = File('/proc/self/fdinfo/$descriptor').openSync();
    try {
      final bytes = info.readSync(_maximumFdInfoBytes);
      final text = utf8.decode(bytes, allowMalformed: false);
      final identity = parseLinuxFdInfoIdentity(text, path);
      return _CreationFileIdentity(identity.mountId, identity.inode);
    } finally {
      info.closeSync();
    }
  }

  _CreationFileIdentity _darwinIdentity(int descriptor, String path) {
    final stat = calloc<Uint8>(_nativeStatBufferBytes);
    try {
      var result = _fstat(descriptor, stat.cast());
      while (result != 0 && _errno().value == _posixInterrupted) {
        result = _fstat(descriptor, stat.cast());
      }
      if (result != 0) {
        throw FileSystemException(
          'Could not identify the opened archive source '
          '(errno ${_errno().value}).',
          path,
        );
      }
      return _CreationFileIdentity(
        stat.cast<Uint32>().value,
        (stat + 8).cast<Uint64>().value,
      );
    } finally {
      calloc.free(stat);
    }
  }

  int read(
    int descriptor,
    Uint8List buffer,
    int offset,
    int count,
    Pointer<Uint8> nativeBuffer,
  ) {
    if (count == 0) return 0;
    final target = nativeBuffer + offset;
    var result = _read(descriptor, target, count);
    while (result < 0 && _errno().value == _posixInterrupted) {
      result = _read(descriptor, target, count);
    }
    if (result < 0) {
      throw FileSystemException(
        'Could not read the archive source (errno ${_errno().value}).',
      );
    }
    buffer.setRange(offset, offset + result, target.asTypedList(result));
    return result;
  }

  int seek(int descriptor, int position, String path) {
    var result = _seek(descriptor, position, 0);
    while (result < 0 && _errno().value == _posixInterrupted) {
      result = _seek(descriptor, position, 0);
    }
    if (result >= 0) return result;
    throw FileSystemException(
      'Could not seek the archive source (errno ${_errno().value}).',
      path,
    );
  }

  void close(int descriptor) {
    if (_close(descriptor) == 0) return;
    throw FileSystemException(
      'Could not close the archive source (errno ${_errno().value}).',
    );
  }

  bool renameNoReplace(String source, String destination) {
    final sourcePath = source.toNativeUtf8();
    final destinationPath = destination.toNativeUtf8();
    try {
      var result = Platform.isMacOS || Platform.isIOS
          ? _renameDarwin(sourcePath.cast(), destinationPath.cast())
          : _renameLinux(sourcePath.cast(), destinationPath.cast());
      while (result != 0 && _errno().value == _posixInterrupted) {
        result = Platform.isMacOS || Platform.isIOS
            ? _renameDarwin(sourcePath.cast(), destinationPath.cast())
            : _renameLinux(sourcePath.cast(), destinationPath.cast());
      }
      if (result == 0) return true;
      final error = _errno().value;
      if (error == _posixAlreadyExists) return false;
      throw FileSystemException(
        'Could not commit the archive without replacing a destination '
        '(errno $error).',
        destination,
      );
    } finally {
      calloc.free(sourcePath);
      calloc.free(destinationPath);
    }
  }

  int _renameLinux(Pointer<Uint8> source, Pointer<Uint8> destination) {
    if (Platform.isAndroid) {
      return _renameLinuxWithSyscall(source, destination);
    }

    return _invokeLinuxRenameAt2(
      resolveAndInvoke: () {
        final rename = DynamicLibrary.process()
            .lookupFunction<_RenameAt2Native, _RenameAt2Dart>('renameat2');
        return rename(
          _posixCurrentDirectory,
          source,
          _posixCurrentDirectory,
          destination,
          _posixRenameNoReplace,
        );
      },
      invokeSyscall: () => _renameLinuxWithSyscall(source, destination),
    );
  }

  int _renameLinuxWithSyscall(
    Pointer<Uint8> source,
    Pointer<Uint8> destination,
  ) {
    final syscall = DynamicLibrary.process()
        .lookupFunction<_SyscallRenameNative, _SyscallRenameDart>('syscall');
    return syscall(
      _linuxRenameAt2SystemCall(),
      _posixCurrentDirectory,
      source,
      _posixCurrentDirectory,
      destination,
      _posixRenameNoReplace,
    );
  }

  int _linuxRenameAt2SystemCall() => switch (Abi.current()) {
    Abi.androidArm || Abi.linuxArm => _armRenameAt2SystemCall,
    Abi.androidArm64 || Abi.linuxArm64 => _arm64RenameAt2SystemCall,
    Abi.androidIA32 || Abi.linuxIA32 => _ia32RenameAt2SystemCall,
    Abi.androidX64 || Abi.linuxX64 => _x64RenameAt2SystemCall,
    Abi.androidRiscv64 ||
    Abi.linuxRiscv32 ||
    Abi.linuxRiscv64 => _riscvRenameAt2SystemCall,
    _ => throw UnsupportedError('Unsupported Linux archive ABI.'),
  };

  int _renameDarwin(Pointer<Uint8> source, Pointer<Uint8> destination) {
    final rename = DynamicLibrary.process()
        .lookupFunction<_RenameDarwinNative, _RenameDarwinDart>('renamex_np');
    return rename(source, destination, _darwinRenameExclusive);
  }
}

final class _WindowsArchiveIo {
  _WindowsArchiveIo._() : _library = DynamicLibrary.open('kernel32.dll') {
    _createFile = _library.lookupFunction<_CreateFileNative, _CreateFileDart>(
      'CreateFileW',
    );
    _getDetails = _library
        .lookupFunction<_GetFileInformationNative, _GetFileInformationDart>(
          'GetFileInformationByHandleEx',
        );
    _getIdentity = _library
        .lookupFunction<_GetFileIdentityNative, _GetFileIdentityDart>(
          'GetFileInformationByHandle',
        );
    _getSize = _library.lookupFunction<_GetFileSizeNative, _GetFileSizeDart>(
      'GetFileSizeEx',
    );
    _read = _library.lookupFunction<_ReadFileNative, _ReadFileDart>('ReadFile');
    _seek = _library.lookupFunction<_SetFilePointerNative, _SetFilePointerDart>(
      'SetFilePointerEx',
    );
    _close = _library.lookupFunction<_CloseHandleNative, _CloseHandleDart>(
      'CloseHandle',
    );
    _move = _library.lookupFunction<_MoveFileNative, _MoveFileDart>(
      'MoveFileExW',
    );
    _lastError = _library
        .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');
  }

  static final _WindowsArchiveIo instance = _WindowsArchiveIo._();

  final DynamicLibrary _library;
  late final _CreateFileDart _createFile;
  late final _GetFileInformationDart _getDetails;
  late final _GetFileIdentityDart _getIdentity;
  late final _GetFileSizeDart _getSize;
  late final _ReadFileDart _read;
  late final _SetFilePointerDart _seek;
  late final _CloseHandleDart _close;
  late final _MoveFileDart _move;
  late final _GetLastErrorDart _lastError;

  int openNoFollow(String path) {
    final nativePath = _windowsExtendedPath(path).toNativeUtf16();
    try {
      final handle = _createFile(
        nativePath,
        _windowsGenericRead,
        _windowsShareRead | _windowsShareWrite | _windowsShareDelete,
        nullptr,
        _windowsOpenExisting,
        _windowsFileAttributeNormal |
            _windowsOpenReparsePoint |
            _windowsSequentialScan,
        0,
      );
      if (handle != -1 && handle != 0) return handle;
      throw FileSystemException(
        'Could not safely open the archive source '
        '(Windows error ${_lastError()}).',
        path,
      );
    } finally {
      calloc.free(nativePath);
    }
  }

  _CreationFileDetails details(int handle) {
    final basic = calloc<Uint8>(_windowsFileBasicInfoBytes);
    final identity = calloc<Uint8>(_windowsFileInformationBytes);
    final size = calloc<Int64>();
    try {
      if (_getDetails(
                handle,
                _windowsFileBasicInfo,
                basic.cast(),
                _windowsFileBasicInfoBytes,
              ) ==
              0 ||
          _getSize(handle, size) == 0 ||
          _getIdentity(handle, identity.cast()) == 0) {
        throw FileSystemException(
          'Could not inspect the archive source '
          '(Windows error ${_lastError()}).',
        );
      }
      final modifiedFileTime = (basic + 16).cast<Int64>().value;
      final attributes = (basic + 32).cast<Uint32>().value;
      final modifiedMicroseconds =
          (modifiedFileTime ~/ 10) - _windowsFileTimeEpochMicroseconds;
      final volume = (identity + 28).cast<Uint32>().value;
      final fileHigh = (identity + 44).cast<Uint32>().value;
      final fileLow = (identity + 48).cast<Uint32>().value;
      return _CreationFileDetails(
        length: size.value,
        modified: DateTime.fromMicrosecondsSinceEpoch(
          modifiedMicroseconds,
          isUtc: true,
        ).toLocal(),
        isRegularFile: (attributes & _windowsFileAttributeDirectory) == 0,
        isReparsePoint: (attributes & _windowsFileAttributeReparsePoint) != 0,
        identity: _CreationFileIdentity(volume, (fileHigh << 32) | fileLow),
      );
    } finally {
      calloc.free(basic);
      calloc.free(identity);
      calloc.free(size);
    }
  }

  int read(
    int handle,
    Uint8List buffer,
    int offset,
    int count,
    Pointer<Uint8> nativeBuffer,
  ) {
    if (count == 0) return 0;
    final bytesRead = calloc<Uint32>();
    try {
      final target = nativeBuffer + offset;
      if (_read(handle, target.cast(), count, bytesRead, nullptr) == 0) {
        throw FileSystemException(
          'Could not read the archive source '
          '(Windows error ${_lastError()}).',
        );
      }
      buffer.setRange(
        offset,
        offset + bytesRead.value,
        target.asTypedList(bytesRead.value),
      );
      return bytesRead.value;
    } finally {
      calloc.free(bytesRead);
    }
  }

  void seek(int handle, int position, String path) {
    if (_seek(handle, position, nullptr, 0) != 0) return;
    throw FileSystemException(
      'Could not seek the archive source (Windows error ${_lastError()}).',
      path,
    );
  }

  void close(int handle) {
    if (_close(handle) != 0) return;
    throw FileSystemException(
      'Could not close the archive source (Windows error ${_lastError()}).',
    );
  }

  bool renameNoReplace(String source, String destination) {
    final sourcePath = _windowsExtendedPath(source).toNativeUtf16();
    final destinationPath = _windowsExtendedPath(destination).toNativeUtf16();
    try {
      if (_move(sourcePath, destinationPath, _windowsMoveWriteThrough) != 0) {
        return true;
      }
      final error = _lastError();
      if (error == _windowsAlreadyExists || error == _windowsFileExists) {
        return false;
      }
      throw FileSystemException(
        'Could not commit the archive without replacing a destination '
        '(Windows error $error).',
        destination,
      );
    } finally {
      calloc.free(sourcePath);
      calloc.free(destinationPath);
    }
  }
}

typedef _OpenNative = Int32 Function(Pointer<Uint8>, Int32);
typedef _OpenDart = int Function(Pointer<Uint8>, int);
typedef _ReadNative = IntPtr Function(Int32, Pointer<Uint8>, IntPtr);
typedef _ReadDart = int Function(int, Pointer<Uint8>, int);
typedef _SeekNative = Int64 Function(Int32, Int64, Int32);
typedef _SeekDart = int Function(int, int, int);
typedef _CloseNative = Int32 Function(Int32);
typedef _CloseDart = int Function(int);
typedef _FstatNative = Int32 Function(Int32, Pointer<Void>);
typedef _FstatDart = int Function(int, Pointer<Void>);
typedef _ErrnoNative = Pointer<Int32> Function();
typedef _ErrnoDart = Pointer<Int32> Function();
typedef _RenameAt2Native =
    Int32 Function(Int32, Pointer<Uint8>, Int32, Pointer<Uint8>, Uint32);
typedef _RenameAt2Dart =
    int Function(int, Pointer<Uint8>, int, Pointer<Uint8>, int);
typedef _RenameDarwinNative =
    Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32);
typedef _RenameDarwinDart = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _SyscallRenameNative =
    IntPtr Function(
      IntPtr,
      Int32,
      Pointer<Uint8>,
      Int32,
      Pointer<Uint8>,
      Uint32,
    );
typedef _SyscallRenameDart =
    int Function(int, int, Pointer<Uint8>, int, Pointer<Uint8>, int);

typedef _CreateFileNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<Void>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileDart =
    int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int);
typedef _GetFileInformationNative =
    Int32 Function(IntPtr, Int32, Pointer<Void>, Uint32);
typedef _GetFileInformationDart = int Function(int, int, Pointer<Void>, int);
typedef _GetFileIdentityNative = Int32 Function(IntPtr, Pointer<Void>);
typedef _GetFileIdentityDart = int Function(int, Pointer<Void>);
typedef _GetFileSizeNative = Int32 Function(IntPtr, Pointer<Int64>);
typedef _GetFileSizeDart = int Function(int, Pointer<Int64>);
typedef _ReadFileNative =
    Int32 Function(
      IntPtr,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
      Pointer<Void>,
    );
typedef _ReadFileDart =
    int Function(int, Pointer<Void>, int, Pointer<Uint32>, Pointer<Void>);
typedef _SetFilePointerNative =
    Int32 Function(IntPtr, Int64, Pointer<Int64>, Uint32);
typedef _SetFilePointerDart = int Function(int, int, Pointer<Int64>, int);
typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);
typedef _MoveFileNative =
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _MoveFileDart = int Function(Pointer<Utf16>, Pointer<Utf16>, int);
typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();
