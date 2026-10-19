import 'dart:io';

import 'package:flutter/services.dart';
import 'package:planchette_core/planchette_core.dart';

import 'document_store.dart';

/// Android documents are provider URIs, not filesystem paths. The runner gives
/// each URI a stable, named identity; only this boundary reads or writes it.
final class AndroidDocuments implements DocumentStore {
  AndroidDocuments({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('planchette/documents');

  final MethodChannel _channel;

  Future<T?> _invoke<T>(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on PlatformException catch (error) {
      if (error.code == 'document_recovery') {
        throw DocumentRecoveryException(
          error.message ?? 'Restart Planchette to open the recovery copy.',
        );
      }
      throw TextDocumentException(
        error.message ?? 'Android document access failed.',
      );
    }
  }

  Future<String> settingsPath() async =>
      (await _invoke<String>('settingsPath'))!;

  Future<List<String>> recoveries() async =>
      (await _invoke<List<Object?>>('recoveries'))!.cast<String>();

  Future<List<String>> pickOpenFiles() async =>
      (await _invoke<List<Object?>>('open'))!.cast<String>();

  Future<String?> pickSavePath(String suggestedName) =>
      _invoke<String>('create', {'name': suggestedName});

  @override
  Future<String> canonicalSavePath(String path) async => path;

  @override
  Future<FileStamp?> stamp(String path) async {
    final value = await _invoke<Map<Object?, Object?>>('stat', {'path': path});
    if (value == null) return null;
    final modified = value['modified'] as int?;
    // Providers may omit timestamps. Force a digest check on each resume then.
    return (
      modified: modified == null
          ? DateTime.now()
          : DateTime.fromMillisecondsSinceEpoch(modified),
      size: value['size'] as int? ?? 0,
    );
  }

  @override
  Future<String?> existingDigest(String path) =>
      _invoke<String>('digest', {'path': path});

  @override
  Future<bool> isWriteProtected(String path) async =>
      (await _invoke<bool>('readOnly', {'path': path}))!;

  @override
  Future<TextDocument> load(
    String path, {
    SymlinkPolicy symlinkPolicy = SymlinkPolicy.resolveOnce,
  }) async {
    final bytes = (await _invoke<Uint8List>('read', {'path': path}))!;
    return _staged((file) async {
      await file.writeAsBytes(bytes, flush: true);
      final document = await loadTextDocument(
        file,
        symlinkPolicy: symlinkPolicy,
      );
      return document.copyWith(file: File(path));
    });
  }

  @override
  Future<TextDocument> write({
    required String path,
    required String text,
    required TextDocument? source,
    required String? expectedSha256,
    TextDocumentMetadata? metadata,
    DocumentWriteTarget target = DocumentWriteTarget.local,
  }) async {
    if (target != DocumentWriteTarget.local) {
      throw const TextDocumentException(
        'Managed remote copies require the filesystem document store.',
      );
    }
    return _staged((file) async {
      final format =
          metadata ?? source?.metadata ?? const TextDocumentMetadata();
      // Reuse the core's encoding, BOM, binary and size rules before publication.
      final digest = await createTextDocument(
        file,
        text,
        hasUtf8Bom: format.utf8Bom == Utf8Bom.present,
        lineEnding: format.lineEnding,
      );
      await _invoke<void>('write', {
        'path': path,
        'bytes': await file.readAsBytes(),
        'expectedSha256': expectedSha256,
      });
      return TextDocument(
        file: File(path),
        text: text,
        hasUtf8Bom: format.utf8Bom == Utf8Bom.present,
        lineEnding: format.lineEnding,
        sha256: digest,
      );
    });
  }

  Future<T> _staged<T>(Future<T> Function(File file) operation) async {
    final directory = await Directory.systemTemp.createTemp('planchette-');
    try {
      return await operation(File('${directory.path}/document'));
    } finally {
      try {
        await directory.delete(recursive: true);
      } on FileSystemException {
        // Temporary-file cleanup cannot turn a committed save into a failure.
      }
    }
  }
}
