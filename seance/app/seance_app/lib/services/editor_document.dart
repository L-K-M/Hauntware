import 'dart:io';

import 'package:planchette_core/planchette_core.dart' as shared;

const builtInEditorMaximumBytes = shared.textDocumentMaximumBytes;
typedef BuiltInEditorException = shared.TextDocumentException;

/// Retains Séance's public metadata shape while the shared package owns all
/// decoding, conflict checks, permissions, and guarded writes.
class BuiltInTextDocument {
  final String text;
  final bool hasUtf8Bom;
  final String lineEnding;
  final String sha256;

  const BuiltInTextDocument({
    required this.text,
    required this.hasUtf8Bom,
    required this.lineEnding,
    required this.sha256,
  });
}

Future<String> loadBuiltInTextDocument(
  File file, {
  int maximumBytes = builtInEditorMaximumBytes,
}) async => (await loadBuiltInTextDocumentDetails(
  file,
  maximumBytes: maximumBytes,
)).text;

Future<BuiltInTextDocument> loadBuiltInTextDocumentDetails(
  File file, {
  int maximumBytes = builtInEditorMaximumBytes,
}) async {
  // The old public loader preserves raw line endings. Managed copies reject
  // links rather than resolving a path outside the checkout's ownership.
  final document = await shared.loadTextDocument(
    file,
    maximumBytes: maximumBytes,
    normalization: shared.TextNormalization.preserve,
  );
  return BuiltInTextDocument(
    text: document.text,
    hasUtf8Bom: document.hasUtf8Bom,
    lineEnding: document.lineEnding == shared.LineEnding.crlf ? '\r\n' : '\n',
    sha256: document.sha256,
  );
}

Future<String> saveBuiltInTextDocument(
  File file,
  String text, {
  bool hasUtf8Bom = false,
  String lineEnding = '\n',
  String? expectedSha256,
  Future<void> Function(File temporary)? observeTemporary,
}) async => shared.saveTextDocument(
  file,
  text,
  hasUtf8Bom: hasUtf8Bom,
  lineEnding: lineEnding == '\r\n'
      ? shared.LineEnding.crlf
      : shared.LineEnding.lf,
  normalization: lineEnding == '\r\n'
      ? shared.TextNormalization.normalize
      : shared.TextNormalization.preserve,
  expectedSha256: expectedSha256 ?? await shared.textDocumentSha256(file),
  temporaryPrefix: '.seance',
  observeTemporary: observeTemporary,
);
