import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// D3 reserves every FileSystem-named abstraction, including wrappers.
final _fileSystemDeclaration = RegExp(
  r'\b(?:class|mixin|typedef)\s+\w*FileSystem\w*\b',
);
const _packageDeclaration = 'name: poltergeist_app';
const _bookmarkBackupLoad = 'await errorReporter.guard(bookmarkBackup.load);';
const _catalogLookupBinding = 'serverConfigs.catalogLookup =';
const _checkoutSessionStart = 'final checkoutSession =';
const _persistentSyncDeviceId = 'deviceId: syncEnrollmentState.deviceId,';
const _sharedLocalSyncDeviceId =
    "deviceId: () async => syncEnrollmentState.cachedDeviceId ?? 'local',";
const _failureFreeCancellation =
    'outcome.cancelled && outcome.failures.isEmpty';

void main() {
  test('recognizes reserved filesystem declaration variants', () {
    const declarations = [
      'class FileSystemAdapter {}',
      'mixin CachedFileSystem {}',
      'typedef LocalFileSystemPort = Object;',
    ];

    for (final declaration in declarations) {
      expect(
        _fileSystemDeclaration.hasMatch(declaration),
        isTrue,
        reason: declaration,
      );
    }
  });

  test('declares no app-local filesystem abstraction', () {
    final pubspec = File('pubspec.yaml');
    if (!pubspec.existsSync() ||
        !pubspec.readAsStringSync().contains(_packageDeclaration)) {
      fail('Run this suite from app/poltergeist_app so lib/ can be scanned.');
    }

    final offenders = <String>[];

    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      if (_fileSystemDeclaration.hasMatch(entity.readAsStringSync())) {
        offenders.add(entity.path);
      }
    }

    // D3 reserves the filesystem interface for seance_core.
    expect(offenders, isEmpty);
  });

  test('loads the server catalog before restoring checkouts', () {
    final source = File('lib/main.dart').readAsStringSync();
    final checkoutStart = source.indexOf(_checkoutSessionStart);
    final backupLoad = source.indexOf(_bookmarkBackupLoad);
    final lookupBinding = source.indexOf(_catalogLookupBinding);

    expect(checkoutStart, greaterThanOrEqualTo(0));
    expect(backupLoad, greaterThanOrEqualTo(0));
    expect(lookupBinding, greaterThanOrEqualTo(0));

    // Startup repair may lease immediately, so every route must already
    // resolve through the materialized catalog.
    expect(backupLoad, lessThan(checkoutStart));
    expect(lookupBinding, lessThan(checkoutStart));
  });

  test('sync trash uses the persisted per-install device id', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains(_persistentSyncDeviceId));
    expect(source, isNot(contains(_sharedLocalSyncDeviceId)));
  });

  test('cancelled purge toast does not hide failures', () {
    final source = File(
      'lib/ui/sync/sync_trash_purge_dialog.dart',
    ).readAsStringSync();

    expect(source, contains(_failureFreeCancellation));
  });
}
