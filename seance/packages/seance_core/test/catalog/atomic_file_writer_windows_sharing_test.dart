import 'dart:io';

import 'package:seance_core/catalog.dart';
import 'package:test/test.dart';

void main() {
  test(
    'a rename waits for canonical-path readers to release the target',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'atomic-sharing-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final path = '${directory.path}/store.json';
      await File(path).writeAsString('old');
      final native = IOOverrides.current ?? _NativeIo();
      final readers = _CanonicalReaders();

      await IOOverrides.runZoned(() async {
        await Future.wait([
          for (var i = 0; i < 20; i++)
            const AtomicFileWriter().write(File(path), 'v$i'),
        ]);
      }, createFile: (path) => _SharingFile(native.createFile(path), readers));

      expect(readers.readCount, greaterThan(0));
      expect(await File(path).readAsString(), 'v19');
      expect(directory.listSync().map((entry) => entry.path), [path]);
    },
  );
}

final class _NativeIo extends IOOverrides {}

class _CanonicalReaders {
  int active = 0;
  int readCount = 0;
}

// Dart's Windows GetCanonicalPath opens a FILE_SHARE_READ handle, without
// FILE_SHARE_DELETE. Hold that constraint across a scheduling turn on every
// platform so a concurrent resolution/rename race is deterministic here.
class _SharingFile implements File {
  _SharingFile(this._file, this._readers);

  final File _file;
  final _CanonicalReaders _readers;

  @override
  String get path => _file.path;

  @override
  Uri get uri => _file.uri;

  @override
  File get absolute => _SharingFile(_file.absolute, _readers);

  @override
  Directory get parent => _file.parent;

  @override
  Future<String> resolveSymbolicLinks() async {
    _readers.active++;
    _readers.readCount++;
    try {
      final path = await _file.resolveSymbolicLinks();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return path;
    } finally {
      _readers.active--;
    }
  }

  @override
  Future<File> rename(String newPath) {
    if (_readers.active != 0) {
      throw FileSystemException('Target has a non-delete-sharing reader', path);
    }
    return _file.rename(newPath);
  }

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _file.open(mode: mode);

  @override
  Future<bool> exists() => _file.exists();

  @override
  Future<FileSystemEntity> delete({bool recursive = false}) =>
      _file.delete(recursive: recursive);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
