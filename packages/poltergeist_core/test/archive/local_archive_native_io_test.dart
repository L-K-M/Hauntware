import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:poltergeist_core/src/archive/local_archive_service.dart'
    as archive_internals;
import 'package:test/test.dart';

void main() {
  test('native reads continue after short chunks', () {
    final calls = <(int, int)>[];
    final chunks = <int>[2, 1, 2].iterator;

    final total = archive_internals.readNativeFileFully(5, (offset, remaining) {
      calls.add((offset, remaining));
      expect(chunks.moveNext(), isTrue);
      return chunks.current;
    });

    expect(total, 5);
    expect(calls, [(0, 5), (2, 3), (3, 2)]);
  });

  test('native reads stop only when the source reaches EOF', () {
    final calls = <(int, int)>[];
    final chunks = <int>[2, 0].iterator;

    final total = archive_internals.readNativeFileFully(5, (offset, remaining) {
      calls.add((offset, remaining));
      expect(chunks.moveNext(), isTrue);
      return chunks.current;
    });

    expect(total, 2);
    expect(calls, [(0, 5), (2, 3)]);
  });

  test('native buffer keeps its allocation when growth fails', () {
    final allocator = _SecondAllocationFails();

    expect(
      () => archive_internals.resizeNativeReadBufferForTesting(
        allocator,
        initialCapacity: 1,
        replacementCapacity: 2,
      ),
      throwsArgumentError,
    );

    expect(allocator.operations, [
      _AllocationOperation.allocate,
      _AllocationOperation.allocate,
      _AllocationOperation.free,
    ]);
  });

  test('Linux rename uses a resolved renameat2 symbol', () {
    var fallbackCalls = 0;

    final result = archive_internals.invokeLinuxRenameAt2ForTesting(
      resolveAndInvoke: () => 7,
      invokeSyscall: () {
        fallbackCalls++;
        return 11;
      },
    );

    expect(result, 7);
    expect(fallbackCalls, 0);
  });

  test('Linux rename falls back when renameat2 is unavailable', () {
    var fallbackCalls = 0;

    final result = archive_internals.invokeLinuxRenameAt2ForTesting(
      resolveAndInvoke: () => throw ArgumentError('missing renameat2'),
      invokeSyscall: () {
        fallbackCalls++;
        return 11;
      },
    );

    expect(result, 11);
    expect(fallbackCalls, 1);
  });

  for (final truncatedIdentity in <String, String>{
    'mount': 'pos:\t0\nflags:\t0100000\nmnt_id:\t12',
    'inode': 'pos:\t0\nflags:\t0100000\nmnt_id:\t12\nino:\t34',
  }.entries) {
    test('Linux fdinfo rejects a truncated ${truncatedIdentity.key}', () {
      const path = '/archive/source';

      expect(
        () => archive_internals.parseLinuxFdInfoIdentity(
          truncatedIdentity.value,
          path,
        ),
        throwsA(
          isA<FileSystemException>().having(
            (error) => error.path,
            'path',
            path,
          ),
        ),
      );
    });
  }

  test('Linux fdinfo accepts truncation after a complete identity', () {
    const path = '/archive/source';
    const fdInfo =
        'pos:\t0\nflags:\t0100000\nmnt_id:\t12\nino:\t34\nlock:\tpart';

    expect(archive_internals.parseLinuxFdInfoIdentity(fdInfo, path), (
      mountId: 12,
      inode: 34,
    ));
  });

  test('missing descriptor stat reports the archive source path', () {
    const path = '/archive/source';

    expect(
      () => archive_internals.validateArchiveDescriptorStat(
        FileStat.statSync(''),
        path,
      ),
      throwsA(
        isA<FileSystemException>().having((error) => error.path, 'path', path),
      ),
    );
  });

  test('native seek errors report the archive source path', () {
    const path = '/archive/source';

    expect(
      () => archive_internals.failNativeArchiveSeekForTesting(path),
      throwsA(
        isA<FileSystemException>().having((error) => error.path, 'path', path),
      ),
    );
  });
}

enum _AllocationOperation { allocate, free }

final class _SecondAllocationFails implements Allocator {
  final List<_AllocationOperation> operations = <_AllocationOperation>[];
  final Set<int> _freedAddresses = <int>{};
  int _allocationCount = 0;

  @override
  Pointer<T> allocate<T extends NativeType>(int byteCount, {int? alignment}) {
    operations.add(_AllocationOperation.allocate);
    _allocationCount++;
    if (_allocationCount == 2) {
      throw ArgumentError('injected allocation failure');
    }

    return calloc.allocate<T>(byteCount, alignment: alignment);
  }

  @override
  void free(Pointer<NativeType> pointer) {
    operations.add(_AllocationOperation.free);

    // Avoid invoking native free twice when exercising the faulty order.
    if (_freedAddresses.add(pointer.address)) calloc.free(pointer);
  }
}
