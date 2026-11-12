import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

void main() {
  test('preparing a parent does not reverse requested snapshots', () async {
    final directory = await Directory.systemTemp.createTemp('parent-order-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/settings.json');
    final native = IOOverrides.current ?? _NativeIo();
    final started = Completer<void>();
    final release = Completer<void>();
    var firstPreparation = true;

    await IOOverrides.runZoned(
      () async {
        final first = writeFileAtomically(file, utf8.encode('first'));
        await started.future;
        final second = writeFileAtomically(file, utf8.encode('second'));
        // The second request can reach the filesystem while the first
        // preparation waits, but it must never commit ahead of that request.
        await Future<void>.delayed(const Duration(milliseconds: 30));
        release.complete();
        await Future.wait([first, second]);
      },
      createDirectory: (path) =>
          _PreparingDirectory(native.createDirectory(path), () async {
            if (!firstPreparation) return;
            firstPreparation = false;
            started.complete();
            await release.future;
          }),
    );

    expect(await file.readAsString(), 'second');
  });
}

final class _NativeIo extends IOOverrides {}

class _PreparingDirectory implements Directory {
  _PreparingDirectory(this._directory, this._beforeCreate);

  final Directory _directory;
  final Future<void> Function() _beforeCreate;

  @override
  String get path => _directory.path;

  @override
  Directory get absolute => _directory.absolute;

  @override
  Future<Directory> create({bool recursive = false}) async {
    await _beforeCreate();
    return _directory.create(recursive: recursive);
  }

  @override
  Future<String> resolveSymbolicLinks() => _directory.resolveSymbolicLinks();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
