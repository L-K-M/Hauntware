import 'dart:io';

/// Refuses an atomic replacement even when tests run as root. The committed
/// file is held aside until [delete] restores it; in-memory reads still work.
final class AtomicWriteBlocker {
  AtomicWriteBlocker(this.file);

  final File file;
  File get _backup => File('${file.path}.before-test-write');

  Future<AtomicWriteBlocker> create() async {
    if (await exists()) return this;
    if (await file.exists()) await file.rename(_backup.path);
    await Directory(file.path).create(recursive: true);
    await File('${file.path}/block-replacement').writeAsString('');
    return this;
  }

  Future<bool> exists() => Directory(file.path).exists();

  Future<void> delete() async {
    await Directory(file.path).delete(recursive: true);
    if (await _backup.exists()) await _backup.rename(file.path);
  }
}
